#!/usr/bin/env python3
"""External, metadata-only preparation for one observed hosted-Mac profile.

Never launches anything. Validation is read-only. This is partial regression
preparation, not product closure, execution permission, or a runtime receipt.
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import uuid
import xml.etree.ElementTree as ET


PROFILE = "mac-isolated-unit"
TARGET = "FluxKlangMacTests"
SCHEME = "FluxKlangMacIsolatedTests"
RUN_KEY = "FLUXKLANG_AUDIT_RUN_ID"
HOST = "__TESTROOT__/Debug/FluxKlangMac.app"
DOCTYPE = (
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
)

# Deliberately closed, value-and-type checked profile: the reviewed XML v1
# Debug specimen, not a generic Xcode schema. Even empty filters/UI markers and
# unreviewed environment keys are refused, never removed or guessed.
OBSERVED = {
    TARGET: {
        "BlueprintName": TARGET,
        "BlueprintProviderName": "FluxKlang",
        "BlueprintProviderRelativePath": "FluxKlang.xcodeproj",
        "BundleIdentifiersForCrashReportEmphasis": [
            "org.davidjensenius.FluxKlang",
            "org.davidjensenius.FluxKlang.mactests",
        ],
        "CommandLineArguments": [],
        "DefaultTestExecutionTimeAllowance": 600,
        "DependentProductPaths": [
            HOST, HOST + "/Contents/PlugIns/FluxKlangMacTests.xctest",
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
        "ProductModuleName": TARGET,
        "RunOrder": 0,
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/FluxKlangMacTests.xctest",
        "TestHostBundleIdentifier": "org.davidjensenius.FluxKlang",
        "TestHostPath": HOST,
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
                "__DEVELOPERUSRLIB__/libMainThreadChecker.dylib:"
                "/usr/lib/libRPAC.dylib"
            ),
            "DYLD_LIBRARY_PATH": (
                "__TESTROOT__/Debug:"
                "__PLATFORMS__/MacOSX.platform/Developer/usr/lib"
            ),
            "PERFC_SUPPRESS_SYSTEM_REPORTS": "1",
            "XCInjectBundleInto": "unused",
            "XCODE_SCHEME_NAME": SCHEME,
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
            "SchemeName": SCHEME,
        },
        "FormatVersion": 1,
    },
}


class Refusal(ValueError):
    """Unsupported or inconsistent metadata; no repair is authorized."""


def require_equal(actual, expected, location):
    """Compare recursively without Python's bool/int equality ambiguity."""
    if type(actual) is not type(expected):
        raise Refusal(f"{location}: unsupported type")
    if isinstance(expected, dict):
        if actual.keys() != expected.keys():
            raise Refusal(f"{location}: unsupported or missing keys")
        for key, value in expected.items():
            require_equal(actual[key], value, f"{location}.{key}")
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise Refusal(f"{location}: unsupported list length")
        for index, value in enumerate(expected):
            require_equal(actual[index], value, f"{location}[{index}]")
    elif actual != expected:
        raise Refusal(f"{location}: unexpected value")


