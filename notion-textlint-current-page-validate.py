#!/usr/bin/env python3
"""Validate the private JSON boundary used by the current-page command."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


_PAGE_ID = re.compile(
    r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{32}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(?![0-9A-Fa-f])"
)
_ALLOWED_HOSTS = {"app.notion.com", "notion.so", "www.notion.so"}
_ALLOWED_CONTEXT_KINDS = {"browser", "notion_desktop"}


def _valid_text(value: object) -> bool:
    return isinstance(value, str) and bool(value) and not any(
        ord(character) < 0x20 or ord(character) == 0x7F for character in value
    )


def _normalized_page_ids(value: str) -> list[str]:
    return [match.replace("-", "").lower() for match in _PAGE_ID.findall(value)]


def _canonical_path_page_id(path: str) -> str:
    segments = [segment for segment in path.split("/") if segment]
    if not segments:
        raise ValueError
    candidates = list(dict.fromkeys(_normalized_page_ids(segments[-1])))
    if len(candidates) != 1:
        raise ValueError
    return candidates[0]


def _validate_url(value: object) -> str:
    if not _valid_text(value):
        raise ValueError
    url = value
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in _ALLOWED_HOSTS:
        raise ValueError
    if parsed.username is not None or parsed.password is not None:
        raise ValueError
    try:
        if parsed.port is not None:
            raise ValueError
    except ValueError:
        raise ValueError from None
    if not parsed.path or parsed.path == "/":
        raise ValueError

    canonical_page_id = _canonical_path_page_id(parsed.path)
    full_ids = _normalized_page_ids(url)
    if not full_ids or full_ids[-1] != canonical_page_id:
        raise ValueError

    trailing_ids = _normalized_page_ids(parsed.query) + _normalized_page_ids(parsed.fragment)
    if any(page_id != canonical_page_id for page_id in trailing_ids):
        raise ValueError
    return url


def _extract_url(source_path: str) -> str:
    try:
        payload = json.loads(Path(source_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise ValueError from None
    if not isinstance(payload, dict):
        raise ValueError
    records = payload.get("records")
    if not isinstance(records, list) or len(records) != 1:
        raise ValueError
    record = records[0]
    if not isinstance(record, dict):
        raise ValueError
    context = record.get("context")
    if not isinstance(context, dict):
        raise ValueError
    kind = context.get("kind")
    application = context.get("application")
    if kind not in _ALLOWED_CONTEXT_KINDS or not _valid_text(application):
        raise ValueError
    if kind == "notion_desktop" and application != "Notion":
        raise ValueError
    return _validate_url(record.get("url"))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 2
    try:
        url = _extract_url(argv[1])
    except ValueError:
        return 1
    sys.stdout.write(url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
