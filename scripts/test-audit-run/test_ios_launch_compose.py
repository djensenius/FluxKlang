"""Fake-only tests for the bind -> re-check -> launch composer; nothing is executed."""

import ast
from pathlib import Path
import unittest
from unittest import mock

import ios_launch_compose as compose
import ios_launch_outcome as outcome
import ios_launch_recheck as recheck
import ios_launch_runner as runner
import prepare
from ios_launch_plan import Refusal
from test_ios_launch_binding import (BUNDLE, HEAD, INPUT_SHA, INTENT_PATH, OUTPUT,
                                     OUTPUT_SHA, RUN_ID, SOURCE, intent, record_line)
from test_ios_launch_recheck import CALL
from test_ios_launch_runner import (CONTAINER, CONTAINER_ARGV, DELETE, LONG, OK, OWNED,
                                    PRE_OWNERSHIP, SHORT, TESTS, FakeCommand, Observer)


TEST_ARGV = runner.xcodebuild_argv(OUTPUT, BUNDLE, OWNED)


def script(test=None):
    return [*PRE_OWNERSHIP,
            (TEST_ARGV, LONG, OK(0, b"fake log") if test is None else test),
            (CONTAINER_ARGV, SHORT, OK(0, f"{CONTAINER}\n".encode())),
            DELETE]


def swapped():
    """A different valid intent: same run ID and paths, different digests."""
    other = intent()
    other["input"]["sha256"] = "3" * 64
    other["output"]["sha256"] = "4" * 64
    return other


_DEFAULT = object()


class Events:
    def __init__(self):
        self.log = []


class LoggedValidate:
    def __init__(self, events, result=None, error=None, mutate=None):
        self.events, self.result, self.error, self.mutate = events, result, error, mutate
        self.calls = []

    def __call__(self, *args, **kwargs):
        self.events.log.append("validate")
        self.calls.append((args, kwargs))
        if self.mutate is not None:
            self.mutate()
        if self.error is not None:
            raise self.error
        return intent() if self.result is None else self.result


class LoggedCommand(FakeCommand):
    def __init__(self, events, responses):
        super().__init__(responses)
        self.events = events

    def __call__(self, argv, **kwargs):
        self.events.log.append(argv)
        return super().__call__(argv, **kwargs)


