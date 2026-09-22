"""Behavioral contract for the HIR-282 current-page textlint entry point.

The macOS page-source boundary is intentionally injected here.  These tests
verify the safety boundary after acquisition: one stable source record, strict
Notion URL validation, one call to the existing CLI, and no clipboard or stale
value fallback.  They do not claim that an accessibility API or a real Notion
session works; that remains local acceptance.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from textwrap import dedent


ROOT = Path(__file__).resolve().parents[1]
COMMAND = ROOT / "notion-textlint-current-page.sh"
PAGE_ID = "0123456789abcdef0123456789abcdef"
PAGE_URL = f"https://app.notion.com/p/molcure/Test-{PAGE_ID}#main"


class CurrentPageCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="hir282-")
        self.addCleanup(self.tmp.cleanup)
        self.temp_dir = Path(self.tmp.name)
        self.fake_bin = self.temp_dir / "bin"
        self.fake_bin.mkdir()
        self.source_log = self.temp_dir / "source-invocation"
        self.cli_log = self.temp_dir / "cli-invocation"
        self.clipboard_log = self.temp_dir / "clipboard-invocation"
        self._tool(
            "osascript",
            '#!/bin/sh\n'
            'printf "called\\n" >> "$HIR282_SOURCE_LOG"\n'
            'printf "%s\\n" "$@" >> "$HIR282_SOURCE_LOG"\n'
            'printf "%s" "$HIR282_SOURCE_JSON"\n'
            'exit "${HIR282_SOURCE_STATUS:-0}"\n',
        )
        self._tool(
            "pbpaste",
            '#!/bin/sh\n'
            'printf "invoked\\n" > "$HIR282_CLIPBOARD_LOG"\n'
            'printf "%s" "$HIR282_STALE_SOURCE_JSON"\n',
        )

        self.fake_cli = self.temp_dir / "fake-notion-textlint.py"
        self.fake_cli.write_text(
            dedent(
                """
                #!/usr/bin/env python3
                import json
                import os
                import sys
                from pathlib import Path

                with Path(os.environ["HIR282_CLI_LOG"]).open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(sys.argv[1:]) + "\\n")
                sys.exit(int(os.environ.get("HIR282_CLI_STATUS", "0")))
                """
            ).lstrip(),
            encoding="utf-8",
        )
        self.fake_cli.chmod(0o755)

    def _tool(self, name: str, content: str) -> None:
        target = self.fake_bin / name
        target.write_text(content, encoding="utf-8")
        target.chmod(0o755)

    def context(self, *, kind: str = "browser", application: str = "Zen") -> dict:
        return {
            "context": {
                "kind": kind,
                "application": application,
                "window_id": "window-1",
                "tab_id": "tab-1",
            },
            "url": PAGE_URL,
        }

    def source_json(self, *records: dict) -> str:
        return json.dumps({"records": list(records)}, ensure_ascii=False)

    def run_command(
        self,
        *records: dict,
        source_status: int = 0,
        cli_status: int = 0,
        stale_source: dict | None = None,
        raw_source_json: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = str(self.fake_bin) + os.pathsep + env.get("PATH", "")
        env["HIR282_SOURCE_JSON"] = (
            raw_source_json if raw_source_json is not None else self.source_json(*records)
        )
        env["HIR282_SOURCE_STATUS"] = str(source_status)
        env["HIR282_SOURCE_LOG"] = str(self.source_log)
        env["HIR282_CLI_LOG"] = str(self.cli_log)
        env["HIR282_CLI_STATUS"] = str(cli_status)
        env["HIR282_CLIPBOARD_LOG"] = str(self.clipboard_log)
        env["HIR282_STALE_SOURCE_JSON"] = json.dumps(stale_source or {}, ensure_ascii=False)
        env["NOTION_TEXTLINT_CLI"] = str(self.fake_cli)
        return subprocess.run(
            ["bash", str(COMMAND)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def assert_not_called(self) -> None:
        self.assertFalse(self.cli_log.exists(), "The existing CLI must not be called")
        self.assertFalse(
            self.clipboard_log.exists(),
            "The command must not use the clipboard as a fallback source",
        )

    def cli_calls(self) -> list[list[str]]:
        if not self.cli_log.exists():
            return []
        return [
            json.loads(line)
            for line in self.cli_log.read_text(encoding="utf-8").splitlines()
        ]

    def source_calls(self) -> int:
        if not self.source_log.exists():
            return 0
        return self.source_log.read_text(encoding="utf-8").splitlines().count("called")

    def test_browser_page_is_forwarded_once_without_reconstruction(self) -> None:
        record = self.context()

        result = self.run_command(record)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.source_log.is_file(), "The page source must be invoked")
        self.assertEqual(self.source_calls(), 1)
        self.assertEqual(self.cli_calls(), [[PAGE_URL]])

    def test_notion_desktop_page_is_forwarded_once(self) -> None:
        record = self.context(kind="notion_desktop", application="Notion")

        result = self.run_command(record)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.source_calls(), 1)
        self.assertEqual(self.cli_calls(), [[PAGE_URL]])

    def test_source_failure_does_not_call_cli_or_clipboard(self) -> None:
        result = self.run_command(self.context(), source_status=23)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.source_log.is_file(), "The source boundary must be exercised")
        self.assertEqual(self.source_calls(), 1)
        self.assert_not_called()

    def test_malformed_or_empty_source_does_not_use_stale_value(self) -> None:
        cases = [
            ("malformed JSON", "{not-json"),
            ("no records", json.dumps({"records": []})),
            ("multiple records", self.source_json(self.context(), self.context(application="Arc"))),
        ]
        stale = self.context(application="StaleBrowser")
        for description, raw_json in cases:
            with self.subTest(source=description):
                self.source_log.unlink(missing_ok=True)
                self.cli_log.unlink(missing_ok=True)
                self.clipboard_log.unlink(missing_ok=True)
                result = self.run_command(
                    source_status=0,
                    stale_source=stale,
                    raw_source_json=raw_json,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.source_calls(), 1)
                self.assert_not_called()

    def test_invalid_notion_urls_are_rejected_before_cli(self) -> None:
        invalid_urls = [
            "https://example.com/p/" + PAGE_ID,
            "https://notion.so.evil.example/p/" + PAGE_ID,
            "http://app.notion.com/p/" + PAGE_ID,
            "https://user:password@app.notion.com/p/" + PAGE_ID,
            "https://app.notion.com/",
            "https://app.notion.com/p/without-a-page-id",
            "https://app.notion.com/p/" + PAGE_ID + "\nInjected",
        ]
        for url in invalid_urls:
            with self.subTest(url=url):
                record = self.context()
                record["url"] = url
                result = self.run_command(record)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.source_calls(), 1)
                self.assert_not_called()

    def test_missing_or_ambiguous_context_is_rejected(self) -> None:
        cases = [
            {"url": PAGE_URL},
            {"context": self.context()["context"], "url": ""},
            {
                **self.context(),
                "context": {**self.context()["context"], "kind": "unknown"},
            },
            {
                **self.context(kind="notion_desktop", application="Zen"),
            },
        ]
        for record in cases:
            with self.subTest(record=record):
                result = self.run_command(record)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.source_calls(), 1)
                self.assert_not_called()

    def test_cli_failure_is_propagated_without_success_report(self) -> None:
        result = self.run_command(self.context(), cli_status=17)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.source_calls(), 1)
        self.assertEqual(self.cli_calls(), [[PAGE_URL]])
        self.assertNotIn("成功", result.stdout + result.stderr)

    def test_diagnostics_do_not_echo_page_body_or_credentials(self) -> None:
        record = self.context()
        record["page_body"] = "PRIVATE-PAGE-BODY"
        record["access_token"] = "PRIVATE-AUTH-TOKEN"

        result = self.run_command(record)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("PRIVATE-PAGE-BODY", result.stdout + result.stderr)
        self.assertNotIn("PRIVATE-AUTH-TOKEN", result.stdout + result.stderr)

    def test_existing_manual_cli_entry_point_remains_available(self) -> None:
        self.assertTrue((ROOT / "notion-textlint.py").is_file())


if __name__ == "__main__":
    unittest.main()
