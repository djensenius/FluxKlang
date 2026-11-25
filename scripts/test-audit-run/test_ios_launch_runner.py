"""Fake-only tests for the composed iOS launch runner; nothing is executed."""

import ast
import json
from pathlib import Path
import unittest

import ios_launch_outcome as outcome
import ios_launch_plan as launch_plan
import ios_launch_runner as runner
import ios_runtime
import ios_simulator_lifecycle as lifecycle
from ios_launch_plan import Refusal


RUN_ID = "123e4567-e89b-42d3-a456-426614174000"
OWNED = "223e4567-e89b-42d3-a456-426614174000"
TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
SIMCTL = launch_plan.CORE_SIMULATOR_SIMCTL
NAME = f"{lifecycle.DEVICE_NAME_PREFIX}{RUN_ID}"
XCTESTRUN = "/runner/Products/FluxKlang.xctestrun"
BUNDLE = "/runner/result.xcresult"
CONTAINER = "/sim/data/Containers/Data/Application/APP"
RECEIPT_DIR = f"{CONTAINER}/{launch_plan.RECEIPT_RELATIVE_PREFIX}/{RUN_ID}"
TESTS = ("Suite/testA", "Suite/testB")
OK = lifecycle.CommandResult
SHORT = (lifecycle.TIMEOUT_SECONDS, lifecycle.MAX_OUTPUT_BYTES)
LONG = (runner.TEST_TIMEOUT_SECONDS, lifecycle.MAX_OUTPUT_BYTES)


def inventory(*uuids):
    devices = [{"udid": item, "name": NAME if item == OWNED else "Other",
                "state": "Shutdown"} for item in uuids]
    return json.dumps({"devices": {ios_runtime.RUNTIME: devices}}).encode()


PRE_OWNERSHIP = [
    ((SIMCTL, "list", "devices", "--json"), SHORT, OK(0, inventory())),
    ((SIMCTL, "list", "devicetypes", "--json"), SHORT, OK(0, json.dumps(
        {"devicetypes": [{"name": "iPhone 17", "identifier": TYPE_ID}]}).encode())),
    ((SIMCTL, "create", NAME, TYPE_ID, ios_runtime.RUNTIME), SHORT,
     OK(0, f"{OWNED}\n".encode())),
    ((SIMCTL, "list", "devices", "--json"), SHORT, OK(0, inventory(OWNED))),
]
TEST_ARGV = (
    ios_runtime.DEVELOPER + "/usr/bin/xcodebuild", "test-without-building",
    "-xctestrun", XCTESTRUN, "-destination", f"id={OWNED}",
    "-parallel-testing-enabled", "NO", "-test-iterations", "1",
    "-resultBundlePath", BUNDLE,
)
CONTAINER_ARGV = (SIMCTL, "get_app_container", OWNED,
                  "org.davidjensenius.FluxKlang", "data")
DELETE = ((SIMCTL, "delete", OWNED), SHORT, OK(0, b""))


def script(test=None, container=None, delete=DELETE):
    return [
        *PRE_OWNERSHIP,
        (TEST_ARGV, LONG, OK(0, b"fake log") if test is None else test),
        (CONTAINER_ARGV, SHORT,
         OK(0, f"{CONTAINER}\n".encode()) if container is None else container),
        delete,
    ]


class FakeCommand:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, argv, *, timeout, max_output_bytes):
        self.calls.append(argv)
        if not self.responses:
            raise AssertionError(f"unexpected command: {argv!r}")
        expected_argv, limits, response = self.responses.pop(0)
        if type(argv) is not tuple or argv != expected_argv:
            raise AssertionError(f"expected {expected_argv!r}, got {argv!r}")
        if (timeout, max_output_bytes) != limits:
            raise AssertionError(f"unexpected limits {(timeout, max_output_bytes)!r}")
        if isinstance(response, BaseException):
            raise response
        return response


class Observer:
    def __init__(self, result=None, receipt=None, error=None):
        self.result = (tuple((test, "passed") for test in TESTS)
                       if result is None else result)
        self.receipt = ({"published": 1, "partial_leftovers": 0,
                         "other_entries": 0} if receipt is None else receipt)
        self.error = error
        self.calls = []

    def __call__(self, *, plan, test_result, receipt_directory):
        self.calls.append((plan, test_result, receipt_directory))
        if self.error is not None:
            raise self.error
        receipt = None if self.receipt == "none" else self.receipt
        return (self.result, receipt)


