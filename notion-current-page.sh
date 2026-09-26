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
cleanup() { rm -f "$RAW_FILE" "$PAYLOAD_FILE"; }
trap cleanup EXIT

if [ -n "$SOURCE" ]; then
  if ! "$SOURCE" >"$RAW_FILE"; then
    echo "現在表示しているNotionページを取得できませんでした。" >&2
    exit 1
  fi
else
  if ! osascript -l JavaScript >"$RAW_FILE" 2>/dev/null <<'JXA'
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
    return /^https:\/\/(www\.)?notion\.so\/.+/.test(raw);
}
function subtreeFocused(element, depth) {
    if (depth > 80) return false;
    var focused = attr(element, "AXFocused");
    if (focused === true || focused === 1) return true;
    var items = children(element);
    for (var i = 0; i < items.length; i++) {
        if (subtreeFocused(items[i], depth + 1)) return true;
    }
    return false;
}
function regionTitle(element) {
    var direct = text(attr(element, "AXTitle"));
    if (direct) return direct;

    // If the web area itself has no title, accept only one shallowest heading.
    // Ambiguous headings deliberately produce no title rather than guessing.
    var headings = [];
    function visit(node, depth) {
        if (depth > 30) return;
        if (text(attr(node, "AXRole")) === "AXHeading") {
            var value = text(attr(node, "AXValue")) || text(attr(node, "AXTitle"));
            if (value) headings.push({depth: depth, value: value});
        }
        var items = children(node);
        for (var i = 0; i < items.length; i++) visit(items[i], depth + 1);
    }
    visit(element, 0);
    if (!headings.length) return "";
    var minDepth = headings.reduce(function(m, h) { return Math.min(m, h.depth); }, headings[0].depth);
    var values = [];
    headings.forEach(function(h) {
        if (h.depth === minDepth && values.indexOf(h.value) < 0) values.push(h.value);
    });
    return values.length === 1 ? values[0] : "";
}
function run() {
    try {
        var events = Application("System Events");
        var notion = events.applicationProcesses.byName("Notion");
        if (!notion.exists() || !notion.frontmost()) throw new Error("not frontmost");
        var regions = [];
        var visited = 0;
        function walk(element, depth) {
            if (depth > 80 || visited++ > 12000) return;
            var role = text(attr(element, "AXRole"));
            var roleDescription = text(attr(element, "AXRoleDescription")).toLowerCase();
            var url = text(attr(element, "AXURL"));
            if ((role === "AXWebArea" || roleDescription === "html content") && notionURL(url)) {
                regions.push({title: regionTitle(element), url: url, focused: subtreeFocused(element, 0)});
                return;
            }
            var items = children(element);
            for (var i = 0; i < items.length; i++) walk(items[i], depth + 1);
        }
        var windows = notion.windows();
        for (var i = 0; i < windows.length; i++) walk(windows[i], 0);
        return JSON.stringify({regions: regions});
    } catch (_) {
        throw new Error("Notion page accessibility lookup failed");
    }
}
JXA
  then
    echo "現在表示しているNotionページを取得できませんでした。" >&2
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
    if (parsed.scheme != "https" or parsed.hostname not in {"notion.so", "www.notion.so"}
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
  echo "ページ情報を安全に特定できないため、クリップボードは変更していません。" >&2
  exit 1
fi

if [ -n "$WRITER" ]; then
  if ! "$WRITER" <"$PAYLOAD_FILE"; then
    echo "タイトル付きリンクをクリップボードに保存できませんでした。" >&2
    exit 1
  fi
else
  if ! swift "$SCRIPT_DIR/notion-current-page-pasteboard.swift" <"$PAYLOAD_FILE" >/dev/null 2>/dev/null; then
    echo "タイトル付きリンクをクリップボードに保存できませんでした。" >&2
    exit 1
  fi
fi

echo "コピーしました"