def parse_plist(data):
    """Parse only unambiguous UTF-8 XML plist containers and scalar types."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Refusal("plist must be UTF-8 XML") from error
    encoding = re.match(
        r"""\ufeff?<\?xml\s+[^?]*\bencoding\s*=\s*(['"])([^'"]+)\1""", text,
    )
    # Also refuse BOM-less UTF-16/32 bytes that happen to decode as UTF-8.
    if "\x00" in text or (encoding and encoding.group(2).lower() != "utf-8"):
        raise Refusal("plist must use UTF-8 encoding")
    # No entity declarations, internal subsets, or alternative external DTDs.
    # Inspect only: ElementTree does not fetch the standard DTD, and must see
    # its original position and the original bytes to reject malformed XML.
    declarations = [match.start() for match in re.finditer("<!", text)]
    if len(declarations) > 1 or any(
        not text.startswith(DOCTYPE, index) for index in declarations
    ):
        raise Refusal("unsupported XML declaration or comment")
    try:
        root = ET.fromstring(data)
    except (ET.ParseError, LookupError, ValueError) as error:
        raise Refusal(f"invalid plist XML: {error}") from error

    def whitespace(text):
        return not text or not text.strip()

    def decode(node):
        if node.attrib or not whitespace(node.tail):
            raise Refusal("unsupported plist attributes or trailing text")
        children = list(node)
        if node.tag in ("dict", "array"):
            if not whitespace(node.text):
                raise Refusal("unexpected plist container text")
            if node.tag == "array":
                return [decode(child) for child in children]
            if len(children) % 2:
                raise Refusal("unpaired plist dictionary key")
            result = {}
            for index in range(0, len(children), 2):
                key = children[index]
                if (key.tag != "key" or key.attrib or len(key)
                        or not whitespace(key.tail)):
                    raise Refusal("malformed plist dictionary key")
                name = key.text or ""
                if name in result:
                    raise Refusal(f"duplicate plist key: {name}")
                result[name] = decode(children[index + 1])
            return result
        if children:
            raise Refusal("nested plist scalar")
        value = node.text or ""
        if node.tag == "string":
            return value
        if node.tag == "integer" and re.fullmatch(r"-?(0|[1-9][0-9]*)", value):
            return int(value)
        if node.tag in ("true", "false") and not value:
            return node.tag == "true"
        raise Refusal(f"unsupported plist value: {node.tag}")

    if (root.tag != "plist" or root.attrib != {"version": "1.0"}
            or len(root) != 1 or not whitespace(root.text)
            or not whitespace(root.tail)):
        raise Refusal("unsupported plist root")
    return decode(root[0])


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def invalid_constant(value):
    raise Refusal(f"unsupported JSON constant: {value}")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def existing_file(selected):
    path = Path(selected)
    if path.is_symlink():
        raise Refusal("file symlinks are unsupported")
    path = path.resolve(strict=True)
    if not path.is_file():
        raise Refusal("expected a regular file")
    return path


def pinned_input(selected, expected_sha256, profile):
    if profile != PROFILE:
        raise Refusal("unsupported profile (only mac-isolated-unit)")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise Refusal("expected SHA256 must be 64 lowercase hexadecimal digits")
    path = existing_file(selected)
    if path.suffix != ".xctestrun":
        raise Refusal("input must have the .xctestrun suffix")
    data = path.read_bytes()
    if digest(data) != expected_sha256:
        raise Refusal("input SHA256 mismatch")
    parsed = parse_plist(data)
    # This also refuses every preexisting run key, including empty/malformed IDs.
    require_equal(parsed, OBSERVED, "input")
    return path, parsed


def check_run_id(value):
    if not isinstance(value, str):
        raise Refusal("run ID must be a literal UUID4 string")
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise Refusal("run ID must be a literal UUID4 string") from error
    if (str(parsed) != value or parsed.version != 4
            or parsed.variant != uuid.RFC_4122):
        raise Refusal("run ID must be a canonical lowercase UUID4")


def output_paths(input_path, run_id):
    output = input_path.with_name(f"{input_path.stem}.audit-run-{run_id}.xctestrun")
    return output, output.with_suffix(".intent.json")


def transformed(original, run_id):
    prepared = copy.deepcopy(original)
    prepared[TARGET]["EnvironmentVariables"][RUN_KEY] = run_id
    return prepared


def intent_record(input_path, input_digest, output, output_digest, intent, run_id):
    return {
        "schema_version": 1,
        "profile": PROFILE,
        "qualification": "partial-regression",
        "run_id": run_id,
        "targets": [TARGET],
        "input": {"path": str(input_path), "sha256": input_digest},
        "output": {"path": str(output), "sha256": output_digest},
        "intent_path": str(intent),
    }


def validate(input_path, expected_sha256, profile, output_path, intent_path):
    """Read and verify only; never create identity, flags, files, or products."""
    source, original = pinned_input(input_path, expected_sha256, profile)
    output = existing_file(output_path)
    intent = existing_file(intent_path)
    record = json.loads(
        intent.read_text(encoding="utf-8"), object_pairs_hook=unique_pairs,
        parse_constant=invalid_constant,
    )
    if not isinstance(record, dict):
        raise Refusal("intent must be a JSON object")
    run_id = record.get("run_id")
    check_run_id(run_id)
    expected_output, expected_intent = output_paths(source, run_id)
    if output != expected_output or intent != expected_intent:
        raise Refusal("output/intent must have the run-linked sibling paths")
    data = output.read_bytes()
    require_equal(
        record,
        intent_record(source, expected_sha256, output, digest(data), intent, run_id),
        "intent",
    )
    # Full type-sensitive comparison proves that the only parsed change is the
    # new EnvironmentVariables run ID. Flags and Xcode placeholders stay exact.
    require_equal(parse_plist(data), transformed(original, run_id), "output")
    return record


def prepare(input_path, expected_sha256, profile):
    """Create an exclusive sibling pair, publishing intent last; never launch."""
    source, original = pinned_input(input_path, expected_sha256, profile)
    run_id = str(uuid.uuid4())
    check_run_id(run_id)
    output, intent = output_paths(source, run_id)
    prepared = transformed(original, run_id)
    data = plistlib.dumps(prepared, fmt=plistlib.FMT_XML, sort_keys=False)
    require_equal(parse_plist(data), prepared, "serialized output")
    record = intent_record(source, expected_sha256, output, digest(data), intent, run_id)
    intent_data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("utf-8")
    created = []
    try:
        for path, content in ((output, data), (intent, intent_data)):
            # Exclusive creation refuses existing files AND dangling symlinks.
            with path.open("xb") as stream:
                created.append(path)
                stream.write(content)
        # Recheck pinned input and actual bytes before reporting success.
        validate(source, expected_sha256, profile, output, intent)
    except BaseException:
        # Remove only our own new files, intent first. Prior collisions survive.
        for path in reversed(created):
            path.unlink()
        raise
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "validate"):
        command = commands.add_parser(name)
        command.add_argument("--input", required=True, type=Path)
        command.add_argument("--expected-sha256", required=True)
        command.add_argument("--profile", required=True, choices=[PROFILE])
        if name == "validate":
            command.add_argument("--output", required=True, type=Path)
            command.add_argument("--intent", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            record = prepare(args.input, args.expected_sha256, args.profile)
        else:
            record = validate(
                args.input, args.expected_sha256, args.profile, args.output, args.intent,
            )
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    print(json.dumps({
        "status": "prepared" if args.command == "prepare" else "validated",
        "claim": "metadata-only; partial-regression; not execution authorization",
        "intent": record,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
