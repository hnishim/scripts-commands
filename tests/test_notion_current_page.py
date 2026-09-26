#!/usr/bin/env python3
"""Behavior contract for HIR-11 Notion current-page link copier."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from textwrap import dedent

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "notion-current-page.sh"

URL_MAIN = "https://www.notion.so/0123456789abcdef0123456789abcdef"
URL_SIDE = "https://www.notion.so/fedcba9876543210fedcba9876543210"


def executable(path: Path, body: str) -> None:
    path.write_text(dedent(body), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class NotionCurrentPageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.writer = self.root / "writer"
        self.writer_log = self.root / "writer.json"
        executable(self.source, r"""#!/usr/bin/env python3
import os, sys
sys.stdout.write(os.environ.get("FAKE_SOURCE_OUTPUT", ""))
sys.exit(int(os.environ.get("FAKE_SOURCE_EXIT", "0")))
""")
        executable(self.writer, r"""#!/usr/bin/env python3
import os, sys
from pathlib import Path
payload = sys.stdin.read()
Path(os.environ["WRITER_LOG"]).write_text(payload, encoding="utf-8")
sys.exit(int(os.environ.get("FAKE_WRITER_EXIT", "0")))
""")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_command(self, source_output: dict | str = "", **extra: str) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "NOTION_CURRENT_PAGE_SOURCE": str(self.source),
            "NOTION_CURRENT_PAGE_WRITER": str(self.writer),
            "WRITER_LOG": str(self.writer_log),
            "FAKE_SOURCE_OUTPUT": (
                json.dumps(source_output, ensure_ascii=False)
                if isinstance(source_output, dict)
                else source_output
            ),
            **extra,
        }
        return subprocess.run([str(SCRIPT)], text=True, capture_output=True, env=env)

    def writer_payload(self) -> dict:
        return json.loads(self.writer_log.read_text(encoding="utf-8"))

    def test_raycast_script_command_entry_point_exists(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("# @raycast.schemaVersion", text)
        self.assertIn("# @raycast.title", text)

    def test_focused_page_region_title_and_url_are_forwarded_as_one_pair(self) -> None:
        snapshot = {
            "regions": [
                {"title": "Main page", "url": URL_MAIN, "focused": False},
                {"title": 'Side & "Peek"', "url": URL_SIDE, "focused": True},
            ]
        }
        result = self.run_command(snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["title"], snapshot["regions"][1]["title"])
        self.assertEqual(payload["url"], snapshot["regions"][1]["url"])

    def test_invalid_or_ambiguous_source_never_invokes_writer(self) -> None:
        cases = [
            "",
            "{bad json",
            {"regions": []},
            {"regions": [{"title": "", "url": URL_MAIN, "focused": True}]},
            {
                "regions": [
                    {"title": "Page", "url": "https://example.com/notion", "focused": True}
                ]
            },
            {
                "regions": [
                    {"title": "Page", "url": "https://www.notion.so/", "focused": True}
                ]
            },
            {
                "regions": [
                    {"title": "Main", "url": URL_MAIN, "focused": True},
                    {"title": "Side", "url": URL_SIDE, "focused": True},
                ]
            },
            {
                "regions": [
                    {"title": "Main", "url": URL_MAIN, "focused": False},
                    {"title": "Side", "url": URL_SIDE, "focused": False},
                ]
            },
        ]
        for source_output in cases:
            with self.subTest(source_output=source_output):
                self.writer_log.unlink(missing_ok=True)
                result = self.run_command(source_output)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.writer_log.exists())

    def test_source_failure_never_invokes_writer(self) -> None:
        result = self.run_command("", FAKE_SOURCE_EXIT="23")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.writer_log.exists())

    def test_writer_failure_is_reported_as_failure(self) -> None:
        snapshot = {
            "regions": [{"title": "Page", "url": URL_MAIN, "focused": True}]
        }
        result = self.run_command(snapshot, FAKE_WRITER_EXIT="24")
        self.assertNotEqual(result.returncode, 0)

    def test_writer_contract_contains_escaped_html_and_markdown_representations(self) -> None:
        title = r'A [B] \ C <D & "E">'
        snapshot = {
            "regions": [{"title": title, "url": URL_MAIN, "focused": True}]
        }
        result = self.run_command(snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["plain"], r'[A \[B\] \\ C <D & "E">](' + URL_MAIN + ")")
        self.assertIn("A [B] \\ C &lt;D &amp; &quot;E&quot;&gt;", payload["html"])
        self.assertIn(URL_MAIN, payload["html"])


if __name__ == "__main__":
    unittest.main()
