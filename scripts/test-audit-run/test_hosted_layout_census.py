"""Safety and status tests for the hosted layout-only entry point."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import checkout_layout
import hosted_layout_census


HEAD = "a" * 40


class HostedLayoutCensusTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hosted-layout-private-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        git = self.root / ".git"
        (git / "objects").mkdir(parents=True)
        (git / "HEAD").write_text(HEAD + "\n", encoding="ascii")

    def run_entry(self, sha=HEAD):
        with mock.patch.dict(os.environ, {
            "GITHUB_WORKSPACE": str(self.root), "GITHUB_SHA": sha,
        }, clear=True), mock.patch.object(os, "write") as write:
            write.side_effect = lambda fd, data: len(data)
            status = hosted_layout_census.main()
        self.assertEqual(write.call_count, 1)
        fd, output = write.call_args.args
        self.assertEqual(fd, 1)
        self.assertNotIn(str(self.root), output.decode())
        self.assertNotIn(HEAD, output.decode())
        return status, json.loads(output)

    def test_normal_observation_is_closed_and_not_acceptance(self):
        with mock.patch.object(
            checkout_layout, "observe_checkout_layout_report",
            wraps=checkout_layout.observe_checkout_layout_report,
        ) as observe:
            status, report = self.run_entry()
        observe.assert_called_once_with(str(self.root), HEAD)
        self.assertEqual(status, 0)
        self.assertEqual(report["status"], "observed")
        self.assertEqual(report["census"]["scope"], "shape-and-metadata-only")
        self.assertEqual(report["census"]["acceptance"], "not-assessed")

    def test_refusal_has_failure_status_and_fixed_diagnostic(self):
        status, report = self.run_entry("b" * 40)
        self.assertEqual(status, 1)
        self.assertEqual(report, {"diagnostic": "Refusal", "status": "refused"})

    def test_unexpected_and_interruptions_do_not_export_exception_context(self):
        for error, expected_status, diagnostic in (
            (RuntimeError("private-error"), 1, "Unexpected failure"),
            (SystemExit("private-exit"), 1, "Unexpected failure"),
            (KeyboardInterrupt("private-interrupt"), 130, "Interrupted"),
        ):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(checkout_layout, "observe_checkout_layout_report",
                                       side_effect=error):
                    try:
                        raise RuntimeError("private-caller-context")
                    except RuntimeError:
                        status, report = self.run_entry()
                self.assertEqual(status, expected_status)
                self.assertEqual(report, {"diagnostic": diagnostic, "status": "failed"})

    def test_output_failure_has_failure_status_without_raising(self):
        with mock.patch.dict(os.environ, {
            "GITHUB_WORKSPACE": str(self.root), "GITHUB_SHA": HEAD,
        }, clear=True), mock.patch.object(os, "write",
                                        side_effect=OSError("private-output-error")):
            self.assertEqual(hosted_layout_census.main(), 1)

    def test_missing_environment_refuses(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(os, "write", side_effect=lambda fd, data: len(data)) as write:
            self.assertEqual(hosted_layout_census.main(), 1)
        self.assertEqual(json.loads(write.call_args.args[1]),
                         {"diagnostic": "Refusal", "status": "refused"})


if __name__ == "__main__":
    unittest.main()
