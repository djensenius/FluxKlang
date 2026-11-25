"""Pre-launch re-check tests; fake validators plus one synthetic real validation."""

from contextlib import ExitStack
import copy
import hashlib
from pathlib import Path
import plistlib
import socket
import subprocess
import os
import tempfile
import unittest
from unittest import mock
import uuid

import ios_launch_binding as binding
import ios_launch_recheck as recheck
import ios_runtime
import observation_runner as products
import prepare
import source_snapshot_integration as integration
from ios_launch_plan import Refusal
from test_bounded_material import CHECKER, OBSERVATION
from test_ios_launch_binding import (BUNDLE, HEAD, INPUT_SHA, INTENT_PATH, OUTPUT,
                                     OUTPUT_SHA, RUN_ID, SOURCE, Text, envelope, intent,
                                     record_line)
import test_prepare_ios


BINDING = (RUN_ID, OUTPUT, BUNDLE)
CALL = ((SOURCE, INPUT_SHA, prepare.IOS_PROVIDER_RUNTIME_PROFILE, OUTPUT, INTENT_PATH),
        {"bounded_material": True})


_UNSET = object()


class FakeValidate:
    def __init__(self, result=_UNSET, error=None):
        self.result, self.error, self.calls = result, error, []

    def __call__(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        if self.error is not None:
            raise self.error
        return intent() if self.result is _UNSET else self.result


class RecheckTests(unittest.TestCase):
    def bound(self):
        return binding.bind_launch(reviewed_head=HEAD, products_record_line=record_line(),
                                   intent=intent(), run_uuid=RUN_ID, xctestrun_path=OUTPUT,
                                   result_bundle_path=BUNDLE)

    def refuses(self, message, validate, bound=BINDING, supplied=None):
        with self.assertRaisesRegex(Refusal, message) as caught:
            recheck.recheck_before_launch(bound, intent=intent() if supplied is None
                                          else supplied, validate=validate)
        return caught.exception

    def test_success_returns_binding_and_calls_validate_once_exactly(self):
        validate = FakeValidate()
        bound = self.bound()
        self.assertIs(recheck.recheck_before_launch(bound, intent=intent(), validate=validate),
                      bound)
        self.assertEqual(validate.calls, [CALL])
        for value in CALL[0]:
            self.assertIs(type(value), str)

    def test_digest_mismatch_refused(self):
        for key in ("input", "output"):
            with self.subTest(key=key):
                changed = intent()
                changed[key]["sha256"] = "3" * 64
                self.refuses(recheck.DIGEST_REFUSAL, FakeValidate(changed))

    def test_path_mismatch_refused(self):
        other = "/runner/Other/x.audit-run-" + RUN_ID
        for key, value in (("input", {"path": "/runner/Other/x.xctestrun", "sha256": INPUT_SHA}),
                           ("output", {"path": other + ".xctestrun", "sha256": OUTPUT_SHA}),
                           ("intent_path", other + ".intent.json")):
            with self.subTest(key=key):
                self.refuses(recheck.PATH_REFUSAL, FakeValidate(dict(intent(), **{key: value})))

    def test_other_record_differences_refused(self):
        changed = intent()
        changed["provider_observation"] = {"xcode": {"version": "Xcode 27.2"}}
        bad = [changed, dict(intent(), schema_version=True), None, [], "x",
               {k: v for k, v in intent().items() if k != "targets"},
               dict(intent(), extra=1), type("D", (dict,), {})(intent()),
               dict(intent(), input={"path": SOURCE, "sha256": Text(INPUT_SHA)}),
               dict(intent(), intent_path=Path(INTENT_PATH))]
        for index, value in enumerate(bad):
            with self.subTest(index=index):
                self.refuses(r"^re-validated (intent|paths)", FakeValidate(value))

    def test_validate_exception_becomes_refusal(self):
        for error in (prepare.Refusal("input SHA256 mismatch"), OSError("gone"),
                      ios_runtime.Refusal("x"), RuntimeError("x")):
            with self.subTest(error=error):
                validate = FakeValidate(error=error)
                refusal = self.refuses(recheck.VALIDATE_REFUSAL, validate)
                self.assertIs(refusal.__cause__, error)
                self.assertEqual(len(validate.calls), 1)

    def test_keyboard_interrupt_and_system_exit_propagate(self):
        for error in (KeyboardInterrupt(), SystemExit(1)):
            with self.subTest(error=error):
                with self.assertRaises(type(error)) as caught:
                    recheck.recheck_before_launch(BINDING, intent=intent(),
                                                  validate=FakeValidate(error=error))
                self.assertIs(caught.exception, error)

    def test_wrong_types_refused_before_validate(self):
        bindings = [list(BINDING), BINDING[:2], BINDING + ("x",), (Text(RUN_ID),) + BINDING[1:],
                    (RUN_ID.upper(),) + BINDING[1:], (RUN_ID, Path(OUTPUT), BUNDLE), None,
                    type("T", (tuple,), {})(BINDING)]
        for index, value in enumerate(bindings):
            with self.subTest(binding=index):
                validate = FakeValidate()
                with self.assertRaises(Refusal):
                    recheck.recheck_before_launch(value, intent=intent(), validate=validate)
                self.assertEqual(validate.calls, [])
        other = "223e4567-e89b-42d3-a456-426614174000"
        intents = [None, list(intent().items()), dict(intent(), extra=1),
                   dict(intent(), profile=prepare.IOS_RUNTIME_PROFILE),
                   dict(intent(), intent_path=Path(INTENT_PATH)),
                   dict(intent(), input={"path": SOURCE, "sha256": "A" * 64}),
                   dict(intent(), output={"path": Text(OUTPUT), "sha256": OUTPUT_SHA}),
                   dict(intent(), run_id=other),
                   dict(intent(), output={"path": OUTPUT + "x", "sha256": OUTPUT_SHA})]
        for index, value in enumerate(intents):
            with self.subTest(intent=index):
                validate = FakeValidate()
                with self.assertRaises(Refusal):
                    recheck.recheck_before_launch(BINDING, intent=value, validate=validate)
                self.assertEqual(validate.calls, [])
        for value in ("prepare.validate", 1):
            with self.subTest(validate=value):
                self.refuses("validate must be callable", value)

    def test_default_validator_is_prepare_validate(self):
        validate = FakeValidate()
        with mock.patch.object(prepare, "validate", validate):
            recheck.recheck_before_launch(BINDING, intent=intent())
        self.assertEqual(validate.calls, [CALL])


class RealValidationTests(unittest.TestCase):
    """Real bounded prepare/validate on a temp fixture; provider probes replaced."""

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for module, names in (
            (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
            (os, ("system", "fork", "posix_spawn", "posix_spawnp", "kill", "killpg")),
        ):
            for name in names:
                if hasattr(module, name):
                    self.stack.enter_context(mock.patch.object(
                        module, name, side_effect=AssertionError("process/signalling denied")))
        self.stack.enter_context(mock.patch.object(socket, "socket",
                                                   side_effect=AssertionError("network")))
        directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.source = directory / "Products" / "fixture.xctestrun"
        self.source.parent.mkdir()
        fixture = copy.deepcopy(test_prepare_ios.FIXTURE)
        fixture["FluxKlangTests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = (
            "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:" + CHECKER
            + ":/usr/lib/libRPAC.dylib")
        fixture["FluxKlangUITests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = CHECKER
        data = plistlib.dumps(fixture, sort_keys=False)
        self.source.write_bytes(data)
        self.pin = hashlib.sha256(data).hexdigest()
        self.run_id = test_prepare_ios.RUN_ID
        self.bundle = str(directory / "results" / (self.run_id + ".xcresult"))
        self.stack.enter_context(mock.patch.object(prepare.uuid, "uuid4",
                                                   return_value=uuid.UUID(self.run_id)))
        self.stack.enter_context(mock.patch.object(
            ios_runtime, "_provider_snapshot",
            lambda **_: (copy.deepcopy(OBSERVATION), CHECKER, CHECKER + "-alias")))
        self.stack.enter_context(mock.patch.object(ios_runtime, "verified_checker",
                                                   side_effect=AssertionError("strict probe")))
        self.intent = prepare.prepare(str(self.source), self.pin,
                                      prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                                      bounded_material=True)
        with mock.patch.object(products, "integration", integration, create=True):
            line = products._products_record(
                (envelope(), {"input": self.pin, "output": self.intent["output"]["sha256"]}),
                self.pin)
        self.binding = binding.bind_launch(
            reviewed_head=HEAD, products_record_line=line, intent=self.intent,
            run_uuid=self.run_id, xctestrun_path=self.intent["output"]["path"],
            result_bundle_path=self.bundle)

    def test_real_validate_accepts_then_refuses_tampered_output(self):
        self.assertIs(recheck.recheck_before_launch(self.binding, intent=self.intent),
                      self.binding)
        output = Path(self.intent["output"]["path"])
        output.write_bytes(output.read_bytes() + b"\n")
        with self.assertRaisesRegex(Refusal, recheck.VALIDATE_REFUSAL) as caught:
            recheck.recheck_before_launch(self.binding, intent=self.intent)
        self.assertIsInstance(caught.exception.__cause__, prepare.Refusal)


if __name__ == "__main__":
    unittest.main()
