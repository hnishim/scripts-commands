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
AX_SOURCE="$SCRIPT_DIR/notion-current-page-accessibility.m"
SOURCE="${NOTION_CURRENT_PAGE_SOURCE:-}"
WRITER="${NOTION_CURRENT_PAGE_WRITER:-}"
RAW_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
ERROR_FILE="$(mktemp)"
AX_READER=""
cleanup() {
  rm -f "$RAW_FILE" "$PAYLOAD_FILE" "$ERROR_FILE"
  if [ -n "$AX_READER" ]; then rm -f "$AX_READER"; fi
}
trap cleanup EXIT

if [ -n "$SOURCE" ]; then
  if ! "$SOURCE" >"$RAW_FILE"; then
    echo "現在表示しているNotionページを取得できませんでした。"
    exit 1
  fi
else
  if [ ! -f "$AX_SOURCE" ]; then
    echo "Notionのページ取得補助処理を特定できませんでした。"
    exit 1
  fi
  AX_READER="$(mktemp)"
  if ! /usr/bin/clang -fobjc-arc -framework AppKit -framework ApplicationServices \
      -framework Foundation "$AX_SOURCE" -o "$AX_READER" >"$ERROR_FILE" 2>&1; then
    echo "Notionのページ取得補助処理を準備できませんでした。"
    exit 1
  fi
  if ! "$AX_READER" >"$RAW_FILE" 2>"$ERROR_FILE"; then
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
      notion_not_frontmost) echo "Notionが最前面ではないため、処理を中止しました。" ;;
      notion_process_unavailable) echo "Notionアプリを特定できませんでした。" ;;
      focused_element_missing) echo "Notionのフォーカス中のUI要素を取得できませんでした。" ;;
      accessibility_timeout|page_area_depth_limit) echo "Notionの現在ページを確認できませんでした（探索上限）。" ;;
      page_pair_missing) echo "同一ページ領域のタイトルとURLを取得できないため、処理を中止しました。" ;;
      *) echo "Notionの現在ページを安全に特定できませんでした。" ;;
    esac
    exit 1
  fi
fi

if ! /usr/bin/python3 - "$RAW_FILE" >"$PAYLOAD_FILE" <<'PY'
import html
import json
import pathlib
import re
import sys
from urllib.parse import parse_qsl, quote, unquote, urlsplit, urlunsplit

MAX_NODES = 512
MAX_ANCESTORS = 64

def nonempty_text(value):
    return isinstance(value, str) and bool(value.strip())

def ancestor_ids(node_id, nodes):
    seen = set()
    current = node_id
    for _ in range(MAX_ANCESTORS):
        if current in seen or current not in nodes:
            raise ValueError("invalid tree ancestry")
        seen.add(current)
        yield current
        parent = nodes[current].get("parent")
        if parent is None:
            return
        if not isinstance(parent, str):
            raise ValueError("invalid parent")
        current = parent
    raise ValueError("tree ancestry limit")

def page_open_link(node):
    if node.get("role") != "AXLink":
        return False
    labels = [node.get("title"), node.get("description"), node.get("value")]
    accepted = {"open as full page", "open in full page", "全ページで開く", "フルページで開く"}
    for label in labels:
        if isinstance(label, str):
            normalized = re.sub(r"\s+", " ", label.strip()).casefold()
            if normalized in accepted:
                return True
    return False

def is_side_peek_scope(node):
    labels = [node.get("title"), node.get("description")]
    return any(
        isinstance(label, str)
        and re.sub(r"\s+", " ", label.strip()).casefold() == "side peek"
        for label in labels
    )

def side_peek_child_url(raw_url):
    if not isinstance(raw_url, str):
        raise ValueError("missing Side Peek link URL")
    parsed = urlsplit(raw_url)
    if (parsed.scheme != "https" or parsed.hostname != "app.notion.com"
            or parsed.netloc.casefold() != "app.notion.com"
            or parsed.username is not None or parsed.password is not None
            or parsed.port is not None):
        raise ValueError("invalid Side Peek link host")

    segments = parsed.path.split("/")
    if (len(segments) != 4 or segments[0] != "" or segments[1] != "p"
            or not segments[2] or not segments[3]):
        raise ValueError("invalid Side Peek link path")
    workspace = unquote(segments[2])
    parent_page = unquote(segments[3])
    if (not workspace or not parent_page
            or any(char in workspace + parent_page for char in "/\\")
            or workspace in {".", ".."} or parent_page in {".", ".."}
            or any(ord(char) < 32 or ord(char) == 127 for char in workspace + parent_page)):
        raise ValueError("invalid Notion workspace segment")

    parameters = parse_qsl(parsed.query, keep_blank_values=True)
    child_ids = [value for key, value in parameters if key == "p"]
    side_modes = [value for key, value in parameters if key == "pm"]
    if (len(child_ids) != 1 or re.fullmatch(r"[0-9a-fA-F]{32}", child_ids[0]) is None
            or len(side_modes) != 1 or side_modes[0] != "s"):
        raise ValueError("invalid Side Peek child parameters")

    direct_path = f"/p/{segments[2]}/{child_ids[0]}"
    return urlunsplit(("https", "app.notion.com", direct_path, "", ""))

