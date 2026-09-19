import test from "node:test";
import assert from "node:assert/strict";
import { retrieveNotionPage } from "../src/notion-api.ts";

const pageId = "01234567-89ab-cdef-0123-456789abcdef";
const token = "test-integration-token";
const page = { object: "page", id: pageId, properties: { title: { type: "title", title: [] } } };
const response = (status, body, retryAfter) => ({
  ok: status >= 200 && status < 300,
  status,
  headers: { get: (name) => name.toLowerCase() === "retry-after" ? retryAfter ?? null : null },
  json: async () => body,
});

test("page lookup uses bearer authentication, pinned API version, and page ID only", async () => {
  let called = 0;
  const result = await retrieveNotionPage({
    pageId, token,
    fetchImpl: async (endpoint, options) => {
      called++;
      assert.equal(endpoint, "https://api.notion.com/v1/pages/" + pageId);
      assert.equal(options.headers.Authorization, "Bearer " + token);
      assert.equal(options.headers["Notion-Version"], "2026-03-11");
      assert.ok(options.signal);
      return response(200, page);
    },
  });
  assert.deepEqual(result, page);
  assert.equal(called, 1);
});

test("401/403/404/500 and malformed JSON are errors, never implicit titles or retries", async () => {
  for (const status of [401, 403, 404, 500]) {
    let attempts = 0;
    await assert.rejects(() => retrieveNotionPage({
      pageId, token, fetchImpl: async () => { attempts++; return response(status, { code: "failure" }); },
    }));
    assert.equal(attempts, 1, "status " + status);
  }
  await assert.rejects(() => retrieveNotionPage({
    pageId, token,
    fetchImpl: async () => ({ ...response(200, page), json: async () => { throw new SyntaxError("bad JSON"); } }),
  }));
});

test("429 retries exactly once only when Retry-After is between 0 and 2 seconds", async () => {
  let attempts = 0;
  const sleeps = [];
  const result = await retrieveNotionPage({
    pageId, token,
    fetchImpl: async () => ++attempts === 1 ? response(429, { code: "rate_limited" }, "1") : response(200, page),
    sleep: async (ms) => { sleeps.push(ms); },
  });
  assert.deepEqual(result, page);
  assert.equal(attempts, 2);
  assert.deepEqual(sleeps, [1000]);
  for (const retryAfter of ["3", "invalid", null]) {
    let count = 0;
    await assert.rejects(() => retrieveNotionPage({
      pageId, token,
      fetchImpl: async () => { count++; return response(429, {}, retryAfter); },
      sleep: async () => { throw new Error("must not sleep"); },
    }));
    assert.equal(count, 1);
  }
});

test("timeout aborts the request rather than leaving an unresolved operation", async () => {
  let aborted = false;
  await assert.rejects(() => retrieveNotionPage({
    pageId, token, timeoutMs: 10,
    fetchImpl: async (_endpoint, options) => new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => {
        aborted = true;
        reject(Object.assign(new Error("Aborted"), { name: "AbortError" }));
      }, { once: true });
    }),
  }));
  assert.equal(aborted, true);
});
