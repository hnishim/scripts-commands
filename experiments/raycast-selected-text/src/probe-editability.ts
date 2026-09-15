import { Clipboard, getSelectedText, showHUD } from "@raycast/api";

type SelectionOutcome = "resolved" | "rejected";
type PasteOutcome = "not_attempted" | "resolved" | "rejected";

function safeErrorType(error: unknown): string {
  if (error instanceof Error) {
    return error.name || "Error";
  }
  return typeof error;
}

function logOutcome(selection: SelectionOutcome, paste: PasteOutcome, errorType?: string) {
  console.log(
    JSON.stringify({
      probe: "editability",
      selection,
      paste,
      ...(errorType ? { errorType } : {}),
    }),
  );
}

export default async function Command() {
  let selectedText: string;

  try {
    selectedText = await getSelectedText();
  } catch (error) {
    logOutcome("rejected", "not_attempted", safeErrorType(error));
    await showHUD("selection: rejected · paste: not attempted");
    return;
  }

  try {
    // Gate 1 probe only: paste the exact selected text back so the API outcome can
    // be compared on controlled editable vs. non-editable fixtures without
    // storing or transforming user content.
    await Clipboard.paste(selectedText);
    logOutcome("resolved", "resolved");
    await showHUD("selection: resolved · paste: resolved");
  } catch (error) {
    logOutcome("resolved", "rejected", safeErrorType(error));
    await showHUD("selection: resolved · paste: rejected");
  }
}
