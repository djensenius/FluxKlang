"""Pure stdlib fixtures; no native products, Xcode, app modules, or launches."""

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

import prepare


# Independently transcribed from the reviewed mac.xctestrun metadata, not built
# from prepare.OBSERVED. No session-state or actual Build products are required.
FIXTURE = {
    "FluxKlangMacTests": {
        "BlueprintName": "FluxKlangMacTests",
        "BlueprintProviderName": "FluxKlang",
        "BlueprintProviderRelativePath": "FluxKlang.xcodeproj",
        "BundleIdentifiersForCrashReportEmphasis": [
            "org.davidjensenius.FluxKlang", "org.davidjensenius.FluxKlang.mactests",
        ],
        "CommandLineArguments": [],
        "DefaultTestExecutionTimeAllowance": 600,
        "DependentProductPaths": [
            "__TESTROOT__/Debug/FluxKlangMac.app",
            "__TESTROOT__/Debug/FluxKlangMac.app/Contents/PlugIns/FluxKlangMacTests.xctest",
        ],
        "DiagnosticCollectionPolicy": 1,
        "EnvironmentVariables": {
            "APP_DISTRIBUTOR_ID_OVERRIDE": "com.apple.AppStore",
            "DYLD_INSERT_LIBRARIES": "/usr/lib/libRPAC.dylib",
            "FLUXKLANG_ISOLATED_TESTING": "1",
            "FLUXKLANG_QUALIFY_APPLE_ROUTING": "0",
            "FLUXKLANG_RUN_APPLE_MODEL_TESTS": "0",
            "IDE_CHOSEN_LOGGING_METHOD": "1",
            "OS_ACTIVITY_DT_MODE": "YES",
            "PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT": "1",
            "PERFC_ENABLE_PROFILE_MODE": "1",
            "PERFC_RESET_INSERT_LIBRARIES": "1",
            "PERFC_SUPPRESS_SYSTEM_REPORTS": "1",
            "SQLITE_ENABLE_THREAD_ASSERTIONS": "1",
            "TERM": "dumb",
        },
        "InProcessParallelizationEnabled": False,
        "IsAppHostedTestBundle": True,
        "IsMemoryTaggingAddressSanitizerEnabled": False,
        "PreferredScreenCaptureFormat": "screenRecording",
        "ProcessNamesForCrashReportCollection": ["FluxKlangMac"],
        "ProductModuleName": "FluxKlangMacTests",
        "RunOrder": 0,
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/FluxKlangMacTests.xctest",
        "TestHostBundleIdentifier": "org.davidjensenius.FluxKlang",
        "TestHostPath": "__TESTROOT__/Debug/FluxKlangMac.app",
        "TestLanguage": "",
        "TestRegion": "",
        "TestTimeoutsEnabled": False,
        "TestingEnvironmentVariables": {
            "DYLD_FRAMEWORK_PATH": (
                "__TESTROOT__/Debug:__TESTROOT__/Debug/PackageFrameworks:"
                "__SHAREDFRAMEWORKS__:"
                "__PLATFORMS__/MacOSX.platform/Developer/Library/Frameworks"
            ),
            "DYLD_INSERT_LIBRARIES": (
                "__TESTHOST__/Contents/Frameworks/libXCTestBundleInject.dylib:"
                "__DEVELOPERUSRLIB__/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib"
            ),
            "DYLD_LIBRARY_PATH": (
                "__TESTROOT__/Debug:__PLATFORMS__/MacOSX.platform/Developer/usr/lib"
            ),
            "PERFC_SUPPRESS_SYSTEM_REPORTS": "1",
            "XCInjectBundleInto": "unused",
            "XCODE_SCHEME_NAME": "FluxKlangMacIsolatedTests",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "__TESTROOT__/Debug",
            "__XPC_DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug",
            "__XPC_DYLD_LIBRARY_PATH": "__TESTROOT__/Debug",
        },
        "ToolchainsSettingValue": [],
        "UserAttachmentLifetime": "deleteOnSuccess",
    },
    "__xctestrun_metadata__": {
        "ContainerInfo": {
            "ContainerName": "FluxKlang",
            "SchemeName": "FluxKlangMacIsolatedTests",
        },
        "FormatVersion": 1,
    },
}
TARGET = "FluxKlangMacTests"
RUN_KEY = "FLUXKLANG_AUDIT_RUN_ID"
PROFILE = "mac-isolated-unit"
RUN_ID = "9e606771-fd79-4e32-afee-405a54ad0294"
SCRIPT = Path(__file__).with_name("prepare.py").resolve()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def set_field(value, path, replacement):
    for key in path[:-1]:
        value = value[key]
    value[path[-1]] = replacement


class PreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mac-audit-preparer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "MacIsolated.xctestrun"
        self.write_source(FIXTURE)

    def write_source(self, value):
        self.source.write_bytes(plistlib.dumps(value, sort_keys=False))
        self.pin = sha256(self.source.read_bytes())

    def snapshot(self):
        # Reads may affect atime; no explicit writes, mtime/ctime/mode/inode or
        # directory-entry changes are allowed during validation.
        return {
            str(path.relative_to(self.root)): (
                path.read_bytes(), path.stat().st_mtime_ns,
                path.stat().st_ctime_ns, path.stat().st_mode, path.stat().st_ino,
            )
            for path in self.root.rglob("*") if path.is_file()
        }

    def prepare(self):
        return prepare.prepare(self.source, self.pin, PROFILE)

    def validate(self, record):
        return prepare.validate(
            self.source, self.pin, PROFILE,
            record["output"]["path"], record["intent_path"],
        )

    def rewrite_output(self, record, data):
        Path(record["output"]["path"]).write_bytes(data)
        record["output"]["sha256"] = sha256(data)
        Path(record["intent_path"]).write_text(json.dumps(record), encoding="utf-8")

    def cli(self, command, *extra, pin=None):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), command, "--input", str(self.source),
             "--expected-sha256", pin if pin is not None else self.pin,
             "--profile", PROFILE, *extra],
            cwd=self.root, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            capture_output=True, text=True, timeout=10, check=False,
        )

    def test_round_trip_preservation_unique_siblings_and_read_only_validation(self):
        original = self.snapshot()[self.source.name]
        first = self.prepare()
        before_second = self.snapshot()
        second = self.prepare()
        self.assertNotEqual(first["run_id"], second["run_id"])
        for record in (first, second):
            self.assertEqual(uuid.UUID(record["run_id"]).version, 4)
            self.assertEqual(record["profile"], PROFILE)
            self.assertEqual(record["qualification"], "partial-regression")
            self.assertEqual(record["targets"], [TARGET])
            self.assertEqual(record["input"], {
                "path": str(self.source), "sha256": self.pin,
            })
            output = Path(record["output"]["path"])
            self.assertEqual(output.parent, self.source.parent)
            self.assertIn(record["run_id"], output.name)
            self.assertEqual(record["output"]["sha256"], sha256(output.read_bytes()))
            parsed = plistlib.loads(output.read_bytes())
            environment = parsed[TARGET]["EnvironmentVariables"]
            self.assertEqual(environment.pop(RUN_KEY), record["run_id"])
            self.assertEqual(parsed, FIXTURE)  # All unrelated fields/placeholders.
        for name, state in before_second.items():
            self.assertEqual(self.snapshot()[name], state)
        before = self.snapshot()
        with mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("UUID write")):
            self.assertEqual(self.validate(first), first)
            self.assertEqual(self.validate(second), second)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.snapshot()[self.source.name], original)

    def test_actual_cli_prepares_validates_and_refuses_without_writes(self):
        result = self.cli("prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "prepared")
        record = payload["intent"]
        before = self.snapshot()
        result = self.cli(
            "validate", "--output", record["output"]["path"],
            "--intent", record["intent_path"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "validated")
        result = self.cli("prepare", pin="0" * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn("input SHA256 mismatch", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.snapshot(), before)

    def test_pin_profile_and_explicit_cli_arguments_are_required(self):
        before = self.snapshot()
        for pin, profile in (
            ("0" * 64, PROFILE), ("${HASH}", PROFILE), (self.pin.upper(), PROFILE),
            (self.pin, "ios-isolated-unit"), (self.pin, "mac-live"),
        ):
            with self.subTest(pin=pin, profile=profile), self.assertRaises(prepare.Refusal):
                prepare.prepare(self.source, pin, profile)
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "prepare"],
            cwd=self.root, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            capture_output=True, text=True, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--input", result.stderr)
        self.assertIn("--expected-sha256", result.stderr)
        self.assertIn("--profile", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_rejects_targets_filters_ui_markers_and_unknown_execution_fields(self):
        variants = [
            (["FluxKlangTests"], FIXTURE[TARGET]),
            (["FluxKlangUITests"], FIXTURE[TARGET]),
            (["FluxKlangAppleQualificationTests"], FIXTURE[TARGET]),
            (["TestConfigurations"], []),
        ]
        variants += [
            ([TARGET, key], value)
            for key, value in (
                ("OnlyTestIdentifiers", []), ("SkipTestIdentifiers", ["Owner/test"]),
                ("IsUITestBundle", False), ("IsXCTRunnerHostedTestBundle", True),
                ("UITargetAppPath", "__TESTROOT__/Debug/Other.app"),
                ("UITargetAppEnvironmentVariables", {}),
                ("UnknownExecutionPolicy", "enabled"),
                ("CommandLineArguments", ["-only-testing:SomeTest"]),
                ("ToolchainsSettingValue", ["custom"]),
            )
        ]
        for path, replacement in variants:
            with self.subTest(path=path):
                value = copy.deepcopy(FIXTURE)
                set_field(value, path, replacement)
                self.write_source(value)
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.prepare()
                self.assertEqual(self.snapshot(), before)

    def test_rejects_substituted_identity_host_bundle_and_dependency_layouts(self):
        variants = [
            ("BlueprintName", "FluxKlangTests"),
            ("ProductModuleName", "FluxKlangAppleQualificationTests"),
            ("BlueprintProviderRelativePath", "Other.xcodeproj"),
            ("TestHostBundleIdentifier", "other.app"),
            ("TestHostPath", "__TESTROOT__/Release/FluxKlangMac.app"),
            ("TestHostPath", "/tmp/FluxKlangMac.app"),
            ("TestBundlePath", "__TESTROOT__/Debug/FluxKlangMacTests.xctest"),
            ("TestBundlePath", "__TESTHOST__/PlugIns/FluxKlangMacTests.xctest"),
            ("IsAppHostedTestBundle", False),
            ("DependentProductPaths", [FIXTURE[TARGET]["TestHostPath"]]),
            ("DependentProductPaths", list(reversed(FIXTURE[TARGET]["DependentProductPaths"]))),
            ("DependentProductPaths", [
                FIXTURE[TARGET]["TestHostPath"], "__TESTROOT__/Debug/Other.xctest",
            ]),
        ]
        for key, replacement in variants:
            with self.subTest(key=key, replacement=replacement):
                value = copy.deepcopy(FIXTURE)
                value[TARGET][key] = replacement
                self.write_source(value)
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.prepare()
                self.assertEqual(self.snapshot(), before)

    def test_rejects_metadata_versions_types_and_scheme_conflicts(self):
        metadata = "__xctestrun_metadata__"
        variants = [
            ([metadata, "FormatVersion"], value) for value in (2, True, "1", 1.0)
        ] + [
            ([metadata, "ContainerInfo", "SchemeName"], "FluxKlangIsolatedTests"),
            ([metadata, "ContainerInfo", "ContainerName"], "Other"),
            ([metadata, "Unknown"], {}),
            ([TARGET, "TestingEnvironmentVariables", "XCODE_SCHEME_NAME"], "Other"),
            ([TARGET, "EnvironmentVariables", "XCODE_SCHEME_NAME"], "Other"),
            ([TARGET, "IsAppHostedTestBundle"], 1),
            ([TARGET, "DefaultTestExecutionTimeAllowance"], True),
            ([TARGET, "EnvironmentVariables"], []),
            ([TARGET, "TestingEnvironmentVariables"], "malformed"),
        ]
        for path, replacement in variants:
            with self.subTest(path=path, replacement=replacement):
                value = copy.deepcopy(FIXTURE)
                set_field(value, path, replacement)
                self.write_source(value)
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.prepare()
                self.assertEqual(self.snapshot(), before)
        value = copy.deepcopy(FIXTURE)
        del value[metadata]
        self.write_source(value)
        with self.assertRaises(prepare.Refusal):
            self.prepare()

    def test_refuses_preexisting_identity_and_all_audit_environment_conflicts(self):
        flags = (
            "FLUXKLANG_ISOLATED_TESTING", "FLUXKLANG_QUALIFY_APPLE_ROUTING",
            "FLUXKLANG_RUN_APPLE_MODEL_TESTS",
        )
        variants = [
            ("EnvironmentVariables", RUN_KEY, value)
            for value in ("", RUN_ID, "$(RUN_ID)", "__RUN_ID__", 123, "not-a-uuid")
        ]
        variants += [
            ("EnvironmentVariables", flag, value)
            for flag in flags for value in ("$(FLAG)", "__FLAG__", "YES", 1, False)
        ]
        variants += [
            ("EnvironmentVariables", flag, "0" if index == 0 else "1")
            for index, flag in enumerate(flags)
        ]
        # Even non-conflicting duplicate audit keys are unreviewed in alternates.
        variants += [
            ("TestingEnvironmentVariables", key, value)
            for key in (*flags, RUN_KEY) for value in ("0", "1", RUN_ID, "$(ID)")
        ]
        for environment, key, replacement in variants:
            with self.subTest(environment=environment, key=key, replacement=replacement):
                value = copy.deepcopy(FIXTURE)
                value[TARGET][environment][key] = replacement
                self.write_source(value)
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.prepare()
                self.assertEqual(self.snapshot(), before)
        self.write_source(FIXTURE)
        record = self.prepare()
        output = Path(record["output"]["path"])
        before = self.snapshot()
        with self.assertRaises(prepare.Refusal):
            prepare.prepare(output, sha256(output.read_bytes()), PROFILE)
        self.assertEqual(self.snapshot(), before)

    def test_rejects_duplicate_plist_keys_and_unsupported_xml_or_binary(self):
        raw = self.source.read_bytes()
        variants = [
            raw.replace(b"<dict>", b"<dict><key>FluxKlangMacTests</key><dict/>", 1),
            raw.replace(b"<key>RunOrder</key>", b"<key>RunOrder</key><integer>0</integer>"
                        b"<key>RunOrder</key>", 1),
            raw.replace(b"<key>FLUXKLANG_ISOLATED_TESTING</key>",
                        b"<key>FLUXKLANG_ISOLATED_TESTING</key><string>1</string>"
                        b"<key>FLUXKLANG_ISOLATED_TESTING</key>", 1),
            raw.replace(b"<key>SchemeName</key>", b"<key>SchemeName</key><string>Other</string>"
                        b"<key>SchemeName</key>", 1),
            raw.replace(b"<integer>1</integer>", b"<real>1</real>", 1),
            raw.replace(b"<integer>1</integer>", b"<data>AQ==</data>", 1),
            raw.replace(b"<integer>1</integer>", b"<unknown/>", 1),
            raw.replace(b"<integer>1</integer>", b"<integer bogus='1'>1</integer>", 1),
            raw.replace(b"<integer>1</integer>", b"<integer>1<string/></integer>", 1),
            raw.replace(b"<integer>1</integer>", b"<integer>1</integer>ambiguous", 1),
            raw.replace(b"<plist version=\"1.0\">", b"<plist version=\"2.0\">", 1),
            raw.replace(prepare.DOCTYPE.encode(), b"<!DOCTYPE plist [<!ENTITY flag '1'>]>"),
            b"<plist><dict>",
            plistlib.dumps(FIXTURE, fmt=plistlib.FMT_BINARY),
        ]
        for index, data in enumerate(variants):
            with self.subTest(index=index):
                self.source.write_bytes(data)
                self.pin = sha256(data)
                before = self.snapshot()
                result = self.cli("prepare")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_nonclobbering_output_intent_and_dangling_symlink_collisions(self):
        output = self.root / f"MacIsolated.audit-run-{RUN_ID}.xctestrun"
        intent = output.with_suffix(".intent.json")
        for path, symlink in ((output, False), (intent, False), (output, True), (intent, True)):
            with self.subTest(path=path.name, symlink=symlink):
                if symlink:
                    path.symlink_to(self.root / "missing")
                else:
                    path.write_bytes(b"previous output: must not overwrite")
                original = self.source.read_bytes()
                with mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(RUN_ID)):
                    with self.assertRaises(FileExistsError):
                        self.prepare()
                self.assertEqual(self.source.read_bytes(), original)
                self.assertEqual(set(self.root.iterdir()), {self.source, path})
                if symlink:
                    self.assertEqual(path.readlink(), self.root / "missing")
                else:
                    self.assertEqual(path.read_bytes(), b"previous output: must not overwrite")
                path.unlink()

    def test_write_failure_and_final_recheck_failure_remove_new_pair(self):
        original_open = Path.open

        class BrokenWrite:
            def __init__(self, stream):
                self.stream = stream

            def __enter__(self):
                return self

            def write(self, content):
                self.stream.write(content[:20])
                raise OSError("fixture disk failure")

            def __exit__(self, *args):
                self.stream.close()

        for suffix in (".xctestrun", ".json"):
            def broken_open(path, mode="r", *args, **kwargs):
                stream = original_open(path, mode, *args, **kwargs)
                return BrokenWrite(stream) if mode == "xb" and path.suffix == suffix else stream

            with self.subTest(suffix=suffix):
                before = self.snapshot()
                with mock.patch.object(Path, "open", broken_open):
                    with self.assertRaisesRegex(OSError, "fixture disk failure"):
                        self.prepare()
                self.assertEqual(self.snapshot(), before)
        before = self.snapshot()
        with mock.patch.object(prepare, "validate", side_effect=prepare.Refusal("changed input")):
            with self.assertRaisesRegex(prepare.Refusal, "changed input"):
                self.prepare()
        self.assertEqual(self.snapshot(), before)

    def test_validator_rejects_input_output_digest_changes_without_repair(self):
        record = self.prepare()
        output = Path(record["output"]["path"])
        original_input = self.source.read_bytes()
        original_output = output.read_bytes()
        for path, original in ((self.source, original_input), (output, original_output)):
            with self.subTest(path=path.name):
                path.write_bytes(original + b"\n")
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.validate(record)
                self.assertEqual(self.snapshot(), before)
                path.write_bytes(original)

    def test_validator_rejects_rehashed_output_tampering_and_missing_identity(self):
        record = self.prepare()
        baseline = plistlib.loads(Path(record["output"]["path"]).read_bytes())
        variants = [
            ([TARGET, "EnvironmentVariables", RUN_KEY], value)
            for value in ("", "not-a-uuid", "$(ID)", RUN_ID, 1)
        ] + [
            ([TARGET, "EnvironmentVariables", "FLUXKLANG_ISOLATED_TESTING"], "0"),
            ([TARGET, "EnvironmentVariables", "FLUXKLANG_RUN_APPLE_MODEL_TESTS"], "1"),
            ([TARGET, "TestingEnvironmentVariables", RUN_KEY], record["run_id"]),
            ([TARGET, "TestingEnvironmentVariables", "XCODE_SCHEME_NAME"], "Other"),
            ([TARGET, "EnvironmentVariables", "TERM"], "xterm"),
            ([TARGET, "TestLanguage"], "en"),
            ([TARGET, "SkipTestIdentifiers"], []),
            ([TARGET, "TestHostPath"], "__TESTROOT__/Release/FluxKlangMac.app"),
            ([TARGET, "IsAppHostedTestBundle"], 1),
        ]
        for path, replacement in variants:
            with self.subTest(path=path, replacement=replacement):
                value = copy.deepcopy(baseline)
                set_field(value, path, replacement)
                self.rewrite_output(record, plistlib.dumps(value))
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.validate(record)
                self.assertEqual(self.snapshot(), before)
        del baseline[TARGET]["EnvironmentVariables"][RUN_KEY]
        self.rewrite_output(record, plistlib.dumps(baseline))
        before = self.snapshot()
        with mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("repair")):
            with self.assertRaises(prepare.Refusal):
                self.validate(record)
        self.assertEqual(self.snapshot(), before)

    def test_validator_rejects_intent_duplicates_types_and_binding_tampering(self):
        record = self.prepare()
        intent = Path(record["intent_path"])
        variants = [
            (["schema_version"], True), (["schema_version"], 2),
            (["profile"], "ios-isolated-unit"), (["qualification"], "full-regression"),
            (["targets"], [TARGET, "FluxKlangUITests"]),
            (["targets"], [TARGET, TARGET]), (["targets"], []),
            (["input", "sha256"], "0" * 64), (["output", "sha256"], "0" * 64),
            (["input", "path"], str(self.root / "other.xctestrun")),
            (["output", "path"], str(self.source)),
            (["intent_path"], str(self.root / "other.json")),
            (["unknown"], True),
        ] + [
            (["run_id"], value)
            for value in (
                None, 1, "", RUN_ID, RUN_ID.upper(), "$(ID)",
                "00000000-0000-0000-0000-000000000000",
                "9e606771-fd79-1e32-afee-405a54ad0294",
            )
        ]
        for path, replacement in variants:
            with self.subTest(path=path, replacement=replacement):
                value = copy.deepcopy(record)
                set_field(value, path, replacement)
                intent.write_text(json.dumps(value), encoding="utf-8")
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.validate(record)
                self.assertEqual(self.snapshot(), before)
        raw = json.dumps(record)
        for data in (
            '{"run_id": "duplicate", ' + raw[1:],
            raw.replace('"sha256":', '"sha256": "duplicate", "sha256":', 1),
            raw.replace('"schema_version": 1', '"schema_version": NaN'),
            "[]", "{",
        ):
            with self.subTest(data=data):
                intent.write_text(data, encoding="utf-8")
                before = self.snapshot()
                result = self.cli(
                    "validate", "--output", record["output"]["path"], "--intent", str(intent),
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_validator_rejects_relocation_symlinks_and_missing_pair_members(self):
        record = self.prepare()
        output = Path(record["output"]["path"])
        intent = Path(record["intent_path"])
        other = self.root / "other"
        other.mkdir()
        relocated = copy.deepcopy(record)
        relocated["output"]["path"] = str(other / output.name)
        relocated["intent_path"] = str(other / intent.name)
        (other / output.name).write_bytes(output.read_bytes())
        (other / intent.name).write_text(json.dumps(relocated), encoding="utf-8")
        before = self.snapshot()
        with self.assertRaises(prepare.Refusal):
            self.validate(relocated)
        self.assertEqual(self.snapshot(), before)
        for path in (self.source, output, intent):
            original = path.read_bytes()
            path.unlink()
            before = self.snapshot()
            with self.assertRaises(OSError):
                self.validate(record)
            self.assertEqual(self.snapshot(), before)
            saved = self.root / "saved"
            saved.write_bytes(original)
            path.symlink_to(saved)
            before = self.snapshot()
            with self.assertRaises(prepare.Refusal):
                self.validate(record)
            self.assertEqual(self.snapshot(), before)
            self.assertTrue(path.is_symlink())
            path.unlink()
            saved.rename(path)


if __name__ == "__main__":
    unittest.main()
