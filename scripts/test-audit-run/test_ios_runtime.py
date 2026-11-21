"""Closed runtime authority fixtures. ALL native/filesystem probes are mocked.

The process/signalling denial gate remains active even when a test substitutes
the helper's narrow command boundary. No native tools are enabled by fixtures.
"""

from contextlib import ExitStack
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import ios_runtime as runtime
import prepare
from test_prepare_ios import FIXTURE, UUID_PATHS


DEVELOPER = runtime.DEVELOPER
# Deliberately NOT the run-local observed suffix.
BUNDLE = (
    "/private/var/run/com.apple.security.cryptexd/mnt/fresh-inventory-mount/"
    "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime"
)
ROOT = BUNDLE + "/Contents/Resources/RuntimeRoot"
LIBRARY = ROOT + "/usr/lib/libMainThreadChecker.dylib"
ALIAS = LIBRARY[len("/private"):]
PLIST = BUNDLE + "/Contents/Info.plist"
DYLD = "DYLD_INSERT_LIBRARIES"


def fixture(checker=ALIAS):
    value = copy.deepcopy(FIXTURE)
    value["FluxKlangTests"]["TestingEnvironmentVariables"][DYLD] = (
        "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:"
        + checker + ":/usr/lib/libRPAC.dylib"
    )
    value["FluxKlangUITests"]["TestingEnvironmentVariables"][DYLD] = checker
    return value


