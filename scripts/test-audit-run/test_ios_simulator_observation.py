"""Owned tempfile fixtures; every subprocess/Apple command is replaced, never executed."""

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import ios_simulator_observation as ios
from test_prepare_ios import FIXTURE

DEVICE = "11111111-2222-4333-8444-555555555555"
FOREIGN = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
CONTAINER = "66666666-7777-4888-8999-000000000000"
RUNTIME = "fixture.runtime.actual-id"
TYPE = "fixture.device.actual-id"
INVENTORY = {
    "runtimes": [{
        "identifier": RUNTIME, "name": "iOS 27.0", "version": "27.0",
        "buildversion": "24Afixture", "isAvailable": True,
        "supportedDeviceTypes": [{"identifier": TYPE, "name": "iPhone 17"}],
    }],
    "devicetypes": [{
        "identifier": TYPE, "name": "iPhone 17", "productFamily": "iPhone",
        "minRuntimeVersion": 27 << 16, "maxRuntimeVersion": 0xFFFFFFFF,
    }],
    "devices": {RUNTIME: [{"udid": FOREIGN, "state": "Booted"}]},
}
# Valid symbol text, checked with the existing swift-demangle --compact (no compilation).
# The private discriminator is fixture-specific; provideScope uses Swift's Scope word substitution.
GUARD_SYMBOLS = {
    "_$s14FluxKlangTests27ProductionAccessObservationO20requiresFileReceiptsSbyKFZ":
        "static FluxKlangTests.ProductionAccessObservation.requiresFileReceipts() throws -> Swift.Bool",
    "_$s14FluxKlangTests27ProductionAccessObservationO12BundleAnchor"
    "33_0123456789ABCDEF0123456789ABCDEFLLCMa":
        "type metadata accessor for FluxKlangTests.ProductionAccessObservation."
        "(BundleAnchor in _0123456789ABCDEF0123456789ABCDEF)",
    "_$s14FluxKlangTests21ProductionAccessScopeV07provideF03for8testCase10performing"
    "y7Testing4TestV_7Testing4TestV4CaseVSgyyYaYbKXEtYaKF":
        "FluxKlangTests.ProductionAccessScope.provideScope(for: Testing.Test, testCase: Testing.Test.Case?, "
        "performing: @Sendable () async throws -> ()) async throws -> ()",
}


