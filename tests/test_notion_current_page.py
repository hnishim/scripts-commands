#!/usr/bin/env python3
"""Behavior contract for HIR-11 Notion current-page link copier."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from textwrap import dedent

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "notion-current-page.sh"
AX_SOURCE = ROOT / "notion-current-page-accessibility.m"

URL_MAIN = "https://www.notion.so/0123456789abcdef0123456789abcdef"
URL_SIDE = "https://www.notion.so/fedcba9876543210fedcba9876543210"
URL_APP = "https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?source=copy_link"
SIDE_CHILD_ID = "89abcdef0123456789abcdef01234567"
SIDE_PEEK_URL = (
    "https://app.notion.com/p/example/0123456789abcdef0123456789abcdef"
    f"?p={SIDE_CHILD_ID}&pm=s&source=copy_link"
)
DIRECT_CHILD_URL = f"https://app.notion.com/p/example/{SIDE_CHILD_ID}"


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

    @unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/clang").exists(), "macOS AX helper")
    def test_native_ax_reader_compiles_on_macos(self) -> None:
        self.assertTrue(AX_SOURCE.is_file(), "native AX reader source is required")
        result = subprocess.run(
            [
                "/usr/bin/clang",
                "-fobjc-arc",
                "-fsyntax-only",
                str(AX_SOURCE),
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def ax_snapshot(
        self,
        focused_pane: str,
        *,
        side_peek_open: bool = False,
        main_links: list[str] | None = None,
        side_links: list[str] | None = None,
        main_title: str = "Main database page",
        side_title: str = 'Side & "Peek"',
        side_page_titles: list[str] | None = None,
    ) -> dict:
        nodes = [
            {"id": "window", "parent": None, "role": "AXWindow"},
            {"id": "main-pane", "parent": "window", "role": "AXWebArea", "title": main_title},
            {"id": "main-focus", "parent": "main-pane", "role": "AXStaticText"},
        ]
        side_titles = side_page_titles if side_page_titles is not None else [side_title]
        if side_peek_open:
            nodes.append(
                {"id": "side-peek-scope", "parent": "window", "role": "AXGroup", "title": "Side Peek"}
            )
            for index, title in enumerate(side_titles):
                pane_id = f"side-pane-{index}"
                nodes.append(
                    {"id": pane_id, "parent": "side-peek-scope", "role": "AXWebArea", "title": title}
                )
                if index == 0:
                    nodes.append(
                        {"id": "side-focus", "parent": pane_id, "role": "AXStaticText"}
                    )
        for index, url in enumerate(main_links if main_links is not None else [URL_MAIN]):
            nodes.append({
                "id": f"main-link-{index}",
                "parent": "main-pane",
                "role": "AXLink",
                "title": "Open as full page",
                "url": url,
            })
        if side_peek_open and side_titles:
            for index, url in enumerate(side_links if side_links is not None else [SIDE_PEEK_URL]):
                nodes.append({
                    "id": f"side-link-{index}",
                    "parent": "side-pane-0",
                    "role": "AXLink",
                    "description": "Open in full page",
                    "url": url,
                })
        return {
            "accessibility_tree": {
                "focused_element": "main-focus" if focused_pane == "main" else "side-focus",
                "nodes": nodes,
            }
        }

    def test_side_peek_always_selects_child_title_and_direct_link(self) -> None:
        scenarios = [
            ("main page focused while Side Peek is open", "main"),
            ("Side Peek focused while the main page is open", "side"),
        ]
        for label, focused_pane in scenarios:
            with self.subTest(focus=label):
                result = self.run_command(self.ax_snapshot(focused_pane, side_peek_open=True))
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = self.writer_payload()
                self.assertEqual(payload["title"], 'Side & "Peek"')
                self.assertEqual(payload["url"], DIRECT_CHILD_URL)
                self.assertEqual(payload["plain"], '[Side & "Peek"](' + DIRECT_CHILD_URL + ")")
                self.assertEqual(
                    payload["html"],
                    '<a href="' + DIRECT_CHILD_URL + '">Side &amp; &quot;Peek&quot;</a>',
                )

    def test_normal_page_without_side_peek_keeps_its_own_title_and_url(self) -> None:
        result = self.run_command(self.ax_snapshot("main"))
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["title"], "Main database page")
        self.assertEqual(payload["url"], URL_MAIN)
        self.assertEqual(payload["plain"], "[Main database page](" + URL_MAIN + ")")
        self.assertEqual(payload["html"], '<a href="' + URL_MAIN + '">Main database page</a>')

    def test_side_peek_fragment_is_removed_from_direct_child_link(self) -> None:
        snapshot = self.ax_snapshot(
            "side",
            side_peek_open=True,
            side_links=[SIDE_PEEK_URL + "#child-block"],
        )
        result = self.run_command(snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["title"], 'Side & "Peek"')
        self.assertEqual(payload["url"], DIRECT_CHILD_URL)
        self.assertEqual(payload["plain"], '[Side & "Peek"](' + DIRECT_CHILD_URL + ")")
        self.assertEqual(
            payload["html"],
            '<a href="' + DIRECT_CHILD_URL + '">Side &amp; &quot;Peek&quot;</a>',
        )

    def test_side_peek_invalid_child_url_never_invokes_writer(self) -> None:
        invalid_urls = [
            "https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?pm=s",
            f"https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?p={SIDE_CHILD_ID}&p={SIDE_CHILD_ID}&pm=s",
            "https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?p=not-a-page-id&pm=s",
            f"https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?p={SIDE_CHILD_ID}",
            f"https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?p={SIDE_CHILD_ID}&pm=s&pm=s",
            f"https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?p={SIDE_CHILD_ID}&pm=other",
            f"https://example.com/p/example/0123456789abcdef0123456789abcdef?p={SIDE_CHILD_ID}&pm=s",
            f"https://app.notion.com/other/example/0123456789abcdef0123456789abcdef?p={SIDE_CHILD_ID}&pm=s",
            f"https://app.notion.com/p/example?p={SIDE_CHILD_ID}&pm=s",
            f"https://app.notion.com/p/?p={SIDE_CHILD_ID}&pm=s",
        ]
        cases = [
            ("child region missing", self.ax_snapshot("main", side_peek_open=True, side_page_titles=[])),
            (
                "child region ambiguous",
                self.ax_snapshot(
                    "main",
                    side_peek_open=True,
                    side_page_titles=["First child", "Second child"],
                ),
            ),
            (
                "child title missing",
                self.ax_snapshot("main", side_peek_open=True, side_title=""),
            ),
            ("child link missing", self.ax_snapshot("main", side_peek_open=True, side_links=[])),
        ] + [
            (f"invalid child URL {index}", self.ax_snapshot(
                "main", side_peek_open=True, side_links=[url]
            ))
            for index, url in enumerate(invalid_urls, 1)
        ]
        for label, snapshot in cases:
            with self.subTest(case=label):
                self.writer_log.unlink(missing_ok=True)
                result = self.run_command(snapshot)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.writer_log.exists())

    def test_valid_page_link_in_another_pane_is_never_used_as_fallback(self) -> None:
        cases = [
            self.ax_snapshot("side", side_peek_open=True, side_links=[]),
            self.ax_snapshot("side", side_peek_open=True, side_links=[URL_SIDE, URL_SIDE + "?duplicate=1"]),
        ]
        for snapshot in cases:
            with self.subTest(snapshot=snapshot):
                result = self.run_command(snapshot)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.writer_log.exists())

    def test_app_notion_canonical_url_is_forwarded(self) -> None:
        snapshot = self.ax_snapshot(
            "main", main_title="Canonical app URL page", main_links=[URL_APP]
        )
        result = self.run_command(snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["title"], "Canonical app URL page")
        self.assertEqual(payload["url"], URL_APP)

    def test_invalid_or_ambiguous_source_never_invokes_writer(self) -> None:
        cases = [
            "",
            "{bad json",
            {"regions": []},
            self.ax_snapshot("main", main_title=""),
            self.ax_snapshot("main", main_links=["https://example.com/notion"]),
            self.ax_snapshot("main", main_links=["https://www.notion.so/"]),
            {"accessibility_tree": {"focused_element": "missing", "nodes": []}},
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
        result = self.run_command(
            self.ax_snapshot("main"),
            FAKE_WRITER_EXIT="24",
        )
        self.assertNotEqual(result.returncode, 0)

    def test_writer_contract_contains_escaped_html_and_markdown_representations(self) -> None:
        title = r'A [B] \ C <D & "E">'
        snapshot = self.ax_snapshot("main", main_title=title)
        result = self.run_command(snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["plain"], r'[A \[B\] \\ C <D & "E">](' + URL_MAIN + ")")
        self.assertIn("A [B] \\ C &lt;D &amp; &quot;E&quot;&gt;", payload["html"])
        self.assertIn(URL_MAIN, payload["html"])


if __name__ == "__main__":
    unittest.main()
