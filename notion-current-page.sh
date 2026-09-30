#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Copy Current Notion Page Link
# @raycast.mode silent
# Optional parameters:
# @raycast.icon 🔗
# @raycast.description Notionで表示中のページのタイトル付きリンクをコピー

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${NOTION_CURRENT_PAGE_SOURCE:-}"
WRITER="${NOTION_CURRENT_PAGE_WRITER:-}"
RAW_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
ERROR_FILE="$(mktemp)"
cleanup() { rm -f "$RAW_FILE" "$PAYLOAD_FILE" "$ERROR_FILE"; }
trap cleanup EXIT

if [ -n "$SOURCE" ]; then
  if ! "$SOURCE" >"$RAW_FILE"; then
    echo "現在表示しているNotionページを取得できませんでした。"
    exit 1
  fi
else
  if ! osascript -l JavaScript >"$RAW_FILE" 2>"$ERROR_FILE" <<'JXA'
function attr(element, name) {
    try { return element.attributes.byName(name).value(); } catch (_) { return null; }
}
function text(value) {
    if (value === null || value === undefined) return "";
    try { return String(value).trim(); } catch (_) { return ""; }
}
function children(element) {
    try { return element.uiElements(); } catch (_) { return []; }
}
function notionURL(value) {
    var raw = text(value);
    return /^https:\/\/((www\.)?notion\.so|app\.notion\.com)\/.+/.test(raw);
}
function subtreeFocused(element, withinBudget) {
    function search(node, depth) {
        if (depth > 32 || !withinBudget()) return false;
        var focused = attr(node, "AXFocused");
        if (focused === true || focused === 1 || text(focused).toLowerCase() === "true") return true;
        var items = children(node);
        for (var i = 0; i < items.length; i++) {
            if (search(items[i], depth + 1)) return true;
        }
        return false;
    }
    return search(element, 0);
}
function run() {
    var stage = "find_notion_process";
    var searchStarted = Date.now();
    var visited = 0;
    var searchTimedOut = false;
    function withinBudget() {
        if (Date.now() - searchStarted > 8000 || visited >= 256) {
            searchTimedOut = true;
            return false;
        }
        visited++;
        return true;
    }
    try {
        var events = Application("System Events");
        var notion = events.applicationProcesses.byName("Notion");
        stage = "check_frontmost";
        if (!notion.exists() || !notion.frontmost()) throw new Error("not frontmost");
        var regions = [];
        stage = "discover_page_areas";
        function walk(element, depth) {
        if (depth > 10 || !withinBudget()) return;
            var role = text(attr(element, "AXRole"));
            var roleDescription = text(attr(element, "AXRoleDescription")).toLowerCase();
            if ((role === "AXWebArea" || roleDescription === "html content")
                    && text(attr(element, "AXTitle")) !== "Tab Bar") {
                // System Events does not expose AXURL on Notion's web areas.
                // Keep the element and resolve the URL only after focus is known.
                regions.push({element: element, title: text(attr(element, "AXTitle"))});
                return;
            }
        var items = children(element);
        for (var i = 0; i < items.length && !searchTimedOut; i++) walk(items[i], depth + 1);
        }
        stage = "find_notion_window";
        var windows = notion.windows();
        if (!windows.length) throw new Error("missing Notion window");
        stage = "discover_page_areas";
        walk(windows[windows.length - 1], 0);
        if (searchTimedOut) {
            stage = "accessibility_search_limit";
            throw new Error("accessibility search limit");
        }
        if (!regions.length) {
            stage = "page_areas_missing";
            throw new Error("missing page areas");
        }

        stage = "locate_focused_area";
        var focused = [];
        for (var i = 0; i < regions.length; i++) {
            if (subtreeFocused(regions[i].element, withinBudget)) focused.push(regions[i]);
            if (searchTimedOut) {
                stage = "accessibility_search_limit";
                throw new Error("accessibility search limit");
            }
        }
        if (focused.length !== 1 || !focused[0].title) {
            stage = "focus_not_unique";
            throw new Error("ambiguous current page");
        }
        var active = focused[0];

        // Notion exposes the canonical page URL through its built-in Copy link command,
        // while AXURL is unavailable on the surrounding web area.
        stage = "copy_standard_link";
        events.keystroke("l", {using: ["command down"]});
        delay(0.3);
        stage = "read_copied_url";
        var current = Application.currentApplication();
        current.includeStandardAdditions = true;
        var copied = current.doShellScript("/usr/bin/pbpaste");
        stage = "validate_copied_url";
        var urls = copied.match(/https:\/\/[^\s)]+/g) || [];
        if (urls.length !== 1 || !notionURL(urls[0])) throw new Error("invalid copied URL");
        return JSON.stringify({regions: [{title: active.title, url: urls[0], focused: true}]});
    } catch (_) {
        throw new Error("HIR11_STAGE:" + stage);
    }
}
JXA
  then
    FAILURE_STAGE="$(/usr/bin/python3 - "$ERROR_FILE" <<'PY'
