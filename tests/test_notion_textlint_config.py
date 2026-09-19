#!/usr/bin/env python3
"""Configuration resolution contract for the relocated Notion textlint CLI."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

import test_notion_textlint as base


class NotionTextlintConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = base.NotionTextlintCliTests(
            "test_page_url_is_accepted_and_noop_does_not_patch"
        )
        self.fixture.setUp()

    def tearDown(self) -> None:
        self.fixture.tearDown()

    def invoke(
        self, script: Path, *, override: str | None, expected: Path
    ) -> subprocess.CompletedProcess[str]:
        env = self.fixture.env()
        if override is None:
            env.pop("NOTION_TEXTLINT_CONFIG", None)
        else:
            env["NOTION_TEXTLINT_CONFIG"] = override
        env["FAKE_EXPECTED_TEXTLINT_CONFIG"] = str(expected)
        return subprocess.run(
            [sys.executable, str(script), base.PAGE_ID],
            text=True,
            capture_output=True,
            env=env,
        )

    def sibling_layout(self, *, with_config: bool) -> tuple[Path, Path]:
        dev = self.fixture.root / "Dev with spaces"
        command_dir = dev / "scripts" / "commands"
        command_dir.mkdir(parents=True)
        script = command_dir / "notion-textlint.py"
        shutil.copy2(base.SCRIPT, script)
        config = dev / "dotfiles" / "textlint" / ".textlintrc.json"
        if with_config:
            config.parent.mkdir(parents=True)
            config.write_text("{}\n", encoding="utf-8")
        return script, config

    def test_explicit_config_allows_independent_checkout(self) -> None:
        original = "# Title\n\nNo lint change.\n"
        self.fixture.write_state([base.page(original)])
        result = self.invoke(
            base.SCRIPT,
            override=str(self.fixture.config),
            expected=self.fixture.config,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fixture.patch_calls(), [])
        args = json.loads(self.fixture.textlint_log.read_text(encoding="utf-8"))
        self.assertEqual(
            Path(args[args.index("--config") + 1]).resolve(),
            self.fixture.config.resolve(),
        )

    def test_sibling_dotfiles_config_is_selected_without_override(self) -> None:
        script, config = self.sibling_layout(with_config=True)
        self.fixture.write_state([base.page("# Title\n\nNo lint change.\n")])
        result = self.invoke(script, override=None, expected=config)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fixture.patch_calls(), [])
        args = json.loads(self.fixture.textlint_log.read_text(encoding="utf-8"))
        self.assertEqual(Path(args[args.index("--config") + 1]).resolve(), config.resolve())

    def test_missing_sibling_config_stops_without_write(self) -> None:
        script, config = self.sibling_layout(with_config=False)
        self.fixture.write_state([base.page("# Title\n\nteh value\n")])
        result = self.invoke(script, override=None, expected=config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config", result.stderr.lower())
        self.assertEqual(self.fixture.patch_calls(), [])
        self.assertFalse(self.fixture.textlint_log.exists())

    def test_missing_explicit_config_stops_without_write(self) -> None:
        missing = self.fixture.root / "not-present.json"
        self.fixture.write_state([base.page("# Title\n\nteh value\n")])
        result = self.invoke(base.SCRIPT, override=str(missing), expected=missing)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config", result.stderr.lower())
        self.assertEqual(self.fixture.patch_calls(), [])
        self.assertFalse(self.fixture.textlint_log.exists())

    def test_directory_is_not_accepted_as_config(self) -> None:
        directory = self.fixture.root / "not-a-config-file"
        directory.mkdir()
        self.fixture.write_state([base.page("# Title\n\nteh value\n")])
        result = self.invoke(base.SCRIPT, override=str(directory), expected=directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config", result.stderr.lower())
        self.assertEqual(self.fixture.patch_calls(), [])
        self.assertFalse(self.fixture.textlint_log.exists())


if __name__ == "__main__":
    unittest.main()
