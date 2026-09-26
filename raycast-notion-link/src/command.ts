import { Cache, Clipboard, getPreferenceValues, showHUD } from "@raycast/api";
import { runLinkCommand } from "./core";
import type { LinkContent } from "./core";
import { retrieveNotionPage } from "./notion-api";

type Preferences = { notionToken: string };
const cache = new Cache({ namespace: "notion-link-titles" });

export async function perform(mode: "copy" | "paste"): Promise<void> {
  const input = await Clipboard.readText();
  const { notionToken } = getPreferenceValues<Preferences>();
  try {
    const result = await runLinkCommand({
      mode,
      input,
      token: notionToken,
      cache,
      now: () => Date.now(),
      getPage: async (pageId, token) => retrieveNotionPage({ pageId, token }),
      deliver: async (content: LinkContent, requestedMode) => {
        if (requestedMode === "paste") await Clipboard.paste(content);
        else await Clipboard.copy(content);
      },
      notify: async (message) => { await showHUD(message); },
    });
    await showHUD(mode === "paste" ? "🔗 " + result.title : "コピーしました: " + result.title);
  } catch {
    // runLinkCommand already displayed the user-facing error. Never log credentials or page data.
  }
}