def run(fake, observer, **overrides):
    arguments = dict(expected_test_ids=TESTS, xctestrun_path=XCTESTRUN,
                     result_bundle_path=BUNDLE, observe=observer)
    arguments.update(overrides)
    return runner.run_launch(RUN_ID, fake, **arguments)


class LaunchRunnerTests(unittest.TestCase):
    def assert_deleted_once(self, fake):
        self.assertEqual(fake.responses, [])
        self.assertEqual(fake.calls.count((SIMCTL, "delete", OWNED)), 1)
        self.assertEqual(fake.calls[-1], (SIMCTL, "delete", OWNED))

    def test_exact_argv_sequence_and_passed_record(self):
        fake, observe = FakeCommand(script()), Observer()
        data = run(fake, observe)
        record = outcome.decode(data)
        self.assertEqual((record["outcome"], record["exit_code"]), ("passed", 0))
        self.assertEqual(record["run_uuid"], RUN_ID)
        self.assert_deleted_once(fake)
        plan, test_result, directory = observe.calls[0]
        self.assertEqual(plan, launch_plan.plan_launch(RUN_ID, OWNED))
        self.assertEqual(test_result, OK(0, b"fake log"))
        self.assertEqual(directory, RECEIPT_DIR)

    def test_input_refusals_precede_every_command(self):
        cases = (
            {"expected_test_ids": ()},
            {"expected_test_ids": ["Suite/testA"]},
            {"xctestrun_path": "relative.xctestrun"},
            {"xctestrun_path": "/a/../b.xctestrun"},
            {"xctestrun_path": "/a/b.plist"},
            {"xctestrun_path": "/" + "a" * 1014 + ".xctestrun"},
            {"result_bundle_path": "/" + "a" * 1015 + ".xcresult"},
            {"result_bundle_path": "/a//r.xcresult"},
            {"result_bundle_path": "/a/r\n.xcresult"},
            {"observe": None},
        )
        with self.assertRaises(Refusal):
            run(None, Observer())
        for overrides in cases:
            with self.subTest(overrides=overrides):
                fake = FakeCommand([])
                with self.assertRaises(Refusal):
                    run(fake, Observer(), **overrides)
                self.assertEqual(fake.calls, [])
        with self.assertRaises(Refusal):
            runner.run_launch("not-a-uuid", FakeCommand([]), expected_test_ids=TESTS,
                              xctestrun_path=XCTESTRUN, result_bundle_path=BUNDLE,
                              observe=Observer())

    def test_path_byte_boundaries_accept_1024(self):
        xctestrun = "/" + "a" * 1013 + ".xctestrun"
        bundle = "/" + "b" * 1014 + ".xcresult"
        container = "/" + "c" * 1023
        self.assertEqual([len(x.encode()) for x in (xctestrun, bundle, container)],
                         [1024] * 3)
        responses = script(container=OK(0, container.encode()))
        argv = list(TEST_ARGV)
        argv[3], argv[-1] = xctestrun, bundle
        responses[4] = (tuple(argv), LONG, OK(0, b""))
        fake, observe = FakeCommand(responses), Observer()
        record = outcome.decode(run(fake, observe, xctestrun_path=xctestrun,
                                    result_bundle_path=bundle))
        self.assertEqual(record["outcome"], "passed")
        self.assertTrue(observe.calls[0][2].startswith(container + "/"))
        self.assert_deleted_once(fake)

    def test_refused_container_output_never_observes(self):
        for data in (b"", b"\n", b"/a\xff\n", b"/" + b"c" * 1024, b"relative\n",
                     b"/a\n/b\n", b"/a\r\n"):
            with self.subTest(data=data[:16]):
                fake, observe = FakeCommand(script(container=OK(0, data))), Observer()
                with self.assertRaises(Refusal):
                    run(fake, observe)
                self.assertEqual(observe.calls, [])
                self.assert_deleted_once(fake)

    def test_nonzero_test_exit_never_passes(self):
        for code in (65, 1, -9):
            with self.subTest(code=code):
                fake = FakeCommand(script(test=OK(code, b"")))
                with self.assertRaisesRegex(Refusal, "non-zero test exit"):
                    run(fake, Observer())
                self.assert_deleted_once(fake)

    def test_ownership_refusal_never_tests_or_deletes(self):
        responses = list(PRE_OWNERSHIP)
        responses[3] = (responses[3][0], SHORT, OK(0, inventory()))
        fake, observe = FakeCommand(responses), Observer()
        with self.assertRaisesRegex(Refusal, "possible orphan"):
            run(fake, observe)
        self.assertEqual(fake.responses, [])
        self.assertNotIn(TEST_ARGV, fake.calls)
        self.assertFalse(any(argv[1] == "delete" for argv in fake.calls))
        self.assertEqual(observe.calls, [])

    def test_operation_failures_propagate_after_single_cleanup(self):
        cases = (
            (script(test=RuntimeError("xcodebuild"))[:-2]
             + [DELETE], Observer(), RuntimeError),
            (script(test=OK(0, b"x" * (lifecycle.MAX_OUTPUT_BYTES + 1)))[:-2]
             + [DELETE], Observer(), Refusal),
            (script(), Observer(error=ValueError("parse")), ValueError),
            (script(), Observer(result=(("Unknown/test", "passed"),)), Refusal),
            (script(), Observer(receipt={"published": 1}), Refusal),
        )
        for responses, observe, error in cases:
            with self.subTest(error=error, observe=observe.error):
                fake = FakeCommand(responses)
                with self.assertRaises(error):
                    run(fake, observe)
                self.assert_deleted_once(fake)

    def test_malformed_observation_shape_is_refused_with_cleanup(self):
        def bad(**_kwargs):
            return [(), None]
        fake = FakeCommand(script())
        with self.assertRaisesRegex(Refusal, "observation must be"):
            run(fake, bad)
        self.assert_deleted_once(fake)

    def test_missing_container_requires_no_receipt_counts(self):
        fake, observe = FakeCommand(script(container=OK(1, b""))), Observer()
        with self.assertRaisesRegex(Refusal, "located receipt directory"):
            run(fake, observe)
        self.assertIsNone(observe.calls[0][2])
        self.assert_deleted_once(fake)
        fake = FakeCommand(script(container=OK(1, b"")))
        record = outcome.decode(run(fake, Observer(receipt="none")))
        self.assertEqual(record["outcome"], "unavailable")
        self.assert_deleted_once(fake)

    def test_before_test_runs_once_after_ownership_before_xcodebuild(self):
        fake, observe = FakeCommand(script()), Observer()
        hook_calls = []

        def hook(*args, **kwargs):
            hook_calls.append((args, kwargs, list(fake.calls)))
            return "ignored"

        record = outcome.decode(run(fake, observe, before_test=hook))
        self.assertEqual(record["outcome"], "passed")
        self.assertEqual(len(hook_calls), 1)
        args, kwargs, seen = hook_calls[0]
        self.assertEqual((args, kwargs), ((), {}))
        self.assertEqual(seen, [entry[0] for entry in PRE_OWNERSHIP])
        self.assertEqual(fake.calls[len(PRE_OWNERSHIP)], TEST_ARGV)
        self.assert_deleted_once(fake)

    def test_before_test_none_is_unchanged(self):
        fake = FakeCommand(script())
        record = outcome.decode(run(fake, Observer(), before_test=None))
        self.assertEqual(record["outcome"], "passed")
        self.assertEqual(fake.calls, [entry[0] for entry in script()])

    def test_non_callable_before_test_refused_before_commands(self):
        for value in ("hook", 1, False):
            with self.subTest(value=value):
                fake = FakeCommand([])
                with self.assertRaisesRegex(Refusal, "before_test"):
                    run(fake, Observer(), before_test=value)
                self.assertEqual(fake.calls, [])

    def test_before_test_errors_skip_xcodebuild_and_delete_once(self):
        for error in (Refusal("stale"), OSError("gone"), KeyboardInterrupt(),
                      SystemExit(143)):
            with self.subTest(error=type(error)):
                fake, observe = FakeCommand([*PRE_OWNERSHIP, DELETE]), Observer()
                calls = []

                def hook():
                    calls.append(1)
                    raise error

                with self.assertRaises(type(error)) as caught:
                    run(fake, observe, before_test=hook)
                self.assertIs(caught.exception, error)
                self.assertEqual(calls, [1])
                self.assertNotIn(TEST_ARGV, fake.calls)
                self.assertNotIn(CONTAINER_ARGV, fake.calls)
                self.assertEqual(observe.calls, [])
                self.assert_deleted_once(fake)

    def test_before_test_error_chained_under_cleanup_failure(self):
        failing = ((SIMCTL, "delete", OWNED), SHORT, OK(1, b""))
        fake = FakeCommand([*PRE_OWNERSHIP, failing])

        def hook():
            raise Refusal("stale")

        with self.assertRaisesRegex(Refusal, "cleanup command failed") as caught:
            run(fake, Observer(), before_test=hook)
        self.assertEqual(str(caught.exception.__cause__), "stale")
        self.assertNotIn(TEST_ARGV, fake.calls)
        self.assert_deleted_once(fake)

    def test_ownership_refusal_never_calls_before_test(self):
        responses = list(PRE_OWNERSHIP)
        responses[3] = (responses[3][0], SHORT, OK(0, inventory()))
        calls = []
        with self.assertRaisesRegex(Refusal, "possible orphan"):
            run(FakeCommand(responses), Observer(), before_test=lambda: calls.append(1))
        self.assertEqual(calls, [])

    def test_termination_propagates_after_cleanup(self):
        for signal in (KeyboardInterrupt(), SystemExit(143)):
            with self.subTest(signal=type(signal)):
                fake = FakeCommand(script(test=signal)[:-2] + [DELETE])
                with self.assertRaises(type(signal)):
                    run(fake, Observer())
                self.assert_deleted_once(fake)

    def test_cleanup_failure_is_final_and_chained(self):
        failing = ((SIMCTL, "delete", OWNED), SHORT, OK(1, b""))
        fake = FakeCommand(script(delete=failing))
        with self.assertRaisesRegex(Refusal, "cleanup command failed") as caught:
            run(fake, Observer(error=ValueError("parse")))
        self.assertIs(type(caught.exception.__cause__), ValueError)
        self.assertEqual(str(caught.exception.__cause__), "parse")
        self.assert_deleted_once(fake)

    def test_outcome_precedence_passthrough(self):
        clean = {"published": 1, "partial_leftovers": 0, "other_entries": 0}
        irregular = dict(clean, partial_leftovers=1)
        cases = (
            (OK(65, b""), (("Suite/testA", "failed"), ("Suite/testB", "passed")),
             clean, "failed"),
            (OK(0, b""), (("Suite/testA", "passed"),), irregular, "failed"),
            (OK(0, b""), (("Suite/testA", "passed"), ("Suite/testB", "skipped")),
             clean, "incomplete"),
            (OK(0, b""), (("Suite/testA", "passed"), ("Suite/testB", "passed")),
             dict(clean, published=0), "unavailable"),
        )
        for test, result, receipt, expected in cases:
            with self.subTest(expected=expected, receipt=receipt):
                fake = FakeCommand(script(test=test))
                record = outcome.decode(run(fake, Observer(result, receipt)))
                self.assertEqual(record["outcome"], expected)
                self.assertEqual(record["exit_code"], 1)
                self.assert_deleted_once(fake)

    def test_source_has_no_direct_execution_io_imports_or_cli(self):
        source = Path(runner.__file__).read_text(encoding="utf-8")
        imports = []
        for node in ast.walk(ast.parse(source)):
            if isinstance(node, ast.Import):
                imports.extend(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imports.append((node.module or "").split(".", 1)[0])
        forbidden = {"argparse", "os", "pathlib", "shutil", "socket",
                     "subprocess", "sys", "tempfile"}
        self.assertFalse(forbidden.intersection(imports), imports)
        for text in ("__main__", "xcrun", "shell=", "/usr/bin/env"):
            self.assertNotIn(text, source)


if __name__ == "__main__":
    unittest.main()
