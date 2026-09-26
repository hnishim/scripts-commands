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
sys.stdout.write(os.environ.get("FAKE_PAGE", ""))
sys.exit(int(os.environ.get("FAKE_SOURCE_EXIT", "0")))
""")
        executable(self.writer, r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
payload = sys.stdin.read()
Path(os.environ["WRITER_LOG"]).write_text(payload, encoding="utf-8")
sys.exit(int(os.environ.get("FAKE_WRITER_EXIT", "0")))
""")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_command(self, page: dict | str = "", **extra: str) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "NOTION_CURRENT_PAGE_SOURCE": str(self.source),
            "NOTION_CURRENT_PAGE_WRITER": str(self.writer),
            "WRITER_LOG": str(self.writer_log),
            "FAKE_PAGE": json.dumps(page, ensure_ascii=False) if isinstance(page, dict) else page,
            **extra,
        }
        return subprocess.run(["bash", str(SCRIPT)], text=True, capture_output=True, env=env)

    def writer_payload(self) -> dict:
        return json.loads(self.writer_log.read_text(encoding="utf-8"))

    def test_raycast_script_command_entry_point_exists(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("# @raycast.schemaVersion", text)
        self.assertIn("# @raycast.title", text)

    def test_same_page_title_and_url_are_forwarded_without_reconstruction(self) -> None:
        page = {"title": 'A & "B"', "url": "https://www.notion.so/0123456789abcdef0123456789abcdef"}
        result = self.run_command(page)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["title"], page["title"])
        self.assertEqual(payload["url"], page["url"])

    def test_invalid_or_ambiguous_source_never_invokes_writer(self) -> None:
        cases = [
            "",
            "{bad json",
            {"title": "", "url": "https://www.notion.so/0123456789abcdef0123456789abcdef"},
            {"title": "Page", "url": "https://example.com/notion"},
            {"title": "Page", "url": "https://www.notion.so/"},
            {"title": "Page", "url": "https://www.notion.so/a", "ambiguous": True},
        ]
        for page in cases:
            with self.subTest(page=page):
                self.writer_log.unlink(missing_ok=True)
                result = self.run_command(page)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.writer_log.exists())

    def test_source_failure_never_invokes_writer(self) -> None:
        result = self.run_command("", FAKE_SOURCE_EXIT="23")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.writer_log.exists())

    def test_writer_failure_is_reported_as_failure(self) -> None:
        page = {"title": "Page", "url": "https://www.notion.so/0123456789abcdef0123456789abcdef"}
        result = self.run_command(page, FAKE_WRITER_EXIT="24")
        self.assertNotEqual(result.returncode, 0)

    def test_writer_contract_contains_html_and_markdown_representations(self) -> None:
        page = {"title": '<A & "B">', "url": "https://www.notion.so/0123456789abcdef0123456789abcdef"}
        result = self.run_command(page)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["plain"], f'[{page["title"]}]({page["url"]})')
        self.assertIn("&lt;A &amp; &quot;B&quot;&gt;", payload["html"])
        self.assertIn(page["url"], payload["html"])


if __name__ == "__main__":
    unittest.main()
