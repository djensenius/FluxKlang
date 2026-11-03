"""Independent combined iOS metadata fixtures; no native execution."""

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


# Independently transcribed complete specimen, not implementation constants,
# Mac-fixture derivation, or a runtime read of session/native products.
FIXTURE = {
    "FluxKlangTests": {
        "BlueprintName": "FluxKlangTests",
        "BlueprintProviderName": "FluxKlang",
        "BlueprintProviderRelativePath": "FluxKlang.xcodeproj",
        "BundleIdentifiersForCrashReportEmphasis": [
            "org.davidjensenius.FluxKlang",
            "org.davidjensenius.FluxKlang.tests",
            "org.davidjensenius.FluxKlang.uitests",
        ],
        "CommandLineArguments": [],
        "DefaultTestExecutionTimeAllowance": 600,
        "DependentProductPaths": [
            "__TESTROOT__/Debug-iphonesimulator/FluxKlang.app",
            "__TESTROOT__/Debug-iphonesimulator/FluxKlang.app/PlugIns/FluxKlangTests.xctest",
            "__TESTROOT__/Debug-iphonesimulator/FluxKlangUITests-Runner.app",
            "__TESTROOT__/Debug-iphonesimulator/FluxKlangUITests-Runner.app/PlugIns/FluxKlangUITests.xctest",
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
        "ProcessNamesForCrashReportCollection": ["FluxKlang", "FluxKlangUITests-Runner"],
        "ProductModuleName": "FluxKlangTests",
        "RunOrder": 0,
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "TestBundlePath": "__TESTHOST__/PlugIns/FluxKlangTests.xctest",
        "TestHostBundleIdentifier": "org.davidjensenius.FluxKlang",
        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/FluxKlang.app",
        "TestLanguage": "",
        "TestRegion": "",
        "TestTimeoutsEnabled": False,
        "TestingEnvironmentVariables": {
            "DYLD_FRAMEWORK_PATH": (
                "__TESTROOT__/Debug-iphonesimulator:"
                "__TESTROOT__/Debug-iphonesimulator/PackageFrameworks:"
                "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks"
            ),
            "DYLD_INSERT_LIBRARIES": (
                "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/usr/lib/libRPAC.dylib"
            ),
            "DYLD_LIBRARY_PATH": (
                "__TESTROOT__/Debug-iphonesimulator:"
                "__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib"
            ),
            "PERFC_SUPPRESS_SYSTEM_REPORTS": "1",
            "XCInjectBundleInto": "unused",
            "XCODE_SCHEME_NAME": "FluxKlangIsolatedTests",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "__TESTROOT__/Debug-iphonesimulator",
            "__XPC_DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator",
            "__XPC_DYLD_LIBRARY_PATH": "__TESTROOT__/Debug-iphonesimulator",
        },
        "ToolchainsSettingValue": [],
        "UserAttachmentLifetime": "deleteOnSuccess",
    },
    "FluxKlangUITests": {
        "BlueprintName": "FluxKlangUITests",
        "BlueprintProviderName": "FluxKlang",
        "BlueprintProviderRelativePath": "FluxKlang.xcodeproj",
        "BundleIdentifiersForCrashReportEmphasis": [
            "org.davidjensenius.FluxKlang",
            "org.davidjensenius.FluxKlang.tests",
            "org.davidjensenius.FluxKlang.uitests",
        ],
        "CommandLineArguments": [],
        "DefaultTestExecutionTimeAllowance": 600,
        "DependentProductPaths": [
            "__TESTROOT__/Debug-iphonesimulator/FluxKlang.app",
            "__TESTROOT__/Debug-iphonesimulator/FluxKlang.app/PlugIns/FluxKlangTests.xctest",
            "__TESTROOT__/Debug-iphonesimulator/FluxKlangUITests-Runner.app",
            "__TESTROOT__/Debug-iphonesimulator/FluxKlangUITests-Runner.app/PlugIns/FluxKlangUITests.xctest",
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
        "IsMemoryTaggingAddressSanitizerEnabled": False,
        "IsUITestBundle": True,
        "IsXCTRunnerHostedTestBundle": True,
        "PreferredScreenCaptureFormat": "screenRecording",
        "ProcessNamesForCrashReportCollection": ["FluxKlang", "FluxKlangUITests-Runner"],
        "ProductModuleName": "FluxKlangUITests",
        "RunOrder": 1,
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "TestBundlePath": "__TESTHOST__/PlugIns/FluxKlangUITests.xctest",
        "TestHostBundleIdentifier": "org.davidjensenius.FluxKlang.uitests.xctrunner",
        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/FluxKlangUITests-Runner.app",
        "TestLanguage": "",
        "TestRegion": "",
        "TestTimeoutsEnabled": False,
        "TestingEnvironmentVariables": {
            "DYLD_FRAMEWORK_PATH": (
                "__TESTROOT__/Debug-iphonesimulator:"
                "__TESTROOT__/Debug-iphonesimulator/PackageFrameworks:"
                "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks"
            ),
            "DYLD_LIBRARY_PATH": (
                "__TESTROOT__/Debug-iphonesimulator:"
                "__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib"
            ),
            "XCODE_SCHEME_NAME": "FluxKlangIsolatedTests",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "__TESTROOT__/Debug-iphonesimulator",
            "__XPC_DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator",
            "__XPC_DYLD_LIBRARY_PATH": "__TESTROOT__/Debug-iphonesimulator",
        },
        "ToolchainsSettingValue": [],
        "UITargetAppCommandLineArguments": [],
        "UITargetAppEnvironmentVariables": {
            "APP_DISTRIBUTOR_ID_OVERRIDE": "com.apple.AppStore",
            "DYLD_FRAMEWORK_PATH": (
                "__TESTROOT__/Debug-iphonesimulator:"
                "__TESTROOT__/Debug-iphonesimulator/PackageFrameworks"
            ),
            "DYLD_LIBRARY_PATH": "__TESTROOT__/Debug-iphonesimulator",
            "XCODE_SCHEME_NAME": "FluxKlangIsolatedTests",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "__TESTROOT__/Debug-iphonesimulator",
            "__XPC_DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator",
            "__XPC_DYLD_LIBRARY_PATH": "__TESTROOT__/Debug-iphonesimulator",
        },
        "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/FluxKlang.app",
        "UITargetAppPerformanceAntipatternCheckerEnabled": True,
        "UserAttachmentLifetime": "deleteOnSuccess",
    },
    "__xctestrun_metadata__": {
        "ContainerInfo": {
            "ContainerName": "FluxKlang",
            "SchemeName": "FluxKlangIsolatedTests",
        },
        "FormatVersion": 1,
    },
}
PROFILE = "ios-simulator-isolated-unit-ui-v1"
TARGETS = ["FluxKlangTests", "FluxKlangUITests"]
RUN_KEY = "FLUXKLANG_AUDIT_RUN_ID"
RUN_ID = "9e606771-fd79-4e32-afee-405a54ad0294"
UUID_PATHS = [
    ("FluxKlangTests", "EnvironmentVariables"),
    ("FluxKlangUITests", "EnvironmentVariables"),
    ("FluxKlangUITests", "UITargetAppEnvironmentVariables"),
]
SCRIPT = Path(__file__).with_name("prepare.py").resolve()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def set_field(value, path, replacement):
    for key in path[:-1]:
        value = value[key]
    value[path[-1]] = replacement


def drift_variants(value, path=()):
    """Mutate every observed value/type/key, including nested identities."""
    if isinstance(value, dict):
        yield path, []
        yield path, {**value, "Unreviewed": ""}
        for key in value:
            missing = copy.deepcopy(value)
            del missing[key]
            yield path, missing
            yield from drift_variants(value[key], (*path, key))
    elif isinstance(value, list):
        yield path, {}
        yield path, [*value, "extra"]
        if value:
            yield path, value[:-1]
            yield path, list(reversed(value))
        for index, item in enumerate(value):
            yield from drift_variants(item, (*path, index))
    elif type(value) is bool:
        yield path, not value
        yield path, int(value)
    elif type(value) is int:
        yield path, value + 1
        yield path, bool(value)
        yield path, float(value)
        yield path, str(value)
    else:
        yield path, value + "-drift"
        yield path, 1


def invalid_xml_variants(raw):
    doctype = (
        b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    )
    stripped = raw.replace(doctype, b"", 1)
    variants = {
        "doctype inside root": stripped.replace(b"<dict>", b"<dict>" + doctype, 1),
        "doctype after root": stripped + doctype,
        "duplicate doctype": raw.replace(doctype, doctype + doctype, 1),
        "internal entity": raw.replace(doctype, b"<!DOCTYPE plist [<!ENTITY x '1'>]>"),
        "alternate DTD": raw.replace(b"PropertyList-1.0.dtd", b"other.dtd"),
        "comment": raw.replace(b"<dict>", b"<dict><!-- comment -->", 1),
        "invalid UTF-8": raw + b"\xff",
        "UTF-16 BOM": raw.decode().encode("utf-16"),
        "UTF-16 no BOM": raw.decode().replace("UTF-8", "UTF-16").encode("utf-16-le"),
        "UTF-32 no BOM": raw.decode().replace("UTF-8", "UTF-32").encode("utf-32-le"),
        "truncated": raw[:-20],
        "binary": plistlib.dumps(plistlib.loads(raw), fmt=plistlib.FMT_BINARY),
        "wrong root": raw.replace(b'version="1.0">', b'version="2.0">'),
    }
    for encoding in (b"UTF-16", b"ISO-8859-1", b"not-an-encoding"):
        variants[str(encoding)] = raw.replace(b'encoding="UTF-8"', b'encoding="' + encoding + b'"')
    for scalar in (
        b"<real>1</real>", b"<data>AQ==</data>", b"<unknown/>",
        b"<integer attr='1'>1</integer>", b"<integer>1<string/></integer>",
        b"<integer>1</integer>trailing", b"<integer>01</integer>",
    ):
        variants[str(scalar)] = raw.replace(b"<integer>1</integer>", scalar, 1)
    # Escaped spellings collide only after XML decoding. Exercise each of the
    # two targets and their environments, UI app environment, and metadata.
    for key in (
        "FluxKlangTests", "FluxKlangUITests", "EnvironmentVariables",
        "UITargetAppEnvironmentVariables", "SchemeName", "RunOrder",
        "FLUXKLANG_ISOLATED_TESTING", "XCODE_SCHEME_NAME",
    ):
        encoded = ("&#" + str(ord(key[0])) + ";" + key[1:]).encode()
        token = b"<key>" + key.encode() + b"</key>"
        variants["decoded duplicate " + key] = raw.replace(
            token, b"<key>" + encoded + b"</key><string>duplicate</string>" + token,
        )
    if RUN_KEY.encode() in raw:
        token = b"<key>" + RUN_KEY.encode() + b"</key>"
        variants["decoded duplicate UUID"] = raw.replace(
            token, b"<key>&#70;LUXKLANG_AUDIT_RUN_ID</key><string/>" + token,
        )
    return variants


class IOSPreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ios-audit-preparer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "IOSIsolated.xctestrun"
        self.write_source(FIXTURE)

    def write_source(self, value):
        self.source.write_bytes(plistlib.dumps(value, sort_keys=False))
        self.pin = sha256(self.source.read_bytes())

    def snapshot(self):
        # atime may change on reads; everything else and directory entries stay.
        return {
            str(path.relative_to(self.root)): (
                path.readlink() if path.is_symlink() else path.read_bytes(),
                path.lstat().st_mtime_ns, path.lstat().st_ctime_ns,
                path.lstat().st_mode, path.lstat().st_ino,
            )
            for path in self.root.rglob("*") if not path.is_dir()
        }

    def prepare(self):
        return prepare.prepare(self.source, self.pin, PROFILE)

    def validate(self, record, profile=PROFILE):
        return prepare.validate(
            self.source, self.pin, profile,
            record["output"]["path"], record["intent_path"],
        )

    def rewrite_output(self, record, data):
        Path(record["output"]["path"]).write_bytes(data)
        record["output"]["sha256"] = sha256(data)
        Path(record["intent_path"]).write_text(json.dumps(record), encoding="utf-8")

    def cli(self, command, *extra, profile=PROFILE, pin=None):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), command, "--input", str(self.source),
             "--expected-sha256", self.pin if pin is None else pin,
             "--profile", profile, *extra],
            cwd=self.root, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            capture_output=True, text=True, timeout=10, check=False,
        )

    def assert_validation_refused_read_only(self, record):
        before = self.snapshot()
        with mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("repair")):
            with self.assertRaises((ValueError, OSError)):
                self.validate(record)
        self.assertEqual(self.snapshot(), before)

    def test_round_trip_exactly_three_equal_additions_and_read_only_validation(self):
        original = self.snapshot()[self.source.name]
        records = [self.prepare(), self.prepare()]
        self.assertNotEqual(records[0]["run_id"], records[1]["run_id"])
        for record in records:
            run_id = record["run_id"]
            self.assertEqual(str(uuid.UUID(run_id)), run_id)
            self.assertEqual(uuid.UUID(run_id).version, 4)
            output = self.root / f"IOSIsolated.audit-run-{run_id}.xctestrun"
            intent = output.with_suffix(".intent.json")
            self.assertEqual(record, {
                "schema_version": 1, "profile": PROFILE,
                "qualification": "partial-regression", "run_id": run_id,
                "targets": TARGETS,
                "input": {"path": str(self.source), "sha256": self.pin},
                "output": {"path": str(output), "sha256": sha256(output.read_bytes())},
                "intent_path": str(intent),
            })
            parsed = plistlib.loads(output.read_bytes())
            for target, environment in UUID_PATHS:
                self.assertEqual(parsed[target][environment].pop(RUN_KEY), run_id)
            # Type-sensitive independent equality, not the implementation helper.
            self.assertEqual(
                plistlib.dumps(parsed, sort_keys=True),
                plistlib.dumps(FIXTURE, sort_keys=True),
            )
            before = self.snapshot()
            with mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("write")):
                self.assertEqual(self.validate(record), record)
            self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.snapshot()[self.source.name], original)
        output = Path(records[0]["output"]["path"])
        before = self.snapshot()
        with self.assertRaises(prepare.Refusal):
            prepare.prepare(output, sha256(output.read_bytes()), PROFILE)
        self.assertEqual(self.snapshot(), before)

    def test_cli_round_trip_and_explicit_pin_profile_refusals(self):
        result = self.cli("prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "prepared")
        record = json.loads(result.stdout)["intent"]
        before = self.snapshot()
        result = self.cli("validate", "--output", record["output"]["path"],
                          "--intent", record["intent_path"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "validated")
        for pin in ("0" * 64, self.pin.upper(), "$(HASH)", ""):
            result = self.cli("prepare", pin=pin)
            self.assertEqual(result.returncode, 1)
            self.assertIn("refused:", result.stderr)
            self.assertEqual(result.stdout, "")
        result = self.cli("prepare", profile="ios-isolated-unit")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.snapshot(), before)

    def test_cross_profile_inputs_and_intents_and_unknown_profiles_refuse(self):
        # Import only the independent Mac literal for actual cross-profile cases;
        # no Mac test inheritance or relabeled Mac cases.
        from test_prepare import FIXTURE as MAC_FIXTURE

        ios_record = self.prepare()
        before = self.snapshot()
        for profile in ("mac-isolated-unit", "ios-isolated-unit", "", "mac-live"):
            with self.subTest(profile=profile):
                with self.assertRaises(prepare.Refusal):
                    prepare.prepare(self.source, self.pin, profile)
                with self.assertRaises(prepare.Refusal):
                    self.validate(ios_record, profile)
        self.assertEqual(self.snapshot(), before)
        mac_source = self.root / "Mac.xctestrun"
        mac_source.write_bytes(plistlib.dumps(MAC_FIXTURE))
        mac_pin = sha256(mac_source.read_bytes())
        mac_record = prepare.prepare(mac_source, mac_pin, "mac-isolated-unit")
        before = self.snapshot()
        with self.assertRaises(prepare.Refusal):
            prepare.prepare(mac_source, mac_pin, PROFILE)
        with self.assertRaises(prepare.Refusal):
            prepare.validate(mac_source, mac_pin, PROFILE,
                             mac_record["output"]["path"], mac_record["intent_path"])
        # Correct input/profile but the other profile's pair must also refuse.
        with self.assertRaises(prepare.Refusal):
            self.validate(mac_record)
        with self.assertRaises(prepare.Refusal):
            prepare.validate(mac_source, mac_pin, "mac-isolated-unit",
                             ios_record["output"]["path"], ios_record["intent_path"])
        self.assertEqual(self.snapshot(), before)
        for record, profile, targets in (
            (ios_record, "mac-isolated-unit", ["FluxKlangMacTests"]),
            (mac_record, PROFILE, TARGETS),
        ):
            changed = {**record, "profile": profile, "targets": targets}
            Path(record["intent_path"]).write_text(json.dumps(changed), encoding="utf-8")
        self.assert_validation_refused_read_only(ios_record)
        before = self.snapshot()
        with self.assertRaises(prepare.Refusal):
            prepare.validate(mac_source, mac_pin, "mac-isolated-unit",
                             mac_record["output"]["path"], mac_record["intent_path"])
        self.assertEqual(self.snapshot(), before)

    def test_every_observed_key_value_type_and_order_drift_on_input_and_output(self):
        record = self.prepare()
        baseline = plistlib.loads(Path(record["output"]["path"]).read_bytes())
        for path, replacement in drift_variants(FIXTURE):
            with self.subTest(path=path, replacement=replacement):
                changed = copy.deepcopy(FIXTURE)
                if path:
                    set_field(changed, path, replacement)
                else:
                    changed = replacement
                self.write_source(changed)
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.prepare()
                self.assertEqual(self.snapshot(), before)
                self.write_source(FIXTURE)
                changed = copy.deepcopy(baseline)
                if path:
                    set_field(changed, path, replacement)
                else:
                    changed = replacement
                self.rewrite_output(record, plistlib.dumps(changed))
                self.assert_validation_refused_read_only(record)

    def test_extra_targets_filters_host_markers_and_environment_keys(self):
        variants = [
            (("FluxKlangMacTests",), {}),
            (("FluxKlangAppleQualificationTests",), {}),
            (("TestConfigurations",), []),
        ]
        for target in TARGETS:
            variants += [
                ((target, key), value) for key, value in (
                    ("OnlyTestIdentifiers", []), ("SkipTestIdentifiers", []),
                    ("OnlyTestIdentifiers", ["Owner/test"]),
                    ("SkipTestIdentifiers", ["Owner/test"]),
                    ("Environment", {}), ("TargetApplicationEnvironment", {}),
                    ("UITargetAppEnvironmentVariables", {}),
                ) if key not in FIXTURE[target]
            ]
        variants += [
            (("FluxKlangTests", "IsUITestBundle"), True),
            (("FluxKlangTests", "IsXCTRunnerHostedTestBundle"), True),
            (("FluxKlangUITests", "IsAppHostedTestBundle"), True),
            (("FluxKlangUITests", "InProcessParallelizationEnabled"), False),
        ]
        flags = (
            "FLUXKLANG_ISOLATED_TESTING", "FLUXKLANG_QUALIFY_APPLE_ROUTING",
            "FLUXKLANG_RUN_APPLE_MODEL_TESTS",
        )
        environments = UUID_PATHS + [
            (target, "TestingEnvironmentVariables") for target in TARGETS
        ]
        for target, environment in environments:
            variants += [
                ((target, environment, key), value)
                for key in (*flags, RUN_KEY, "FLUXKLANG_AUDIT_ID", "XCODE_SCHEME_NAME")
                for value in ("1", "0", RUN_ID, "$(ID)", "", 1, False)
                if FIXTURE[target][environment].get(key) != value
            ]
        record = self.prepare()
        baseline = plistlib.loads(Path(record["output"]["path"]).read_bytes())
        for path, replacement in variants:
            with self.subTest(path=path, replacement=replacement):
                value = copy.deepcopy(FIXTURE)
                set_field(value, path, replacement)
                self.write_source(value)
                before = self.snapshot()
                # A matching preexisting UUID is refused, not adopted.
                with mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(RUN_ID)):
                    with self.assertRaises(prepare.Refusal):
                        self.prepare()
                self.assertEqual(self.snapshot(), before)
                self.write_source(FIXTURE)
                value = copy.deepcopy(baseline)
                set_field(value, path, replacement)
                self.rewrite_output(record, plistlib.dumps(value))
                self.assert_validation_refused_read_only(record)
        # Even equal UUID copies outside the three fixed paths are not allowed.
        for target in TARGETS:
            value = copy.deepcopy(baseline)
            value[target]["TestingEnvironmentVariables"][RUN_KEY] = record["run_id"]
            self.rewrite_output(record, plistlib.dumps(value))
            self.assert_validation_refused_read_only(record)

    def test_each_missing_divergent_or_malformed_output_uuid_refuses(self):
        record = self.prepare()
        baseline = plistlib.loads(Path(record["output"]["path"]).read_bytes())
        for target, environment in UUID_PATHS:
            for replacement in (None, RUN_ID, "", "$(ID)", 1, False, record["run_id"].upper()):
                with self.subTest(target=target, environment=environment, value=replacement):
                    value = copy.deepcopy(baseline)
                    if replacement is None:
                        del value[target][environment][RUN_KEY]
                    else:
                        value[target][environment][RUN_KEY] = replacement
                    self.rewrite_output(record, plistlib.dumps(value))
                    self.assert_validation_refused_read_only(record)

    def test_original_byte_xml_and_decoded_duplicates_refuse_on_input_and_rehashed_output(self):
        record = self.prepare()
        output_raw = Path(record["output"]["path"]).read_bytes()
        input_raw = self.source.read_bytes()
        for mode, raw in (("input", input_raw), ("output", output_raw)):
            for name, data in invalid_xml_variants(raw).items():
                with self.subTest(mode=mode, variant=name):
                    if mode == "input":
                        self.source.write_bytes(data)
                        self.pin = sha256(data)
                        command = ("prepare",)
                    else:
                        self.rewrite_output(record, data)
                        command = ("validate", "--output", record["output"]["path"],
                                   "--intent", record["intent_path"])
                    before = self.snapshot()
                    result = self.cli(*command)
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertIn("refused:", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertEqual(result.stdout, "")
                    if mode == "input":
                        with self.assertRaises(prepare.Refusal):
                            self.prepare()
                        # Validation also reparses the pinned original.
                        self.assert_validation_refused_read_only(record)
                    else:
                        self.assert_validation_refused_read_only(record)
                    self.assertEqual(self.snapshot(), before)
            self.source.write_bytes(input_raw)
            self.pin = sha256(input_raw)

    def test_strict_intent_schema_identity_paths_hashes_and_decoded_json_duplicates(self):
        record = self.prepare()
        intent = Path(record["intent_path"])
        variants = list(drift_variants(record))
        variants += [
            (("run_id",), value) for value in (
                None, "", RUN_ID, RUN_ID.upper(), "$(ID)", RUN_ID.replace("-", ""),
                "00000000-0000-0000-0000-000000000000",
                "9e606771-fd79-1e32-afee-405a54ad0294",
            )
        ]
        for path, replacement in variants:
            with self.subTest(path=path, replacement=replacement):
                value = copy.deepcopy(record)
                if path:
                    set_field(value, path, replacement)
                else:
                    value = replacement
                intent.write_text(json.dumps(value), encoding="utf-8")
                self.assert_validation_refused_read_only(record)
        raw = json.dumps(record)
        for data in (
            '{"r\\u0075n_id": "duplicate", ' + raw[1:],
            raw.replace('"sha256":', '"sh\\u0061256": "duplicate", "sha256":'),
            raw.replace('"schema_version": 1', '"schema_version": NaN'),
            raw.replace('"schema_version": 1', '"schema_version": Infinity'),
            "{", "[]",
        ):
            with self.subTest(data=data):
                intent.write_text(data, encoding="utf-8")
                before = self.snapshot()
                result = self.cli("validate", "--output", record["output"]["path"],
                                  "--intent", str(intent))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("refused:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assert_validation_refused_read_only(record)
                self.assertEqual(self.snapshot(), before)

    def test_digest_changes_relocation_symlinks_and_orphans_refuse(self):
        record = self.prepare()
        output = Path(record["output"]["path"])
        intent = Path(record["intent_path"])
        for path in (self.source, output):
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            self.assert_validation_refused_read_only(record)
            path.write_bytes(original)
        other = self.root / "other"
        other.mkdir()
        relocated = copy.deepcopy(record)
        relocated["output"]["path"] = str(other / output.name)
        relocated["intent_path"] = str(other / intent.name)
        (other / output.name).write_bytes(output.read_bytes())
        (other / intent.name).write_text(json.dumps(relocated), encoding="utf-8")
        self.assert_validation_refused_read_only(relocated)
        for path in (self.source, output, intent):
            original = path.read_bytes()
            path.unlink()
            self.assert_validation_refused_read_only(record)
            saved = self.root / "saved"
            saved.write_bytes(original)
            path.symlink_to(saved)
            self.assert_validation_refused_read_only(record)
            if path == self.source:
                before = self.snapshot()
                with self.assertRaises(prepare.Refusal):
                    self.prepare()
                self.assertEqual(self.snapshot(), before)
            path.unlink()
            saved.rename(path)
        wrong_suffix = self.root / "input.plist"
        wrong_suffix.write_bytes(self.source.read_bytes())
        before = self.snapshot()
        with self.assertRaises(prepare.Refusal):
            prepare.prepare(wrong_suffix, self.pin, PROFILE)
        self.assertEqual(self.snapshot(), before)

    def test_exclusive_output_intent_and_symlink_collisions_do_not_clobber(self):
        output = self.root / f"IOSIsolated.audit-run-{RUN_ID}.xctestrun"
        intent = output.with_suffix(".intent.json")
        for path in (output, intent):
            for kind in ("file", "dangling symlink", "symlink"):
                with self.subTest(path=path.name, kind=kind):
                    if kind == "file":
                        path.write_bytes(b"previous")
                    else:
                        path.symlink_to(self.source if kind == "symlink" else self.root / "missing")
                    before = self.snapshot()
                    with mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(RUN_ID)):
                        with self.assertRaises(FileExistsError):
                            self.prepare()
                    self.assertEqual(self.snapshot(), before)
                    path.unlink()

    def test_partial_writes_and_final_recheck_cleanup_intent_last(self):
        original_open = Path.open
        events = []

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

        for suffix in (".xctestrun", ".json", None):
            def broken_open(path, mode="r", *args, **kwargs):
                stream = original_open(path, mode, *args, **kwargs)
                if mode == "xb":
                    events.append(path.suffix)
                    if path.suffix == suffix:
                        return BrokenWrite(stream)
                return stream

            with self.subTest(suffix=suffix):
                before = self.snapshot()
                events.clear()
                with mock.patch.object(Path, "open", broken_open):
                    if suffix is None:
                        with mock.patch.object(prepare, "validate",
                                               side_effect=prepare.Refusal("final recheck")):
                            with self.assertRaisesRegex(prepare.Refusal, "final recheck"):
                                self.prepare()
                    else:
                        with self.assertRaisesRegex(OSError, "fixture disk failure"):
                            self.prepare()
                self.assertEqual(events, [".xctestrun"] if suffix == ".xctestrun"
                                 else [".xctestrun", ".json"])
                self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