class ComposeTests(unittest.TestCase):
    def setUp(self):
        self.events = Events()

    def launch(self, validate=_DEFAULT, command=None, observe=None, **changes):
        arguments = dict(
            reviewed_head=HEAD, products_record_line=record_line(), intent=intent(),
            run_uuid=RUN_ID, xctestrun_path=OUTPUT, result_bundle_path=BUNDLE,
            expected_test_ids=TESTS,
            command=LoggedCommand(self.events, script()) if command is None else command,
            observe=Observer() if observe is None else observe,
            validate=LoggedValidate(self.events) if validate is _DEFAULT else validate)
        arguments.update(changes)
        return compose.bind_recheck_and_launch(**arguments)

    def test_success_orders_recheck_before_every_command(self):
        validate = LoggedValidate(self.events)
        command = LoggedCommand(self.events, script())
        record = outcome.decode(self.launch(validate, command))
        self.assertEqual((record["outcome"], record["run_uuid"]), ("passed", RUN_ID))
        self.assertEqual(validate.calls, [CALL])
        self.assertEqual(self.events.log[0], "validate")
        self.assertEqual(self.events.log[1:], [entry[0] for entry in script()])
        self.assertEqual(command.responses, [])

    def test_bind_refusal_stops_recheck_and_launch(self):
        cases = (dict(reviewed_head="f" * 40), dict(run_uuid=str(OWNED)),
                 dict(xctestrun_path=SOURCE), dict(result_bundle_path=OUTPUT[:-10] + ".xcresult"),
                 dict(products_record_line=record_line(output_sha="9" * 64)),
                 dict(intent=swapped()))
        for changes in cases:
            with self.subTest(changes=sorted(changes)):
                self.events.log.clear()
                command = LoggedCommand(self.events, [])
                with self.assertRaises(Refusal):
                    self.launch(command=command, **changes)
                self.assertEqual(self.events.log, [])

    def test_input_refusals_precede_bind_and_recheck(self):
        for changes in (dict(command="not callable"), dict(observe=1),
                        dict(expected_test_ids=()), dict(expected_test_ids=list(TESTS))):
            with self.subTest(changes=changes):
                self.events.log.clear()
                with self.assertRaises(Refusal):
                    self.launch(**changes)
                self.assertEqual(self.events.log, [])

    def test_recheck_refusal_never_invokes_runner(self):
        for validate in (LoggedValidate(self.events, error=OSError("gone")),
                         LoggedValidate(self.events, result=swapped())):
            with self.subTest(error=validate.error):
                self.events.log.clear()
                with self.assertRaises(Refusal):
                    self.launch(validate, LoggedCommand(self.events, []))
                self.assertEqual(self.events.log, ["validate"])

    def test_intent_swapped_after_bind_is_refused(self):
        """Reviewer scenario: same run ID and paths, different digests, swapped later."""
        supplied = intent()
        real_bind = compose.launch_binding.bind_launch

        def bind_then_swap(**kwargs):
            result = real_bind(**kwargs)
            supplied.clear()
            supplied.update(swapped())
            return result

        validate = LoggedValidate(self.events, result=swapped())
        with mock.patch.object(compose.launch_binding, "bind_launch", bind_then_swap):
            with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
                self.launch(validate, LoggedCommand(self.events, []), intent=supplied)
        self.assertEqual(self.events.log, [])
        self.assertEqual((supplied["run_id"], supplied["output"]["path"],
                          supplied["intent_path"]), (RUN_ID, OUTPUT, INTENT_PATH))

    def test_intent_changed_during_validate_is_refused(self):
        supplied = intent()
        changed = intent()
        changed["provider_observation"] = {"xcode": {"version": "Xcode 27.2"}}

        def mutate():
            supplied["provider_observation"] = changed["provider_observation"]

        validate = LoggedValidate(self.events, result=changed, mutate=mutate)
        with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
            self.launch(validate, LoggedCommand(self.events, []), intent=supplied)
        self.assertEqual(self.events.log, ["validate"])

    def test_provider_observation_change_after_bind_is_refused(self):
        """Only the whole-intent digest differs: same run ID, paths and file digests."""
        supplied = intent()
        changed = intent()
        changed["provider_observation"] = {"xcode": {"version": "Xcode 27.2"}}
        real_bind = compose.launch_binding.bind_launch

        def bind_then_change(**kwargs):
            result = real_bind(**kwargs)
            supplied["provider_observation"] = changed["provider_observation"]
            return result

        validate = LoggedValidate(self.events, result=changed)
        with mock.patch.object(compose.launch_binding, "bind_launch", bind_then_change):
            with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
                self.launch(validate, LoggedCommand(self.events, []), intent=supplied)
        self.assertEqual(self.events.log, [])
        self.assertEqual(supplied, changed)

    def test_runner_errors_propagate_after_cleanup(self):
        command = LoggedCommand(self.events, script(test=OK(65, b"")))
        with self.assertRaisesRegex(Refusal, "non-zero test exit"):
            self.launch(command=command)
        self.assertEqual(command.responses, [])
        self.assertEqual(command.calls[-1], DELETE[0])

    def test_interrupts_propagate_unchanged(self):
        for error in (KeyboardInterrupt(), SystemExit(1)):
            with self.subTest(stage="recheck", error=type(error)):
                self.events.log.clear()
                with self.assertRaises(type(error)) as caught:
                    self.launch(LoggedValidate(self.events, error=error),
                                LoggedCommand(self.events, []))
                self.assertIs(caught.exception, error)
                self.assertEqual(self.events.log, ["validate"])
            with self.subTest(stage="launch", error=type(error)):
                command = LoggedCommand(self.events, script(test=error)[:-2] + [DELETE])
                with self.assertRaises(type(error)) as caught:
                    self.launch(command=command)
                self.assertIs(caught.exception, error)
                self.assertEqual(command.calls[-1], DELETE[0])

    def test_default_validate_is_prepare_validate(self):
        validate = LoggedValidate(self.events)
        with mock.patch.object(prepare, "validate", validate):
            self.launch(command=LoggedCommand(self.events, script()), validate=None)
        self.assertEqual(validate.calls, [CALL])

    def test_source_has_no_direct_execution_io_imports_or_cli(self):
        source = Path(compose.__file__).read_text(encoding="utf-8")
        imports = []
        for node in ast.walk(ast.parse(source)):
            if isinstance(node, ast.Import):
                imports.extend(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imports.append((node.module or "").split(".", 1)[0])
        forbidden = {"argparse", "io", "os", "pathlib", "shutil", "signal", "socket",
                     "subprocess", "sys", "tempfile"}
        self.assertFalse(forbidden.intersection(imports), imports)
        for text in ("__main__", "xcrun", "shell=", "/usr/bin/env"):
            self.assertNotIn(text, source)


class BoundDigestRecheckTests(unittest.TestCase):
    BINDING = (RUN_ID, OUTPUT, BUNDLE)

    def test_bound_digests_snapshot(self):
        digests = recheck.bound_digests(record_line(), intent())
        self.assertEqual(digests[:2], (INPUT_SHA, OUTPUT_SHA))
        self.assertEqual(digests[2], recheck.intent_sha256(intent()))
        self.assertNotEqual(digests[2], recheck.intent_sha256(swapped()))

    def test_bound_digests_anchor_on_record(self):
        with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
            recheck.bound_digests(record_line(), swapped())
        with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
            recheck.bound_digests(record_line(output_sha="4" * 64), intent())
        for line in (record_line()[:-1], b"", None):
            with self.assertRaisesRegex(Refusal, "Products observation record"):
                recheck.bound_digests(line, intent())
        with self.assertRaisesRegex(Refusal, "provider-profile intent"):
            recheck.bound_digests(record_line(), dict(intent(), extra=1))

    def test_swapped_intent_refused_before_validate(self):
        validate = LoggedValidate(Events(), result=swapped())
        digests = recheck.bound_digests(record_line(), intent())
        with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
            recheck.recheck_before_launch(self.BINDING, intent=swapped(), validate=validate,
                                          digests=digests)
        self.assertEqual(validate.calls, [])

    def test_digests_are_required(self):
        with self.assertRaises(TypeError):
            recheck.recheck_before_launch(self.BINDING, intent=intent(),
                                          validate=LoggedValidate(Events()))

    def test_other_intent_field_change_refused(self):
        changed = intent()
        changed["provider_observation"] = {"xcode": {"version": "Xcode 27.2"}}
        validate = LoggedValidate(Events(), result=changed)
        digests = recheck.bound_digests(record_line(), intent())
        with self.assertRaisesRegex(Refusal, recheck.BOUND_REFUSAL):
            recheck.recheck_before_launch(self.BINDING, intent=changed, validate=validate,
                                          digests=digests)
        self.assertEqual(validate.calls, [])

    def test_malformed_digests_refused_before_validate(self):
        good = recheck.bound_digests(record_line(), intent())
        for value in (None, list(good), good[:2], good + ("0" * 64,), ("A" * 64,) + good[1:],
                      (b"1" * 64,) + good[1:], "x"):
            with self.subTest(value=value):
                validate = LoggedValidate(Events())
                with self.assertRaisesRegex(Refusal, "bound digests"):
                    recheck.recheck_before_launch(self.BINDING, intent=intent(),
                                                  validate=validate, digests=value)
                self.assertEqual(validate.calls, [])

    def test_intent_sha256_is_key_order_independent(self):
        original = intent()
        reordered = {key: original[key] for key in reversed(list(original))}
        reordered["input"] = {key: original["input"][key]
                              for key in reversed(list(original["input"]))}
        self.assertNotEqual(list(reordered), list(original))
        self.assertEqual(recheck.intent_sha256(reordered), recheck.intent_sha256(original))

    def test_unencodable_intent_refused(self):
        for value in (dict(intent(), provider_observation={"x": float("nan")}),
                      dict(intent(), provider_observation={"x": object()})):
            with self.assertRaisesRegex(Refusal, recheck.INTENT_DIGEST_REFUSAL):
                recheck.intent_sha256(value)


if __name__ == "__main__":
    unittest.main()