def resolve_side_peek_page(scope_id, nodes):
    page_areas = []
    scope_links = []
    for node_id, node in nodes.items():
        path = list(ancestor_ids(node_id, nodes))
        if scope_id not in path[1:]:
            continue
        if node.get("role") == "AXWebArea" and nonempty_text(node.get("title")):
            page_areas.append(node_id)
        if page_open_link(node):
            scope_links.append(node_id)

    if len(page_areas) != 1:
        raise ValueError("Side Peek child region missing or ambiguous")
    if len(scope_links) != 1:
        raise ValueError("Side Peek child link missing or ambiguous")

    link = nodes[scope_links[0]]
    title = nodes[page_areas[0]].get("title")
    raw_url = link.get("url", link.get("value"))
    return title, side_peek_child_url(raw_url)

def resolve_focused_page(raw):
    tree = raw.get("accessibility_tree") if isinstance(raw, dict) else None
    if not isinstance(tree, dict):
        raise ValueError("missing accessibility tree")
    items = tree.get("nodes")
    focused_id = tree.get("focused_element")
    if not isinstance(items, list) or not items or len(items) > MAX_NODES:
        raise ValueError("invalid accessibility nodes")
    if not isinstance(focused_id, str):
        raise ValueError("missing focused element")

    nodes = {}
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("invalid accessibility node")
        node_id = item.get("id")
        if not isinstance(node_id, str) or not node_id or node_id in nodes:
            raise ValueError("invalid accessibility node id")
        nodes[node_id] = item
    if focused_id not in nodes:
        raise ValueError("focused element missing from tree")

    side_peek_scopes = [
        node_id for node_id, node in nodes.items() if is_side_peek_scope(node)
    ]
    if len(side_peek_scopes) > 1:
        raise ValueError("Side Peek scope is ambiguous")
    if side_peek_scopes:
        return resolve_side_peek_page(side_peek_scopes[0], nodes)

    focus_path = list(ancestor_ids(focused_id, nodes))
    page_area_id = next(
        (node_id for node_id in focus_path
         if nodes[node_id].get("role") == "AXWebArea" and nonempty_text(nodes[node_id].get("title"))),
        None,
    )
    if page_area_id is None:
        raise ValueError("focused page area missing")

    for scope_id in focus_path[focus_path.index(page_area_id):]:
        scoped = []
        for node_id in nodes:
            if scope_id in ancestor_ids(node_id, nodes):
                scoped.append(node_id)
        page_areas = [
            node_id for node_id in scoped
            if nodes[node_id].get("role") == "AXWebArea" and nonempty_text(nodes[node_id].get("title"))
        ]
        if len(page_areas) > 1:
            break
        links = [node_id for node_id in scoped if page_open_link(nodes[node_id])]
        if len(links) > 1:
            raise ValueError("ambiguous page link")
        if len(links) == 1:
            link = nodes[links[0]]
            title = nodes[page_area_id].get("title")
            raw_url = link.get("url", link.get("value"))
            if page_area_id not in scoped:
                raise ValueError("page area outside selected scope")
            return title, raw_url

    raise ValueError("page link missing from focused pane")

try:
    raw = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    title, raw_url = resolve_focused_page(raw)
    if not isinstance(title, str) or not title.strip() or not isinstance(raw_url, str):
        raise ValueError("missing fields")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in title + raw_url):
        raise ValueError("control character")
    parsed = urlsplit(raw_url)
    if (parsed.scheme != "https" or parsed.hostname not in {"notion.so", "www.notion.so", "app.notion.com"}
            or parsed.username is not None or parsed.password is not None
            or not parsed.path or parsed.path == "/" or parsed.fragment):
        raise ValueError("invalid Notion URL")
    md_url = urlunsplit((parsed.scheme, parsed.netloc, quote(parsed.path, safe="/%:@-._~!$&'*,;=+"),
                         quote(parsed.query, safe="=&%:@-._~!$'*,;+?:/"), ""))
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
  if ! "$AX_READER" --write-pasteboard <"$PAYLOAD_FILE" >/dev/null 2>"$ERROR_FILE"; then
    echo "タイトル付きリンクをクリップボードに保存できませんでした。"
    exit 1
  fi
fi

echo "コピーしました"