class HostedFixture:
    """Fake command implementation with an explicit allowlist, not a native fallback."""

    def __init__(self, root, fault=None, exit_code=0):
        self.root, self.fault, self.exit_code = root, fault, exit_code
        self.repo = root / "repo"
        self.repo.mkdir()
        self.temp = root / "runner-temp"
        self.temp.mkdir()
        self.home = root / "home"
        self.devices = self.home / "Library/Developer/CoreSimulator/Devices"
        self.devices.mkdir(parents=True)
        self.foreign = self.devices / FOREIGN
        self.foreign.mkdir()
        (self.foreign / "untouched").write_text("foreign")
        (self.temp / "unrelated").write_text("untouched")
        package = self.repo / ios.PACKAGE
        package.parent.mkdir(parents=True)
        package.write_text('{"pins": []}')
        self.pins = {}
        for relative in ios.SOURCE_PINS:
            source = self.repo / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("owned fixture source: " + relative)
            self.pins[relative] = hashlib.sha256(source.read_bytes()).hexdigest()
        if fault == "source":
            source.write_text("changed source")
        self.env = {
            "RUNNER_TEMP": str(self.temp), "HOME": str(self.home),
            "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "DEVELOPER_DIR": ios.DEVELOPER,
            "SETUP_OUTCOME": "success/success", "GITHUB_SHA": "b" * 40, "PR_HEAD_SHA": "c" * 40,
            "GITHUB_STEP_SUMMARY": str(self.root / "step-summary.md"),
            "GITHUB_OUTPUT": str(self.root / "outputs.txt"),
        }
        if fault == "setup":
            self.env["SETUP_OUTCOME"] = "success/failure"
        if fault == "ambient":
            self.env["TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR"] = "/foreign"
        self.calls, self.test_calls = [], []
        self.created = False
        self.device_state = "Shutdown"
        self.name = ""
        self.device_root = self.devices / DEVICE
        self.data = self.device_root / "data"
        self.container = self.data / "Containers/Data/Application" / CONTAINER
        self.installed = self.data / "Containers/Bundle/Application" / CONTAINER / "FluxKlang.app"

    def build(self, argv):
        dd = Path(argv[argv.index("-derivedDataPath") + 1])
        products = dd / "Build/Products"
        unit = products / "Debug-iphonesimulator/FluxKlang.app/PlugIns/FluxKlangTests.xctest"
        unit.mkdir(parents=True)
        app = unit.parent.parent
        for bundle, name, bundle_id in ((app, "FluxKlang", ios.APP_ID),
                                       (unit, "FluxKlangTests", ios.APP_ID + ".tests")):
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": bundle_id, "CFBundleExecutable": name}))
            (bundle / name).write_bytes(b"fixture executable " + ios.MARKER.encode())
        metadata = copy.deepcopy(FIXTURE)
        if self.fault == "profile":
            metadata["FluxKlangTests"]["EnvironmentVariables"]["FLUXKLANG_ISOLATED_TESTING"] = "0"
        (products / "generated.xctestrun").write_bytes(plistlib.dumps(metadata))
        if self.fault == "multiple":
            (products / "second.xctestrun").write_bytes(plistlib.dumps(metadata))
        if self.fault == "marker":
            (unit / ios.MARKER).write_text("not empty")
        if self.fault == "marker-symlink":
            (unit / ios.MARKER).symlink_to(self.foreign / "untouched")

    def execute(self, argv, *, cwd, env, timeout, input_text=None):
        assert cwd == str(self.repo) and 0 < timeout <= 2700
        assert isinstance(argv, list) and all(isinstance(v, str) for v in argv)
        self.calls.append(argv)
        output, error, code = "", "", 0
        if argv == ["git", "rev-parse", "HEAD"]:
            output = "a" * 40
        elif argv[:2] == ["git", "status"]:
            output = "changed project" if self.fault == "project" else ""
        elif argv[:3] == ["git", "--no-pager", "diff"]:
            pass
        elif argv[:2] == ["git", "ls-files"]:
            output = ios.PACKAGE
        elif argv == ["mise", "current", "xcodegen"]:
            output = "fixture"
        elif argv == ["xcodegen", "--version"]:
            output = "Version: fixture"
        elif argv == ["xcodegen", "generate"]:
            pass
        elif argv == ["sw_vers", "-productVersion"]:
            output = "27.0.1"
        elif argv == ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]:
            output = "27.1"
        elif argv[:3] == ["xcrun", "nm", "-a"]:
            symbols = list(GUARD_SYMBOLS)
            output = "\n".join("0000000000001000 t " + item for item in symbols)
            if self.fault == "symbols":
                output = "old unguarded binary"
            elif self.fault == "undefined-symbols":
                output = "\n".join("0000000000001000 t " + item for item in symbols[:-1])
                output += "\n                 U " + symbols[-1]
                output += "\n0000000000000000 U " + symbols[-1]
            elif self.fault == "foreign-symbols":
                output = output.replace("FluxKlangTests", "FakeKlangTests")
        elif argv == ["xcrun", "swift-demangle", "--compact"]:
            assert isinstance(input_text, str), "symbols must be passed via stdin, not argv"
            self.demangle_input = input_text
            names = dict(GUARD_SYMBOLS)
            names.update({k.replace("FluxKlangTests", "FakeKlangTests"):
                          v.replace("FluxKlangTests", "FakeKlangTests") for k, v in GUARD_SYMBOLS.items()})
            output = "\n".join(names[name] for name in input_text.splitlines() if name)
            if self.fault == "demangle":
                code, error = 1, "fixture demangler failure"
        elif argv[:5] == ["xcrun", "xcresulttool", "get", "test-results", "summary"]:
            output = json.dumps({
                "result": "Passed" if self.exit_code == 0 else "Failed", "totalTestCount": 3,
                "passedTests": 3 if self.exit_code == 0 else 2, "failedTests": int(self.exit_code != 0),
                "skippedTests": 0, "expectedFailures": 0,
                "testFailures": [] if self.exit_code == 0 else [{
                    "testName": "scope", "failureText": "audit file publication failed"}],
            })
        elif argv[0] == ios.DEVELOPER + "/usr/bin/xcodebuild":
            if argv[1:] == ["-version"]:
                output = "Xcode 27.1\nBuild version fixture"
            elif "-resolvePackageDependencies" in argv:
                if self.fault == "package":
                    (self.repo / ios.PACKAGE).write_text("drift")
            elif "build-for-testing" in argv:
                if self.fault == "build":
                    code = 65
                else:
                    self.build(argv)
            elif argv[1] == "test-without-building":
                self.test_calls.append((argv, env))
                if self.fault in ("timeout", "killed"):
                    error = subprocess.TimeoutExpired(argv, timeout)
                    if self.fault == "killed":
                        error.returncode = -15
                    raise error
                bundle = Path(argv[argv.index("-resultBundlePath") + 1])
                bundle.mkdir()
                if self.fault == "container-change":
                    shutil.rmtree(self.container)
                else:
                    receipt_dir = Path(env["TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR"])
                    name = "production-access-suiteExit-" + FOREIGN + ".json"
                    if self.fault == "partial":
                        name = "." + name + ".partial"
                    if self.fault != "no-receipts":
                        (receipt_dir / name).write_text("not read or uploaded")
                prepared = Path(argv[argv.index("-xctestrun") + 1])
                self.envelope = plistlib.loads(prepared.read_bytes())
                code = self.exit_code
            else:
                raise AssertionError("unexpected xcodebuild: " + repr(argv))
        elif argv[:2] == ["xcrun", "simctl"]:
            operation = argv[2]
            if operation == "list":
                inventory = copy.deepcopy(INVENTORY)
                if self.created:
                    inventory["devices"][RUNTIME].append({
                        "udid": DEVICE, "name": self.name, "state": self.device_state,
                        "deviceTypeIdentifier": TYPE, "isAvailable": True, "dataPath": str(self.data),
                    })
                output = json.dumps(inventory)
            elif operation == "create":
                assert argv[4:] == [TYPE, RUNTIME]
                self.name = argv[3]
                if self.fault == "create-collision":
                    output = FOREIGN
                elif self.fault == "create-malformed":
                    output = "not a UUID"
                else:
                    self.created = True
                    self.data.mkdir(parents=True)
                    output = DEVICE
                    code = 1 if self.fault == "create" else 0
                    if self.fault == "create":
                        (self.data / "uncertain-owner").write_text("not adopted")
            else:
                assert argv[3] == DEVICE, "command targeted a foreign/global device"
                if self.fault == operation:
                    code, error = 1, "fixture " + operation + " failure"
                elif operation == "boot":
                    self.device_state = "Booted"
                elif operation == "bootstatus":
                    pass
                elif operation == "install":
                    shutil.copytree(Path(argv[4]), self.installed)
                    self.container.mkdir(parents=True)
                    if self.fault == "installed-marker":
                        (self.installed / "PlugIns/FluxKlangTests.xctest" / ios.MARKER).unlink()
                    if self.fault == "installed-binary":
                        (self.installed / "PlugIns/FluxKlangTests.xctest/FluxKlangTests").write_bytes(b"old code")
                elif operation == "get_app_container":
                    assert argv[4] == ios.APP_ID
                    output = str(self.container if argv[5] == "data" else self.installed)
                    if self.fault == "container-path":
                        output = str(self.foreign)
                    if self.fault == "directory" and self.container.exists():
                        for path in self.container.iterdir():
                            path.chmod(0o755)
                elif operation == "shutdown":
                    self.device_state = "Shutdown"
                elif operation == "delete":
                    shutil.rmtree(self.device_root)
                    self.created = False
                else:
                    raise AssertionError("unexpected simctl: " + repr(argv))
        else:
            raise AssertionError("external command not mocked: " + repr(argv))
        return subprocess.CompletedProcess(argv, code, output, error)

    def observe(self):
        # Catch accidental code paths which bypass the injected command boundary.
        with mock.patch.object(ios, "SOURCE_PINS", self.pins), \
                mock.patch("subprocess.Popen", side_effect=AssertionError("native command forbidden")):
            observation = ios.Observation(self.repo, self.env, self.execute)
            status = observation.observe()
        summary = json.loads((observation.summary_dir / "summary.json").read_text())
        assert (self.foreign / "untouched").read_text() == "foreign"
        assert (self.temp / "unrelated").read_text() == "untouched"
        assert not observation.work.exists()
        return status, summary