class Host:
    """In-memory descriptor-relative filesystem and exact command transcript."""

    def __init__(self):
        self.nodes = {}
        self.fds = {}
        self.next_fd = 10
        self.commands = []
        self.responses = {}
        self.after_command = lambda argv: None
        self.runtime = {
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "version": "27.0", "buildversion": "24A434", "isAvailable": True,
            "bundlePath": BUNDLE, "runtimeRoot": ROOT,
        }
        self.runtimes = [self.runtime]
        self.alias_target = "private/var"
        self.add("/", directory=True)
        self.add("/var", symlink=True)
        for tool in ("xcodebuild", "simctl"):
            self.add(DEVELOPER + "/usr/bin/" + tool, b"mock Apple tool")
        self.bytes = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + bytes(338880 - 8)
        self.add(LIBRARY, self.bytes)
        self.add(PLIST, plistlib.dumps({
            "CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "CFBundleVersion": "392", "CFBundleShortVersionString": "392",
        }))
        # The reviewed artifact measured 0664, not the executable's 0755.
        self.nodes[PLIST].st_mode = stat.S_IFREG | 0o664
        self.plist_readonly = True
        self.os = SimpleNamespace(**{
            name: getattr(os, name) for name in
            ("O_RDONLY", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK", "SEEK_SET", "ST_RDONLY")
        })
        for name in ("open", "close", "fstat", "fstatvfs", "stat", "lstat", "read", "lseek", "readlink"):
            setattr(self.os, name, getattr(self, name))
        self.os.uname = lambda: SimpleNamespace(machine="arm64")

    def add(self, path, data=b"", directory=False, symlink=False):
        parent = str(Path(path).parent)
        if path != "/" and parent not in self.nodes:
            self.add(parent, directory=True)
        mode = stat.S_IFLNK | 0o755 if symlink else (
            stat.S_IFDIR | 0o755 if directory else stat.S_IFREG | 0o755
        )
        self.nodes[path] = SimpleNamespace(
            data=data, st_dev=12, st_ino=len(self.nodes) + 100,
            st_mode=mode, st_uid=0, st_gid=0, st_size=len(data),
            st_mtime_ns=1000, st_ctime_ns=1000,
        )

    def path(self, path, dir_fd=None):
        return str(Path(self.fds[dir_fd][0]) / path) if dir_fd is not None else path

    def open(self, path, flags, dir_fd=None):
        path = self.path(path, dir_fd)
        node = self.nodes[path]
        if flags & os.O_NOFOLLOW and stat.S_ISLNK(node.st_mode):
            raise OSError("mock ELOOP")
        fd = self.next_fd
        self.next_fd += 1
        self.fds[fd] = [path, node, 0]
        return fd

    def close(self, fd):
        del self.fds[fd]

    def fstat(self, fd):
        return copy.copy(self.fds[fd][1])

    def fstatvfs(self, fd):
        assert self.fds[fd][0] == PLIST, "unexpected mount probe"
        return SimpleNamespace(f_flag=os.ST_RDONLY if self.plist_readonly else 0)

    def stat(self, path, dir_fd=None, follow_symlinks=True):
        path = self.path(path, dir_fd)
        if follow_symlinks and (path == "/var" or path.startswith("/var/")):
            target = "/" + self.alias_target.lstrip("/")
            path = target + path[len("/var"):]
        return copy.copy(self.nodes[path])

    def lstat(self, path):
        return self.stat(path, follow_symlinks=False)

    def readlink(self, path):
        assert path == "/var", "unexpected symlink probe"
        return self.alias_target

    def read(self, fd, size):
        entry = self.fds[fd]
        result = entry[1].data[entry[2]:entry[2] + size]
        entry[2] += len(result)
        return result

    def lseek(self, fd, offset, whence):
        assert whence == os.SEEK_SET
        self.fds[fd][2] = offset

    def command(self, argv, developer=None):
        key = tuple(argv)
        self.commands.append((key, developer))
        if key in self.responses:
            result = self.responses[key]
            if isinstance(result, Exception):
                raise result
        elif argv == [DEVELOPER + "/usr/bin/xcodebuild", "-version"]:
            result = "Xcode 27.1\nBuild version 27A9275"
        elif argv == [DEVELOPER + "/usr/bin/xcodebuild", "-version", "-sdk",
                      "iphonesimulator", "SDKVersion"]:
            result = "27.1"
        elif argv == [DEVELOPER + "/usr/bin/simctl", "list", "runtimes", "--json"]:
            result = json.dumps({"runtimes": self.runtimes})
        elif argv in [
            ["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple",
             DEVELOPER + "/usr/bin/" + tool] for tool in ("xcodebuild", "simctl")
        ]:
            result = ""
        elif argv == ["/usr/bin/codesign", "--verify", "--strict", "-R",
                      '=identifier "com.apple.libMainThreadChecker" and anchor apple', LIBRARY]:
            result = ""
        else:
            raise AssertionError("unapproved native argv: " + repr(argv))
        self.after_command(argv)
        return result


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        # A process audit hook in the check invocation is an additional gate.
        # These mocks make any accidental process/signalling attempt fail here.
        for module, names in (
            (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
            (os, ("system", "fork", "posix_spawn", "posix_spawnp", "kill", "killpg")),
        ):
            for name in names:
                if hasattr(module, name):
                    self.stack.enter_context(mock.patch.object(
                        module, name, side_effect=AssertionError("native process/signalling denied"),
                    ))
        self.host = Host()
        self.stack.enter_context(mock.patch.object(runtime, "os", self.host.os))
        self.stack.enter_context(mock.patch.object(runtime.sys, "platform", "darwin"))
        self.command = self.stack.enter_context(mock.patch.object(
            runtime, "_command", side_effect=self.host.command,
        ))
        # Synthetic Mach-O bytes cannot have the reviewed real-file digest.
        # Exercise real SHA256 logic against this fixture, never mock hashing.
        self.stack.enter_context(mock.patch.object(
            runtime, "LIBRARY_SHA256", hashlib.sha256(self.host.bytes).hexdigest(),
        ))
        temporary = self.stack.enter_context(tempfile.TemporaryDirectory(prefix="runtime-profile-fixture-"))
        self.source = Path(temporary).resolve() / "input.xctestrun"
        self.write(fixture())

    def write(self, value):
        data = plistlib.dumps(value, sort_keys=False)
        self.source.write_bytes(data)
        self.pin = hashlib.sha256(data).hexdigest()

    def prepare(self):
        return prepare.prepare(self.source, self.pin, prepare.IOS_RUNTIME_PROFILE)

    def prepare_provider(self):
        return prepare.prepare(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE)

    def validate(self, record):
        return prepare.validate(self.source, self.pin, prepare.IOS_RUNTIME_PROFILE,
                                record["output"]["path"], record["intent_path"])

    def validate_provider(self, record):
        return prepare.validate(
            self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            record["output"]["path"], record["intent_path"],
        )

    def test_fresh_alias_and_canonical_round_trip_preserves_generated_fields(self):
        for spelling in (ALIAS, LIBRARY):
            with self.subTest(spelling=spelling):
                self.write(fixture(spelling))
                record = self.prepare()
                parsed = plistlib.loads(Path(record["output"]["path"]).read_bytes())
                for target, environment in UUID_PATHS:
                    self.assertEqual(parsed[target][environment].pop(prepare.RUN_KEY), record["run_id"])
                self.assertEqual(parsed, fixture(spelling))
                before = len(self.host.commands)
                self.assertEqual(self.validate(record), record)
                self.assertGreater(len(self.host.commands), before)
                self.assertNotIn("verified", record)
                self.assertNotIn("provider_observation", record)
                self.assertEqual(record["schema_version"], 1)
        self.write(fixture(LIBRARY.replace("fresh-inventory-mount", "untrusted-location")))
        with self.assertRaisesRegex(
            ValueError, "UI checker does not match the independently verified runtime",
        ):
            self.prepare()
        signatures = [argv for argv, _ in self.host.commands if LIBRARY in argv]
        self.assertTrue(signatures)
        self.assertTrue(all(argv[-2] ==
                            '=identifier "com.apple.libMainThreadChecker" and anchor apple'
                            for argv in signatures))
        self.assertFalse(self.host.fds)

    def test_provider_trusted_profile_accepts_bounded_observation_separately(self):
        self.write(fixture())
        ancestor = self.host.nodes["/Applications"]
        ancestor.st_mode = stat.S_IFDIR | 0o775
        ancestor.st_gid = 80
        record = self.prepare_provider()
        self.assertEqual(record["schema_version"], 3)
        self.assertEqual(
            set(record),
            {
                "schema_version", "profile", "qualification", "run_id", "targets",
                "input", "output", "intent_path", "provider_observation",
            },
        )
        observation = record["provider_observation"]
        self.assertEqual(observation["schema"], "ios-provider-trusted-runtime-observation-v1")
        self.assertEqual(set(observation), {"schema", "xcode", "runtime", "checker"})
        self.assertEqual(
            set(observation["xcode"]),
            {
                "developer_directory", "version", "build", "simulator_sdk_version",
                "xcodebuild_path", "xcodebuild_file_identity", "xcodebuild_apple_anchor_check",
                "simctl_path", "simctl_file_identity", "simctl_apple_anchor_check",
            },
        )
        self.assertEqual(
            set(observation["runtime"]),
            {"identifier", "version", "build", "available", "bundle_path", "runtime_root"},
        )
        self.assertEqual(
            set(observation["checker"]),
            {
                "canonical_path", "accepted_paths", "size", "sha256", "architecture",
                "signature_requirement", "signature_check",
            },
        )
        self.assertEqual(observation["xcode"]["version"], "Xcode 27.1")
        self.assertEqual(observation["xcode"]["build"], "27A9275")
        self.assertEqual(observation["xcode"]["simulator_sdk_version"], "27.1")
        self.assertEqual(observation["runtime"]["identifier"], runtime.RUNTIME)
        self.assertEqual(observation["runtime"]["version"], "27.0")
        self.assertEqual(observation["runtime"]["build"], "24A434")
        self.assertEqual(observation["checker"]["canonical_path"], LIBRARY)
        self.assertEqual(observation["checker"]["sha256"], runtime.LIBRARY_SHA256)
        self.assertEqual(observation["checker"]["accepted_paths"], [LIBRARY, ALIAS])
        self.assertNotIn("source", observation)
        self.assertNotIn("head", observation)
        self.assertNotIn("runner", observation)
        output = plistlib.loads(Path(record["output"]["path"]).read_bytes())
        expected = fixture()
        for target, environment in UUID_PATHS:
            expected[target][environment][prepare.RUN_KEY] = record["run_id"]
        self.assertEqual(output, expected)
        self.assertEqual(self.validate_provider(record), record)
        # The original strict profile retains its protected-ancestor refusal.
        with self.assertRaisesRegex(ValueError, "root-owned"):
            self.prepare()
        commands = [argv for argv, _ in self.host.commands]
        self.assertIn(
            ("/usr/bin/codesign", "--verify", "--strict", "-R", runtime.REQUIREMENT, LIBRARY),
            commands,
        )
        self.assertFalse(self.host.fds)

    def test_provider_inventory_paths_are_bounded_and_non_traversing(self):
        cases = (
            ("bundlePath", BUNDLE + "/../escape"),
            ("bundlePath", "/private/var//invalid/iOS 27.0.simruntime"),
            ("bundlePath", "/private/var/" + "x" * 4100 + "/iOS 27.0.simruntime"),
            ("runtimeRoot", ROOT + "/../../escape"),
            ("runtimeRoot", "/etc"),
        )
        for key, value in cases:
            saved = self.host.runtime[key]
            self.host.runtime[key] = value
            with self.subTest(key=key, value=value[:80]), self.assertRaises(ValueError):
                self.prepare_provider()
            self.host.runtime[key] = saved
            self.assertEqual(list(self.source.parent.iterdir()), [self.source])
        self.assertFalse(self.host.fds)

    def test_provider_context_rechecks_observations_on_exit(self):
        original = self.host.nodes[LIBRARY].data
        with self.assertRaisesRegex(ValueError, "digest"):
            with runtime.provider_verified_checker():
                self.host.nodes[LIBRARY].data = original[:-1] + b"x"
        self.host.nodes[LIBRARY].data = original
        self.assertFalse(self.host.fds)

    def test_provider_validation_rejects_altered_input_and_intent(self):
        record = self.prepare_provider()
        original_input = self.source.read_bytes()
        self.source.write_bytes(original_input + b"\n")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            prepare.validate(
                self.source, record["input"]["sha256"], prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                record["output"]["path"], record["intent_path"],
            )
        self.source.write_bytes(original_input)

        intent_path = Path(record["intent_path"])
        original_intent = intent_path.read_text()
        altered = json.loads(original_intent)
        altered["provider_observation"]["runtime"]["build"] = "24A435"
        intent_path.write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, "provider_observation"):
            self.validate_provider(record)
        for version in (1, 2, 4, True):
            altered = json.loads(original_intent)
            altered["schema_version"] = version
            intent_path.write_text(json.dumps(altered))
            with self.subTest(schema_version=version), self.assertRaisesRegex(
                ValueError, "schema_version",
            ):
                self.validate_provider(record)
        altered = json.loads(original_intent)
        altered["unexpected"] = "not in schema 3"
        intent_path.write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, "unsupported or missing keys"):
            self.validate_provider(record)
        altered = json.loads(original_intent)
        altered["provider_observation"]["runner"] = "unverified"
        intent_path.write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, "provider_observation"):
            self.validate_provider(record)
        intent_path.write_text(original_intent)
        self.assertEqual(self.validate_provider(record), record)
        self.assertFalse(self.host.fds)

    def test_provider_profile_refuses_identity_and_closed_metadata_drift(self):
        for key, value in (
            ("version", "27.1"), ("buildversion", "24A435"),
            ("identifier", "com.apple.CoreSimulator.SimRuntime.iOS-27-1"),
            ("isAvailable", False),
        ):
            saved = self.host.runtime[key]
            self.host.runtime[key] = value
            with self.subTest(identity=key), self.assertRaises(ValueError):
                self.prepare_provider()
            self.host.runtime[key] = saved
        self.host.runtimes.append(dict(self.host.runtime))
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.prepare_provider()
        self.host.runtimes.pop()

        xcode = (DEVELOPER + "/usr/bin/xcodebuild", "-version")
        self.host.responses[tuple(xcode)] = "Xcode 27.1\nBuild version wrong"
        with self.assertRaisesRegex(ValueError, "Xcode version"):
            self.prepare_provider()
        self.host.responses.clear()
        sdk = (
            DEVELOPER + "/usr/bin/xcodebuild", "-version", "-sdk",
            "iphonesimulator", "SDKVersion",
        )
        self.host.responses[tuple(sdk)] = "27.0"
        with self.assertRaisesRegex(ValueError, "SDK observation"):
            self.prepare_provider()
        self.host.responses.clear()

        original_bytes = self.host.nodes[LIBRARY].data
        self.host.nodes[LIBRARY].data = original_bytes[:-1] + b"x"
        with self.assertRaisesRegex(ValueError, "digest"):
            self.prepare_provider()
        self.host.nodes[LIBRARY].data = original_bytes
        signature = (
            "/usr/bin/codesign", "--verify", "--strict", "-R",
            runtime.REQUIREMENT, LIBRARY,
        )
        self.host.responses[signature] = runtime.Refusal("provider checker signature mismatch")
        with self.assertRaisesRegex(ValueError, "signature mismatch"):
            self.prepare_provider()
        self.host.responses.clear()
        plist = self.host.nodes[PLIST]
        original_plist = plist.data
        plist.data = plistlib.dumps({"CFBundleIdentifier": "unexpected"})
        with self.assertRaisesRegex(ValueError, "plist identifier"):
            self.prepare_provider()
        plist.data = original_plist

        original = fixture()
        candidates = []
        bad_path = copy.deepcopy(original)
        bad_path["FluxKlangUITests"]["TestingEnvironmentVariables"][DYLD] = (
            LIBRARY.replace("fresh-inventory-mount", "untrusted-location")
        )
        candidates.append(bad_path)
        extra_library = copy.deepcopy(original)
        extra_library["FluxKlangUITests"]["TestingEnvironmentVariables"][DYLD] += (
            ":/tmp/unreviewed.dylib"
        )
        candidates.append(extra_library)
        main_thread_setting = copy.deepcopy(original)
        main_thread_setting["FluxKlangUITests"]["UITargetAppMainThreadCheckerEnabled"] = True
        candidates.append(main_thread_setting)
        target_app_injection = copy.deepcopy(original)
        target_app_injection["FluxKlangUITests"]["UITargetAppEnvironmentVariables"][DYLD] = LIBRARY
        candidates.append(target_app_injection)
        for index, value in enumerate(candidates):
            self.write(value)
            before = len(self.host.commands)
            if index == 0:
                context = self.assertRaisesRegex(
                    ValueError, "UI checker does not match the fixed provider-trusted runtime observation",
                )
            else:
                context = self.assertRaises(ValueError)
            with self.subTest(metadata=index), context:
                self.prepare_provider()
            self.assertEqual(list(self.source.parent.iterdir()), [self.source])
            self.assertNotIn(LIBRARY.replace("fresh-inventory-mount", "untrusted-location"),
                             [item for argv, _ in self.host.commands[before:] for item in argv])
        self.assertFalse(self.host.fds)

    def test_library_lists_and_ui_presence_remain_closed(self):
        original = fixture()
        unit = original["FluxKlangTests"]["TestingEnvironmentVariables"][DYLD].split(":")
        variants = []
        for target, entries in (("FluxKlangTests", unit), ("FluxKlangUITests", [ALIAS])):
            for replacement in (
                ":".join(reversed(entries)) if len(entries) > 1 else "",
                ":".join(entries + [entries[0]]), ":".join(entries[1:]),
                ":".join(entries + ["/unexpected.dylib"]), entries,
                ":".join(entries).replace("fresh-inventory-mount", "another-mount"),
                ":".join(entries).replace("/var/run/", "/var/../var/run/"),
            ):
                value = copy.deepcopy(original)
                value[target]["TestingEnvironmentVariables"][DYLD] = replacement
                variants.append(value)
            value = copy.deepcopy(original)
            del value[target]["TestingEnvironmentVariables"][DYLD]
            variants.append(value)
        for key, replacement in (
            ("UITargetAppMainThreadCheckerEnabled", False),
            ("UITargetAppMainThreadCheckerEnabled", True),
            ("UITargetAppMainThreadCheckerEnabled", "YES"),
            ("IsUITestBundle", 1), ("RunOrder", True),
        ):
            value = copy.deepcopy(original)
            value["FluxKlangUITests"][key] = replacement
            variants.append(value)
        for replacement in ("", ALIAS, []):
            value = copy.deepcopy(original)
            value["FluxKlangUITests"]["UITargetAppEnvironmentVariables"][DYLD] = replacement
            variants.append(value)
        value = copy.deepcopy(original)
        value["FluxKlangTests"]["EnvironmentVariables"][DYLD] += ":" + ALIAS
        variants.append(value)
        for index, value in enumerate(variants):
            with self.subTest(index=index):
                self.write(value)
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertEqual(list(self.source.parent.iterdir()), [self.source])

    def test_inventory_pins_and_unavailable_authority(self):
        cases = [
            ("identifier", "com.apple.CoreSimulator.SimRuntime.iOS-27-1"),
            ("version", "27.1"), ("buildversion", "392"),
            ("buildversion", "24A435"), ("isAvailable", 1),
            ("runtimeRoot", ROOT + "/escape"),
            ("bundlePath", BUNDLE.replace("/private/var", "/var")),
        ]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                saved = self.host.runtime[key]
                self.host.runtime[key] = value
                with self.assertRaises(ValueError):
                    self.prepare()
                self.host.runtime[key] = saved
        self.host.runtimes.append(dict(self.host.runtime))
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.prepare()
        self.host.runtimes.pop()
        for argv, bad in (
            ([DEVELOPER + "/usr/bin/xcodebuild", "-version"], "Xcode 27.1\nBuild version wrong"),
            ([DEVELOPER + "/usr/bin/xcodebuild", "-version", "-sdk", "iphonesimulator", "SDKVersion"], "27.0"),
            ([DEVELOPER + "/usr/bin/xcodebuild", "-version"], runtime.Refusal("unavailable")),
        ):
            self.host.responses[tuple(argv)] = bad
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                self.prepare()
            self.host.responses.clear()
        with mock.patch.object(runtime.sys, "platform", "linux"):
            with self.assertRaisesRegex(ValueError, "Darwin arm64"):
                self.prepare()
        self.host.os.uname = lambda: SimpleNamespace(machine="x86_64")
        with self.assertRaisesRegex(ValueError, "Darwin arm64"):
            self.prepare()

    def test_alias_requires_positive_identity_and_no_symlink_escape(self):
        for target in ("elsewhere", "/private/var/../var"):
            with self.subTest(target=target):
                self.host.alias_target = target
                with self.assertRaisesRegex(ValueError, "standard /var"):
                    self.prepare()
        self.host.alias_target = "private/var"
        # Same suffix with a different inode is not an authorized alias.
        real_stat = self.host.os.stat

        def substituted(path, **kwargs):
            info = real_stat(path, **kwargs)
            if path == ALIAS:
                info.st_ino += 1
            return info

        with mock.patch.object(self.host.os, "stat", side_effect=substituted):
            with self.assertRaisesRegex(ValueError, "alias identity"):
                self.prepare()
        # Root-owned symlinks in the independent path are still refused.
        for path in (LIBRARY, ROOT + "/usr", BUNDLE, "/private"):
            with self.subTest(path=path):
                node = self.host.nodes[path]
                saved = node.st_mode
                node.st_mode = stat.S_IFLNK | 0o755
                with self.assertRaises(ValueError):
                    self.prepare()
                node.st_mode = saved

    def test_content_architecture_ownership_and_signature_failures(self):
        node = self.host.nodes[LIBRARY]
        for key, bad in (("st_uid", 501), ("st_mode", stat.S_IFREG | 0o777),
                         ("st_size", 338879), ("data", self.host.bytes[:-1] + b"x")):
            with self.subTest(key=key):
                old = getattr(node, key)
                setattr(node, key, bad)
                with self.assertRaises(ValueError):
                    self.prepare()
                setattr(node, key, old)
        # Isolate architecture rejection even when a digest matches.
        wrong_arch = b"notarm64" + self.host.bytes[8:]
        node.data = wrong_arch
        with mock.patch.object(runtime, "LIBRARY_SHA256", hashlib.sha256(wrong_arch).hexdigest()):
            with self.assertRaisesRegex(ValueError, "thin arm64"):
                self.prepare()
        node.data = self.host.bytes
        argv = ("/usr/bin/codesign", "--verify", "--strict", "-R",
                '=identifier "com.apple.libMainThreadChecker" and anchor apple', LIBRARY)
        for failure in ("wrong identifier", "non-Apple signer", "unsigned", "codesign unavailable"):
            self.host.responses[argv] = runtime.Refusal(failure)
            with self.subTest(failure=failure), self.assertRaisesRegex(ValueError, failure):
                self.prepare()
        self.host.responses.clear()
        plist = self.host.nodes[BUNDLE + "/Contents/Info.plist"]
        plist.data = plistlib.dumps({"CFBundleIdentifier": "wrong"})
        with self.assertRaisesRegex(ValueError, "plist identifier"):
            self.prepare()

    def test_replacement_and_late_failure_remove_only_created_pair(self):
        sentinel = self.source.parent / "keep.txt"
        sentinel.write_text("untouched")
        # Replace the pathname, not the held descriptor, at a signature check.
        def replace(argv):
            if argv[-1] == LIBRARY:
                self.host.nodes[LIBRARY] = copy.copy(self.host.nodes[LIBRARY])
                self.host.nodes[LIBRARY].st_ino += 1

        self.host.after_command = replace
        with self.assertRaisesRegex(ValueError, "replaced"):
            self.prepare()
        self.host.after_command = lambda argv: None
        # The outer verification exits after files were created and validated.
        real_inventory = runtime._inventory
        calls = 0

        def late_inventory():
            nonlocal calls
            calls += 1
            value = real_inventory()
            if calls == 4:
                raise runtime.Refusal("late stale inventory")
            return value

        with mock.patch.object(runtime, "_inventory", side_effect=late_inventory):
            with self.assertRaisesRegex(ValueError, "late stale"):
                self.prepare()
        self.assertEqual(set(self.source.parent.iterdir()), {self.source, sentinel})
        self.assertEqual(sentinel.read_text(), "untouched")
        self.assertFalse(self.host.fds)

    def test_held_file_ancestor_and_alias_changes_during_check(self):
        for path, attribute in ((LIBRARY, "st_ino"), (ROOT, "st_ino"), ("/var", "st_ino")):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    with runtime.verified_checker():
                        node = copy.copy(self.host.nodes[path])
                        setattr(node, attribute, getattr(node, attribute) + 1)
                        self.host.nodes[path] = node

    def test_runtime_plist_requires_readonly_filesystem(self):
        self.host.plist_readonly = False
        with self.assertRaisesRegex(ValueError, "read-only filesystem"):
            self.prepare()
        self.host.plist_readonly = True
        with mock.patch.object(self.host.os, "fstatvfs", side_effect=OSError("unavailable")):
            with self.assertRaises(ValueError):
                self.prepare()
        for path, key, bad in (
            (PLIST, "st_mode", stat.S_IFREG | 0o666),
            (PLIST, "st_uid", 501),
            (PLIST, "st_mode", stat.S_IFLNK | 0o664),
            (LIBRARY, "st_mode", stat.S_IFREG | 0o775),
            (BUNDLE, "st_mode", stat.S_IFDIR | 0o775),
            (DEVELOPER, "st_mode", stat.S_IFDIR | 0o775),
        ):
            with self.subTest(path=path, key=key):
                node = self.host.nodes[path]
                saved = getattr(node, key)
                setattr(node, key, bad)
                with self.assertRaises(ValueError):
                    self.prepare()
                setattr(node, key, saved)
        self.assertEqual(list(self.source.parent.iterdir()), [self.source])
        self.assertFalse(self.host.fds)

    def test_plist_write_protection_loss_removes_new_pair(self):
        inventory = runtime._inventory
        calls = 0

        def remount():
            nonlocal calls
            calls += 1
            if calls == 4:
                self.host.plist_readonly = False
            return inventory()

        with mock.patch.object(runtime, "_inventory", side_effect=remount):
            with self.assertRaisesRegex(ValueError, "read-only filesystem"):
                self.prepare()
        self.assertEqual(list(self.source.parent.iterdir()), [self.source])
        self.assertFalse(self.host.fds)

    def test_stale_intent_forged_context_and_old_profiles(self):
        record = self.prepare()
        intent = Path(record["intent_path"])
        record["verified"] = True
        record["runtime_context"] = {"canonical_path": LIBRARY, "sha256": runtime.LIBRARY_SHA256}
        intent.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "intent"):
            self.validate(record)
        del record["verified"], record["runtime_context"]
        intent.write_text(json.dumps(record))
        self.host.runtime["buildversion"] = "unreviewed"
        with self.assertRaisesRegex(ValueError, "runtime"):
            self.validate(record)
        with self.assertRaises(TypeError):
            runtime.verified_checker(verified=True, context=record)
        self.host.runtime["buildversion"] = "24A434"
        self.command.side_effect = AssertionError("old profile attempted live verification")
        for profile, original in (
            (prepare.IOS_PROFILE, FIXTURE), (prepare.IOS_RETENTION_PROFILE, FIXTURE),
            (prepare.PROFILE, prepare.OBSERVED), (prepare.RETENTION_PROFILE, prepare.OBSERVED),
        ):
            with self.subTest(profile=profile):
                self.write(original)
                old = prepare.prepare(self.source, self.pin, profile)
                self.assertEqual(prepare.validate(self.source, self.pin, profile,
                                                 old["output"]["path"], old["intent_path"]), old)

    def test_cli_refuses_unavailable_authority_without_publishing(self):
        self.host.runtime["isAvailable"] = False
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            status = prepare.main([
                "prepare", "--input", str(self.source), "--expected-sha256", self.pin,
                "--profile", prepare.IOS_RUNTIME_PROFILE,
            ])
        self.assertEqual(status, 1)
        self.assertIn("refused:", stderr.getvalue())
        self.assertEqual(list(self.source.parent.iterdir()), [self.source])


