"""Owned tempfile fixtures; every subprocess/Apple command is replaced, never executed."""

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

import ios_simulator_observation as ios
from test_ios_runtime import Host, LIBRARY, PLIST, fixture as runtime_fixture
from test_prepare_ios import FIXTURE

DEVICE = "11111111-2222-4333-8444-555555555555"
FOREIGN = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
CONTAINER = "66666666-7777-4888-8999-000000000000"
RUNTIME = ios.ios_runtime.RUNTIME
TYPE = "fixture.device.actual-id"
INVENTORY = {
    "runtimes": [{
        "identifier": RUNTIME, "name": "iOS 27.0", "version": "27.0",
        "buildversion": "24A434", "isAvailable": True,
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
        self.runtime_host, self.runtime_metadata = Host(), False
        self.inventory = copy.deepcopy(INVENTORY)
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
        metadata = runtime_fixture() if self.runtime_metadata else copy.deepcopy(FIXTURE)
        if self.fault == "profile":
            metadata["FluxKlangTests"]["EnvironmentVariables"]["FLUXKLANG_ISOLATED_TESTING"] = "0"
        if self.fault == "dyld":
            # Synthetic mismatch, NOT a claim about hosted run 43672143259's unknown value.
            metadata["FluxKlangTests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = "fixture-only"
        if self.fault == "dyld-sensitive":
            metadata["FluxKlangTests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = (
                "file:///private/.production-access-suiteExit-" + FOREIGN + ".json.partial "
                + FOREIGN + "x" * 2000)
        if self.fault == "missing-ui":
            del metadata["FluxKlangUITests"]
        if self.fault == "metadata-more":
            metadata["FluxKlangUITests"]["UITargetAppMainThreadCheckerEnabled"] = True
            metadata["FluxKlangUITests"]["EnvironmentVariables"].update(
                {"unexpected%02d" % i: "DO NOT UPLOAD" for i in range(40)})
        if self.fault == "candidate":
            metadata["FluxKlangUITests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = str(
                self.foreign / "untouched")
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
                output = "Xcode 27.1\nBuild version 27A9275"
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
                inventory = copy.deepcopy(self.inventory)
                if self.created and self.fault == "cleanup-inventory":
                    raise ios.Refusal("fixture cleanup inventory unavailable")
                if self.created:
                    inventory["devices"][RUNTIME].append({
                        "udid": DEVICE, "name": self.name, "state": self.device_state,
                        "deviceTypeIdentifier": TYPE, "isAvailable": True, "dataPath": str(self.data),
                    })
                    if self.fault == "cleanup-replaced" and any("build-for-testing" in a for a in self.calls):
                        self.device_root.rename(self.devices / "original-owned")
                        shutil.copytree(self.foreign, self.device_root)
                        self.data.mkdir()
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
                    if self.device_state == "Shutdown":
                        code, error = 149, "CoreSimulator SimError 405: current state: Shutdown"
                    else:
                        self.device_state = "Shutdown"
                elif operation == "delete":
                    shutil.rmtree(self.device_root)
                    self.created = False
                else:
                    raise AssertionError("unexpected simctl: " + repr(argv))
        else:
            raise AssertionError("external command not mocked: " + repr(argv))
        return subprocess.CompletedProcess(argv, code, output, error)

    def observe(self, runner=ios.Observation):
        # Catch accidental code paths which bypass the injected command boundary.
        self.runtime_metadata = issubclass(runner, ios.MetadataDiagnostic)
        with mock.patch.object(ios, "SOURCE_PINS", self.pins), \
                mock.patch("subprocess.Popen", side_effect=AssertionError("native command forbidden")), \
                mock.patch.object(ios.ios_runtime, "_command", side_effect=self.runtime_host.command), \
                mock.patch.object(ios.ios_runtime, "os", self.runtime_host.os), \
                mock.patch.object(ios.ios_runtime.sys, "platform", "darwin"), \
                mock.patch.object(ios.ios_runtime, "LIBRARY_SHA256",
                                  hashlib.sha256(self.runtime_host.bytes).hexdigest()), \
                mock.patch.object(ios.os, "killpg", side_effect=AssertionError("real signal forbidden")):
            observation = runner(self.repo, self.env, self.execute)
            status = observation.observe()
        summary = json.loads((observation.summary_dir / "summary.json").read_text())
        assert (self.foreign / "untouched").read_text() == "foreign"
        assert (self.temp / "unrelated").read_text() == "untouched"
        assert not observation.work.exists()
        assert not self.runtime_host.fds
        self.markdown = (observation.summary_dir / "summary.md").read_text()
        return status, summary


class CommandProcess:
    # Exercise real context exit semantics: old code's implicit wait must fail,
    # not disappear behind MagicMock.__exit__. No OS process or pipe exists.
    __enter__ = subprocess.Popen.__enter__
    __exit__ = subprocess.Popen.__exit__

    def __init__(self, outcomes, wait_error=None):
        self.pid, self.returncode = 12345, None
        self.stdin, self.stdout, self.stderr = (io.BytesIO() for _ in range(3))
        for stream in (self.stdin, self.stdout, self.stderr):
            stream.close = mock.Mock(wraps=stream.close)

        def communicate(input=None, timeout=None):
            assert timeout is not None and timeout > 0, "unbounded communicate"
            outcome = outcomes.pop(0)
            if isinstance(outcome, BaseException):
                raise outcome
            self.returncode = outcome
            return "fixture stdout", "fixture stderr"

        def wait(timeout=None):
            assert timeout is not None and timeout > 0, "unbounded wait"
            if wait_error is not None:
                raise wait_error
            if self.returncode is None:
                self.returncode = 0  # Leader exited; a descendant may still hold its pipes.
            return self.returncode

        self.communicate = mock.Mock(side_effect=communicate)
        self.wait = mock.Mock(side_effect=wait)


class ObservationTests(unittest.TestCase):
    def test_demangler_symbol_input_uses_pipe_not_argv(self):
        argv = ["xcrun", "swift-demangle", "--compact"]
        # Larger than a typical ARG_MAX; only the fixed command ever enters argv.
        symbols = ("\n".join(GUARD_SYMBOLS) + "\n") * 1000
        process = CommandProcess([0])
        with mock.patch.object(ios.subprocess, "Popen", return_value=process) as popen:
            result = ios.commands(argv, cwd="/unused-mocked-path", env={}, timeout=120, input_text=symbols)
            self.assertEqual(popen.call_args[0], (argv,))
            self.assertEqual(popen.call_args[1]["stdin"], subprocess.PIPE)
            self.assertEqual(popen.call_args[1]["bufsize"], 0)
            process.communicate.assert_called_once_with(input=symbols, timeout=120)
            self.assertEqual(result.returncode, 0)

    def test_command_timeout_reaps_only_its_mocked_group_and_preserves_exit(self):
        process = CommandProcess([subprocess.TimeoutExpired(["fixture"], 1), -15])
        with mock.patch.object(ios.subprocess, "Popen", return_value=process) as popen, \
                mock.patch.object(ios.os, "killpg") as kill:
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                ios.commands(["fixture"], cwd="/unused-mocked-path", env={}, timeout=1)
            self.assertEqual(raised.exception.returncode, -15)
            kill.assert_called_once_with(12345, ios.signal.SIGTERM)
            self.assertTrue(popen.call_args[1]["start_new_session"])
            self.assertEqual(process.communicate.call_count, 2)
            self.assertEqual(process.wait.call_args_list, [mock.call(timeout=10)])
            self.assertTrue(all(s.closed for s in (process.stdin, process.stdout, process.stderr)))

    def test_command_escalation_streams_and_cleanup_errors_are_bounded_and_visible(self):
        def timeout():
            return subprocess.TimeoutExpired(["fixture"], 10, output=b"PARTIAL NOT PUBLISHED")

        for case in ("escalate", "descendant", "term-error", "kill-error", "drain-error", "term-drain-error",
                     "wait-timeout", "wait-error", "close-error", "initial-error", "group-gone", "cancel"):
            with self.subTest(case=case):
                first = (OSError("initial wait failed") if case == "initial-error" else
                         KeyboardInterrupt("fixture cancellation") if case == "cancel" else timeout())
                final = (OSError("final drain failed") if case == "drain-error" else
                         timeout() if case in ("descendant", "wait-timeout", "wait-error", "group-gone") else -9)
                wait_error = (timeout() if case == "wait-timeout" else
                              OSError("final wait failed") if case == "wait-error" else None)
                grace = OSError("grace drain failed") if case == "term-drain-error" else timeout()
                process = CommandProcess([first, grace, final], wait_error)
                if case == "descendant":
                    process.returncode = 0  # Still signal the owned group even after leader exit.
                if case == "close-error":
                    process.stdout.close.side_effect = OSError("stdout close failed")
                    self.addCleanup(io.BytesIO.close, process.stdout)  # Reclaim the deliberately failed fake stream.

                def terminate(pid, signum):
                    self.assertEqual(pid, process.pid)
                    if case == "group-gone":
                        raise ProcessLookupError("group gone")
                    if (case == "term-error" and signum == ios.signal.SIGTERM
                            or case == "kill-error" and signum == ios.signal.SIGKILL):
                        raise PermissionError(1, "group signal denied")

                with mock.patch.object(ios.subprocess, "Popen", return_value=process) as popen, \
                        mock.patch.object(ios.os, "killpg", side_effect=terminate) as kill:
                    with self.assertRaises((subprocess.TimeoutExpired, OSError, ios.Refusal, KeyboardInterrupt)) as raised:
                        ios.commands(["fixture"], cwd="/unused", env={}, timeout=1, input_text="fixture")
                self.assertEqual(popen.call_count, 1)
                self.assertEqual(kill.call_args_list, [
                    mock.call(process.pid, ios.signal.SIGTERM), mock.call(process.pid, ios.signal.SIGKILL)])
                self.assertEqual([c.kwargs["timeout"] for c in process.communicate.call_args_list], [1, 10, 10])
                self.assertEqual(process.wait.call_args_list, [mock.call(timeout=10)])
                for stream in (process.stdin, process.stdout, process.stderr):
                    stream.close.assert_called_once()
                self.assertTrue(process.stdin.closed and process.stderr.closed)
                self.assertNotIn("PARTIAL NOT PUBLISHED", str(raised.exception))
                self.assertEqual(raised.exception.returncode, process.returncode)
                if case in ("escalate", "initial-error", "cancel"):
                    self.assertIs(raised.exception, first)
                else:
                    self.assertIn("command cleanup failed", str(raised.exception))
                    detail = {"term-error": "SIGTERM", "kill-error": "SIGKILL",
                              "wait-timeout": "wait", "wait-error": "wait", "close-error": "stdout close",
                              "term-drain-error": "SIGTERM communicate"}
                    self.assertIn(detail.get(case, "SIGKILL communicate"), str(raised.exception))
                if wait_error is not None:
                    self.assertIsNone(raised.exception.returncode)

    def test_failed_command_reaping_still_publishes_summary_and_cleans_owned_device(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = HostedFixture(Path(temporary).resolve())
            execute = fixture.execute
            timeout = lambda: subprocess.TimeoutExpired(["fixture"], 10)
            process = CommandProcess([timeout(), timeout(), timeout()], timeout())

            def failed_build(argv, **kwargs):
                if "build-for-testing" in argv:
                    with mock.patch.object(ios.subprocess, "Popen", return_value=process), \
                            mock.patch.object(ios.os, "killpg", side_effect=PermissionError(1, "denied")):
                        return ios.commands(argv, **kwargs)
                return execute(argv, **kwargs)

            fixture.execute = failed_build
            status, summary = fixture.observe(ios.MetadataDiagnostic)
            self.assertEqual((status, summary["test_launch_calls"], fixture.test_calls), (1, 0, []))
            for key in ("run_id", "result", "test_exit_code", "receipts_published"):
                self.assertEqual(summary[key], "not available")
            self.assertIn("command cleanup failed", summary["refusal"])
            self.assertIn("wait: TimeoutExpired", fixture.markdown)
            self.assertIn("SIGKILL: PermissionError (errno=1)", fixture.markdown)
            self.assertEqual(summary["cleanup_failures"], [])
            self.assertIn(["xcrun", "simctl", "delete", DEVICE], fixture.calls)
            self.assertFalse(fixture.device_root.exists())

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
                expected = []
                if fault not in ("create", "create-collision", "create-malformed"):
                    if fault in ("bootstatus", "install"):
                        expected.append(["shutdown", DEVICE])
                    expected.append(["delete", DEVICE])
                self.assertEqual(cleanup, expected, summary)
                if fault == "create":
                    self.assertEqual((fixture.data / "uncertain-owner").read_text(), "not adopted")
                    self.assertEqual(summary["device_udid"], "not available")
                    self.assertIn("simctl create exited 1", summary["refusal"])
                    self.assertTrue(any("ownership uncertain" in item for item in summary["cleanup_failures"]))
                else:
                    self.assertFalse(fixture.device_root.exists())

    def test_diagnostic_always_stops_before_preparation_even_when_profile_matches(self):
        for fault in (None, "dyld", "dyld-sensitive", "missing-ui", "metadata-more", "candidate"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve(), fault)
                with mock.patch.object(ios.prepare, "prepare", side_effect=AssertionError("preparation forbidden")), \
                        mock.patch.object(ios.prepare, "pinned_input", wraps=ios.prepare.pinned_input) as binding, \
                        mock.patch.object(ios.Observation, "install_receipts",
                                          side_effect=AssertionError("marker/install forbidden")):
                    status, summary = fixture.observe(ios.MetadataDiagnostic)
                self.assertEqual(status, 1)
                self.assertEqual(fixture.test_calls, [])
                self.assertEqual(summary["test_launch_calls"], 0)
                self.assertEqual(summary["run_id"], "not available")
                self.assertEqual(summary["test_exit_code"], "not available")
                self.assertEqual(summary["receipts_published"], "not available")
                self.assertEqual(summary["preparation"], "not available")
                self.assertEqual(summary["runtime_evidence"]["prebuild"], "accepted")
                self.assertEqual(summary["runtime_evidence"]["generated_input"],
                                 "accepted" if fault is None else "refused")
                self.assertEqual(binding.call_count, 1)
                self.assertEqual(binding.call_args.args[1:],
                                 (summary["xctestrun_sha256"], ios.prepare.IOS_RUNTIME_PROFILE))
                self.assertEqual(sum("build-for-testing" in a for a in fixture.calls), 1)
                self.assertFalse(fixture.device_root.exists())
                # Two completed prebuild inventories, then a fresh entry (and exit on success).
                inventories = [a for a, _ in fixture.runtime_host.commands if "runtimes" in a]
                self.assertEqual(len(inventories), 4 if fault is None else 3)
                forbidden = {"boot", "bootstatus", "install", "launch", "spawn"}
                self.assertFalse(any(a[:2] == ["xcrun", "simctl"] and a[2] in forbidden for a in fixture.calls))
                self.assertFalse(any(a[:2] == ["xcrun", "nm"] for a in fixture.calls))
                if fault is None:
                    self.assertIn("full observation remains blocked", summary["refusal"])
                elif fault.startswith("dyld"):
                    self.assertIn("DYLD_INSERT_LIBRARIES: unexpected value", summary["refusal"])
                if fault == "candidate":
                    self.assertIn("independently verified runtime", summary["refusal"])
                    self.assertFalse(any(str(fixture.foreign) in str(a) for a, _ in fixture.runtime_host.commands))
                for rendered in (json.dumps(summary), fixture.markdown):
                    self.assertNotIn(FOREIGN, rendered)
                    self.assertNotIn("production-access-", rendered)
                    self.assertNotIn("DO NOT UPLOAD", rendered)
                    self.assertIn("runtime_evidence", rendered)

    def test_actual_verifier_refusal_and_late_exit_never_record_acceptance(self):
        for fault in ("ancestry", "prebuild-exit", "binding-entry", "binding-exit"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve())
                host = fixture.runtime_host
                if fault == "ancestry":
                    host.nodes["/Applications"].st_mode = stat.S_IFDIR | 0o775
                calls = 0

                def change_mount(argv):
                    nonlocal calls
                    if "runtimes" in argv:
                        calls += 1
                        if calls == {"prebuild-exit": 2, "binding-entry": 3, "binding-exit": 4}.get(fault):
                            host.plist_readonly = False

                host.after_command = change_mount
                status, summary = fixture.observe(ios.MetadataDiagnostic)
                self.assertEqual((status, summary["test_launch_calls"], fixture.test_calls), (1, 0, []))
                prebuild = fault in ("ancestry", "prebuild-exit")
                evidence = summary["runtime_evidence"]
                self.assertEqual(evidence["prebuild"], "refused" if prebuild else "accepted")
                self.assertEqual(evidence["generated_input"], "not available" if prebuild else "refused")
                context = evidence["refusal_context"]
                self.assertEqual(context["component"], "/Applications" if fault == "ancestry" else PLIST)
                self.assertEqual(context["uid"], 0)
                self.assertEqual(context["mode"], "0o775" if fault == "ancestry" else "0o664")
                if fault != "ancestry":
                    self.assertFalse(context["st_readonly"])
                    self.assertEqual(context["stage"], "plist entry" if fault == "binding-entry" else "plist exit")
                self.assertEqual(any("build-for-testing" in a for a in fixture.calls), not prebuild)
                self.assertEqual(any(a[:3] == ["xcrun", "simctl", "create"] for a in fixture.calls), not prebuild)
                self.assertFalse(fixture.device_root.exists())
                self.assertEqual(summary["cleanup_failures"], [])
                if fault == "ancestry":
                    self.assertEqual(host.commands, [])  # No extra probes after refusal.

    def test_diagnostic_entrypoint_and_command_boundary_cannot_launch(self):
        with mock.patch.object(ios, "MetadataDiagnostic") as diagnostic, \
                mock.patch.object(ios.signal, "signal") as signals:
            diagnostic.return_value.observe.return_value = 1
            self.assertEqual(ios.main(), 1)
            diagnostic.return_value.observe.assert_called_once_with()
            self.assertEqual(signals.call_count, 2)
        with tempfile.TemporaryDirectory() as temporary:
            fixture = HostedFixture(Path(temporary).resolve())
            observation = ios.MetadataDiagnostic(fixture.repo, fixture.env, fixture.execute)
            forbidden = [
                [ios.DEVELOPER + "/usr/bin/xcodebuild", "test-without-building"],
                [ios.DEVELOPER + "/usr/bin/xcodebuild", "build-for-testing", "test"],
                ["/usr/bin/codesign", "--sign", "-", "/foreign"],
                ["/usr/bin/codesign", "--display", "--verbose=4", "-r-", "/foreign"],
                ["/usr/bin/security", "find-identity"],
                *[["xcrun", "simctl", op, DEVICE] for op in ("boot", "bootstatus", "install", "launch", "spawn")],
            ]
            for argv in forbidden:
                with self.assertRaises(ios.Refusal):
                    observation.run(argv)
            self.assertEqual(fixture.calls, [])
            self.assertEqual(observation.state["test_launch_calls"], 0)

    def test_cleanup_skips_only_positively_verified_owned_shutdown(self):
        for fault in ("profile", "cleanup-inventory", "shutdown", "delete"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                fixture = HostedFixture(Path(temporary).resolve(), fault)
                status, summary = fixture.observe()
                self.assertEqual(status, 1)
                self.assertIn(["xcrun", "simctl", "delete", DEVICE], fixture.calls)
                if fault == "profile":
                    self.assertNotIn(["xcrun", "simctl", "shutdown", DEVICE], fixture.calls)
                    self.assertEqual(summary["cleanup_shutdown"], "not needed: owned device observed Shutdown")
                    self.assertEqual(summary["cleanup_failures"], [])
                else:
                    self.assertIn(["xcrun", "simctl", "shutdown", DEVICE], fixture.calls)
                    self.assertTrue(summary["cleanup_failures"])
                if fault != "delete":
                    self.assertEqual(summary["cleanup_delete"], "command exited 0; absence not independently verified")

    def test_cleanup_losing_ownership_during_shutdown_probe_skips_both_device_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = HostedFixture(Path(temporary).resolve(), "cleanup-replaced")
            status, summary = fixture.observe(ios.MetadataDiagnostic)
            self.assertEqual(status, 1)
            self.assertEqual(fixture.test_calls, [])
            self.assertEqual(summary["test_launch_calls"], 0)
            self.assertEqual(summary["runtime_evidence"]["generated_input"], "accepted")
            self.assertEqual(fixture.calls.count(["xcrun", "simctl", "list", "devices", "--json"]), 2)
            self.assertEqual(summary["cleanup_shutdown_precheck"],
                             "not confirmed: owned device directory replaced")
            self.assertEqual([a for a in fixture.calls if a[:2] == ["xcrun", "simctl"]
                              and a[2] in ("shutdown", "delete")], [])
            self.assertEqual(summary["cleanup_failures"], ["device ownership: owned device directory replaced"])
            self.assertNotIn("cleanup_shutdown", summary)
            self.assertNotIn("cleanup_delete", summary)
            self.assertEqual((fixture.device_root / "untouched").read_text(), "foreign")
            self.assertTrue((fixture.devices / "original-owned/data").is_dir())
            # HostedFixture.observe also requires removal of owned work and preservation of summaries.

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
