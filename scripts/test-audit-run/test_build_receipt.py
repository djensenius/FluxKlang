"""Pure synthetic Git/toolchain/compile fixtures; real preparation and sealing."""

import sys

sys.dont_write_bytecode = True

import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

import build_mac
import build_receipt as receipt
import mac_launch
import mac_launch_claim
import prepare
from test_prepare import FIXTURE


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def fixture_git(root, *args):
    """Writes only disposable, test-owned synthetic Git data, no hooks/network."""
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
           "GIT_AUTHOR_NAME": "Synthetic Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "Synthetic Fixture",
           "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
    return subprocess.run(
        ["/usr/bin/git", "--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
         "-C", str(root), *args], env=env, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=True,
    ).stdout.decode().strip()


def initialize(root):
    fixture_git(root, "init", "--template=")
    fixture_git(root, "add", ".")
    fixture_git(root, "commit", "-m", "pure fixture")
    return fixture_git(root, "rev-parse", "HEAD")


def snapshot(root):
    result = {}
    for path in [root, *root.rglob("*")]:
        info = path.lstat()
        data = path.read_bytes() if stat.S_ISREG(info.st_mode) else None
        if stat.S_ISLNK(info.st_mode):
            data = os.readlink(os.fsencode(path))
        result[str(path.relative_to(root))] = (
            data, info.st_mode, info.st_ino, info.st_mtime_ns, info.st_ctime_ns,
        )
    return result


def binary_object_table(objects):
    """Encode test objects verbatim: four-byte offsets, two-byte object refs."""
    data = b"bplist00"
    offsets = []
    for obj in objects:
        offsets.append(len(data))
        data += obj
    table_offset = len(data)
    data += b"".join(offset.to_bytes(4, "big") for offset in offsets)
    return (data + b"\0" * 6 + bytes((4, 2)) + len(objects).to_bytes(8, "big")
            + (0).to_bytes(8, "big") + table_offset.to_bytes(8, "big"))


class ProducerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="compile-receipt-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.scratch = Path(cls.temporary.name).resolve()
        cls.template = cls.scratch / "template"
        pins = []
        dependencies = []
        for identity in receipt.IDENTITIES:
            root = cls.template / "Packages/checkouts" / identity
            write(root / "Sources/Package Input.swift", b"struct PackageInput {}\n")
            revision = initialize(root)
            pin = {"identity": identity, "kind": "remoteSourceControl",
                   "location": "https://example.invalid/" + identity,
                   "state": {"revision": revision, "version": "1.0.0"}}
            pins.append(pin)
            dependencies.append({
                "basedOn": None, "packageRef": {key: pin[key]
                                                for key in ("identity", "kind", "location")},
                "state": {"name": "sourceControlCheckout", "checkoutState": pin["state"]},
                "subpath": identity,
            })
            dependencies[-1]["packageRef"]["name"] = "Retained " + identity
        source = cls.template / "source"
        for relative in receipt.REVIEWED:
            write(source / relative, b"synthetic reviewed project input\n")
        write(source / receipt.LOCKFILE, receipt.encode(
            {"version": 3, "originHash": "1" * 64, "pins": pins}))
        write(source / "Sources/App Input.swift", b"struct AppInput {}\n")
        write(source / ".gitignore", b"ignored\n")
        cls.commit = initialize(source)
        cls.tree = fixture_git(source, "rev-parse", "HEAD^{tree}")
        write(cls.template / "Packages/workspace-state.json", receipt.encode({
            "version": 7, "object": {"artifacts": [], "prebuilts": [],
                                     "dependencies": dependencies},
        }))

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="case-", dir=self.scratch)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.w = self.root / "W"
        shutil.copytree(self.template, self.w)
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.binary = str(self.developer / "usr/bin/xcodebuild")
        write(Path(self.binary), b"synthetic compiler witness, never executed")
        for name, fields in (
            ("Info.plist", {"CFBundleShortVersionString": "26.1", "CFBundleVersion": "24000",
                            "DTXcodeBuild": "17A100"}),
            ("version.plist", {"CFBundleShortVersionString": "26.1",
                               "CFBundleVersion": "24000", "ProductBuildVersion": "17B200"}),
        ):
            write(self.developer.parent / name, plistlib.dumps(fields))
        for target, value in (("DEVELOPER", str(self.developer)), ("XCODEBUILD", self.binary)):
            patcher = mock.patch.object(receipt, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.compile = mock.patch.object(build_mac, "compile_once", side_effect=self.fake_compile)
        self.compiler = self.compile.start()
        self.addCleanup(self.compile.stop)
        self.final = self.w / "build-evidence/receipt.json"
        # Every launch call, including expected refusals, has private fail-fast
        # Xcode and signal boundaries. Never patch Popen: consumer Git is real.
        for target in ("_spawn", "_signal_group"):
            patcher = mock.patch.object(mac_launch, target,
                                        side_effect=AssertionError("unexpected " + target))
            setattr(self, target, patcher.start())
            self.addCleanup(patcher.stop)
        for target in ("kill", "killpg"):
            patcher = mock.patch.object(os, target,
                                        side_effect=AssertionError("real signaling forbidden"))
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_compile(self, argv, environment, cwd, stdout, stderr):
        self.assertEqual(argv, receipt.recipe(self.w))
        self.assertEqual(environment, receipt.environment(self.w))
        self.assertEqual(cwd, self.w / "source")
        evidence = self.w / "build-evidence"
        for name in ("claim.json", "journal.log", "stdout.log", "stderr.log"):
            self.assertTrue((evidence / name).is_file())
        self.assertEqual(json.loads((evidence / "journal.log").read_bytes())["state"],
                         "compile-intent")
        write(self.w / receipt.PRODUCTS / "Mac.xctestrun", plistlib.dumps(FIXTURE))
        write(self.w / receipt.PRODUCTS / "Debug/FluxKlangMac.app/Contents/MacOS/FluxKlangMac",
              b"synthetic compiled bytes")
        generated = self.w / receipt.DERIVED_SOURCES / "Generated Input.swift"
        write(generated, b"struct GeneratedInput {}\n")
        paths = [self.w / "source/Sources/App Input.swift", generated]
        paths += [self.w / "Packages/checkouts" / identity / "Sources/Package Input.swift"
                  for identity in receipt.IDENTITIES]
        for relative in (*receipt.MANDATORY, "Extra/Other.SwiftFileList"):
            write(self.w / receipt.INTERMEDIATES / relative,
                  ("\n".join(str(path) for path in paths) + "\n").encode())
        stdout.write(b"synthetic compile stdout\n")
        stderr.write(b"synthetic compile stderr\n")
        return 0

    def fake_compile_space_escaped(self, *args):
        code = self.fake_compile(*args)
        for relative in (*receipt.MANDATORY, "Extra/Other.SwiftFileList"):
            path = self.w / receipt.INTERMEDIATES / relative
            path.write_bytes(path.read_bytes().replace(b" ", b"\\ "))
        return code

    def fake_compile_nested_generated(self, *args):
        code = self.fake_compile(*args)
        leaf = self.w / receipt.DERIVED_SOURCES / "Container.swift/Leaf.swift"
        write(leaf, b"struct NestedGeneratedInput {}\n")
        for relative in (*receipt.MANDATORY, "Extra/Other.SwiftFileList"):
            path = self.w / receipt.INTERMEDIATES / relative
            with path.open("ab") as stream:
                stream.write((str(leaf) + "\n").encode())
        return code

    def produce(self):
        return build_mac.produce(str(self.w), self.commit, self.tree)

    def consume(self, result):
        return receipt.validate(result["receipt"], result["sha256"])

    def launch_fixture(self, name=None):
        if name is not None:
            self.w = self.root / name
            shutil.copytree(self.template, self.w)
            self.final = self.w / "build-evidence/receipt.json"
        count = self.compiler.call_count
        with mock.patch.object(prepare, "prepare", wraps=prepare.prepare) as preparation:
            result = self.produce()
        preparation.assert_called_once()
        self.assertEqual(self.compiler.call_count, count + 1)
        return result, self.w.with_name(self.w.name + ".mac-launch-evidence")

    def reserve(self, result):
        import mac_launch_claim

        # Real validation may run restricted read-only Git observations. Only
        # production/preparation/new identity are forbidden, not all processes.
        with mock.patch.object(build_mac, "produce", side_effect=AssertionError("producer")), \
                mock.patch.object(build_mac, "compile_once", side_effect=AssertionError("compile")), \
                mock.patch.object(prepare, "prepare", side_effect=AssertionError("prepare")), \
                mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("new identity")):
            return mac_launch_claim.claim(result["receipt"], result["sha256"])

    def fake_child(self, code=0, pid=314159):
        child = mock.Mock(pid=pid)
        child.wait.return_value = code
        child.poll.return_value = code
        self._spawn.reset_mock(side_effect=True)
        self._spawn.return_value = child
        self._signal_group.reset_mock(side_effect=True)
        self._signal_group.side_effect = AssertionError("unexpected signal")
        return child

    def launch(self, result):
        # Guard against accidental extra production/preparation/new identity.
        with mock.patch.object(build_mac, "produce", side_effect=AssertionError("producer")), \
                mock.patch.object(build_mac, "compile_once", side_effect=AssertionError("compile")), \
                mock.patch.object(prepare, "prepare", side_effect=AssertionError("prepare")), \
                mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("new identity")):
            return mac_launch.launch(result["receipt"], result["sha256"])

    def assert_launch_consumed(self, result, slot):
        before = snapshot(slot)
        count = self._spawn.call_count
        with self.assertRaises((receipt.Refusal, OSError)):
            self.launch(result)
        self.assertEqual(self._spawn.call_count, count)
        self.assertEqual(snapshot(slot), before)

    def test_mac_launch_exit_contract_environment_and_preservation(self):
        for code in (0, 7, -15):
            with self.subTest(returncode=code):
                result, slot = self.launch_fixture("exit-" + str(code))
                intent = self.consume(result)
                prepared = Path(intent["output"]["path"])
                prepared_bytes = prepared.read_bytes()
                before = snapshot(self.w)
                child = self.fake_child(code)
                prelaunch = None

                def spawn(argv, **kwargs):
                    nonlocal prelaunch
                    prelaunch = (slot / "prelaunch.json").read_bytes()
                    self.assertEqual(argv, [
                        self.binary, "test-without-building", "-xctestrun", str(prepared),
                        "-destination", "platform=macOS,arch=arm64",
                        "-parallel-testing-enabled", "NO", "-test-iterations", "1",
                        "-derivedDataPath", str(slot / "DerivedData"),
                        "-resultBundlePath", str(slot / "result.xcresult"),
                    ])
                    self.assertEqual(set(kwargs), {
                        "env", "cwd", "stdout", "stderr", "stdin", "close_fds", "shell",
                        "start_new_session",
                    })
                    self.assertEqual(kwargs["env"], {
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "DEVELOPER_DIR": str(self.developer), "HOME": str(slot / "home"),
                        "TMPDIR": str(slot / "tmp"), "LC_ALL": "C",
                    })
                    self.assertEqual(kwargs["cwd"], str(slot))
                    self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                    for name, value in (("close_fds", True), ("shell", False),
                                        ("start_new_session", True)):
                        self.assertIs(kwargs[name], value)
                    for name in ("stdout", "stderr"):
                        stream = kwargs[name]
                        self.assertFalse(stream.closed)
                        self.assertTrue(stat.S_ISREG(os.fstat(stream.fileno()).st_mode))
                        self.assertEqual(stream.name, str(slot / (name + ".log")))
                        os.write(stream.fileno(), (name + " fake child bytes\n").encode())
                    for name in ("home", "tmp"):
                        self.assertEqual(stat.S_IMODE((slot / name).stat().st_mode), 0o700)
                    for name in ("DerivedData", "result.xcresult", "process-outcome.json"):
                        self.assertFalse(os.path.lexists(slot / name))
                    self.assertEqual(prepared.read_bytes(), prepared_bytes)
                    self.assertEqual(plistlib.loads(prepared_bytes)["FluxKlangMacTests"]
                                     ["EnvironmentVariables"]["FLUXKLANG_AUDIT_RUN_ID"],
                                     intent["run_id"])
                    return child

                self._spawn.side_effect = spawn
                with mock.patch.dict(os.environ, {
                    "DYLD_INSERT_LIBRARIES": "/not/loaded", "FLUXKLANG_AUDIT_RUN_ID": "ambient",
                    "GIT_INDEX_FILE": "/not/used", "HOME": "/not/copied", "LC_ALL": "ambient",
                }):
                    environment = dict(os.environ)
                    with mock.patch.object(mac_launch_claim, "claim",
                                           wraps=mac_launch_claim.claim) as claim, \
                            mock.patch.object(receipt, "validate",
                                              wraps=receipt.validate) as validation:
                        outcome = self.launch(result)
                    self.assertEqual(dict(os.environ), environment)
                claim.assert_called_once_with(result["receipt"], result["sha256"])
                self.assertEqual(validation.call_count, 3)
                self._spawn.assert_called_once()
                child.wait.assert_called_once_with(timeout=1800)
                self._signal_group.assert_not_called()
                expected = {
                    "schema_version": 1, "state": "process-exited", "reservation": str(slot),
                    "receipt_sha256": result["sha256"], "prepared_xctestrun": str(prepared),
                    "pid": child.pid, "returncode": code, "descendant_closure": "unproven",
                    "artifacts_sealed": False,
                }
                receipt.equal(outcome, expected, "exact typed outcome")
                self.assertEqual((slot / "process-outcome.json").read_bytes(),
                                 receipt.encode(expected))
                self.assertEqual((slot / "prelaunch.json").read_bytes(), prelaunch)
                self.assertEqual(snapshot(self.w), before)
                for name in ("stdout", "stderr"):
                    self.assertEqual((slot / (name + ".log")).read_bytes(),
                                     (name + " fake child bytes\n").encode())
                    self.assertTrue(self._spawn.call_args.kwargs[name].closed)
                self.assert_launch_consumed(result, slot)

    def test_mac_launch_refusals_and_competition(self):
        result, slot = self.launch_fixture()
        for pin in ("0" * 64, "A" * 64, "", None, True):
            with self.subTest(pin=pin):
                with self.assertRaises(receipt.Refusal):
                    self.launch(dict(result, sha256=pin))
                self.assertFalse(os.path.lexists(slot))
        for path in (str(self.final) + "\0", "/invalid\udcff", "/" + "x" * 4096):
            with self.subTest(path=path):
                with self.assertRaises(receipt.Refusal):
                    self.launch(dict(result, receipt=path))
        log = self.w / "build-evidence/stdout.log"
        log.write_bytes(b"actual drift")
        with self.assertRaises(receipt.Refusal):
            self.launch(result)
        self._spawn.assert_not_called()
        for kind in ("file", "directory", "partial", "dangling", "prior-record",
                     "claim-zero", "claim-sync"):
            with self.subTest(kind=kind):
                result, slot = self.launch_fixture(kind)
                if kind == "file":
                    slot.write_bytes(b"existing")
                elif kind == "dangling":
                    slot.symlink_to("missing")
                elif kind == "prior-record":
                    self.reserve(result)
                elif kind in ("directory", "partial"):
                    slot.mkdir()
                    if kind == "partial":
                        (slot / "prelaunch.json").write_bytes(b'{"partial":')
                before = snapshot(self.w)
                if kind == "claim-zero":
                    with mock.patch.object(build_mac, "write_all", return_value=None):
                        with self.assertRaises(receipt.Refusal):
                            self.launch(result)
                    self.assertEqual((slot / "prelaunch.json").stat().st_size, 0)
                elif kind == "claim-sync":
                    with mock.patch.object(mac_launch_claim, "sync_directory",
                                           side_effect=OSError("claim sync")):
                        with self.assertRaises(OSError):
                            self.launch(result)
                else:
                    old = snapshot(self.root)
                    with self.assertRaises(FileExistsError):
                        self.launch(result)
                    self.assertEqual(snapshot(self.root), old)
                self.assertEqual(snapshot(self.w), before)
                self._spawn.assert_not_called()
                self.assert_launch_consumed(result, slot)

        result, slot = self.launch_fixture("competition")
        before = snapshot(self.w)
        self.fake_child()
        barrier = threading.Barrier(2)
        original_mkdir = Path.mkdir

        def mkdir(path, *args, **kwargs):
            if path == slot:
                barrier.wait(timeout=30)
            return original_mkdir(path, *args, **kwargs)

        def compete():
            try:
                return mac_launch.launch(result["receipt"], result["sha256"])
            except FileExistsError:
                return None

        with mock.patch.object(Path, "mkdir", mkdir):
            with ThreadPoolExecutor(max_workers=2) as pool:
                outcomes = list(pool.map(lambda _: compete(), range(2)))
        self.assertEqual(sum(value is not None for value in outcomes), 1)
        self._spawn.assert_called_once()
        self.assertEqual(snapshot(self.w), before)
        self.assert_launch_consumed(result, slot)

    def test_mac_launch_setup_paths_and_final_real_validation(self):
        original_conf = os.fpathconf
        original_mkdir = Path.mkdir
        original_sync = build_mac.sync_directory
        original_open = Path.open
        cases = ["outcome-path-nul", "name-limit", "unknown-limit", "final-drift"]
        cases += ["mkdir-" + name for name in ("home", "tmp")]
        cases += ["sync-" + name for name in ("home", "tmp", "slot", "parent")]
        cases += ["open-" + name for name in ("stdout.log", "stderr.log")]
        cases += ["collision-" + name for name in (
            "home", "tmp", "stdout.log", "stderr.log", "DerivedData", "result.xcresult",
            "process-outcome.json")]
        for phase in cases:
            with self.subTest(phase=phase):
                result, slot = self.launch_fixture(phase)
                before = snapshot(self.w)
                prelaunch = None

                def limits(fd, key):
                    if slot.is_dir() and os.fstat(fd).st_ino == slot.stat().st_ino:
                        if phase == "outcome-path-nul" and key == "PC_PATH_MAX":
                            # Claim's prelaunch fits, but longer outcome + NUL does not.
                            return len(str(slot / "process-outcome.json").encode())
                        if phase == "name-limit" and key == "PC_NAME_MAX":
                            return len("process-outcome.json") - 1
                        if phase == "unknown-limit":
                            return -1
                    return original_conf(fd, key)

                def mkdir(path, *args, **kwargs):
                    if phase == "mkdir-" + path.name and path.parent == slot:
                        raise OSError("private mkdir")
                    return original_mkdir(path, *args, **kwargs)

                def opening(path, *args, **kwargs):
                    if path.parent == slot and phase == "open-" + path.name:
                        raise OSError("exclusive log open")
                    return original_open(path, *args, **kwargs)

                def sync(path):
                    nonlocal prelaunch
                    answer = original_sync(path)
                    # The claim imports its own sync function. This boundary is
                    # reached only after real claim completion and log setup.
                    if path == slot:
                        prelaunch = (slot / "prelaunch.json").read_bytes()
                    if phase == "final-drift" and path == slot:
                        (self.w / "build-evidence/stdout.log").write_bytes(b"real drift")
                    name = "slot" if path == slot else "parent" if path == slot.parent else path.name
                    if phase == "sync-" + name:
                        raise OSError("runner directory sync")
                    return answer

                # Inject an actual dangling entry after the real claim, at the
                # runner's first path-limit syscall; never mock claim success.
                inserted = False

                def conf(fd, key):
                    nonlocal inserted
                    if (phase.startswith("collision-") and not inserted and slot.is_dir()
                            and os.fstat(fd).st_ino == slot.stat().st_ino):
                        (slot / phase.removeprefix("collision-")).symlink_to("missing")
                        inserted = True
                    return limits(fd, key)

                with mock.patch.object(os, "fpathconf", side_effect=conf), \
                        mock.patch.object(Path, "mkdir", mkdir), \
                        mock.patch.object(Path, "open", opening), \
                        mock.patch.object(build_mac, "sync_directory", side_effect=sync):
                    with self.assertRaises((receipt.Refusal, OSError)):
                        self.launch(result)
                self._spawn.assert_not_called()
                self.assertTrue((slot / "prelaunch.json").is_file())
                if prelaunch is not None:
                    self.assertEqual((slot / "prelaunch.json").read_bytes(), prelaunch)
                if phase != "final-drift":
                    self.assertEqual(snapshot(self.w), before)
                self.assert_launch_consumed(result, slot)

    def test_mac_launch_wait_uncertainty_and_bounded_cleanup(self):
        timeout = lambda: subprocess.TimeoutExpired("fake Xcode", 1800)
        cases = [
            ("spawn", OSError("ambiguous spawn"), [], [], []),
            ("spawn-interrupt", KeyboardInterrupt("ambiguous spawn"), [], [], []),
            ("timeout", timeout(), [timeout(), -9], [None, None], [signal.SIGTERM, signal.SIGKILL]),
            ("wait-error", OSError("wait"), [-15], [None], [signal.SIGTERM]),
            ("interrupt", KeyboardInterrupt("wait"), [-15], [None], [signal.SIGTERM]),
            ("already-exited", timeout(), [], [0], []),
            ("term-leader-exit", timeout(), [0], [None], [signal.SIGTERM]),
            ("exit-before-kill", timeout(), [timeout()], [None, 0], [signal.SIGTERM]),
            ("term-failure", timeout(), [timeout(), -9], [None, None],
             [signal.SIGTERM, signal.SIGKILL]),
            ("kill-failure", timeout(), [timeout(), timeout()], [None, None],
             [signal.SIGTERM, signal.SIGKILL]),
            ("reap-failure", timeout(), [timeout(), OSError("reap")], [None, None],
             [signal.SIGTERM, signal.SIGKILL]),
            ("term-wait-failure", timeout(), [OSError("term wait")], [None], [signal.SIGTERM]),
            ("repeat-interrupt", KeyboardInterrupt("first"), [KeyboardInterrupt("second")],
             [None], [signal.SIGTERM]),
            ("poll-failure", OSError("wait"), [], [OSError("poll")], []),
        ]
        for phase, error, grace, polls, signals in cases:
            with self.subTest(phase=phase):
                result, slot = self.launch_fixture(phase)
                before = snapshot(self.w)
                child = self.fake_child()
                if phase.startswith("spawn"):
                    self._spawn.side_effect = error
                else:
                    child.wait.side_effect = [error, *grace]
                    child.poll.side_effect = polls

                def signaling(pid, signum):
                    self.assertIs(type(pid), int)
                    self.assertEqual(pid, child.pid)
                    self.assertGreater(pid, 0)
                    if (phase == "term-failure" and signum == signal.SIGTERM or
                            phase == "kill-failure" and signum == signal.SIGKILL):
                        raise OSError("signal syscall")

                self._signal_group.side_effect = signaling
                with self.assertRaises(type(error)) as raised:
                    self.launch(result)
                self.assertIs(raised.exception, error)
                self._spawn.assert_called_once()
                self.assertEqual(self._signal_group.call_args_list,
                                 [mock.call(child.pid, signum) for signum in signals])
                waits = [] if phase.startswith("spawn") else [
                    mock.call(timeout=1800), *[mock.call(timeout=5) for _ in grace]]
                self.assertEqual(child.wait.call_args_list, waits)
                self.assertFalse((slot / "process-outcome.json").exists())
                self.assertEqual(snapshot(self.w), before)
                self.assert_launch_consumed(result, slot)

        for field, values in (("pid", (True, 0, -1, 1.5, None)),
                              ("returncode", (True, 0.0, None))):
            for value in values:
                with self.subTest(field=field, value=value):
                    result, slot = self.launch_fixture(field + "-" + str(value))
                    child = self.fake_child()
                    if field == "pid":
                        child.pid = value
                    else:
                        child.wait.return_value = value
                    with self.assertRaises(receipt.Refusal):
                        self.launch(result)
                    self._signal_group.assert_not_called()
                    self._spawn.assert_called_once()
                    if field == "pid":
                        child.wait.assert_not_called()
                    self.assert_launch_consumed(result, slot)

    def test_mac_launch_log_and_outcome_io_faults(self):
        original_open = Path.open
        original_fsync = os.fsync
        original_bounded = receipt.bounded
        original_encode = receipt.encode
        cases = [(name, phase) for name in ("stdout.log", "stderr.log")
                 for phase in ("pre-flush", "pre-fsync", "post-flush", "post-fsync", "close")]
        cases += [("process-outcome.json", phase) for phase in (
            "open", "short", "partial", "zero", "flush", "fsync", "close", "dirsync",
            "reread", "bytes", "bound", "version-bool", "interrupt")]
        for name, phase in cases:
            with self.subTest(name=name, phase=phase):
                result, slot = self.launch_fixture(name + "-" + phase)
                target = slot / name
                self.fake_child()
                before = snapshot(self.w)
                short_writes = 0

                class Writer:
                    def __init__(self, stream):
                        self.stream = stream
                        self.writes = 0

                    def write(self, data):
                        nonlocal short_writes
                        self.writes += 1
                        if phase == "zero":
                            return 0
                        if phase == "partial" and self.writes > 1:
                            raise OSError("partial outcome")
                        if phase in ("short", "partial"):
                            short_writes += 1
                            return self.stream.write(data[:11])
                        return self.stream.write(data)

                    def flush(self):
                        stage = "post" if self_test._spawn.called else "pre"
                        if phase in ("flush", stage + "-flush"):
                            raise OSError("flush")
                        if phase == "interrupt":
                            raise KeyboardInterrupt("outcome flush")
                        self.stream.flush()

                    def fileno(self):
                        return self.stream.fileno()

                    def close(self):
                        self.stream.close()
                        if phase in ("close", "interrupt"):
                            raise OSError("close")

                self_test = self

                def opening(path, *args, **kwargs):
                    if path == target and args == ("xb",) and phase == "open":
                        raise OSError("outcome open")
                    stream = original_open(path, *args, **kwargs)
                    return Writer(stream) if path == target and args == ("xb",) else stream

                def fsync(fd):
                    info = os.fstat(fd)
                    stage = "post" if self._spawn.called else "pre"
                    if target.exists() and info.st_ino == target.stat().st_ino:
                        if phase in ("fsync", stage + "-fsync"):
                            raise OSError("file fsync")
                    if (phase == "dirsync" and self._spawn.called and slot.exists()
                            and info.st_ino == slot.stat().st_ino):
                        raise OSError("outcome directory fsync")
                    return original_fsync(fd)

                def bounded(path, *args, **kwargs):
                    if Path(path) == target and name == "process-outcome.json":
                        self.assertEqual(args, (receipt.METADATA_BYTES,))
                        if phase == "reread":
                            raise OSError("outcome reread")
                        if phase == "bytes":
                            witness, data = original_bounded(path, *args, **kwargs)
                            return witness, data + b"\n"
                    return original_bounded(path, *args, **kwargs)

                def encode(value):
                    if value.get("state") == "process-exited":
                        if phase == "bound":
                            return b"x" * (receipt.METADATA_BYTES + 1)
                        if phase == "version-bool":
                            return original_encode(dict(value, schema_version=True))
                    return original_encode(value)

                with mock.patch.object(Path, "open", opening), \
                        mock.patch.object(os, "fsync", side_effect=fsync), \
                        mock.patch.object(receipt, "bounded", side_effect=bounded), \
                        mock.patch.object(receipt, "encode", side_effect=encode):
                    if phase == "short":
                        self.assertEqual(self.launch(result)["returncode"], 0)
                        self.assertGreater(short_writes, 1)
                    else:
                        error = KeyboardInterrupt if phase == "interrupt" else (OSError, receipt.Refusal)
                        with self.assertRaises(error):
                            self.launch(result)
                self.assertEqual(self._spawn.call_count, 0 if phase.startswith("pre-") else 1)
                self._signal_group.assert_not_called()
                self.assertEqual(snapshot(self.w), before)
                if phase == "zero":
                    self.assertEqual(target.stat().st_size, 0)
                if phase == "partial":
                    self.assertEqual(target.stat().st_size, 11)
                self.assert_launch_consumed(result, slot)

    def test_launch_claim_preserves_complete_intent_and_workspace(self):
        result, slot = self.launch_fixture()
        intent = self.consume(result)
        before = snapshot(self.w)
        with mock.patch.object(receipt, "validate", wraps=receipt.validate) as validation:
            record = self.reserve(result)
        self.assertEqual(validation.call_count, 2)
        self.assertEqual(record, {
            "schema_version": 1, "status": "reservation-recorded",
            "workspace": str(self.w), "reservation": str(slot),
            "receipt": {"path": result["receipt"], "sha256": result["sha256"]},
            "intent": intent,
        })
        self.assertEqual(json.loads((slot / "prelaunch.json").read_bytes()), record)
        self.assertEqual(list(slot.iterdir()), [slot / "prelaunch.json"])
        self.assertEqual(stat.S_IMODE(slot.stat().st_mode), 0o700)
        self.assertEqual(intent["qualification"], "partial-regression")
        self.assertEqual(intent["profile"], prepare.RETENTION_PROFILE)
        self.assertIn("attachment_policy", intent)
        self.assertEqual(snapshot(self.w), before)
        self.assertEqual(self.compiler.call_count, 1)
        consumed = snapshot(slot)
        with self.assertRaises(FileExistsError):
            self.reserve(result)
        self.assertEqual(snapshot(slot), consumed)

    def test_launch_claim_pin_drift_and_receipt_aliases_refuse_before_mkdir(self):
        result, slot = self.launch_fixture()
        copied = self.root / "receipt-copy.json"
        copied.write_bytes(self.final.read_bytes())
        linked = self.root / "receipt-link.json"
        linked.symlink_to(self.final)
        ancestor = self.root / "alias"
        ancestor.symlink_to(self.w, target_is_directory=True)
        invalid = [
            dict(result, sha256="0" * 64),
            dict(result, receipt=str(copied)),
            dict(result, receipt=str(linked)),
            dict(result, receipt=str(ancestor / "build-evidence/receipt.json")),
        ]
        for path in (str(self.final).replace("/build-evidence/", "//build-evidence/"),
                     str(self.w) + "/./build-evidence/receipt.json",
                     str(self.final) + "\0", "/invalid\udcff", "/" + "x" * 4096):
            invalid.append(dict(result, receipt=path))
        with mock.patch.object(Path, "mkdir", side_effect=AssertionError("premature mkdir")):
            for value in invalid:
                with self.subTest(receipt=value["receipt"], pin=value["sha256"]):
                    with self.assertRaises((receipt.Refusal, OSError)):
                        self.reserve(value)
            log = self.w / "build-evidence/stdout.log"
            log.write_bytes(log.read_bytes() + b"drift")
            with self.assertRaises(receipt.Refusal):
                self.reserve(result)
        self.assertFalse(os.path.lexists(slot))

    def test_launch_claim_local_limits_and_record_bound_precede_mkdir(self):
        result, slot = self.launch_fixture()
        original_conf = os.fpathconf
        parent_info = self.root.stat()
        for kind in ("suffix", "record-path-nul", "unknown", "metadata"):
            with self.subTest(kind=kind):
                def limits(fd, key):
                    info = os.fstat(fd)
                    if (info.st_dev, info.st_ino) == (parent_info.st_dev, parent_info.st_ino):
                        if kind == "suffix" and key == "PC_NAME_MAX":
                            return len(slot.name.encode()) - 1
                        if kind == "record-path-nul" and key == "PC_PATH_MAX":
                            return len(str(slot / "prelaunch.json").encode())
                        if kind == "unknown":
                            return -1
                    return original_conf(fd, key)

                with mock.patch.object(os, "fpathconf", side_effect=limits), \
                        mock.patch.object(Path, "mkdir", side_effect=AssertionError("premature mkdir")):
                    if kind == "metadata":
                        with mock.patch.object(receipt, "encode",
                                               return_value=b"x" * (receipt.METADATA_BYTES + 1)):
                            with self.assertRaises(receipt.Refusal):
                                self.reserve(result)
                    else:
                        with self.assertRaises(receipt.Refusal):
                            self.reserve(result)
                self.assertFalse(os.path.lexists(slot))
        # A genuinely supported W basename can become unsupported after the
        # fixed suffix. Real compile/preparation/validation still succeed.
        name_max = os.pathconf(self.root, "PC_NAME_MAX")
        result, slot = self.launch_fixture("w" * (name_max - 1))
        with mock.patch.object(Path, "mkdir", side_effect=AssertionError("premature mkdir")):
            with self.assertRaises(receipt.Refusal):
                self.reserve(result)
        self.assertFalse(os.path.lexists(slot))

    def test_launch_claim_existing_slots_are_untouched(self):
        for kind in ("file", "directory", "partial", "dangling"):
            with self.subTest(kind=kind):
                result, slot = self.launch_fixture(kind)
                if kind == "file":
                    slot.write_bytes(b"existing")
                elif kind == "dangling":
                    slot.symlink_to("missing")
                else:
                    slot.mkdir()
                    if kind == "partial":
                        (slot / "prelaunch.json").write_bytes(b'{"partial":')
                before = snapshot(self.root)
                with self.assertRaises(FileExistsError):
                    self.reserve(result)
                self.assertEqual(snapshot(self.root), before)

    def test_launch_claim_competing_claimants_have_one_success(self):
        import mac_launch_claim

        result, slot = self.launch_fixture()
        before = snapshot(self.w)
        barrier = threading.Barrier(2)
        original_mkdir = Path.mkdir

        def mkdir(path, *args, **kwargs):
            if path == slot:
                barrier.wait(timeout=30)
            return original_mkdir(path, *args, **kwargs)

        def compete():
            try:
                return mac_launch_claim.claim(result["receipt"], result["sha256"])
            except FileExistsError:
                return None

        with mock.patch.object(Path, "mkdir", mkdir), \
                mock.patch.object(prepare, "prepare", side_effect=AssertionError("prepare")), \
                mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("identity")), \
                mock.patch.object(build_mac, "compile_once", side_effect=AssertionError("compile")):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: compete(), range(2)))
        self.assertEqual(sum(value is not None for value in results), 1)
        self.assertEqual(snapshot(self.w), before)
        self.assertEqual(self.compiler.call_count, 1)

    def test_launch_claim_publication_failures_consume_without_repair(self):
        original_open = Path.open
        original_mkdir = Path.mkdir
        original_fsync = os.fsync
        original_bounded = receipt.bounded
        for phase in ("partial", "zero", "flush", "close", "parent-sync", "dir-sync",
                      "final-parent-sync", "file-sync", "reread", "reread-bytes",
                      "extra-entry", "revalidation", "postmkdir-interrupt",
                      "mkdir-return-interrupt"):
            with self.subTest(phase=phase):
                result, slot = self.launch_fixture(phase)
                before = snapshot(self.w)
                record_path = slot / "prelaunch.json"
                parent_syncs = 0

                class Writer:
                    def __init__(self, stream):
                        self.stream = stream
                        self.writes = 0

                    def __enter__(self):
                        return self

                    def __exit__(self, *args):
                        self.stream.close()

                    def write(self, data):
                        self.writes += 1
                        if phase == "zero":
                            return 0
                        if phase == "partial":
                            if self.writes > 1:
                                raise OSError("partial write")
                            return self.stream.write(data[:11])
                        return self.stream.write(data)

                    def flush(self):
                        if phase == "flush":
                            raise OSError("flush")
                        self.stream.flush()

                    def fileno(self):
                        return self.stream.fileno()

                    def close(self):
                        self.stream.close()
                        if phase == "close":
                            raise OSError("close")

                def opening(path, *args, **kwargs):
                    stream = original_open(path, *args, **kwargs)
                    return Writer(stream) if path == record_path and args == ("xb",) else stream

                def mkdir(path, *args, **kwargs):
                    answer = original_mkdir(path, *args, **kwargs)
                    if path == slot and phase == "mkdir-return-interrupt":
                        raise KeyboardInterrupt("mkdir succeeded before returning")
                    return answer

                def fsync(fd):
                    nonlocal parent_syncs
                    info = os.fstat(fd)
                    parent = self.root.stat()
                    if (info.st_dev, info.st_ino) == (parent.st_dev, parent.st_ino):
                        parent_syncs += 1
                        if phase == "postmkdir-interrupt":
                            raise KeyboardInterrupt("first parent sync")
                        if phase == "parent-sync" or (phase == "final-parent-sync"
                                                      and parent_syncs == 2):
                            raise OSError("parent fsync")
                        if phase == "extra-entry":
                            (slot / "unexpected").write_bytes(b"retained")
                        if phase == "revalidation":
                            log = self.w / "build-evidence/stdout.log"
                            log.write_bytes(b"postclaim drift")
                    elif stat.S_ISDIR(info.st_mode) and phase == "dir-sync":
                        raise OSError("claim directory fsync")
                    elif stat.S_ISREG(info.st_mode) and phase == "file-sync":
                        raise OSError("record fsync")
                    return original_fsync(fd)

                def bounded(path, *args, **kwargs):
                    if Path(path) == record_path:
                        if phase == "reread":
                            raise OSError("reread")
                        if phase == "reread-bytes":
                            witness, data = original_bounded(path, *args, **kwargs)
                            return witness, data + b"\n"
                    return original_bounded(path, *args, **kwargs)

                with mock.patch.object(Path, "open", opening), \
                        mock.patch.object(Path, "mkdir", mkdir), \
                        mock.patch.object(os, "fsync", side_effect=fsync), \
                        mock.patch.object(receipt, "bounded", side_effect=bounded):
                    with self.assertRaises((OSError, receipt.Refusal, KeyboardInterrupt)):
                        self.reserve(result)
                self.assertTrue(slot.is_dir())
                consumed = snapshot(slot)
                if phase != "revalidation":
                    self.assertEqual(snapshot(self.w), before)
                if phase == "partial":
                    self.assertEqual(record_path.stat().st_size, 11)
                if phase == "zero":
                    self.assertEqual(record_path.stat().st_size, 0)
                with self.assertRaises((FileExistsError, receipt.Refusal)):
                    self.reserve(result)
                self.assertEqual(snapshot(slot), consumed)

    def assert_consumed(self):
        self.assertTrue((self.w / "build-evidence").is_dir())
        self.assertFalse(self.final.exists())
        count = self.compiler.call_count
        with self.assertRaises((receipt.Refusal, OSError)):
            self.produce()
        self.assertEqual(self.compiler.call_count, count)

    def pin_nio_revision(self):
        """Only disposable test repos: update the sole lock/state pin together."""
        revision = fixture_git(self.nio, "rev-parse", "HEAD")
        lockfile = self.w / "source" / receipt.LOCKFILE
        lock = json.loads(lockfile.read_bytes())
        next(pin for pin in lock["pins"] if pin["identity"] == "swift-nio")["state"]["revision"] = revision
        lockfile.write_bytes(receipt.encode(lock))
        statefile = self.w / "Packages/workspace-state.json"
        state = json.loads(statefile.read_bytes())
        dependency = next(d for d in state["object"]["dependencies"]
                          if d["packageRef"]["identity"] == "swift-nio")
        dependency["state"]["checkoutState"]["revision"] = revision
        statefile.write_bytes(receipt.encode(state))
        fixture_git(self.w / "source", "add", receipt.LOCKFILE)
        fixture_git(self.w / "source", "commit", "-m", "synthetic reviewed NIO pin")
        self.commit = fixture_git(self.w / "source", "rev-parse", "HEAD")
        self.tree = fixture_git(self.w / "source", "rev-parse", "HEAD^{tree}")

    def add_nio_links(self):
        self.nio = self.w / "Packages/checkouts/swift-nio"
        self.nio_data = self.nio / "Tests/NIOFSIntegrationTests/Test Data"
        write(self.nio_data / "Foo/Fixture.swift", b"struct RealTrackedFixture {}\n")
        write(self.nio_data / "README.md", b"real tracked fixture readme\n")
        (self.nio_data / "Foo.symlink").symlink_to("Foo", target_is_directory=True)
        (self.nio_data / "README.md.symlink").symlink_to("README.md")
        fixture_git(self.nio, "add", ".")
        fixture_git(self.nio, "commit", "-m", "synthetic genuine tracked fixture links")
        self.pin_nio_revision()

    def test_space_escape_real_prepare_seal_pinned_consumer_and_raw_witness(self):
        self.nio = self.w / "Packages/checkouts/swift-nio"
        spaced = self.nio / "Sources/More  Spaced Input.swift"
        write(spaced, b"struct MultipleSpacedInput {}\n")
        fixture_git(self.nio, "add", ".")
        fixture_git(self.nio, "commit", "-m", "synthetic tracked multiple spaces")
        self.pin_nio_revision()

        def compile_spaced(*args):
            code = self.fake_compile_space_escaped(*args)
            path = self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0]
            with path.open("ab") as stream:
                stream.write((str(spaced).replace(" ", "\\ ") + "\n").encode())
            return code

        self.compiler.side_effect = compile_spaced
        result = self.produce()  # Real prepare, metadata validation and Products seal.
        value = json.loads(self.final.read_bytes())
        for item in value["inputs"]["lists"]:
            raw = Path(item["file"]["path"]).read_bytes()
            self.assertIn(b"\\ ", raw)
            self.assertEqual(item["file"]["sha256"], prepare.digest(raw))
            self.assertEqual(item["file"]["size"], len(raw))
            self.assertEqual(receipt.swift_paths(raw), [i["path"] for i in item["inputs"]])
        selected = next(item for item in value["inputs"]["lists"]
                        if item["file"]["path"].endswith(receipt.MANDATORY[0]))
        self.assertIn({"path": str(spaced), "association": "package:swift-nio"}, selected["inputs"])
        path = Path(selected["file"]["path"])
        raw = path.read_bytes()
        self.assertIn(b"More\\ \\ Spaced\\ Input.swift", raw)
        before = snapshot(self.root)
        self.assertEqual(self.consume(result)["profile"], prepare.RETENTION_PROFILE)
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual(self.compiler.call_count, 1)
        # Equivalent decoded paths do NOT permit changing sealed raw evidence.
        equivalent = raw.replace(b"\\ ", b" ")
        self.assertEqual(receipt.swift_paths(raw), receipt.swift_paths(equivalent))
        self.assertNotEqual(prepare.digest(raw), prepare.digest(equivalent))
        path.write_bytes(equivalent)
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_space_escape_root_association_and_nofollow_boundaries(self):
        original_w = self.w
        outside = self.root / "Outside Input.swift"
        outside.write_bytes(b"struct OutsideInput {}\n")
        for index, case in enumerate(("outside", "unresolved", "symlink")):
            with self.subTest(case=case):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def compile_bad_input(*args):
                    code = self.fake_compile_space_escaped(*args)
                    if case == "outside":
                        input_path = outside
                    elif case == "unresolved":
                        input_path = self.w / "Packages/checkouts/swift-ascii/Unknown Input.swift"
                    else:
                        directory = self.w / receipt.DERIVED_SOURCES
                        (directory / "Alias Directory").symlink_to(directory, target_is_directory=True)
                        input_path = directory / "Alias Directory/Generated Input.swift"
                    path = self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0]
                    with path.open("ab") as stream:
                        stream.write((str(input_path).replace(" ", "\\ ") + "\n").encode())
                    return code

                self.compiler.side_effect = compile_bad_input
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.produce()
                self.assert_consumed()

    def test_space_escape_rehashed_receipt_and_list_corruption(self):
        self.compiler.side_effect = self.fake_compile_space_escaped
        self.produce()
        original = json.loads(self.final.read_bytes())
        for mutation in ("escaped-label", "association", "normalized-hash"):
            with self.subTest(mutation=mutation):
                value = copy.deepcopy(original)
                item = value["inputs"]["lists"][0]
                package_input = next(i for i in item["inputs"]
                                     if i["association"] == "package:swift-ascii")
                if mutation == "escaped-label":
                    package_input["path"] = package_input["path"].replace(" ", "\\ ")
                elif mutation == "association":
                    package_input["association"] = "source"
                else:
                    raw = Path(item["file"]["path"]).read_bytes()
                    item["file"]["sha256"] = prepare.digest(raw.replace(b"\\ ", b" "))
                data = receipt.encode(value)
                self.final.write_bytes(data)
                with self.assertRaises(receipt.Refusal):
                    receipt.validate(self.final, prepare.digest(data))
        path = Path(original["inputs"]["lists"][0]["file"]["path"])
        raw = path.read_bytes()
        for mutation in ("mixed-alias-duplicate", "invalid-escape"):
            with self.subTest(mutation=mutation):
                if mutation == "mixed-alias-duplicate":
                    corrupted = raw + raw.split(b"\n")[0].replace(b"\\ ", b" ") + b"\n"
                else:
                    corrupted = raw.replace(b"\\ ", b"\\q", 1)
                path.write_bytes(corrupted)
                value = copy.deepcopy(original)
                value["inputs"]["lists"][0]["file"] = receipt.file_data(path)[0]
                data = receipt.encode(value)
                self.final.write_bytes(data)
                with self.assertRaises(receipt.Refusal):
                    receipt.validate(self.final, prepare.digest(data))
                path.write_bytes(raw)

    def test_space_escape_raw_list_bound_precedes_decoding(self):
        def compile_oversized_list(*args):
            code = self.fake_compile_space_escaped(*args)
            path = self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0]
            path.write_bytes(b"\\ " * (receipt.METADATA_BYTES // 2) + b"x")
            return code

        self.compiler.side_effect = compile_oversized_list
        with self.assertRaisesRegex(receipt.Refusal, "regular byte limit"):
            self.produce()
        self.assert_consumed()

    def test_nio_links_real_prepare_seal_pinned_consumer_and_read_only(self):
        self.add_nio_links()

        def compile_real_referent(*args):
            code = self.fake_compile(*args)
            path = self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0]
            with path.open("ab") as stream:
                stream.write((str(self.nio_data / "Foo/Fixture.swift") + "\n").encode())
            return code

        self.compiler.side_effect = compile_real_referent
        result = self.produce()
        value = json.loads(self.final.read_bytes())
        nio = next(c for c in value["packages"]["checkouts"] if c["root"] == str(self.nio))
        entries = {entry["path"]: entry for entry in nio["entries"]}
        tracked = {entry["path"]: entry["git_mode"] for entry in nio["tracked"]}
        for name, target in (("Foo.symlink", "Foo"), ("README.md.symlink", "README.md")):
            relative = "Tests/NIOFSIntegrationTests/Test Data/" + name
            self.assertEqual(entries[relative], {
                "path": relative, "type": "symlink", "target": target,
                "mode": stat.S_IMODE((self.nio_data / name).lstat().st_mode),
            })
            self.assertEqual(tracked[relative], "120000")
            raw = target.encode()
            blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
            header = fixture_git(self.nio, "ls-tree", "HEAD", "--", relative).split("\t")[0]
            self.assertEqual(header, "120000 blob " + blob)
        self.assertIn("Tests/NIOFSIntegrationTests/Test Data/Foo/Fixture.swift", tracked)
        self.assertIn("Tests/NIOFSIntegrationTests/Test Data/README.md", tracked)
        self.assertFalse(any("/Foo.symlink/" in entry["path"] for entry in nio["entries"]))
        before = snapshot(self.root)
        self.assertEqual(self.consume(result)["profile"], prepare.RETENTION_PROFILE)
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual(self.compiler.call_count, 1)

    def test_nio_links_wrong_extra_missing_chained_external_and_referent_swaps(self):
        self.add_nio_links()
        for name, target in (("Foo.symlink", "Foo"), ("README.md.symlink", "README.md")):
            link = self.nio_data / name
            for wrong in ("missing", "../outside", str(self.root / "external"), "./" + target):
                with self.subTest(name=name, wrong=wrong):
                    link.unlink()
                    link.symlink_to(wrong)
                    with self.assertRaises((receipt.Refusal, OSError)):
                        receipt.package_observation(self.w)
            link.unlink()
            with self.assertRaises(receipt.Refusal):
                receipt.package_observation(self.w)
            # Same literal bytes are NOT an acceptable replacement for Git 120000.
            link.write_bytes(target.encode())
            with self.assertRaisesRegex(receipt.Refusal, "expected tracked package link"):
                receipt.package_observation(self.w)
            link.unlink()
            link.symlink_to(target)
            referent = self.nio_data / target
            saved = self.root / ("saved-" + target)
            referent.rename(saved)
            with self.assertRaises((receipt.Refusal, OSError)):
                receipt.package_observation(self.w)
            # Correct literal target but another link at that name must fail.
            referent.symlink_to(saved, target_is_directory=target == "Foo")
            with self.assertRaises((receipt.Refusal, OSError)):
                receipt.package_observation(self.w)
            referent.unlink()
            if target == "Foo":
                referent.write_bytes(b"directory replaced by file")
            else:
                referent.mkdir()
            with self.assertRaises(receipt.Refusal):
                receipt.package_observation(self.w)
            if referent.is_dir():
                referent.rmdir()
            else:
                referent.unlink()
            saved.rename(referent)
        extra = self.nio_data / "Extra.symlink"
        extra.symlink_to("Foo")
        with self.assertRaisesRegex(receipt.Refusal, "unsupported package fixture link"):
            receipt.package_observation(self.w)
        extra.unlink()
        # A file referent is still independently protected against hardlinks/dirt.
        external = self.root / "hardlink"
        os.link(self.nio_data / "README.md", external)
        with self.assertRaisesRegex(receipt.Refusal, "hardlink"):
            receipt.package_observation(self.w)
        external.unlink()
        (self.nio_data / "untracked").write_bytes(b"dirty")
        with self.assertRaisesRegex(receipt.Refusal, "dirty untracked"):
            receipt.package_observation(self.w)
        self.compiler.assert_not_called()
        self.assertFalse((self.w / "build-evidence").exists())

    def test_nio_links_wrong_git_mode_and_literal_blob_refuse(self):
        self.add_nio_links()
        relative = "Tests/NIOFSIntegrationTests/Test Data/Foo.symlink"
        original_blob = fixture_git(self.nio, "rev-parse", "HEAD:" + relative)
        fixture_git(self.nio, "update-index", "--cacheinfo", "100644," + original_blob + "," + relative)
        fixture_git(self.nio, "commit", "-m", "synthetic wrong link Git mode")
        self.pin_nio_revision()
        with self.assertRaisesRegex(receipt.Refusal, "expected tracked regular file"):
            receipt.package_observation(self.w)
        wrong = self.root / "wrong-literal-target"
        wrong.write_bytes(b"NotFoo")
        blob = fixture_git(self.nio, "hash-object", "-w", str(wrong))
        fixture_git(self.nio, "update-index", "--cacheinfo", "120000," + blob + "," + relative)
        fixture_git(self.nio, "commit", "-m", "synthetic wrong literal target blob")
        self.pin_nio_revision()
        with self.assertRaisesRegex(receipt.Refusal, "dirty tracked bytes"):
            receipt.package_observation(self.w)
        self.compiler.assert_not_called()

    def test_nio_links_directory_requires_component_delimited_tracked_descendant(self):
        self.add_nio_links()
        (self.nio_data / "Foo/Fixture.swift").unlink()
        write(self.nio_data / "FooSibling/Fixture.swift", b"struct NotADescendant {}\n")
        fixture_git(self.nio, "add", "-A")
        fixture_git(self.nio, "commit", "-m", "synthetic untracked directory referent")
        self.pin_nio_revision()
        self.assertTrue((self.nio_data / "Foo").is_dir())  # Existence alone is not proof.
        with self.assertRaisesRegex(receipt.Refusal, "lacks tracked descendant"):
            receipt.package_observation(self.w)
        self.compiler.assert_not_called()

    def test_nio_links_wrong_root_package_and_default_inventories_refuse(self):
        self.add_nio_links()
        with self.assertRaisesRegex(receipt.Refusal, "unsupported package fixture link"):
            receipt.inventory(self.nio)  # Ordinary inventories stay link-free.
        with self.assertRaisesRegex(receipt.Refusal, "unsupported package fixture link"):
            receipt.inventory(self.nio, workspace=self.w / "wrong")
        for root in (self.w / "source", self.w / "Packages/checkouts/swift-ascii",
                     self.nio / ".git", self.w / receipt.PRODUCTS,
                     self.w / receipt.DERIVED_SOURCES):
            with self.subTest(root=root):
                data = root / "Tests/NIOFSIntegrationTests/Test Data"
                write(data / "Foo/Fixture.swift", b"struct WrongRoot {}\n")
                (data / "Foo.symlink").symlink_to("Foo", target_is_directory=True)
                with self.assertRaisesRegex(receipt.Refusal, "unsupported package fixture link"):
                    receipt.inventory(root, workspace=self.w)
                shutil.rmtree(root / "Tests")

    def test_nio_links_swift_descendant_alias_refused_without_traversal(self):
        self.add_nio_links()
        alias = self.nio_data / "Foo.symlink/Fixture.swift"
        with self.assertRaises(OSError):
            receipt.file_data(alias)

        def compile_alias(*args):
            code = self.fake_compile(*args)
            path = self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0]
            with path.open("ab") as stream:
                stream.write((str(alias) + "\n").encode())
            return code

        self.compiler.side_effect = compile_alias
        with self.assertRaisesRegex(receipt.Refusal, "unresolved Swift input"):
            self.produce()
        self.assert_consumed()

    def test_nio_links_permission_and_literal_target_drift(self):
        self.add_nio_links()
        result = self.produce()
        link = self.nio_data / "README.md.symlink"
        original_mode = stat.S_IMODE(link.lstat().st_mode)
        referent_mode = (self.nio_data / "README.md").stat().st_mode
        os.chmod(link, original_mode ^ 0o100, follow_symlinks=False)
        self.assertEqual(stat.S_IMODE(link.lstat().st_mode), original_mode ^ 0o100)
        self.assertEqual((self.nio_data / "README.md").stat().st_mode, referent_mode)
        with self.assertRaises(receipt.Refusal):
            self.consume(result)
        os.chmod(link, original_mode, follow_symlinks=False)
        link.unlink()
        link.symlink_to("Foo")
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_nio_links_rehashed_receipt_cannot_grant_exceptions(self):
        self.add_nio_links()
        self.produce()
        original = json.loads(self.final.read_bytes())
        relative = "Tests/NIOFSIntegrationTests/Test Data/"

        def nio(value):
            return next(c for c in value["packages"]["checkouts"] if c["root"] == str(self.nio))

        def entry(value, name):
            return next(e for e in nio(value)["entries"] if e["path"] == relative + name)

        def flatten(value):
            link = entry(value, "Foo.symlink")
            link.pop("target")
            link.update(type="file", size=3, sha256=prepare.digest(b"Foo"))

        def wrong_git_mode(value):
            next(e for e in nio(value)["tracked"]
                 if e["path"] == relative + "Foo.symlink")["git_mode"] = "100644"

        def no_descendant(value):
            nio(value)["tracked"] = [t for t in nio(value)["tracked"]
                                     if not t["path"].startswith(relative + "Foo/")]

        def wrong_root(value):
            nio(value)["root"] = str(self.w / "Packages/checkouts/swift-ascii")

        for mutate in (
            lambda v: entry(v, "Foo.symlink").update(target="../Foo"),
            lambda v: entry(v, "Foo.symlink").update(mode=True),
            lambda v: entry(v, "Foo.symlink").update(resolved_tracked_entry=None),
            lambda v: entry(v, "Foo.symlink").update(type="directory"),
            flatten, wrong_git_mode, no_descendant, wrong_root,
        ):
            with self.subTest(mutate=mutate):
                value = copy.deepcopy(original)
                mutate(value)
                data = receipt.encode(value)
                self.final.write_bytes(data)
                with self.assertRaises(receipt.Refusal):
                    receipt.schema(value)
                with self.assertRaises(receipt.Refusal):
                    receipt.validate(self.final, prepare.digest(data))
        # A well-typed but invented permission witness passes shape, not evidence.
        value = copy.deepcopy(original)
        entry(value, "Foo.symlink")["mode"] ^= 0o100
        receipt.schema(value)
        data = receipt.encode(value)
        self.final.write_bytes(data)
        with self.assertRaises(receipt.Refusal):
            receipt.validate(self.final, prepare.digest(data))

    def test_end_to_end_real_prepare_seal_consumer_and_read_only(self):
        result = self.produce()
        self.assertEqual(result["status"], "committed")
        self.assertEqual(self.compiler.call_count, 1)
        value = json.loads(self.final.read_bytes())
        self.assertEqual(len(value["packages"]["checkouts"]), 9)
        self.assertEqual(len(value["inputs"]["lists"]), 3)
        self.assertTrue(value["inputs"]["generated"])
        self.assertNotEqual(value["toolchain"]["info"]["fields"]["DTXcodeBuild"],
                            value["toolchain"]["version"]["fields"]["ProductBuildVersion"])
        before = snapshot(self.root)
        record = self.consume(result)
        self.assertEqual(record["profile"], prepare.RETENTION_PROFILE)
        prepared = Path(record["output"]["path"])
        parsed = plistlib.loads(prepared.read_bytes())
        self.assertEqual(parsed["FluxKlangMacTests"]["SystemAttachmentLifetime"], "keepAlways")
        self.assertEqual(snapshot(self.root), before)
        self.assertTrue(sys.dont_write_bytecode)
        self.assertFalse(list(self.root.rglob("__pycache__")))
        self.assertEqual(self.compiler.call_count, 1)
        with self.assertRaises(receipt.Refusal):
            receipt.validate(self.final.with_name("receipt.pending"), result["sha256"])
        with self.assertRaises(receipt.Refusal):
            receipt.validate(self.final, "0" * 64)
        with self.assertRaises(TypeError):
            receipt.validate(self.final)

    def test_binary_info_real_prepare_seal_pinned_consumer_and_separate_identities(self):
        info = {"CFBundleShortVersionString": "27.2", "CFBundleVersion": "25400.63.5",
                "DTXcodeBuild": "27B51", "Nested": [{"ValidKey": "retained raw witness"}]}
        version = {"CFBundleShortVersionString": "27.2", "CFBundleVersion": "25400.63.5",
                   "ProductBuildVersion": "27B52"}
        raw_info = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
        raw_version = plistlib.dumps(version, fmt=plistlib.FMT_XML)
        self.assertTrue(raw_info.startswith(b"bplist00"))
        write(self.developer.parent / "Info.plist", raw_info)
        write(self.developer.parent / "version.plist", raw_version)
        result = self.produce()  # Fake compile; REAL prepare, validation and seal.
        self.assertEqual(self.compiler.call_count, 1)
        value = json.loads(self.final.read_bytes())
        toolchain = value["toolchain"]
        self.assertEqual(toolchain["info"]["fields"]["DTXcodeBuild"], "27B51")
        self.assertEqual(toolchain["version"]["fields"]["ProductBuildVersion"], "27B52")
        for key, raw in (("info", raw_info), ("version", raw_version)):
            self.assertEqual(toolchain[key]["file"]["sha256"], prepare.digest(raw))
            self.assertEqual(toolchain[key]["file"]["size"], len(raw))
            self.assertEqual(toolchain[key]["fields"]["CFBundleVersion"], "25400.63.5")
        before = snapshot(self.root)
        record = self.consume(result)
        self.assertEqual(record["profile"], prepare.RETENTION_PROFILE)
        self.assertEqual(snapshot(self.root), before)
        # Mutating a binary Info witness is detected independently of version.
        info["DTXcodeBuild"] = "27B52"
        write(self.developer.parent / "Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_binary_info_actual_encoded_duplicate_and_non_string_keys_refuse(self):
        path = self.developer.parent / "Info.plist"
        original = plistlib.loads(path.read_bytes())
        for nested in (False, True):
            for kind in ("duplicate", "non-string"):
                with self.subTest(nested=nested, kind=kind):
                    extra = {"TwinA": "left", "TwinB": "right"} if kind == "duplicate" else {"K": "value"}
                    fields = dict(original)
                    fields.update({"Nested": extra} if nested else extra)
                    raw = plistlib.dumps(fields, fmt=plistlib.FMT_BINARY)
                    # Ordinary dict dumping cannot encode duplicate or integer
                    # keys. Replace equal-size *encoded key objects*, keeping the
                    # object references/offset table/trailer valid.
                    old, new = ((b"\x55TwinB", b"\x55TwinA") if kind == "duplicate"
                                else (b"\x51K", b"\x10\x01"))
                    self.assertEqual(raw.count(old), 1)
                    raw = raw.replace(old, new, 1)
                    ordinary = plistlib.loads(raw, fmt=plistlib.FMT_BINARY)
                    affected = ordinary["Nested"] if nested else ordinary
                    if kind == "duplicate":
                        self.assertEqual(affected["TwinA"], "right")  # Default parser loses a key.
                        self.assertNotIn("TwinB", affected)
                    else:
                        self.assertEqual(affected[1], "value")  # Actual integer dictionary key.
                    path.write_bytes(raw)
                    with self.assertRaises(receipt.Refusal):
                        receipt.toolchain_observation()
        self.compiler.assert_not_called()
        self.assertFalse((self.w / "build-evidence").exists())

    def test_binary_info_malformed_recursion_and_root_refusals(self):
        path = self.developer.parent / "Info.plist"
        fields = plistlib.loads(path.read_bytes())
        good = plistlib.dumps(fields, fmt=plistlib.FMT_BINARY)
        # Real deeply nested encoded objects exercise parser recursion failure,
        # without requiring the stdlib serializer itself to recurse.
        depth = sys.getrecursionlimit() + 50
        objects = [b"\xd1\x00\x01\x00\x02", b"\x51K"]
        objects += [b"\xa1" + (index + 1).to_bytes(2, "big")
                    for index in range(2, depth + 2)]
        objects.append(b"\x00")
        deep = binary_object_table(objects)
        with self.assertRaises(RecursionError):
            plistlib.loads(deep, fmt=plistlib.FMT_BINARY)
        malformed = (b"bplist00", good[:-10], b"bplist01" + good[8:],
                     binary_object_table([b"\xff"]), deep)
        for data in malformed:
            with self.subTest(data_prefix=data[:12]):
                path.write_bytes(data)
                with self.assertRaises(receipt.Refusal):
                    receipt.toolchain_observation()
        for root in ([], "not a dictionary", 7, b"data", [list(item) for item in fields.items()]):
            with self.subTest(root=root):
                path.write_bytes(plistlib.dumps(root, fmt=plistlib.FMT_BINARY))
                with self.assertRaisesRegex(receipt.Refusal, "must be dictionary"):
                    receipt.toolchain_observation()
        self.compiler.assert_not_called()

    def test_binary_info_critical_types_missing_fields_and_bound_refuse(self):
        path = self.developer.parent / "Info.plist"
        original = plistlib.loads(path.read_bytes())
        for field in ("CFBundleShortVersionString", "CFBundleVersion",
                      "DTXcodeBuild", "ProductBuildVersion"):
            for value in (False, 27, b"bytes", ["string"], {"nested": "string"}, ""):
                with self.subTest(field=field, value=value):
                    fields = dict(original, **{field: value})
                    path.write_bytes(plistlib.dumps(fields, fmt=plistlib.FMT_BINARY))
                    with self.assertRaises(receipt.Refusal):
                        receipt.toolchain_observation()
        for field in ("CFBundleShortVersionString", "CFBundleVersion"):
            fields = dict(original)
            del fields[field]
            path.write_bytes(plistlib.dumps(fields, fmt=plistlib.FMT_BINARY))
            with self.assertRaisesRegex(receipt.Refusal, "missing Xcode version field"):
                receipt.toolchain_observation()
        path.write_bytes(b"bplist00" + b"\0" * (receipt.METADATA_BYTES - 7))
        with self.assertRaisesRegex(receipt.Refusal, "byte limit"):
            receipt.toolchain_observation()
        self.compiler.assert_not_called()

    def test_binary_info_interruption_exceptions_propagate(self):
        path = self.developer.parent / "Info.plist"
        path.write_bytes(plistlib.dumps(plistlib.loads(path.read_bytes()), fmt=plistlib.FMT_BINARY))
        for interruption in (KeyboardInterrupt, SystemExit):
            with self.subTest(interruption=interruption):
                with mock.patch.object(receipt.plistlib, "loads", side_effect=interruption):
                    with self.assertRaises(interruption):
                        receipt.toolchain_observation()

    def test_binary_version_and_xctestrun_stay_refused(self):
        version = self.developer.parent / "version.plist"
        xml = version.read_bytes()
        version.write_bytes(plistlib.dumps(plistlib.loads(xml), fmt=plistlib.FMT_BINARY))
        with self.assertRaises(receipt.Refusal):
            receipt.toolchain_observation()
        self.compiler.assert_not_called()
        version.write_bytes(xml)

        def compile_binary_metadata(*args):
            code = self.fake_compile(*args)
            write(self.w / receipt.PRODUCTS / "Mac.xctestrun",
                  plistlib.dumps(FIXTURE, fmt=plistlib.FMT_BINARY))
            return code

        self.compiler.side_effect = compile_binary_metadata
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assert_consumed()

    def test_product_mutations_and_relocation(self):
        result = self.produce()
        products = self.w / receipt.PRODUCTS
        executable = products / "Debug/FluxKlangMac.app/Contents/MacOS/FluxKlangMac"
        original = executable.read_bytes()
        mode = executable.stat().st_mode
        for operation, restore in (
            (lambda: executable.write_bytes(b"changed"), lambda: executable.write_bytes(original)),
            (lambda: executable.chmod(0o4750), lambda: executable.chmod(stat.S_IMODE(mode))),
            (lambda: (products / "extra").write_bytes(b"x"), lambda: (products / "extra").unlink()),
            (lambda: (products / "empty").mkdir(), lambda: (products / "empty").rmdir()),
            (lambda: executable.rename(executable.with_name("renamed")),
             lambda: executable.with_name("renamed").rename(executable)),
            (lambda: (products / "dangling").symlink_to("missing"),
             lambda: (products / "dangling").unlink()),
            (lambda: os.mkfifo(products / "fifo"), lambda: (products / "fifo").unlink()),
            (lambda: (products / "Debug").chmod(0o1777),
             lambda: (products / "Debug").chmod(0o755)),
        ):
            with self.subTest(operation=operation):
                operation()
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.consume(result)
                restore()
        relocated = self.root / "relocated"
        self.w.rename(relocated)
        with self.assertRaises((receipt.Refusal, OSError)):
            receipt.validate(relocated / "build-evidence/receipt.json", result["sha256"])

    def test_extra_real_prepared_pair_refused(self):
        result = self.produce()
        original = self.w / receipt.PRODUCTS / "Mac.xctestrun"
        prepare.prepare(original, prepare.digest(original.read_bytes()), prepare.RETENTION_PROFILE)
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_source_package_and_independent_toolchain_drift(self):
        result = self.produce()
        for path in [self.w / "source/Sources/App Input.swift",
                     self.w / "Packages/checkouts/swift-ascii/Sources/Package Input.swift",
                     self.developer.parent / "Info.plist", self.developer.parent / "version.plist",
                     Path(self.binary), self.w / receipt.DERIVED_SOURCES / "Generated Input.swift",
                     self.w / "build-evidence/stdout.log"]:
            with self.subTest(path=path):
                original = path.read_bytes()
                if path.suffix == ".plist":
                    parsed = plistlib.loads(original)
                    parsed["CFBundleVersion"] = "changed"
                    path.write_bytes(plistlib.dumps(parsed))
                else:
                    path.write_bytes(original + b"changed")
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.consume(result)
                path.write_bytes(original)

    def test_lists_generated_parent_modes_and_metadata_bindings_drift(self):
        result = self.produce()
        value = json.loads(self.final.read_bytes())
        extra_list = self.w / receipt.INTERMEDIATES / "Extra/Other.SwiftFileList"
        original = extra_list.read_bytes()
        extra_list.write_bytes(original.replace(b"/App Input.swift", b"/Nonexistent.swift"))
        with self.assertRaises((receipt.Refusal, OSError)):
            self.consume(result)
        extra_list.write_bytes(original)
        generated_parent = self.w / receipt.DERIVED_SOURCES
        mode = stat.S_IMODE(generated_parent.stat().st_mode)
        generated_parent.chmod(0o1777)
        with self.assertRaises(receipt.Refusal):
            self.consume(result)
        generated_parent.chmod(mode)
        for key in ("original", "prepared", "intent"):
            path = Path(value["metadata"][key]["path"])
            data = path.read_bytes()
            path.write_bytes(data + b"\n")
            with self.assertRaises(receipt.Refusal):
                self.consume(result)
            path.write_bytes(data)
        output = Path(value["metadata"]["prepared"]["path"])
        data = output.read_bytes()
        output.unlink()
        output.symlink_to("missing")
        with self.assertRaises((receipt.Refusal, OSError)):
            self.consume(result)
        output.unlink()
        output.write_bytes(data)
        # Both malformed extra evidence and a removed mandatory list are caught.
        extra_list.write_bytes(b'"/unsupported/Quoted.swift"\n')
        with self.assertRaises(receipt.Refusal):
            self.consume(result)
        extra_list.write_bytes(original)
        (self.w / receipt.INTERMEDIATES / receipt.MANDATORY[1]).unlink()
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_closed_receipt_schema_and_duplicate_keys(self):
        self.produce()
        value = json.loads(self.final.read_bytes())
        for change in (
            lambda v: v.update(reviewed=True),
            lambda v: v.update(schema_version=True),
            lambda v: v["compile"].update(exit_code=False),
            lambda v: v["metadata"].update(profile=prepare.PROFILE),
            lambda v: v["products"][0].update(extra="unsupported"),
            lambda v: v["packages"]["checkouts"][0].update(root="/outside"),
            lambda v: v["inputs"]["lists"][0]["inputs"][0].update(association="generated"),
            lambda v: v["compile"]["environment"].update(OTHER="override"),
            lambda v: v["source"]["entries"][0].update(mode=True),
        ):
            with self.subTest(change=change):
                mutated = copy.deepcopy(value)
                change(mutated)
                data = receipt.encode(mutated)
                self.final.write_bytes(data)
                with self.assertRaises(receipt.Refusal):
                    receipt.validate(self.final, prepare.digest(data))
        data = receipt.encode(value).replace(b'"schema_version": 1,',
                                            b'"schema_version": 1, "schema_version": 1,')
        self.final.write_bytes(data)
        with self.assertRaisesRegex(receipt.Refusal, "duplicate"):
            receipt.validate(self.final, prepare.digest(data))

    def test_missing_extra_duplicate_and_mismatched_package_state(self):
        path = self.w / "Packages/workspace-state.json"
        raw = path.read_bytes()
        original = json.loads(raw)
        for change in (
            lambda d: d.pop(),
            lambda d: d.append(copy.deepcopy(d[0])),
            lambda d: d.__setitem__(1, copy.deepcopy(d[0])),
            lambda d: d[0]["packageRef"].update(location="https://elsewhere.invalid"),
            lambda d: d[0]["state"]["checkoutState"].update(revision="0" * 40),
            lambda d: d[0]["state"]["checkoutState"].update(version="2.0.0"),
            lambda d: d[0].update(subpath="../escape"),
            lambda d: d[0]["packageRef"].update(name=""),
        ):
            with self.subTest(change=change):
                value = copy.deepcopy(original)
                change(value["object"]["dependencies"])
                path.write_bytes(receipt.encode(value))
                with self.assertRaises(receipt.Refusal):
                    self.produce()
                self.assertEqual(self.compiler.call_count, 0)
                self.assertFalse((self.w / "build-evidence").exists())
        path.write_bytes(raw)
        (self.w / "Packages/checkouts/extra").mkdir()
        with self.assertRaises(receipt.Refusal):
            self.produce()

    def test_dirty_ignored_untracked_and_gitlink_refused(self):
        for root, name in ((self.w / "source", "ignored"),
                           (self.w / "source", "untracked"),
                           (self.w / "Packages/checkouts/swift-ascii", "untracked")):
            path = root / name
            path.write_bytes(b"dirty")
            with self.assertRaises(receipt.Refusal):
                self.produce()
            path.unlink()
        checkout = self.w / "Packages/checkouts/swift-ascii"
        (checkout / "Sources/Package Input.swift").write_bytes(b"edited")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)
        source = self.w / "source"
        fixture_git(source, "update-index", "--add", "--cacheinfo",
                    "160000," + self.commit + ",submodule")
        fixture_git(source, "commit", "-m", "synthetic unsupported gitlink")
        commit = fixture_git(source, "rev-parse", "HEAD")
        tree = fixture_git(source, "rev-parse", "HEAD^{tree}")
        with self.assertRaisesRegex(receipt.Refusal, "Git link/submodule"):
            receipt.source_observation(source, self.w, commit, tree)

    def assert_non_directory_git_marker_preflight_refusal(self, relative):
        root = self.w / relative
        marker = root / ".git"
        expected_commit = fixture_git(root, "rev-parse", "HEAD")
        real_file_data = receipt.file_data
        real_git = receipt.git
        for variant in ("internal-pointer", "hardlinked-pointer", "symlink-marker"):
            with self.subTest(root=relative, variant=variant):
                control = self.w / "test-git-storage" / (relative.replace("/", "-") + "-" + variant)
                control.parent.mkdir(parents=True, exist_ok=True)
                marker.rename(control)
                external_alias = self.root / "external-marker"
                try:
                    if variant == "symlink-marker":
                        marker.symlink_to(control, target_is_directory=True)
                    else:
                        marker.write_text("gitdir: " + str(control) + "\n", encoding="utf-8")
                        if variant == "hardlinked-pointer":
                            os.link(marker, external_alias)
                            self.assertFalse(external_alias.is_relative_to(self.w))
                            self.assertEqual(marker.stat().st_nlink, 2)
                    self.assertTrue(control.is_relative_to(self.w))
                    # Fixture setup proves the internal pointer really works in
                    # Git; refusal must not merely be caused by an invalid repo.
                    self.assertEqual(fixture_git(root, "rev-parse", "HEAD"), expected_commit)
                    before = snapshot(self.root)

                    def guarded_read(path, *args, **kwargs):
                        self.assertNotEqual(Path(path), marker, "rejected .git marker was read")
                        return real_file_data(path, *args, **kwargs)

                    def guarded_git(selected, *args):
                        self.assertNotEqual(Path(selected), root, "Git invoked for rejected root")
                        return real_git(selected, *args)

                    with mock.patch.object(receipt, "file_data", side_effect=guarded_read) as reads, \
                            mock.patch.object(receipt, "git", side_effect=guarded_git) as calls:
                        with self.assertRaisesRegex(receipt.Refusal, r"\.git.*directory"):
                            self.produce()
                        self.assertFalse(any(Path(c.args[0]) == marker for c in reads.call_args_list))
                        self.assertFalse(any(Path(c.args[0]) == root for c in calls.call_args_list))
                        if relative != "source":
                            # Valid roots earlier in the actual preflight order
                            # still receive their real read-only observations.
                            self.assertTrue(any(Path(c.args[0]) == self.w / "source"
                                                for c in calls.call_args_list))
                            self.assertTrue(any(Path(c.args[0]) == self.w / "Packages/checkouts/swift-ascii"
                                                for c in calls.call_args_list))
                    self.compiler.assert_not_called()
                    self.assertFalse((self.w / "build-evidence").exists())
                    self.assertFalse((self.w / "DerivedData").exists())
                    self.assertEqual(snapshot(self.root), before)
                finally:
                    if external_alias.exists():
                        external_alias.unlink()
                    marker.unlink()
                    control.rename(marker)

    def test_git_marker_source_internal_pointers_refuse_before_read_or_git(self):
        self.assert_non_directory_git_marker_preflight_refusal("source")

    def test_git_marker_package_internal_pointers_refuse_before_read_or_git(self):
        self.assert_non_directory_git_marker_preflight_refusal("Packages/checkouts/swift-nio")

    def assert_git_reserved_case_lookup(self, relative):
        root = self.w / relative
        external = self.root / "external-control"
        write(external, b"[fixture]\nvalue = external\n")
        real_git = receipt.git
        real_file_data = receipt.file_data
        for name in ("objects/info/ALTERNATES", "objects/info/HTTP-ALTERNATES",
                     "CONFIG", "CONFIG.WORKTREE"):
            with self.subTest(root=relative, name=name):
                target = root / ".git" / name
                lookup = root / ".git" / name.lower()
                original = lookup.read_bytes() if lookup.is_file() else None
                if original is not None:
                    lookup.rename(target)  # Preserve the actual uppercase directory entry.
                data = ((str(external) + "\n").encode() if "ALTERNATES" in name else
                        (original or b"") + b"\n[include]\npath = " + os.fsencode(external) + b"\n")
                write(target, data)
                try:
                    aliases = lookup.exists() and lookup.samefile(target)
                    before = snapshot(self.root)

                    def guarded_git(selected, *args):
                        self.assertNotEqual(Path(selected), root, "Git invoked before reserved-path refusal")
                        return real_git(selected, *args)

                    def guarded_read(path, *args, **kwargs):
                        self.assertNotEqual(Path(path), external, "external control was read")
                        return real_file_data(path, *args, **kwargs)

                    with mock.patch.object(receipt, "git", side_effect=guarded_git) as calls, \
                            mock.patch.object(receipt, "file_data", side_effect=guarded_read):
                        if aliases:
                            with self.assertRaisesRegex(receipt.Refusal, "alternates|configuration"):
                                self.produce()
                            if relative != "source":
                                self.assertTrue(any(Path(c.args[0]) == self.w / "source"
                                                    for c in calls.call_args_list))
                        else:
                            # On case-sensitive filesystems these are NOT Git's
                            # reserved paths. A casefolded-name proxy is incorrect.
                            receipt.git_control(root, self.w)
                        self.assertFalse(any(Path(c.args[0]) == root for c in calls.call_args_list))
                    self.compiler.assert_not_called()
                    self.assertFalse((self.w / "build-evidence").exists())
                    self.assertFalse((self.w / "DerivedData").exists())
                    self.assertEqual(snapshot(self.root), before)
                finally:
                    target.unlink()
                    if original is not None:
                        lookup.write_bytes(original)

    def test_git_reserved_case_source_lookup_refuses_before_git(self):
        self.assert_git_reserved_case_lookup("source")

    def test_git_reserved_case_package_lookup_refuses_before_git(self):
        self.assert_git_reserved_case_lookup("Packages/checkouts/swift-nio")

    def test_git_control_escape_alternates_hardlinks_and_external_config(self):
        source = self.w / "source"
        gitdir = source / ".git"
        external = self.root / "external-git"
        gitdir.rename(external)
        gitdir.write_text("gitdir: " + str(external) + "\n")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        gitdir.unlink()
        external.rename(gitdir)
        alternate = gitdir / "objects/info/alternates"
        alternate.write_text(str(external) + "\n")
        with self.assertRaisesRegex(receipt.Refusal, "alternates"):
            self.produce()
        alternate.unlink()
        hardlink = self.root / "linked-config"
        os.link(gitdir / "config", hardlink)
        with self.assertRaisesRegex(receipt.Refusal, "hardlink"):
            self.produce()
        hardlink.unlink()
        os.link(source / "Sources/App Input.swift", hardlink)
        with self.assertRaisesRegex(receipt.Refusal, "hardlink"):
            self.produce()
        hardlink.unlink()
        with (gitdir / "config").open("a") as stream:
            stream.write('\n[include]\npath = /outside\n')
        with self.assertRaisesRegex(receipt.Refusal, "configuration"):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)

    def test_missing_checkout_and_lockfile_pin_mutations(self):
        lockfile = self.w / "source" / receipt.LOCKFILE
        original = json.loads(lockfile.read_bytes())
        for mutation in (
            lambda v: v["pins"].pop(),
            lambda v: v["pins"].append(copy.deepcopy(v["pins"][0])),
            lambda v: v["pins"].__setitem__(1, copy.deepcopy(v["pins"][0])),
            lambda v: v["pins"][0].update(identity="unsupported"),
            lambda v: v["pins"][0]["state"].update(revision="short"),
            lambda v: v.update(version=True),
            lambda v: v["pins"][0].update(unreviewed=True),
        ):
            value = copy.deepcopy(original)
            mutation(value)
            with self.assertRaises(receipt.Refusal):
                receipt.pins_from_lock(receipt.encode(value))
        checkout = self.w / "Packages/checkouts/swift-ascii"
        checkout.rename(self.root / "removed-checkout")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)

    def test_ancestor_links_and_special_entries_before_claim(self):
        source = self.w / "source"
        actual = self.w / "real-source"
        source.rename(actual)
        source.symlink_to(actual, target_is_directory=True)
        with self.assertRaises(OSError):
            self.produce()
        source.unlink()
        actual.rename(source)
        os.mkfifo(source / "special")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)

    def test_mandatory_lists_missing_empty_and_unresolved_inputs(self):
        # Individual compile attempts use fresh independently claimed workspaces.
        original_w = self.w
        for index, mutation in enumerate((
            lambda p: p.unlink(), lambda p: p.write_bytes(b""),
            lambda p: p.write_bytes(b"/outside/Missing.swift\n"),
            lambda p: p.write_bytes((str(self.w / receipt.DERIVED_SOURCES / "Missing.swift")
                                    + "\n").encode()),
            lambda p: p.write_bytes((str(self.w / "source/untracked.swift") + "\n").encode()),
        )):
            with self.subTest(index=index):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def compile_mutation(*args):
                    code = self.fake_compile(*args)
                    mutation(self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0])
                    return code

                self.compiler.side_effect = compile_mutation
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.produce()
                self.assert_consumed()

    def test_generated_cache_directory_input_refused_before_prepare(self):
        original_w = self.w
        for index, relative in enumerate(("Extra/Other.SwiftFileList", receipt.MANDATORY[0])):
            with self.subTest(list=relative):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def compile_directory_input(*args):
                    code = self.fake_compile_nested_generated(*args)
                    container = self.w / receipt.DERIVED_SOURCES / "Container.swift"
                    path = self.w / receipt.INTERMEDIATES / relative
                    data = path.read_bytes()
                    if index:
                        # The earlier Extra list alone populates this cache entry.
                        data = data.replace((str(container / "Leaf.swift") + "\n").encode(), b"")
                    path.write_bytes(data + (str(container) + "\n").encode())
                    return code

                self.compiler.side_effect = compile_directory_input
                with mock.patch.object(prepare, "prepare", wraps=prepare.prepare) as preparer:
                    with self.assertRaisesRegex(receipt.Refusal, "regular file"):
                        self.produce()
                    preparer.assert_not_called()
                self.assert_consumed()

    def test_generated_cache_directory_rehashed_consumer_refusal(self):
        self.compiler.side_effect = self.fake_compile_nested_generated
        result = self.produce()  # Repeated real files beneath a .swift directory are valid.
        before = snapshot(self.root)
        self.consume(result)
        self.assertEqual(snapshot(self.root), before)
        value = json.loads(self.final.read_bytes())
        container = self.w / receipt.DERIVED_SOURCES / "Container.swift"
        entry = next(item for item in value["inputs"]["generated"]
                     if item["path"] == str(container))
        self.assertEqual(entry["type"], "directory")
        item = next(item for item in value["inputs"]["lists"]
                    if item["file"]["path"].endswith("/Extra/Other.SwiftFileList"))
        path = Path(item["file"]["path"])
        path.write_bytes(path.read_bytes() + (str(container) + "\n").encode())
        item["file"] = receipt.bounded(path)[0]
        item["inputs"].append({"path": str(container), "association": "generated"})
        receipt.schema(value)  # Structurally valid; live input reconstruction must refuse.
        data = receipt.encode(value)
        self.final.write_bytes(data)
        before = snapshot(self.root)
        with self.assertRaisesRegex(receipt.Refusal, "regular file"):
            receipt.validate(self.final, prepare.digest(data))
        self.assertEqual(snapshot(self.root), before)

    def test_claim_collision_and_each_pre_spawn_publication_failure(self):
        original_w = self.w
        original_exclusive = build_mac.exclusive
        original_open = Path.open
        for index, name in enumerate(("claim.json", "journal.log", "stdout.log", "stderr.log",
                                      "directory-sync")):
            with self.subTest(name=name):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def exclusive(path, data):
                    if path.name == name:
                        raise OSError("synthetic pre-spawn write failure")
                    return original_exclusive(path, data)

                def opening(path, *args, **kwargs):
                    if path.name == name and args == ("xb",):
                        raise OSError("synthetic pre-spawn open failure")
                    return original_open(path, *args, **kwargs)

                with mock.patch.object(build_mac, "exclusive", side_effect=exclusive), \
                        mock.patch.object(Path, "open", opening):
                    if name == "directory-sync":
                        with mock.patch.object(build_mac, "sync_directory",
                                               side_effect=OSError("sync failure")):
                            with self.assertRaises(OSError):
                                self.produce()
                    else:
                        with self.assertRaises(OSError):
                            self.produce()
                self.assertEqual(self.compiler.call_count, 0)
                self.assert_consumed()

    def test_nonzero_spawn_error_and_interruption_preserve_claim(self):
        original_w = self.w
        for index, outcome in enumerate((7, OSError("spawn failure"), KeyboardInterrupt())):
            with self.subTest(index=index):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"
                if type(outcome) is int:
                    self.compiler.side_effect = None
                    self.compiler.return_value = outcome
                else:
                    self.compiler.side_effect = outcome
                with self.assertRaises((receipt.Refusal, OSError, KeyboardInterrupt)):
                    self.produce()
                self.assert_consumed()

    def test_real_preparation_failure_preserves_consumed_workspace(self):
        original_open = Path.open

        def opening(path, *args, **kwargs):
            if path.name.endswith(".intent.json") and args == ("xb",):
                raise OSError("synthetic preparer output failure")
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", opening):
            with self.assertRaisesRegex(OSError, "preparer output"):
                self.produce()
        self.assertEqual(self.compiler.call_count, 1)
        self.assert_consumed()

    def test_oversized_original_refused_before_real_preparer(self):
        def compile_oversize(*args):
            code = self.fake_compile(*args)
            path = self.w / receipt.PRODUCTS / "Mac.xctestrun"
            path.write_bytes(b" " * (receipt.METADATA_BYTES + 1))
            return code

        self.compiler.side_effect = compile_oversize
        with self.assertRaisesRegex(receipt.Refusal, "byte limit"):
            self.produce()
        self.assertEqual(list((self.w / receipt.PRODUCTS).glob("*.intent.json")), [])
        self.assert_consumed()

    def test_ambiguous_original_and_wrong_profile(self):
        original_w = self.w
        for index in range(2):
            self.w = self.root / f"W{index}"
            shutil.copytree(original_w, self.w)
            self.final = self.w / "build-evidence/receipt.json"

            def compile_invalid(*args):
                code = self.fake_compile(*args)
                path = self.w / receipt.PRODUCTS / "Mac.xctestrun"
                if index == 0:
                    path.with_name("Other.xctestrun").write_bytes(path.read_bytes())
                else:
                    parsed = copy.deepcopy(FIXTURE)
                    parsed["FluxKlangMacTests"]["SystemAttachmentLifetime"] = "keepAlways"
                    path.write_bytes(plistlib.dumps(parsed))
                return code

            self.compiler.side_effect = compile_invalid
            with self.assertRaises(receipt.Refusal):
                self.produce()
            self.assert_consumed()

    def test_exact_preparer_serialization_prediction(self):
        products = self.w / receipt.PRODUCTS
        write(products / "Mac.xctestrun", plistlib.dumps(FIXTURE))
        original, sizes = receipt.original_metadata(self.w)
        record = prepare.prepare(original["path"], original["sha256"], prepare.RETENTION_PROFILE)
        metadata = receipt.metadata_from_record(record, original, sizes)
        self.assertEqual(receipt.validate_metadata(metadata), record)
        self.assertEqual(len(record["run_id"]), len(receipt.EXEMPLAR))
        self.assertNotEqual(record["run_id"], receipt.EXEMPLAR)

    def test_pending_failure_collision_and_postcommit_sync_uncertainty(self):
        original_w = self.w
        original_exclusive = build_mac.exclusive
        original_sync = build_mac.sync_directory
        original_link = os.link
        for index, phase in enumerate(("pending", "collision", "link", "postcommit",
                                       "interrupted-link")):
            with self.subTest(phase=phase):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def exclusive(path, data):
                    if phase == "pending" and path.name == "receipt.pending":
                        # Preserve a deliberately incomplete failed staging attempt.
                        path.write_bytes(data[:11])
                        raise OSError("pending failure")
                    return original_exclusive(path, data)

                def link(source, destination, **kwargs):
                    if Path(destination).name == "receipt.json":
                        if phase == "collision":
                            Path(destination).write_bytes(b"prior collision")
                        if phase == "link":
                            raise OSError("precommit link failure")
                        result = original_link(source, destination, **kwargs)
                        if phase == "interrupted-link":
                            raise KeyboardInterrupt()
                        return result
                    return original_link(source, destination, **kwargs)

                def sync(path):
                    if phase == "postcommit" and self.final.exists():
                        raise OSError("postcommit fsync failure")
                    return original_sync(path)

                with mock.patch.object(build_mac, "exclusive", side_effect=exclusive), \
                        mock.patch.object(build_mac, "sync_directory", side_effect=sync), \
                        mock.patch.object(os, "link", side_effect=link):
                    with self.assertRaises((OSError, build_mac.CommittedUncertain)):
                        self.produce()
                if phase in ("postcommit", "interrupted-link"):
                    self.assertTrue(self.final.exists())
                    pin = prepare.digest(self.final.read_bytes())  # Test consumer's explicit pin.
                    self.assertEqual(receipt.validate(self.final, pin)["profile"],
                                     prepare.RETENTION_PROFILE)
                    with self.assertRaises(receipt.Refusal):
                        self.produce()
                elif phase == "collision":
                    self.assertEqual(self.final.read_bytes(), b"prior collision")
                    with self.assertRaises(receipt.Refusal):
                        receipt.validate(self.final, prepare.digest(self.final.read_bytes()))
                else:
                    self.assert_consumed()