class ObservationTests(unittest.TestCase):
    def test_demangler_symbol_input_uses_pipe_not_argv(self):
        argv = ["xcrun", "swift-demangle", "--compact"]
        # Larger than a typical ARG_MAX; only the fixed command ever enters argv.
        symbols = ("\n".join(GUARD_SYMBOLS) + "\n") * 1000
        process = mock.MagicMock()
        process.communicate.return_value = ("\n".join(GUARD_SYMBOLS.values()), "")
        process.returncode = 0
        with mock.patch.object(ios.subprocess, "Popen") as popen:
            popen.return_value.__enter__.return_value = process
            result = ios.commands(argv, cwd="/unused-mocked-path", env={}, timeout=120, input_text=symbols)
            self.assertEqual(popen.call_args[0], (argv,))
            self.assertEqual(popen.call_args[1]["stdin"], subprocess.PIPE)
            process.communicate.assert_called_once_with(input=symbols, timeout=120)
            self.assertEqual(result.returncode, 0)

    def test_command_timeout_reaps_only_its_mocked_group_and_preserves_exit(self):
        process = mock.MagicMock()
        process.pid, process.returncode = 12345, -15
        process.communicate.side_effect = [subprocess.TimeoutExpired(["fixture"], 1), ("", "")]
        with mock.patch.object(ios.subprocess, "Popen") as popen, \
                mock.patch.object(ios.os, "killpg") as kill:
            popen.return_value.__enter__.return_value = process
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                ios.commands(["fixture"], cwd="/unused-mocked-path", env={}, timeout=1)
            self.assertEqual(raised.exception.returncode, -15)
            kill.assert_called_once_with(12345, ios.signal.SIGTERM)
            self.assertTrue(popen.call_args[1]["start_new_session"])
            self.assertEqual(process.communicate.call_count, 2)

    def test_inventory_exact_selection_and_closed_refusals(self):
        self.assertEqual(ios.select_inventory(copy.deepcopy(INVENTORY))["runtime_identifier"], RUNTIME)
        for fault in ("duplicate-runtime", "unavailable", "absent", "duplicate-type",
                      "incompatible", "unsupported", "ambiguous-support"):
            with self.subTest(fault=fault):
                inventory = copy.deepcopy(INVENTORY)
                runtime = inventory["runtimes"][0]
                if fault == "duplicate-runtime":
                    inventory["runtimes"].append(copy.deepcopy(runtime))
                elif fault == "unavailable":
                    runtime["isAvailable"] = False
                elif fault == "absent":
                    runtime["version"], runtime["name"] = "27.1", "iOS 27.1"
                elif fault == "duplicate-type":
                    inventory["devicetypes"] *= 2
                elif fault == "incompatible":
                    inventory["devicetypes"][0]["minRuntimeVersion"] = 28 << 16
                elif fault == "ambiguous-support":
                    runtime["supportedDeviceTypes"].append({"identifier": TYPE, "name": "other"})
                else:
                    runtime["supportedDeviceTypes"] = []
                with self.assertRaises(ios.Refusal):
                    ios.select_inventory(inventory)

    def test_one_attempt_exit_propagation_and_unchanged_envelope(self):
        for code in (0, 65):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve(), exit_code=code)
                status, summary = fixture.observe()
                self.assertEqual(status, code, summary)
                self.assertEqual(summary["test_exit_code"], code)
                self.assertEqual(len(fixture.test_calls), 1)
                argv, env = fixture.test_calls[0]
                self.assertEqual(argv[argv.index("-destination") + 1], "platform=iOS Simulator,id=" + DEVICE)
                self.assertEqual(argv[argv.index("-parallel-testing-enabled") + 1], "NO")
                self.assertFalse(any("iteration" in a or "retry" in a or "only-testing" in a
                                     or "skip-testing" in a for a in argv))
                self.assertNotIn("FLUXKLANG_AUDIT_RECEIPT_DIR", env)
                self.assertTrue(env["TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR"].startswith(str(fixture.container)))
                self.assertEqual(set(fixture.envelope), set(FIXTURE))
                for target, key in (("FluxKlangTests", "EnvironmentVariables"),
                                    ("FluxKlangUITests", "EnvironmentVariables"),
                                    ("FluxKlangUITests", "UITargetAppEnvironmentVariables")):
                    self.assertEqual(fixture.envelope[target][key],
                                     dict(FIXTURE[target][key], FLUXKLANG_AUDIT_RUN_ID=summary["run_id"]))
                self.assertEqual(summary["head_sha"], "a" * 40)
                self.assertEqual(summary["pr_head_sha"], "c" * 40)
                self.assertEqual(summary["receipts_published"], 1)
                self.assertEqual(fixture.demangle_input.splitlines(), list(GUARD_SYMBOLS))
                self.assertFalse(fixture.device_root.exists())
                self.assertEqual([a[2:] for a in fixture.calls if a[:2] == ["xcrun", "simctl"]
                                  and a[2] in ("shutdown", "delete")], [["shutdown", DEVICE], ["delete", DEVICE]])

    def test_preflight_refusals_never_launch(self):
        faults = ("source", "setup", "ambient", "project", "package", "profile", "multiple",
                  "symbols", "undefined-symbols", "foreign-symbols", "demangle",
                  "marker", "marker-symlink", "installed-marker", "installed-binary",
                  "directory", "container-path")
        for fault in faults:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve(), fault)
                status, summary = fixture.observe()
                self.assertEqual(status, 1)
                self.assertEqual(fixture.test_calls, [])
                self.assertEqual(summary["test_launch_calls"], 0)
                self.assertEqual(summary["test_exit_code"], "not available")
                self.assertTrue(summary["refusal"])
                self.assertFalse(fixture.device_root.exists())
                if fault == "undefined-symbols":
                    self.assertEqual(fixture.demangle_input.splitlines(), list(GUARD_SYMBOLS)[:-1])
                    self.assertIn("built unit guard symbol absent: provideScope", summary["refusal"])

    def test_partial_setup_cleanup_and_no_foreign_adoption(self):
        for fault in ("create", "build", "boot", "bootstatus", "install", "create-collision", "create-malformed"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve(), fault)
                status, summary = fixture.observe()
                self.assertEqual(status, 1)
                self.assertEqual(fixture.test_calls, [])
                cleanup = [a[2:] for a in fixture.calls if a[:2] == ["xcrun", "simctl"]
                           and a[2] in ("shutdown", "delete")]
                expected = [] if fault in ("create", "create-collision", "create-malformed") else [
                    ["shutdown", DEVICE], ["delete", DEVICE]]
                self.assertEqual(cleanup, expected, summary)
                if fault == "create":
                    self.assertEqual((fixture.data / "uncertain-owner").read_text(), "not adopted")
                    self.assertEqual(summary["device_udid"], "not available")
                    self.assertIn("simctl create exited 1", summary["refusal"])
                    self.assertTrue(any("ownership uncertain" in item for item in summary["cleanup_failures"]))
                else:
                    self.assertFalse(fixture.device_root.exists())

    def test_publication_container_timeout_and_cleanup_failures_end_attempt(self):
        for fault in ("partial", "no-receipts", "container-change", "timeout", "killed", "shutdown", "delete"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve(), fault)
                status, summary = fixture.observe()
                self.assertEqual(status, 143 if fault == "killed" else 1, summary)
                self.assertEqual(len(fixture.test_calls), 1)
                self.assertTrue(summary["refusal"] or summary["cleanup_failures"])
                expected_exit = {"timeout": "not available", "killed": -15}.get(fault, 0)
                self.assertEqual(summary["test_exit_code"], expected_exit)
                if fault in ("shutdown", "delete"):
                    self.assertTrue(summary["cleanup_failures"])
                    self.assertIn(["xcrun", "simctl", "delete", DEVICE], fixture.calls)
                if fault == "container-change":
                    self.assertEqual(summary["receipts_published"], "not available")

    def test_changed_device_ownership_is_not_deleted_and_deadline_never_launches(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = HostedFixture(Path(temporary).resolve())
            observation = ios.Observation(fixture.repo, fixture.env, fixture.execute)
            fixture.device_root.mkdir()
            observation.device, observation.device_root = DEVICE, fixture.device_root
            observation.device_identity = ios.identity(fixture.device_root.stat())
            fixture.device_root.rename(fixture.devices / "original-owned")
            shutil.copytree(fixture.foreign, fixture.device_root)
            observation.cleanup()
            self.assertEqual(fixture.calls, [])
            self.assertTrue((fixture.device_root / "untouched").exists())
            self.assertTrue(observation.state["cleanup_failures"])
            observation.deadline = 0
            with self.assertRaisesRegex(ios.Refusal, "deadline exhausted"):
                observation.run([ios.DEVELOPER + "/usr/bin/xcodebuild", "test-without-building"])
            self.assertEqual(observation.state["test_launch_calls"], 0)
            observation.deadline = float("inf")
            observation.state["test_launch_calls"] = 1
            with self.assertRaisesRegex(ios.Refusal, "second test invocation"):
                observation.run([ios.DEVELOPER + "/usr/bin/xcodebuild", "test-without-building"])
            self.assertEqual(fixture.calls, [])


if __name__ == "__main__":
    unittest.main()
