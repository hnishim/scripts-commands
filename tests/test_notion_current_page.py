"""Behavioral contract for the open-page Notion link Script Command.

The browser/Notion desktop API and the actual macOS pasteboard are local acceptance
boundaries. CI replaces only these external boundaries; it does not assert that
Arc or Notion exposes a particular AppleScript property.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COMMAND = ROOT / "notion-current-page.sh"
PASTEBOARD = ROOT / "notion-current-page-pasteboard.swift"
NOTION_URL = "https://www.notion.so/Team-0123456789abcdef0123456789abcdef?p=1&x=2"


class ScriptCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="hir11-")
        self.addCleanup(self.tmp.cleanup)
        self.temp_dir = Path(self.tmp.name)
        self.fake_bin = self.temp_dir / "bin"
        self.fake_bin.mkdir()
        self.copy_log = self.temp_dir / "copy-invocation"
        self.payload_log = self.temp_dir / "copy-payload"
        self._tool(
            "osascript",
            '#!/bin/sh\n'
            'printf "%s" "$HIR11_PAGE_JSON"\n'
            'exit "${HIR11_SOURCE_STATUS:-0}"\n',
        )
        self._tool(
            "swift",
            '#!/bin/sh\n'
            'printf "%s\\n" "$@" > "$HIR11_COPY_LOG"\n'
            'cat > "$HIR11_PAYLOAD_LOG"\n',
        )

    def _tool(self, name: str, content: str) -> None:
        target = self.fake_bin / name
        target.write_text(content, encoding="utf-8")
        target.chmod(0o755)

    def run_command(self, page: object, source_status: int = 0) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = str(self.fake_bin) + os.pathsep + env.get("PATH", "")
        env["HIR11_PAGE_JSON"] = json.dumps(page, ensure_ascii=False)
        env["HIR11_SOURCE_STATUS"] = str(source_status)
        env["HIR11_COPY_LOG"] = str(self.copy_log)
        env["HIR11_PAYLOAD_LOG"] = str(self.payload_log)
        return subprocess.run(
            ["bash", str(COMMAND)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def test_open_page_is_forwarded_without_guessing_title_or_url(self) -> None:
        page = {"title": "研究 & <概要> [A]", "url": NOTION_URL}
        result = self.run_command(page)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.copy_log.is_file(), "Copy helper was not invoked")
        self.assertEqual(self.copy_log.read_text(encoding="utf-8").splitlines()[-1], "--copy")
        self.assertEqual(
            json.loads(self.payload_log.read_text(encoding="utf-8")),
            page,
            "The copied title and URL must come from the same open-page record",
        )

    def test_source_failure_does_not_invoke_clipboard_writer(self) -> None:
        result = self.run_command({"title": "stale", "url": NOTION_URL}, source_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.copy_log.exists(), "An unavailable page must not change the clipboard")

    def test_script_command_has_a_raycast_entry_point(self) -> None:
        source = COMMAND.read_text(encoding="utf-8")
        self.assertTrue(source.startswith("#!/bin/bash") or source.startswith("#!/usr/bin/env bash"))
        self.assertIn("# @raycast.schemaVersion 1", source)
        self.assertIn("# @raycast.mode silent", source)


class PasteboardContentTests(unittest.TestCase):
    def test_render_contract_and_invalid_inputs(self) -> None:
        """Build the standalone Swift helper once, then exercise its public render mode."""
        with tempfile.TemporaryDirectory(prefix="hir11-swift-") as folder:
            binary = Path(folder) / "notion-link-helper"
            built = subprocess.run(
                ["swiftc", str(PASTEBOARD), "-o", str(binary)],
                text=True,
                capture_output=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(built.returncode, 0, built.stderr)

            def render(page: object) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [str(binary), "--render"],
                    input=json.dumps(page, ensure_ascii=False),
                    text=True,
                    capture_output=True,
                    timeout=10,
                    check=False,
                )

            title = "研究 & <概要> [A] \\ beta"
            result = render({"title": title, "url": NOTION_URL})
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(
                value["html"],
                '<a href="https://www.notion.so/Team-0123456789abcdef0123456789abcdef?p=1&amp;x=2">'
                "研究 &amp; &lt;概要&gt; [A] \\ beta</a>",
            )
            self.assertEqual(
                value["text"],
                r"[研究 & <概要> \[A\] \\ beta](" + NOTION_URL + ")",
            )

            bad_pages = [
                {"title": "", "url": NOTION_URL},
                {"title": "Unrelated site", "url": "https://example.com/"},
                {"title": "Impostor", "url": "https://notion.so.evil.example/a"},
                {"title": "Insecure", "url": "http://www.notion.so/a"},
                {"title": "No page", "url": "https://www.notion.so/"},
                {"title": "Missing URL"},
                {"title": "Missing title", "url": ""},
                {"title": "Unsafe control", "url": NOTION_URL + "\nInjected"},
            ]
            for page in bad_pages:
                with self.subTest(page=page):
                    failed = render(page)
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertEqual(failed.stdout, "")


if __name__ == "__main__":
    unittest.main()
