#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Copy Current Notion Page Link
# @raycast.mode silent
# Optional parameters:
# @raycast.icon 🔗
# @raycast.description 現在開いているNotionページのタイトル付きリンクをコピー

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAGE_FILE="$(mktemp)"
trap 'rm -f "$PAGE_FILE"' EXIT

# Only an explicitly identified, open page may become the clipboard source.
# stdout is private page data: never print the source or helper diagnostics.
if ! osascript -l JavaScript "$SCRIPT_DIR/notion-current-page-source.js" >"$PAGE_FILE" 2>/dev/null; then
    echo "現在表示しているNotionページを特定できません。Arcで対象ページを前面にして再実行してください。" >&2
    exit 1
fi

# Fail before calling the (possibly non-validating) pasteboard writer.
# Do not normalize/reconstruct either source field: the writer gets the same record.
if ! python3 - "$PAGE_FILE" <<'PY'
import json
import pathlib
import sys
from urllib.parse import urlsplit

try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"title", "url"}:
        raise ValueError("invalid record")
    title, raw_url = data["title"], data["url"]
    if not isinstance(title, str) or not title.strip() or not isinstance(raw_url, str):
        raise ValueError("missing fields")
    if any(ord(c) < 32 or ord(c) == 127 for c in title + raw_url):
        raise ValueError("control character")
    url = urlsplit(raw_url)
    if (url.scheme != "https" or url.hostname not in ("notion.so", "www.notion.so")
            or url.username is not None or url.password is not None
            or not url.path or url.path == "/" or url.fragment):
        raise ValueError("invalid Notion page URL")
except (ValueError, KeyError, TypeError, UnicodeError, OSError):
    sys.exit(1)
PY
then
    echo "ページのタイトルまたはURLが不正なため、クリップボードは変更していません。" >&2
    exit 1
fi

if ! swift "$SCRIPT_DIR/notion-current-page-pasteboard.swift" --copy <"$PAGE_FILE" >/dev/null 2>/dev/null; then
    echo "タイトル付きリンクをクリップボードに保存できませんでした。" >&2
    exit 1
fi
echo "コピーしました"