import pathlib
import re
import sys

error_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
match = re.search(r"HIR11_STAGE:([a-z_]+)", error_text)
print(match.group(1) if match else "unknown")
PY
)"
    case "$FAILURE_STAGE" in
      check_frontmost) echo "Notionが最前面ではないため、処理を中止しました。" ;;
      find_notion_process) echo "Notionアプリを特定できませんでした。" ;;
      find_notion_window) echo "Notionのウィンドウを特定できませんでした。" ;;
      page_areas_missing) echo "Notionのページ領域を特定できませんでした。" ;;
      accessibility_search_limit) echo "Notionのページ探索が時間または要素数の上限に達したため停止しました。" ;;
      focus_not_unique) echo "Notionの現在ページを一意に特定できませんでした。" ;;
      locate_focused_area) echo "Notionのフォーカス領域を確認できませんでした。" ;;
      copy_standard_link) echo "Notionの標準リンクコピーを実行できませんでした。" ;;
      read_copied_url|validate_copied_url) echo "Notionの標準リンクURLを確認できませんでした。" ;;
      *) echo "Notionページ情報の取得に失敗しました（詳細不明）。" ;;
    esac
    exit 1
  fi
fi

if ! /usr/bin/python3 - "$RAW_FILE" >"$PAYLOAD_FILE" <<'PY'
import html
import json
import pathlib
import sys
from urllib.parse import quote, urlsplit, urlunsplit

try:
    raw = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    regions = raw.get("regions") if isinstance(raw, dict) else None
    if not isinstance(regions, list):
        raise ValueError("invalid regions")
    focused = [r for r in regions if isinstance(r, dict) and r.get("focused") is True]
    if len(focused) != 1:
        raise ValueError("ambiguous focus")
    region = focused[0]
    title = region.get("title")
    raw_url = region.get("url")
    if not isinstance(title, str) or not title.strip() or not isinstance(raw_url, str):
        raise ValueError("missing fields")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in title + raw_url):
        raise ValueError("control character")
    parsed = urlsplit(raw_url)
    if (parsed.scheme != "https" or parsed.hostname not in {"notion.so", "www.notion.so", "app.notion.com"}
            or parsed.username is not None or parsed.password is not None
            or not parsed.path or parsed.path == "/" or parsed.fragment):
        raise ValueError("invalid Notion URL")
    # Preserve the source URL except for characters that would break a Markdown destination.
    md_url = urlunsplit((parsed.scheme, parsed.netloc, quote(parsed.path, safe="/%:@-._~!$&'*,;=+"),
                         quote(parsed.query, safe="=&%:@-._~!$'*,;+/?:"), ""))
    md_title = title.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
    payload = {
        "title": title,
        "url": raw_url,
        "plain": f"[{md_title}]({md_url})",
        "html": f'<a href="{html.escape(raw_url, quote=True)}">{html.escape(title, quote=True)}</a>',
    }
    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    sys.exit(1)
PY
then
  echo "ページ情報を安全に特定できないため、クリップボードは変更していません。"
  exit 1
fi

if [ -n "$WRITER" ]; then
  if ! "$WRITER" <"$PAYLOAD_FILE"; then
    echo "タイトル付きリンクをクリップボードに保存できませんでした。"
    exit 1
  fi
else
  if ! swift "$SCRIPT_DIR/notion-current-page-pasteboard.swift" <"$PAYLOAD_FILE" >/dev/null 2>/dev/null; then
    echo "タイトル付きリンクをクリップボードに保存できませんでした。"
    exit 1
  fi
fi

echo "コピーしました"
