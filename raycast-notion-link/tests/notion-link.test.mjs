import test from "node:test";
import assert from "node:assert/strict";
import { parseNotionUrl, titleFromPage, contentForLink, runLinkCommand } from "../src/core.ts";

const id = "0123456789abcdef0123456789abcdef";
const uuid = "01234567-89ab-cdef-0123-456789abcdef";
const url = "https://www.notion.so/Private-" + id + "?pvs=4#heading";
const page = (title) => ({ properties: { Tags: { type: "rich_text", rich_text: [{ plain_text: "not title" }] }, Name: { type: "title", title: [{ plain_text: title }] } } });

test("canonical Notion URLs preserve destination and normalize page ID", () => {
  assert.deepEqual(parseNotionUrl("  " + url + "\n"), { pageId: uuid, originalUrl: url });
  assert.equal(parseNotionUrl("https://team.notion.site/Title-" + uuid).pageId, uuid);
  assert.equal(parseNotionUrl("https://notion.so/" + id).pageId, uuid);
});

test("invalid, ambiguous and non-Notion input is rejected", () => {
  for (const value of ["", "http://notion.so/" + id, "https://notion.so.evil.example/" + id,
    "https://notion.site/" + id, "https://notion.so/missing-id",
    "See " + url, url + " " + url]) {
    assert.throws(() => parseNotionUrl(value), value);
  }
});

test("title is taken from the title property and normalized", () => {
  assert.equal(titleFromPage(page("  日本語 \n 🧪  ")), "日本語 🧪");
  assert.equal(titleFromPage({ properties: { Name: { type: "title", title: [] } } }), "Untitled");
  assert.throws(() => titleFromPage({ properties: { Tags: { type: "rich_text" } } }));
});

test("HTML and Markdown escaping preserve the exact destination", () => {
  const result = contentForLink('A & <B> "C" [D]', url);
  assert.equal(result.html, '<a href="' + url.replace("&", "&amp;") + '">A &amp; &lt;B&gt; &quot;C&quot; [D]</a>');
  assert.equal(result.text, '[A & <B> "C" \\[D\\]](' + url + ')');
  assert.throws(() => contentForLink("Unsafe", "https://notion.so/" + id + "?q=(unsafe)"));
});

function fixture() {
  const cacheData = new Map();
  const writes = [];
  const calls = [];
  let token = "integration-a", currentTime = 100000, deny = false;
  const run = (mode = "copy", input = url) => runLinkCommand({
    mode, input, token, now: () => currentTime,
    cache: { get: (key) => cacheData.get(key), set: (key, value) => cacheData.set(key, value), clear: () => cacheData.clear() },
    getPage: async (pageId, auth) => {
      calls.push({ pageId, auth });
      if (deny || auth === "integration-b") throw Object.assign(new Error("not shared"), { status: 404 });
      return page("Confidential title");
    },
    deliver: async (content, selectedMode) => { writes.push({ content, mode: selectedMode }); },
  });
  return { cacheData, writes, calls, run,
    changeToken: (next) => { token = next; },
    advance: (ms) => { currentTime += ms; },
    deny: () => { deny = true; } };
}

test("copy and paste share HTML/Markdown content and same-token cache", async () => {
  const f = fixture();
  await f.run("copy");
  await f.run("paste");
  assert.deepEqual(f.writes.map((w) => w.mode), ["copy", "paste"]);
  for (const w of f.writes) {
    assert.equal(w.content.text, "[Confidential title](" + url + ")");
    assert.match(w.content.html, /<a href="https:\/\/www\.notion\.so\/Private-/);
  }
  assert.equal(f.calls.length, 1);
});

test("cache TTL expires and API failures cannot change clipboard", async () => {
  const f = fixture();
  await f.run();
  await f.run();
  assert.equal(f.calls.length, 1);
  f.advance(300001);
  await f.run();
  assert.equal(f.calls.length, 2);
  f.deny();
  f.advance(300001);
  await assert.rejects(() => f.run());
  await assert.rejects(() => f.run());
  assert.equal(f.calls.length, 4);
  assert.equal(f.writes.length, 3);
});

test("A to B to A token switch cannot disclose stale titles or reuse old cache", async () => {
  const f = fixture();
  await f.run("copy");
  f.changeToken("integration-b");
  await assert.rejects(() => f.run("paste"));
  assert.equal(f.writes.length, 1);
  assert.equal(f.calls.at(-1).auth, "integration-b");
  f.changeToken("integration-a");
  await f.run("copy");
  assert.equal(f.calls.length, 3);
  assert.equal(f.writes.length, 2);
  for (const [key, value] of f.cacheData) {
    assert.equal(key.includes("integration-a") || key.includes("integration-b"), false);
    assert.equal(value.includes("integration-a") || value.includes("integration-b"), false);
  }
});

test("invalid input never invokes API or changes clipboard", async () => {
  const f = fixture();
  await assert.rejects(() => f.run("paste", "https://example.com/not-notion"));
  assert.equal(f.calls.length, 0);
  assert.equal(f.writes.length, 0);
});