class CommandProcess:
    # Preserve the real context-manager behavior to catch implicit wait(None).
    __enter__ = subprocess.Popen.__enter__
    __exit__ = subprocess.Popen.__exit__

    def __init__(self, case):
        self.stdin = self.stderr = None
        self.stdout = io.BytesIO()
        self.stdout.fileno = lambda: 99
        self.poll = mock.Mock(return_value=None if case in (
            "timeout", "overflow", "cleanup-timeout", "kill-failure",
        ) else 0)
        self.kill = mock.Mock(side_effect=OSError("kill failed") if case == "kill-failure" else None)

        def wait(timeout=None):
            if case == "cleanup-timeout" and timeout is not None:
                raise subprocess.TimeoutExpired("mock", timeout)
            return 1 if case == "nonzero" else 0

        self.wait = mock.Mock(side_effect=wait)


class CommandTests(unittest.TestCase):
    def test_bounded_read_only_command_boundary(self):
        # The real Popen is denied throughout. Only an in-memory process is
        # supplied to this module's subprocess proxy, including timeout cleanup.
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(subprocess, "Popen", side_effect=AssertionError("denied")))
            stack.enter_context(mock.patch.object(os, "kill", side_effect=AssertionError("denied")))
            stack.enter_context(mock.patch.object(os, "killpg", side_effect=AssertionError("denied")))
            for case in ("success", "nonzero", "timeout", "overflow", "unavailable", "bad-utf8",
                         "cleanup-timeout", "kill-failure"):
                with self.subTest(case=case), ExitStack() as local:
                    process = CommandProcess(case)
                    popen = mock.Mock(return_value=process)
                    if case == "unavailable":
                        popen.side_effect = OSError("unavailable")
                    proxy = SimpleNamespace(Popen=popen, DEVNULL=subprocess.DEVNULL,
                                            PIPE=subprocess.PIPE, STDOUT=subprocess.STDOUT,
                                            SubprocessError=subprocess.SubprocessError)
                    local.enter_context(mock.patch.object(runtime, "subprocess", proxy))
                    selector = mock.MagicMock()
                    selector.__enter__.return_value = selector
                    selector.select.return_value = [] if case in (
                        "timeout", "cleanup-timeout", "kill-failure",
                    ) else [True]
                    local.enter_context(mock.patch.object(runtime.selectors, "DefaultSelector", return_value=selector))
                    data = b"x" * 33 if case == "overflow" else (b"\xff" if case == "bad-utf8" else b"ok")
                    local.enter_context(mock.patch.object(runtime.os, "read", side_effect=[data, b""]))
                    local.enter_context(mock.patch.object(runtime, "OUTPUT_LIMIT", 32))
                    if case == "success":
                        self.assertEqual(runtime._command([DEVELOPER + "/usr/bin/xcodebuild", "-version"]), "ok")
                        kwargs = popen.call_args.kwargs
                        self.assertEqual(kwargs["env"], {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
                        self.assertEqual(kwargs["cwd"], "/")
                        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                    else:
                        with self.assertRaises(runtime.Refusal):
                            runtime._command([DEVELOPER + "/usr/bin/xcodebuild", "-version"])
                    if case != "unavailable":
                        self.assertTrue(process.stdout.closed)
                        self.assertTrue(all(call.kwargs.get("timeout") is not None
                                            for call in process.wait.call_args_list))
                    if case in ("timeout", "overflow", "cleanup-timeout", "kill-failure"):
                        process.kill.assert_called_once()
                        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=30)])


if __name__ == "__main__":
    unittest.main()
