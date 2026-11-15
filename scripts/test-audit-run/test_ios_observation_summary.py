"""Pure iOS summary/redaction and owned-directory counting fixtures."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib.parse import quote

import ios_observation_summary as summary

RUN = "01234567-89ab-4cde-8fab-0123456789ab"
OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
NAME = "production-access-suiteExit-" + OTHER + ".json"


class SummaryTests(unittest.TestCase):
    def test_all_text_redacted_before_truncation_in_json_and_markdown(self):
        forms = ("/private/container/" + NAME, "file:///private/container/." + NAME + ".partial",
                 "C:\\container\\" + NAME, quote("/private/" + NAME, safe=""),
                 r"\/private\/" + NAME, "/container/PRODUCTION-ACCESS-case-" + OTHER)
        for path in forms:
            with self.subTest(path=path):
                state = {"run_id": RUN, "test_argv": ["xcodebuild", path, "id=" + OTHER],
                         "refusal": path + " " + OTHER + " " + "x" * 5000,
                         "runtime_evidence": {"prebuild": "refused", "generated_input": "not available",
                                              "refusal_context": {"component": path + OTHER + "x" * 5000,
                                                                  "argv_sanitized": ["codesign", path],
                                                                  "exit_code": 1, "st_readonly": False}},
                         "cleanup_failures": [path + " " + OTHER]}
                result, markdown = summary.summarize(state, {
                    "result": path,
                    "testFailures": [{"targetName": path, "testName": path,
                                      "failureText": "audit " + path + " " + OTHER + "x" * 5000}],
                }, path)
                for rendered in (json.dumps(result), markdown):
                    self.assertNotIn(NAME, rendered)
                    self.assertNotIn(OTHER, rendered)
                    self.assertNotIn("production-access", rendered.lower())
                    self.assertIn(RUN, rendered)
                    self.assertIn("<receipt-file>", rendered)
                self.assertEqual(result["audit_failure_count"], 1)
                self.assertIn(json.dumps(result["runtime_evidence"], indent=2, ensure_ascii=True), markdown)
                self.assertIn("sanitized, possibly truncated; not exact", markdown)

    def test_unavailable_is_not_zero_and_no_receipt_contents_are_read(self):
        result, _ = summary.summarize({"test_exit_code": 65})
        for key in ("total", "failed", "audit_failure_count", "receipts_published"):
            self.assertEqual(result[key], "not available")
        self.assertEqual(result["test_exit_code"], 65)
        result, _ = summary.summarize({}, {"totalTestCount": 0, "failedTests": False})
        self.assertEqual(result["total"], 0)
        self.assertEqual(result["failed"], "not available")
        self.assertEqual(result["failure_count"], "not available")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertEqual(summary.receipt_counts(directory)["receipts_published"], 0)
            (directory / NAME).write_text("DO NOT READ")
            (directory / ("." + NAME + ".partial")).write_text("DO NOT READ")
            (directory / "other").symlink_to(directory / NAME)
            with mock.patch.object(Path, "open", side_effect=AssertionError("receipt contents opened")):
                counts = summary.receipt_counts(directory)
            self.assertEqual(list(counts.values()), [1, 1, 1])
            self.assertEqual(summary.receipt_counts(directory / "missing")["receipts_published"], "not available")
            result, _ = summary.summarize({}, {"testFailures": []}, counts=counts)
            self.assertEqual(result["audit_failure_count"], 0)
            self.assertNotIn(NAME, json.dumps(result))


if __name__ == "__main__":
    unittest.main()
