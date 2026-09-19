#!/usr/bin/env python3
"""Run textlint --fix against a Notion page and write back targeted changes."""

from __future__ import annotations

import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


NOTION_VERSION = "2026-03-11"
UNKNOWN_MARKER = re.compile(r"<unknown(?:\s|/|>)")
PLAIN_ID = re.compile(r"^[0-9A-Fa-f]{32}$")
UUID_ID = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
EMBEDDED_ID = re.compile(
    r"(?<![0-9A-Fa-f])(" 
    r"[0-9A-Fa-f]{32}|"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    r")(?![0-9A-Fa-f])"
)


class NotionTextlintError(RuntimeError):
    """Safe-stop error for the Notion textlint workflow."""


def parse_page_id(value: str) -> str:
    candidate = value.strip()
    if PLAIN_ID.fullmatch(candidate) or UUID_ID.fullmatch(candidate):
        return candidate.replace("-", "").lower()

    matches = EMBEDDED_ID.findall(candidate)
    if not matches:
        raise NotionTextlintError("Notion page URLまたはpage IDを解釈できません。")
    return matches[-1].replace("-", "").lower()


def ntn_executable() -> str:
    executable = shutil.which("ntn")
    if not executable:
        raise NotionTextlintError("ntnコマンドが見つかりません。")
    return executable


def run_ntn(
    page_id: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    command = [
        ntn_executable(),
        "api",
        f"/v1/pages/{page_id}/markdown",
        "--notion-version",
        NOTION_VERSION,
    ]
    if method != "GET":
        command.extend(["-X", method])
    if payload is not None:
        command.extend(["--data", json.dumps(payload, ensure_ascii=False)])

    result = subprocess.run(
        command,
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise NotionTextlintError(f"Notion API {method}に失敗しました{suffix}")

    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise NotionTextlintError("Notion API responseがJSONではありません。") from exc

    if not isinstance(response, dict):
        raise NotionTextlintError("Notion API responseの形式が不正です。")
    if response.get("object") == "error":
        code = response.get("code") or response.get("status") or "unknown"
        raise NotionTextlintError(f"Notion API error: {code}")
    return response


def markdown_from_response(response: dict[str, Any]) -> str:
    if response.get("truncated") is True:
        raise NotionTextlintError("Notion Markdownがtruncatedのため更新しません。")

    unknown_ids = response.get("unknown_block_ids")
    if isinstance(unknown_ids, list) and unknown_ids:
        raise NotionTextlintError("Notion Markdownにunknown blockがあるため更新しません。")

    markdown = response.get("markdown")
    if not isinstance(markdown, str):
        raise NotionTextlintError("Notion Markdown responseにmarkdown文字列がありません。")
    if UNKNOWN_MARKER.search(markdown):
        raise NotionTextlintError("Notion Markdownに<unknown .../>があるため更新しません。")
    return markdown


def fetch_markdown(page_id: str) -> str:
    return markdown_from_response(run_ntn(page_id))


def textlint_binary() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "dotfiles"
        / "textlint"
        / "node_modules"
        / ".bin"
        / "textlint"
    )


def textlint_config() -> Path:
    """Resolve the dotfiles config without copying it into this repository."""
    override = os.environ.get("NOTION_TEXTLINT_CONFIG")
    if override is not None:
        config = Path(override).expanduser()
    else:
        config = (
            Path(__file__).resolve().parents[2]
            / "dotfiles"
            / "textlint"
            / ".textlintrc.json"
        )
    if not config.is_file():
        raise NotionTextlintError(f"textlint configが見つかりません: {config}")
    return config


def run_textlint(markdown: str) -> tuple[str, list[dict[str, Any]]]:
    """Accept a valid fix result even when non-autofixable findings remain."""
    executable = textlint_binary()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise NotionTextlintError(
            f"Application Support側のtextlintを実行できません: {executable}"
        )
    config = textlint_config()

    with tempfile.TemporaryDirectory(prefix="notion-textlint-") as temp_dir:
        target = Path(temp_dir) / "page.md"
        target.write_text(markdown, encoding="utf-8")
        command = [
            str(executable),
            "--config", str(config),
            "--fix", "--format", "json", str(target),
        ]
        try:
            result = subprocess.run(
                command,
                text=True,
                capture_output=True,
                stdin=subprocess.DEVNULL,
            )
        except OSError as exc:
            raise NotionTextlintError("textlintを起動できません。") from exc

        if result.returncode not in (0, 1):
            detail = result.stderr.strip() or result.stdout.strip()
            raise NotionTextlintError(
                f"textlint実行に失敗しました (exit {result.returncode}): {detail}"
            )
        if result.stderr.strip():
            raise NotionTextlintError(
                f"textlintが標準エラー出力を返したため更新しません: {result.stderr.strip()}"
            )
        try:
            reports = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError) as exc:
            raise NotionTextlintError("textlintのJSON結果を解釈できません。") from exc

        if not isinstance(reports, list) or len(reports) != 1:
            raise NotionTextlintError("textlintのJSON結果は単一ファイルである必要があります。")
        report = reports[0]
        if not isinstance(report, dict):
            raise NotionTextlintError("textlintの結果レコードが不正です。")
        file_path = report.get("filePath")
        if not isinstance(file_path, str) or Path(file_path).resolve() != target.resolve():
            raise NotionTextlintError("textlintの結果が別のファイルを参照しています。")
        messages = report.get("messages")
        remaining = report.get("remainingMessages")
        if not isinstance(messages, list) or not isinstance(remaining, list):
            raise NotionTextlintError("textlintの指摘結果が不正です。")
        for message in messages + remaining:
            if (
                not isinstance(message, dict)
                or not isinstance(message.get("ruleId"), str)
                or not isinstance(message.get("message"), str)
            ):
                raise NotionTextlintError("textlintの指摘レコードが不正です。")
        if result.returncode == 1 and not remaining:
            raise NotionTextlintError(
                "textlint終了コード1の原因を未修正指摘として確認できません。"
            )

        try:
            fixed = target.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise NotionTextlintError("修正後の一時Markdownを読めません。") from exc
        output = report.get("output")
        if output is not None:
            if not isinstance(output, str) or output != fixed:
                raise NotionTextlintError(
                    "textlintのJSON修正結果と一時Markdownが一致しません。"
                )
        elif fixed != markdown:
            raise NotionTextlintError(
                "textlintのJSONに修正結果がないのに一時Markdownが変化しました。"
            )
        return fixed, remaining


