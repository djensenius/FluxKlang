"""Safety and status tests for the hosted layout-only entry point."""

import json
import os
from pathlib import Path
import runpy
import signal
import sys
import tempfile
import unittest
from unittest import mock

import checkout_layout
import hosted_layout_census


HEAD = "a" * 40


class HostedLayoutCensusTests(unittest.TestCase):
    def setUp(self):
        previous_handler = signal.getsignal(signal.SIGINT)
        self.addCleanup(signal.signal, signal.SIGINT, previous_handler)
        temporary = tempfile.TemporaryDirectory(prefix="hosted-layout-private-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        git = self.root / ".git"
        (git / "objects").mkdir(parents=True)
        (git / "HEAD").write_text(HEAD + "\n", encoding="ascii")

    def run_entry(self, sha=HEAD, v2=False):
        with mock.patch.dict(os.environ, {
            "GITHUB_WORKSPACE": str(self.root), "GITHUB_SHA": sha,
        }, clear=True), mock.patch.object(os, "write") as write:
            write.side_effect = lambda fd, data: len(data)
            status = hosted_layout_census.main(v2=v2)
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

    def test_v2_entry_uses_closed_report_and_keeps_failures_private(self):
        pack_directory = self.root / ".git" / "objects" / "pack"
        pack_directory.mkdir()
        oid = "1" * 40
        with (pack_directory / f"pack-{oid}.pack").open("wb") as stream:
            stream.truncate(1234567)
        with mock.patch.object(
            checkout_layout, "observe_checkout_layout_v2_report",
            wraps=checkout_layout.observe_checkout_layout_v2_report,
        ) as observe:
            status, report = self.run_entry(v2=True)
        observe.assert_called_once_with(str(self.root), HEAD)
        self.assertEqual(status, 0)
        self.assertEqual(report["census"]["schema"], "checkout-layout-census-v2")
        self.assertEqual(report["census"]["pack_size_buckets"]["le_8_mib"], 1)
        self.assertNotIn(oid, json.dumps(report))
        self.assertNotIn("1234567", json.dumps(report))
        self.assertEqual(self.run_entry("b" * 40, v2=True), (1, {
            "diagnostic": "Refusal", "status": "refused",
        }))
        for error, status, diagnostic in (
            (RuntimeError("private-error"), 1, "Unexpected failure"),
            (KeyboardInterrupt("private-interrupt"), 130, "Interrupted"),
        ):
            with self.subTest(error=type(error).__name__), mock.patch.object(
                    checkout_layout, "observe_checkout_layout_v2_report", side_effect=error):
                self.assertEqual(self.run_entry(v2=True), (status, {
                    "diagnostic": diagnostic, "status": "failed",
                }))

    def test_v2_entry_script_selects_v2(self):
        script = Path(hosted_layout_census.__file__).with_name("hosted_layout_census_v2.py")
        with mock.patch.object(hosted_layout_census, "main", return_value=0) as main:
            with self.assertRaises(SystemExit) as raised:
                runpy.run_path(str(script), run_name="__main__")
        self.assertEqual(raised.exception.code, 0)
        main.assert_called_once_with(v2=True)

    def test_v2_sigint_during_observation_reports_interruption(self):
        observe = checkout_layout.observe_checkout_layout_v2_report

        def interrupted_observation(root, sha):
            os.kill(os.getpid(), signal.SIGINT)
            return observe(root, sha)

        with mock.patch.object(checkout_layout, "observe_checkout_layout_v2_report",
                               side_effect=interrupted_observation):
            self.assertEqual(self.run_entry(v2=True), (130, {
                "diagnostic": "Interrupted", "status": "failed",
            }))

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

    def test_sigint_during_unexpected_exception_handling_stays_closed(self):
        delivered = False
        escaped = False
        result = None

        def trace(frame, event, arg):
            nonlocal delivered
            if (not delivered and frame.f_code is hosted_layout_census.main.__code__
                    and event == "line" and isinstance(sys.exc_info()[1], RuntimeError)):
                delivered = True
                os.kill(os.getpid(), signal.SIGINT)
            return trace

        with mock.patch.object(checkout_layout, "observe_checkout_layout_report",
                               side_effect=RuntimeError("private-error")):
            previous_trace = sys.gettrace()
            try:
                sys.settrace(trace)
                try:
                    result = self.run_entry()
                except BaseException:
                    escaped = True
            finally:
                sys.settrace(previous_trace)
        self.assertTrue(delivered, "SIGINT was not sent during exception handling")
        self.assertFalse(escaped, "SIGINT escaped the output boundary")
        self.assertEqual(result, (130, {
            "diagnostic": "Unexpected failure", "status": "failed",
        }))

    def test_sigint_during_observation_reports_interruption(self):
        observe = checkout_layout.observe_checkout_layout_report

        def interrupted_observation(root, sha):
            os.kill(os.getpid(), signal.SIGINT)
            return observe(root, sha)

        with mock.patch.object(checkout_layout, "observe_checkout_layout_report",
                               side_effect=interrupted_observation):
            self.assertEqual(self.run_entry(), (130, {
                "diagnostic": "Interrupted", "status": "failed",
            }))

    def test_sigint_during_report_write_still_fails(self):
        def interrupted_write(fd, data):
            os.kill(os.getpid(), signal.SIGINT)
            return len(data)

        with mock.patch.dict(os.environ, {
            "GITHUB_WORKSPACE": str(self.root), "GITHUB_SHA": HEAD,
        }, clear=True), mock.patch.object(os, "write", side_effect=interrupted_write) as write:
            self.assertEqual(hosted_layout_census.main(), 130)
        self.assertEqual(json.loads(write.call_args.args[1])["status"], "observed")

    def test_missing_environment_refuses(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(os, "write", side_effect=lambda fd, data: len(data)) as write:
            self.assertEqual(hosted_layout_census.main(), 1)
        self.assertEqual(json.loads(write.call_args.args[1]),
                         {"diagnostic": "Refusal", "status": "refused"})


if __name__ == "__main__":
    unittest.main()
