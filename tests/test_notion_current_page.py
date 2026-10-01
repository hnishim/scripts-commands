#!/usr/bin/env python3
"""Behavior contract for HIR-11 Notion current-page link copier."""

from __future__ import annotations

import json
import os
import re
import shutil
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
URL_APP = "https://app.notion.com/p/example/0123456789abcdef0123456789abcdef?source=copy_link"


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

    def run_jxa_regions(
        self, regions: list[dict], clipboard_url: str
    ) -> subprocess.CompletedProcess[str]:
        node = shutil.which("node")
        self.assertIsNotNone(node, "node is required to execute the JXA region-selection contract")
        source = SCRIPT.read_text(encoding="utf-8")
        match = re.search(r"<<'JXA'\n(.*?)\nJXA\n", source, re.DOTALL)
        self.assertIsNotNone(match, "the script must keep its JXA source in the checked heredoc")
        harness = r"""
const fs = require("fs");
const input = JSON.parse(fs.readFileSync(0, "utf8"));
function element(spec) {
  return {
    attributes: {
      byName(name) {
        return { value: () => Object.hasOwn(spec.attrs || {}, name) ? spec.attrs[name] : null };
      },
    },
    uiElements() { return (spec.children || []).map(element); },
  };
}
const window = element({
  attrs: { AXRole: "AXWindow" },
  children: input.regions.map((region) => ({
    attrs: { AXRole: "AXWebArea", AXTitle: region.title, AXRoleDescription: "html content" },
    children: region.children || [],
  })),
});
const notion = { exists: () => true, frontmost: () => true, windows: () => [window] };
const audit = { keystrokeCalls: 0, clipboardReads: 0 };
const events = {
  applicationProcesses: { byName: () => notion },
  keystroke() { audit.keystrokeCalls++; },
};
function Application(name) {
  if (name !== "System Events") throw new Error("unexpected application");
  return events;
}
Application.currentApplication = () => ({
  includeStandardAdditions: false,
  doShellScript() { audit.clipboardReads++; return input.clipboardUrl; },
});
globalThis.Application = Application;
globalThis.delay = () => {};
try {
  process.stdout.write(JSON.stringify({ result: eval(input.jxa + "\nrun();"), audit }));
} catch (error) {
  process.stdout.write(JSON.stringify({ result: null, audit }));
  process.stderr.write(String(error.message || error));
  process.exitCode = 1;
}
"""
        return subprocess.run(
            [node, "-e", harness],
            input=json.dumps(
                {"jxa": match.group(1), "regions": regions, "clipboardUrl": clipboard_url}
            ),
            text=True,
            capture_output=True,
        )

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

    def test_jxa_selects_side_peek_region_matching_active_page_url(self) -> None:
        regions = [
            {
                "title": "Right Side Peek page",
                "children": [
                    {
                        "attrs": {"AXRole": "AXGroup"},
                        "children": [{"attrs": {"AXRole": "AXTextField", "AXFocused": True}}],
                    }
                ],
            },
            {"title": "Left database page", "children": []},
        ]
        result = self.run_jxa_regions(regions, URL_SIDE)
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = json.loads(result.stdout)
        payload = json.loads(trace["result"])
        self.assertEqual(
            payload["regions"],
            [{"title": "Right Side Peek page", "url": URL_SIDE, "focused": True}],
        )
        self.assertEqual(trace["audit"], {"keystrokeCalls": 1, "clipboardReads": 1})

    def test_jxa_selects_main_page_when_side_peek_region_is_last(self) -> None:
        regions = [
            {
                "title": "Left database page",
                "children": [
                    {
                        "attrs": {"AXRole": "AXGroup"},
                        "children": [{"attrs": {"AXRole": "AXTextField", "AXFocused": True}}],
                    }
                ],
            },
            {"title": "Right Side Peek page", "children": []},
        ]
        result = self.run_jxa_regions(regions, URL_MAIN)
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = json.loads(result.stdout)
        payload = json.loads(trace["result"])
        self.assertEqual(
            payload["regions"],
            [{"title": "Left database page", "url": URL_MAIN, "focused": True}],
        )
        self.assertEqual(trace["audit"], {"keystrokeCalls": 1, "clipboardReads": 1})

    def test_jxa_refuses_zero_or_multiple_focused_page_regions(self) -> None:
        cases = [
            [
                {"title": "Right Side Peek page", "children": []},
                {"title": "Left database page", "children": []},
            ],
            [
                {
                    "title": "Right Side Peek page",
                    "children": [{"attrs": {"AXFocused": True}}],
                },
                {
                    "title": "Left database page",
                    "children": [{"attrs": {"AXFocused": True}}],
                },
            ],
        ]
        for regions in cases:
            with self.subTest(regions=regions):
                result = self.run_jxa_regions(regions, URL_SIDE)
                self.assertNotEqual(result.returncode, 0)
                trace = json.loads(result.stdout)
                self.assertEqual(trace["audit"], {"keystrokeCalls": 0, "clipboardReads": 0})

    def test_app_notion_canonical_url_is_forwarded(self) -> None:
        snapshot = {
            "regions": [{"title": "Canonical app URL page", "url": URL_APP, "focused": True}]
        }
        result = self.run_command(snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.writer_payload()
        self.assertEqual(payload["title"], snapshot["regions"][0]["title"])
        self.assertEqual(payload["url"], URL_APP)

    def test_jxa_url_gate_allows_app_notion_and_retains_allowlist(self) -> None:
        node = shutil.which("node")
        self.assertIsNotNone(node, "node is required to execute the JXA URL gate contract")
        evaluator = r"""
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const start = source.indexOf("function text");
const end = source.indexOf("function subtreeFocused", start);
if (start < 0 || end < 0) process.exit(2);
eval(source.slice(start, end));
const cases = [
  ["https://app.notion.com/p/example/page?source=copy_link", true],
  ["https://notion.so/example/page", true],
  ["https://www.notion.so/example/page", true],
  ["https://example.com/example/page", false],
  ["https://app.notion.com.evil/example/page", false],
  ["http://app.notion.com/example/page", false],
];
for (const [url, expected] of cases) {
  if (notionURL(url) !== expected) {
    console.error(`${url}: expected ${expected}, got ${notionURL(url)}`);
    process.exit(1);
  }
}
"""
        result = subprocess.run(
            [node, "-e", evaluator, str(SCRIPT)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

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
