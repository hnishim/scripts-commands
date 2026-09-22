#!/usr/bin/env bash

set -u -o pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/notion-textlint-current-page-validate.py"
SOURCE_SCRIPT="${SCRIPT_DIR}/notion-textlint-current-page-source.js"
SOURCE_HELPER="${SCRIPT_DIR}/notion-textlint-current-page-ax.swift"
SOURCE_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/notion-textlint-current-page.XXXXXX")" || {
    printf '%s\n' '現在表示しているNotionページを取得できませんでした。' >&2
    exit 1
}

cleanup() {
    rm -f -- "${SOURCE_OUTPUT}"
}
trap cleanup EXIT

# The source boundary is intentionally a single read. In particular, do not
# retry through the clipboard or another application after it fails.
if ! HIR282_SOURCE_HELPER="${SOURCE_HELPER}" osascript -l JavaScript "${SOURCE_SCRIPT}" >"${SOURCE_OUTPUT}" 2>/dev/null; then
    printf '%s\n' '現在表示しているNotionページを一意に取得できないため、処理を中止しました。' >&2
    exit 1
fi

PAGE_URL="$(python3 "${VALIDATOR}" "${SOURCE_OUTPUT}")"
if [ "$?" -ne 0 ] || [ -z "${PAGE_URL}" ]; then
    printf '%s\n' '現在表示しているNotionページのURLを安全に検証できないため、処理を中止しました。' >&2
    exit 1
fi

if [ -n "${NOTION_TEXTLINT_CLI:-}" ]; then
    if "${NOTION_TEXTLINT_CLI}" "${PAGE_URL}"; then
        exit 0
    else
        exit "$?"
    fi
fi

if python3 "${SCRIPT_DIR}/notion-textlint.py" "${PAGE_URL}"; then
    exit 0
else
    exit "$?"
fi
