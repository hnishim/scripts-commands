import { createHash } from "node:crypto";

export type LinkContent = { html: string; text: string };
export type ParsedNotionUrl = { pageId: string; originalUrl: string };
export type CacheAdapter = {
  get(key: string): string | undefined;
  set(key: string, value: string): void;
  clear(): void;
};
export type LinkCommandOptions = {
  mode: "copy" | "paste";
  input: string | undefined;
  token: string;
  now: () => number;
  cache: CacheAdapter;
  getPage: (pageId: string, token: string) => Promise<unknown>;
  deliver: (content: LinkContent, mode: "copy" | "paste") => Promise<void>;
  notify?: (message: string) => Promise<void>;
};

class LinkError extends Error {
  readonly code: "EMPTY" | "NOT_NOTION" | "MISSING_ID" | "UNSAFE_URL";
  constructor(code: "EMPTY" | "NOT_NOTION" | "MISSING_ID" | "UNSAFE_URL") {
    super(code);
    this.name = "LinkError";
    this.code = code;
  }
}

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32}/gi;
const TTL_MS = 5 * 60 * 1000;
const AUTH_KEY = "__notion_auth_scope";

export function parseNotionUrl(value: string | undefined): ParsedNotionUrl {
  const originalUrl = (value ?? "").trim();
  if (!originalUrl) throw new LinkError("EMPTY");
  if (!/^https:\/\/\S+$/i.test(originalUrl)) throw new LinkError("NOT_NOTION");
  let parsed: URL;
  try {
    parsed = new URL(originalUrl);
  } catch {
    throw new LinkError("NOT_NOTION");
  }
  const host = parsed.hostname.toLowerCase();
  const acceptedHost = host === "notion.so" || host === "www.notion.so" ||
    (host.endsWith(".notion.site") && host !== "notion.site");
  if (parsed.protocol !== "https:" || !acceptedHost || parsed.username || parsed.password) {
    throw new LinkError("NOT_NOTION");
  }
  let last: string | undefined;
  for (const candidate of parsed.pathname.matchAll(UUID)) {
    const index = candidate.index ?? 0;
    const before = parsed.pathname[index - 1] ?? "";
    const after = parsed.pathname[index + candidate[0].length] ?? "";
    if (/[0-9a-f]/i.test(before) || /[0-9a-f]/i.test(after)) continue;
    last = candidate[0];
  }
  if (!last) throw new LinkError("MISSING_ID");
  const compact = last.replace(/-/g, "").toLowerCase();
  const pageId = compact.slice(0, 8) + "-" + compact.slice(8, 12) + "-" +
    compact.slice(12, 16) + "-" + compact.slice(16, 20) + "-" + compact.slice(20);
  return { pageId, originalUrl };
}

export function titleFromPage(page: unknown): string {
  if (typeof page !== "object" || page === null || !("properties" in page)) {
    throw new Error("INVALID_PAGE");
  }
  const properties = page.properties;
  if (typeof properties !== "object" || properties === null) throw new Error("INVALID_PAGE");
  const candidate = Object.values(properties).find((value) =>
    typeof value === "object" && value !== null && "type" in value && value.type === "title");
  if (!candidate || !("title" in candidate) || !Array.isArray(candidate.title)) {
    throw new Error("MISSING_TITLE_PROPERTY");
  }
  const title = candidate.title.map((part: unknown) => {
    if (typeof part !== "object" || part === null || !("plain_text" in part) ||
      typeof part.plain_text !== "string") throw new Error("INVALID_TITLE");
    return part.plain_text;
  }).join("").replace(/\s+/gu, " ").trim();
  return title || "Untitled";
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export function contentForLink(title: string, originalUrl: string): LinkContent {
  const { originalUrl: checkedUrl } = parseNotionUrl(originalUrl);
  // Reject syntax that would make the Markdown fallback point to a different destination.
  if (/[()\\<>\s]/u.test(checkedUrl)) throw new LinkError("UNSAFE_URL");
  const safeTitle = title.replace(/[\\[\]]/g, "\\$&");
  return {
    html: '<a href="' + escapeHtml(checkedUrl) + '">' + escapeHtml(title) + "</a>",
    text: "[" + safeTitle + "](" + checkedUrl + ")",
  };
}

function messageForError(error: unknown): string {
  if (error instanceof LinkError) {
    if (error.code === "EMPTY") return "クリップボードが空です";
    if (error.code === "NOT_NOTION") return "Notion URLがクリップボードにありません";
    if (error.code === "MISSING_ID") return "Notion Page IDを取得できません";
  }
  if (typeof error === "object" && error !== null) {
    if ("status" in error) {
      if (error.status === 401) return "Notionトークンを確認してください";
      if (error.status === 403 || error.status === 404) return "このページをNotion Integrationに共有してください";
      if (error.status === 429) return "Notion APIの利用制限中です";
    }
    if ("name" in error && error.name === "AbortError") return "Notion APIがタイムアウトしました";
  }
  return "Notionページ名を取得できませんでした";
}

export async function runLinkCommand(options: LinkCommandOptions): Promise<{ title: string; content: LinkContent }> {
  try {
    const { pageId, originalUrl } = parseNotionUrl(options.input);
    if (!options.token) throw Object.assign(new Error("MISSING_TOKEN"), { status: 401 });
    const scope = createHash("sha256").update(options.token, "utf8").digest("hex");
    const previousScope = options.cache.get(AUTH_KEY);
    if (previousScope !== scope) {
      options.cache.clear();
      options.cache.set(AUTH_KEY, scope);
    }
    const key = "title:" + scope + ":" + pageId;
    let title: string | undefined;
    const saved = options.cache.get(key);
    if (saved !== undefined) {
      try {
        const cached: unknown = JSON.parse(saved);
        if (typeof cached === "object" && cached !== null && "title" in cached &&
          "fetchedAt" in cached && typeof cached.title === "string" &&
          typeof cached.fetchedAt === "number" &&
          options.now() >= cached.fetchedAt && options.now() - cached.fetchedAt <= TTL_MS) {
          title = cached.title;
        }
      } catch {
        // A corrupt cache entry is a miss, never a synthetic page title.
      }
    }
    if (title === undefined) {
      const page = await options.getPage(pageId, options.token);
      title = titleFromPage(page);
      // A concurrent token switch must not reinstate the prior authorization scope.
      if (options.cache.get(AUTH_KEY) === scope) {
        options.cache.set(key, JSON.stringify({ title, fetchedAt: options.now() }));
      }
    }
    const content = contentForLink(title, originalUrl);
    await options.deliver(content, options.mode);
    return { title, content };
  } catch (error) {
    if (options.notify) await options.notify(messageForError(error));
    throw error;
  }
}
