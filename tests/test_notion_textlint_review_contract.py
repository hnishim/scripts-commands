#!/usr/bin/env python3
'''Regression tests added after HIR-101 Test Review findings.'''

from __future__ import annotations

import json
import unittest
from textwrap import dedent

import test_notion_textlint as base


class NotionTextlintReviewContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = base.NotionTextlintCliTests(
            "test_page_url_is_accepted_and_noop_does_not_patch"
        )
        self.fixture.setUp()

    def tearDown(self) -> None:
        self.fixture.tearDown()

    def test_targeted_update_does_not_replace_entire_page(self) -> None:
        original = (
            "# Title\n\n"
            "UNRELATED-TOP\n\n"
            "teh value\n\n"
            "UNRELATED-BOTTOM\n"
        )
        fixed = original.replace("teh value", "the value")
        self.fixture.write_state(
            [base.page(original), base.page(original), base.page(fixed)],
            patch_response=base.page(fixed),
        )

        result = self.fixture.run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        patches = self.fixture.patch_calls()
        self.assertEqual(len(patches), 1)
        updates = patches[0]["data"]["update_content"]["content_updates"]
        self.assertGreaterEqual(len(updates), 1)

        reconstructed = original
        for update in updates:
            old = update["old_str"]
            new = update["new_str"]
            self.assertNotEqual(old, new)
            self.assertNotEqual(old, original)
            self.assertNotEqual(new, fixed)
            for marker in ("UNRELATED-TOP", "UNRELATED-BOTTOM"):
                self.assertNotIn(
                    marker,
                    old,
                    f"target old_str must not include distant unchanged region {marker}",
                )
                self.assertNotIn(
                    marker,
                    new,
                    f"target new_str must not include distant unchanged region {marker}",
                )
            self.assertEqual(reconstructed.count(old), 1)
            reconstructed = reconstructed.replace(old, new, 1)
        self.assertEqual(reconstructed, fixed)

    def test_patch_api_failures_do_not_retry_or_fallback(self) -> None:
        original = "# Title\n\nteh value\n"
        cases = [
            {
                "object": "error",
                "status": 403,
                "code": "restricted_resource",
                "message": "permission denied",
            },
            {
                "object": "error",
                "status": 409,
                "code": "conflict_error",
                "message": "conflict",
            },
            {
                "object": "error",
                "status": 400,
                "code": "validation_error",
                "message": "synced content cannot be updated through markdown",
            },
        ]
        for error in cases:
            with self.subTest(error=error):
                self.fixture.write_state(
                    [base.page(original), base.page(original)],
                    patch_exit=1,
                    patch_response=error,
                )
                self.fixture.textlint_log.unlink(missing_ok=True)

                result = self.fixture.run_cli()

                self.assertNotEqual(result.returncode, 0)
                calls = self.fixture.ntn_calls()
                self.assertEqual(
                    [call["method"] for call in calls],
                    ["GET", "GET", "PATCH"],
                )
                patches = self.fixture.patch_calls()
                self.assertEqual(len(patches), 1)
                self.assertEqual(patches[0]["data"]["type"], "update_content")
                self.assertTrue(self.fixture.textlint_log.exists())

    def test_initial_get_api_failure_stops_before_lint_or_write(self) -> None:
        cases = [
            {
                "object": "error",
                "status": 403,
                "code": "restricted_resource",
                "message": "permission denied",
            },
            {
                "object": "error",
                "status": 502,
                "code": "internal_server_error",
                "message": "upstream failure",
            },
        ]
        for error in cases:
            with self.subTest(error=error):
                fake_ntn = self.fixture.fake_bin / "ntn"
                fake_ntn.write_text(
                    dedent(
                        f'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
log_path = Path(os.environ["FAKE_NTN_LOG"])
record = {{"args": args, "method": "GET"}}
with log_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False) + "\\n")
error = {error!r}
print(json.dumps(error))
sys.exit(1)
'''
                    ),
                    encoding="utf-8",
                )
                base.make_executable(fake_ntn)
                self.fixture.ntn_log.write_text("", encoding="utf-8")
                self.fixture.textlint_log.unlink(missing_ok=True)

                result = self.fixture.run_cli()

                self.assertNotEqual(result.returncode, 0)
                calls = self.fixture.ntn_calls()
                self.assertEqual([call["method"] for call in calls], ["GET"])
                self.assertEqual(self.fixture.patch_calls(), [])
                self.assertFalse(self.fixture.textlint_log.exists())


if __name__ == "__main__":
    unittest.main()