def _change_groups(
    opcodes: list[tuple[str, int, int, int, int]],
    join_equal_max: int,
) -> list[tuple[int, int]]:
    groups: list[tuple[int, int]] = []
    index = 0
    while index < len(opcodes):
        if opcodes[index][0] == "equal":
            index += 1
            continue

        start = index
        end = index
        while end + 2 < len(opcodes):
            equal_opcode = opcodes[end + 1]
            next_change = opcodes[end + 2]
            if equal_opcode[0] != "equal" or next_change[0] == "equal":
                break
            equal_length = equal_opcode[2] - equal_opcode[1]
            if equal_length > join_equal_max:
                break
            end += 2
        groups.append((start, end))
        index = end + 1
    return groups


def _unique_target_for_group(
    base: str,
    fixed: str,
    opcodes: list[tuple[str, int, int, int, int]],
    group: tuple[int, int],
) -> dict[str, str]:
    start_index, end_index = group
    _, i1, _, j1, _ = opcodes[start_index]
    _, _, i2, _, j2 = opcodes[end_index]

    left_max = 0
    if start_index > 0 and opcodes[start_index - 1][0] == "equal":
        _, pi1, _, pj1, _ = opcodes[start_index - 1]
        left_max = min(i1 - pi1, j1 - pj1)

    right_max = 0
    if end_index + 1 < len(opcodes) and opcodes[end_index + 1][0] == "equal":
        _, _, ni2, _, nj2 = opcodes[end_index + 1]
        right_max = min(ni2 - i2, nj2 - j2)

    for total_context in range(left_max + right_max + 1):
        min_left = max(0, total_context - right_max)
        max_left = min(left_max, total_context)
        for left in range(min_left, max_left + 1):
            right = total_context - left
            old = base[i1 - left : i2 + right]
            if not old or old == base or base.count(old) != 1:
                continue
            new = fixed[j1 - left : j2 + right]
            if old == new:
                continue
            return {"old_str": old, "new_str": new}

    raise NotionTextlintError(
        "変更箇所をページ全文に広げず一意に特定できないため更新しません。"
    )


def _build_updates(
    base: str,
    fixed: str,
    opcodes: list[tuple[str, int, int, int, int]],
    join_equal_max: int,
) -> list[dict[str, str]]:
    updates = [
        _unique_target_for_group(base, fixed, opcodes, group)
        for group in _change_groups(opcodes, join_equal_max)
    ]
    if not updates:
        raise NotionTextlintError("textlint差分からtargeted updateを生成できません。")

    reconstructed = base
    for update in updates:
        old = update["old_str"]
        if reconstructed.count(old) != 1:
            raise NotionTextlintError(
                "targeted updateを安全な順序で適用できないため更新しません。"
            )
        reconstructed = reconstructed.replace(old, update["new_str"], 1)
    if reconstructed != fixed:
        raise NotionTextlintError(
            "targeted updateがtextlint結果を再構成できないため更新しません。"
        )
    return updates


def build_content_updates(base: str, fixed: str) -> list[dict[str, str]]:
    if base == fixed:
        return []

    opcodes = difflib.SequenceMatcher(
        None,
        base,
        fixed,
        autojunk=False,
    ).get_opcodes()

    last_error: NotionTextlintError | None = None
    for join_equal_max in (1, 2, 4, 8, 16):
        try:
            return _build_updates(base, fixed, opcodes, join_equal_max)
        except NotionTextlintError as exc:
            last_error = exc

    assert last_error is not None
    raise last_error


def apply_updates(page_id: str, updates: list[dict[str, str]]) -> None:
    payload = {
        "type": "update_content",
        "update_content": {"content_updates": updates},
    }
    run_ntn(page_id, method="PATCH", payload=payload)


def process_page(target: str) -> None:
    page_id = parse_page_id(target)
    base = fetch_markdown(page_id)
    fixed, remaining = run_textlint(base)
    if remaining:
        rules = ", ".join(sorted({message["ruleId"] for message in remaining}))
        print(f"未自動修正の指摘が残っています: {rules}", file=sys.stderr)
    if fixed == base:
        print("No textlint changes.")
        return

    updates = build_content_updates(base, fixed)

    latest = fetch_markdown(page_id)
    if latest != base:
        raise NotionTextlintError(
            "Notion pageがlint後に変更されたためwriteせず終了します。"
        )

    apply_updates(page_id, updates)

    readback = fetch_markdown(page_id)
    if readback != fixed:
        raise NotionTextlintError(
            "更新後のNotion Markdownが期待したtextlint結果と一致しません。"
        )
    print("Updated Notion page with targeted textlint fixes.")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(
            "Usage: notion-textlint.py <notion-page-url-or-id>",
            file=sys.stderr,
        )
        return 64
    try:
        process_page(argv[1])
    except NotionTextlintError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
