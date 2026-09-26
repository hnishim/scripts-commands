export type NotionRequestOptions = {
  pageId: string;
  token: string;
  fetchImpl?: typeof fetch;
  sleep?: (milliseconds: number) => Promise<void>;
  timeoutMs?: number;
};

const NOTION_VERSION = "2026-03-11";
const pause = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

export async function retrieveNotionPage(options: NotionRequestOptions): Promise<unknown> {
  const request = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? pause;
  const timeoutMs = options.timeoutMs ?? 5000;
  for (let attempt = 0; attempt <= 1; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    let result: Response;
    try {
      result = await request("https://api.notion.com/v1/pages/" + encodeURIComponent(options.pageId), {
        method: "GET",
        headers: {
          Authorization: "Bearer " + options.token,
          "Notion-Version": NOTION_VERSION,
          "Content-Type": "application/json",
        },
        signal: controller.signal,
      });
    } catch (error) {
      if (controller.signal.aborted) {
        throw Object.assign(new Error("REQUEST_TIMEOUT"), { name: "AbortError" });
      }
      throw error;
    } finally {
      clearTimeout(timeout);
    }
    if (result.status === 429 && attempt === 0) {
      const raw = result.headers.get("retry-after");
      if (raw !== null && /^(?:\d+)(?:\.\d+)?$/.test(raw.trim())) {
        const seconds = Number(raw);
        if (seconds >= 0 && seconds <= 2) {
          await sleep(seconds * 1000);
          continue;
        }
      }
    }
    if (!result.ok) {
      throw Object.assign(new Error("NOTION_HTTP_ERROR"), { status: result.status });
    }
    return await result.json();
  }
  throw new Error("NOTION_UNEXPECTED_RETRY_STATE");
}