class PrimitiveTests(unittest.TestCase):
    def test_source_list_closed_grammar(self):
        self.assertEqual(receipt.swift_paths(b"/some/literal space.swift\n"),
                         ["/some/literal space.swift"])
        self.assertEqual(receipt.swift_paths(b"/some/literal@name.swift"),
                         ["/some/literal@name.swift"])
        self.assertEqual(receipt.swift_paths(b"/x\\ y.swift\n"), ["/x y.swift"])
        for value in (b"/x.swift\r\n", b'"/x.swift"\n', b"/x\\q.swift\n", b"@/x.swift\n",
                      b"/x.swift\n\n", b"/x.swift\n/x.swift", b"\xef\xbb\xbf/x.swift",
                      b"/x.swift\0", b"relative.swift", b"/a/../x.swift",
                      b"/x.c", b"/x.swift\n\n/y.swift", b"/x\xff.swift"):
            with self.subTest(value=value), self.assertRaises(receipt.Refusal):
                receipt.swift_paths(value)

    def test_space_escape_decoding_preserves_spaces_and_detects_alias_duplicates(self):
        for raw, decoded in (
            (b"/some\\ directory/a\\ \\ b\\ c.swift", "/some directory/a  b c.swift"),
            (b"/some directory/a\\ b c.swift\n", "/some directory/a b c.swift"),
            (b"/ directory\\ / name\\ .swift\n", "/ directory / name .swift"),
            (b"/plain.swift\n/raw space.swift\n", None),
        ):
            expected = [decoded] if decoded is not None else ["/plain.swift", "/raw space.swift"]
            self.assertEqual(receipt.swift_paths(raw), expected)
        for raw in (
            b"/a b.swift\n/a\\ b.swift",
            b"/a\\ b.swift\n/a b.swift\n",
            b"/a\\ \\ b.swift\n/a \\ b.swift\n",
            b"/a\\ b.swift\n/a\\ b.swift\n",
        ):
            with self.subTest(raw=raw), self.assertRaisesRegex(receipt.Refusal, "duplicate Swift input"):
                receipt.swift_paths(raw)

    def test_space_escape_invalid_sequences_controls_blank_and_trailing(self):
        for raw in (
            b"/a\\q.swift", b"/a\\t.swift", b"/a\\\tb.swift",
            "/a\\\u00a0b.swift".encode(), "/a\\\u2003b.swift".encode(),
            b"/a\\" + b"\\ b.swift", b"/a\\" + b"\\\\ b.swift",
            b"/a.swift\\", b"/a.swift\\\n", b"/a\\\nb.swift\n",
            b"/a\\\r\nb.swift", b"/a\\\0b.swift", b"/a\\\xff.swift",
            b'"/a\\ b.swift"', b"/a\\'b.swift", b"\xef\xbb\xbf/a\\ b.swift",
            b"/a\\ b.swift\r\n", b"/a\\ b.swift\n\n", b"/a\\ b.swift\n\n/c.swift",
            b"/a\\ b.swift\n\\ \n/c.swift", b" /a.swift", b"\\ /a.swift",
            b"/a.swift ", b"/a.swift\\ ", b"/a\\ /../b.swift",
        ):
            with self.subTest(raw=raw), self.assertRaises(receipt.Refusal):
                receipt.swift_paths(raw)

    def test_space_escape_decoded_utf8_path_length_boundary(self):
        suffix = " é.swift"
        path = "/" + "x" * (receipt.PATH_BYTES - len(("/" + suffix).encode())) + suffix
        self.assertEqual(len(path.encode()), receipt.PATH_BYTES)
        raw = path.replace(" ", "\\ ").encode()
        self.assertGreater(len(raw), receipt.PATH_BYTES)
        self.assertEqual(receipt.swift_paths(raw), [path])
        for oversized in ("/x" + path[1:], path.replace("x", "é", 1)):
            self.assertEqual(len(oversized.encode()), receipt.PATH_BYTES + 1)
            with self.assertRaisesRegex(receipt.Refusal, "path byte limit"):
                receipt.swift_paths(oversized.replace(" ", "\\ ").encode())

    def test_fixed_inclusive_entry_depth_byte_and_path_limits(self):
        self.assertEqual((receipt.RECEIPT_BYTES, receipt.METADATA_BYTES, receipt.TREE_ENTRIES,
                          receipt.TREE_DEPTH, receipt.TREE_BYTES, receipt.PATH_BYTES),
                         (33554432, 2097152, 200000, 64, 68719476736, 4096))
        budget = receipt.Budget()
        for _ in range(receipt.TREE_ENTRIES):
            budget.entry(64)
        with self.assertRaises(receipt.Refusal):
            budget.entry(0)
        with self.assertRaises(receipt.Refusal):
            receipt.Budget().entry(65)
        budget.regular(receipt.TREE_BYTES)
        with self.assertRaises(receipt.Refusal):
            budget.regular(1)
        receipt.path_text("/" + "x" * 4095)
        with self.assertRaises(receipt.Refusal):
            receipt.path_text("/" + "x" * 4096)
        with self.assertRaises(receipt.Refusal):
            receipt.path_text("/" + "é" * 2048)
        with self.assertRaises(receipt.Refusal):
            receipt.path_text("/invalid\udcff")

    def test_streaming_inclusive_metadata_receipt_and_tree_budgets(self):
        class Reader:
            def __init__(self, total):
                self.remaining = total
                self.requests = []

            def read(self, size):
                self.requests.append(size)
                count = min(self.remaining, size)
                self.remaining -= count
                return b"x" * count

        for limit in (receipt.METADATA_BYTES, receipt.RECEIPT_BYTES):
            reader = Reader(limit)
            self.assertEqual(receipt.read_stream(reader, limit)[0], limit)
            self.assertLessEqual(max(reader.requests), 1048576)
            with self.assertRaises(receipt.Refusal):
                receipt.read_stream(Reader(limit + 1), limit)
        # Synthetic remaining budget exercises the 64GiB edge without allocating
        # or hashing 64GiB, and without overriding any production limit.
        budget = receipt.Budget()
        budget.regular(receipt.TREE_BYTES - 1)
        self.assertEqual(receipt.read_stream(Reader(1), receipt.TREE_BYTES - budget.bytes)[0], 1)
        with self.assertRaises(receipt.Refusal):
            receipt.read_stream(Reader(2), receipt.TREE_BYTES - budget.bytes)

    def test_short_zero_flush_and_close_failures(self):
        class Writer:
            def __init__(self, zero=False):
                self.data = b""
                self.zero = zero

            def write(self, data):
                if self.zero:
                    return 0
                self.data += data[:2]
                return len(data[:2])

        stream = Writer()
        build_mac.write_all(stream, b"abcdefg")
        self.assertEqual(stream.data, b"abcdefg")
        with self.assertRaises(receipt.Refusal):
            build_mac.write_all(Writer(zero=True), b"x")
        for phase in ("flush", "close"):
            stream = mock.Mock()
            getattr(stream, phase).side_effect = OSError(phase + " failure")
            with mock.patch.object(os, "fsync"):
                with self.assertRaisesRegex(OSError, phase):
                    build_mac.finalize(stream)

    def test_receipt_serialization_exact_limit_and_one_beyond(self):
        # JSON string quoting plus LF accounts for three bytes.
        value = "x" * (receipt.RECEIPT_BYTES - 3)
        self.assertEqual(len(receipt.encode(value)), receipt.RECEIPT_BYTES)
        with self.assertRaises(receipt.Refusal):
            receipt.encode(value + "x")

    def test_inventory_directory_depth_boundary_and_special_modes(self):
        with tempfile.TemporaryDirectory(prefix="inventory-depth-") as temporary:
            root = Path(temporary).resolve()
            directory = root
            for _ in range(receipt.TREE_DEPTH):
                directory /= "d"
                directory.mkdir()
            directory.chmod(0o1777)
            entries = receipt.inventory(root)
            self.assertEqual(len(entries), receipt.TREE_DEPTH + 1)
            self.assertEqual(entries[-1]["mode"], 0o1777)
            (root / "!before-root-in-sort-order").write_bytes(b"regular")
            receipt.entries_schema(receipt.inventory(root))
            (directory / "excess").mkdir()
            with self.assertRaisesRegex(receipt.Refusal, "depth limit"):
                receipt.inventory(root)

    def test_cli_bytecode_disabled_before_sibling_imports_and_signal_handlers_restored(self):
        before = {signum: build_mac.signal.getsignal(signum)
                  for signum in (build_mac.signal.SIGTERM, build_mac.signal.SIGHUP)}
        with tempfile.TemporaryDirectory(prefix="import-bytecode-") as temporary:
            root = Path(temporary).resolve()
            for name in ("build_mac.py", "build_receipt.py", "prepare.py"):
                shutil.copyfile(Path(__file__).with_name(name), root / name)
            env = {key: value for key, value in os.environ.items()
                   if key not in ("PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX")}
            result = subprocess.run(
                [sys.executable, str(root / "build_mac.py"), "validate",
                 "--receipt", str(root / "absent"), "--expected-sha256", "0" * 64],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertFalse(list(root.rglob("__pycache__")))
            with mock.patch.object(sys, "stderr", new=mock.Mock()):
                self.assertEqual(build_mac.main([
                    "validate", "--receipt", str(root / "absent"),
                    "--expected-sha256", "0" * 64]), 1)
        self.assertEqual({signum: build_mac.signal.getsignal(signum) for signum in before}, before)

    def test_termination_uses_only_spawned_process_group_and_reaps(self):
        child = mock.Mock(pid=123456)
        child.wait.side_effect = [KeyboardInterrupt(), 0]
        with mock.patch.object(build_mac.subprocess, "Popen", return_value=child) as spawn, \
                mock.patch.object(os, "killpg") as kill:
            with self.assertRaises(KeyboardInterrupt):
                build_mac.compile_once(["synthetic"], {}, Path("/synthetic"), None, None)
            self.assertTrue(spawn.call_args.kwargs["start_new_session"])
            kill.assert_called_once_with(child.pid, build_mac.signal.SIGTERM)
            self.assertEqual(child.wait.call_count, 2)
        with mock.patch.object(build_mac.subprocess, "Popen", side_effect=OSError("spawn")), \
                mock.patch.object(os, "killpg") as kill:
            with self.assertRaises(OSError):
                build_mac.compile_once(["synthetic"], {}, Path("/synthetic"), None, None)
            kill.assert_not_called()

    def test_metadata_size_and_path_prebound_without_api_changes(self):
        with tempfile.TemporaryDirectory(prefix="bounds-") as temporary:
            root = Path(temporary).resolve()
            path = root / "metadata"
            path.write_bytes(b"x" * receipt.METADATA_BYTES)
            self.assertEqual(len(receipt.bounded(path)[1]), receipt.METADATA_BYTES)
            with path.open("ab") as stream:
                stream.write(b"x")
            with self.assertRaises(receipt.Refusal):
                receipt.bounded(path)
            linked = root / "linked"
            linked.symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError):
                receipt.bounded(linked / "metadata")


if __name__ == "__main__":
    unittest.main()
