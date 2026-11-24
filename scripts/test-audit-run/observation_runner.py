"""Closed-output, source-only entry point; no launch or qualification."""

import os
import signal
import sys


_interrupted = False
_stage = "input"
_STAGES = {
    "input": b"input",
    "project-checks": b"project-checks",
    "pack-discovery": b"pack-discovery",
    "candidate-discovery": b"candidate-discovery",
    "snapshot-before": b"snapshot-before",
    "provider-enter": b"provider-enter",
    "provider-record": b"provider-record",
    "prepare": b"prepare",
    "provider-exit": b"provider-exit",
    "snapshot-after": b"snapshot-after",
    "consistency": b"consistency",
    "encoding": b"encoding",
    "final-check": b"final-check",
}
_PROVIDER_STAGES = frozenset(("provider-enter", "provider-record", "provider-exit"))
# Closed allowlist: exact literal ios_runtime provider-trusted refusal message
# -> fixed reason code. Codes are never derived from exception text.
_UNAVAILABLE = "provider-trusted runtime verification unavailable"
_PROVIDER_REASONS = {
    "runtime verification command timed out": b"command-timeout",
    "runtime verification output limit": b"command-output-limit",
    "runtime verification command failed": b"command-failed",
    "runtime verification command unavailable": b"command-unavailable",
    "invalid inventory path": b"invalid-path",
    "ambiguous inventory path": b"ambiguous-path",
    "runtime file size limit": b"file-size-limit",
    "duplicate inventory key": b"inventory-duplicate-key",
    "provider-trusted runtime requires Darwin arm64": b"platform",
    "fixed Xcode tool is not a regular file": b"xcode-tool-shape",
    "fixed CoreSimulator simctl is not a regular file": b"simctl-tool-shape",
    "unreviewed Xcode version/build observation": b"xcode-version",
    "malformed Xcode build observation": b"xcode-build-malformed",
    "unreviewed simulator SDK observation": b"simulator-sdk",
    "invalid provider-trusted runtime inventory": b"inventory-invalid",
    "invalid provider-trusted runtime inventory shape": b"inventory-shape",
    "provider-trusted runtime missing or ambiguous": b"runtime-missing",
    "unreviewed/unavailable provider-trusted runtime observation": b"runtime-build",
    "unexpected provider-trusted runtime bundle/root relationship": b"runtime-bundle-root",
    "fixed provider tool changed during provider-trusted inventory": b"provider-tool-drift",
    "provider-trusted runtime file shape/size mismatch": b"file-shape",
    "provider-trusted runtime file changed during observation": b"file-drift",
    "provider-trusted runtime file unavailable": b"file-unavailable",
    "standard /var alias unavailable": b"var-alias-unavailable",
    "standard /var alias identity mismatch": b"var-alias-identity",
    "checker alias identity mismatch": b"checker-alias-identity",
    "unreviewed checker digest observation": b"checker-digest",
    "checker observation must be thin arm64 Mach-O": b"checker-architecture",
    "checker changed during provider-trusted signature observation": b"checker-drift",
    "invalid provider-trusted runtime Info.plist observation": b"runtime-plist-invalid",
    "provider-trusted runtime plist identifier mismatch": b"runtime-plist-identifier",
    "provider-trusted runtime/toolchain observation changed": b"observation-drift",
    _UNAVAILABLE: b"verification-unavailable",
}
# Exact builtin cause classes only (no subclasses, no text).
_UNAVAILABLE_CAUSES = (
    (FileNotFoundError, b"verification-unavailable-filenotfound"),
    (PermissionError, b"verification-unavailable-permission"),
    (NotADirectoryError, b"verification-unavailable-notadirectory"),
    (TimeoutError, b"verification-unavailable-timeout"),
    (ProcessLookupError, b"verification-unavailable-processlookup"),
    (OSError, b"verification-unavailable-oserror"),
)


# Stage "prepare" only: the bounded producer wraps every failure as exactly
# ios_runtime.Refusal("bounded producer refused"); its direct cause selects a
# fixed code from these closed tables. No exception text is ever emitted.
_PRODUCER_REFUSED = "bounded producer refused"
# Exact literal prepare.Refusal messages.
_PREPARE_REASONS = {
    "unsupported profile": b"profile-unsupported",
    "plist must be UTF-8 XML": b"plist-not-utf8",
    "plist must use UTF-8 encoding": b"plist-encoding",
    "unsupported XML declaration or comment": b"plist-declaration",
    "unsupported plist attributes or trailing text": b"plist-attributes",
    "unexpected plist container text": b"plist-container-text",
    "unpaired plist dictionary key": b"plist-unpaired-key",
    "malformed plist dictionary key": b"plist-malformed-key",
    "nested plist scalar": b"plist-nested-scalar",
    "unsupported plist root": b"plist-root",
    "file symlinks are unsupported": b"file-symlink",
    "expected a regular file": b"file-not-regular",
    "expected SHA256 must be 64 lowercase hexadecimal digits": b"pin-format",
    "input must have the .xctestrun suffix": b"input-suffix",
    "input SHA256 mismatch": b"input-sha256-mismatch",
    "missing runtime-backed UI checker field": b"checker-field-missing",
    "UI checker does not match the independently verified runtime": b"checker-runtime-mismatch",
    "UI checker does not match the fixed provider-trusted runtime observation":
        b"checker-provider-mismatch",
    "run ID must be a literal UUID4 string": b"run-id-type",
    "run ID must be a canonical lowercase UUID4": b"run-id-noncanonical",
    "provider runtime observations are required": b"provider-observation-missing",
    "bounded material option must be boolean": b"bounded-option-type",
    "bounded material is only available for the provider profile": b"bounded-option-profile",
    "intent must be a JSON object": b"intent-not-object",
    "output/intent must have the run-linked sibling paths": b"intent-paths",
    "material serialization scalar limit": b"serialization-scalar-limit",
    "material serialization integer limit": b"serialization-integer-limit",
    "material serialization key type": b"serialization-key-type",
    "material serialization value type": b"serialization-value-type",
    "material serialization byte limit": b"serialization-byte-limit",
    "created material path changed": b"created-path-drift",
    "created material is not a regular file": b"created-not-regular",
    "invalid material write": b"created-write-invalid",
    "created material changed during write": b"created-write-drift",
    "material parent changed": b"material-parent-drift",
}
# Fixed literal prefixes of prepare.Refusal f-string messages; the dynamic
# remainder is never read beyond the prefix match.
_PREPARE_PREFIXES = (
    ("invalid plist XML: ", b"plist-xml-invalid"),
    ("duplicate plist key: ", b"plist-duplicate-key"),
    ("unsupported plist value: ", b"plist-value-unsupported"),
    ("duplicate JSON key: ", b"json-duplicate-key"),
    ("unsupported JSON constant: ", b"json-constant-unsupported"),
)
# prepare.require_equal f"{location}: <kind>" suffixes and the closed literal
# root locations passed to it; other locations get require-equal-<kind>.
_REQUIRE_EQUAL_KINDS = (
    (": unsupported type", b"type"),
    (": unsupported or missing keys", b"keys"),
    (": unsupported list length", b"length"),
    (": unexpected value", b"value"),
)
_REQUIRE_EQUAL_LOCATIONS = {
    "input": b"input",
    "intent": b"intent",
    "output": b"output",
    "serialized output": b"serialized-output",
    "validated intent": b"validated-intent",
    "provider observation": b"provider-observation",
}
# Exact literal bounded_material.Refusal messages.
_MATERIAL_REASONS = {
    "material path must be text": b"material-path-type",
    "invalid material path": b"material-path-invalid",
    "noncanonical material path": b"material-path-noncanonical",
    "material path component limit": b"material-path-component-limit",
    "material path changed": b"material-path-drift",
    "retained descriptors required": b"material-descriptors-required",
    "three material paths required": b"material-path-count",
    "material root changed": b"material-root-drift",
    "material path is not a regular file or directory": b"material-path-shape",
    "material path changed during open": b"material-open-drift",
    "material byte limit": b"material-byte-limit",
    "material changed during read": b"material-read-drift",
}
_PREPARE_UNAVAILABLE_CAUSES = (
    (FileNotFoundError, b"prepare-unavailable-filenotfound"),
    (FileExistsError, b"prepare-unavailable-fileexists"),
    (PermissionError, b"prepare-unavailable-permission"),
    (NotADirectoryError, b"prepare-unavailable-notadirectory"),
    (IsADirectoryError, b"prepare-unavailable-isadirectory"),
    (OSError, b"prepare-unavailable-oserror"),
)


def _single_text(error):
    args = error.args
    if type(args) is not tuple or len(args) != 1 or type(args[0]) is not str:
        return None
    return args[0]


def _provider_reason(error):
    message = _single_text(error)
    reason = _PROVIDER_REASONS.get(message)
    if reason is not None and message == _UNAVAILABLE:
        cause = error.__cause__
        for cause_type, cause_reason in _UNAVAILABLE_CAUSES:
            if type(cause) is cause_type:
                return cause_reason
    return reason


def _prepare_reason(cause):
    if type(cause) is integration.ios_runtime.Refusal:
        reason = _provider_reason(cause)
        return None if reason is None else b"prepare-provider-" + reason
    # The integration project checks pin both lazily imported modules.
    material = sys.modules.get("bounded_material")
    if material is not None and type(cause) is material.Refusal:
        return _MATERIAL_REASONS.get(_single_text(cause))
    producer = sys.modules.get("prepare")
    if producer is not None and type(cause) is producer.Refusal:
        message = _single_text(cause)
        if message is None:
            return None
        reason = _PREPARE_REASONS.get(message)
        if reason is not None:
            return reason
        for prefix, reason in _PREPARE_PREFIXES:
            if message.startswith(prefix):
                return reason
        for suffix, kind in _REQUIRE_EQUAL_KINDS:
            if message.endswith(suffix):
                location = message[:-len(suffix)]
                for literal, code in _REQUIRE_EQUAL_LOCATIONS.items():
                    if (location == literal or location.startswith(literal + ".")
                            or location.startswith(literal + "[")):
                        return code + b"-mismatch-" + kind
                return b"require-equal-" + kind
        return None
    for cause_type, reason in _PREPARE_UNAVAILABLE_CAUSES:
        if type(cause) is cause_type:
            return reason
    return None


def _reason_bytes(error):
    """Return a fixed allowlisted provider/prepare-stage reason code, or None."""
    try:
        if type(_stage) is not str or type(error) is not integration.ios_runtime.Refusal:
            return None
        if _stage in _PROVIDER_STAGES:
            return _provider_reason(error)
        if _stage == "prepare" and _single_text(error) == _PRODUCER_REFUSED:
            return _prepare_reason(error.__cause__)
        return None
    except BaseException:
        return None


def set_stage(stage):
    global _stage
    _stage = stage


def _stage_bytes():
    return _STAGES.get(_stage, b"observation") if type(_stage) is str else b"observation"


def _sigint(_signum, _frame):
    global _interrupted
    _interrupted = True


def check_interrupted():
    if _interrupted:
        raise KeyboardInterrupt


def main():
    global _interrupted, _stage, integration, acquisition
    _interrupted = False
    _stage = "input"
    try:
        signal.signal(signal.SIGINT, _sigint)
        import observation_acquisition as acquisition
        import source_snapshot_integration as integration

        root = os.environ.get("GITHUB_WORKSPACE")
        if sys.argv[1:2] == ["--bounded-prepare-v1"]:
            integration.ios_runtime.require(len(sys.argv) == 4, "invalid explicit input")
            integration.observe_v5(root, sys.modules[__name__], sys.argv[2], sys.argv[3])
        elif sys.argv[1:2] == ["--provider-products-v1"]:
            integration.ios_runtime.require(len(sys.argv) == 3, "invalid Products input")
            set_stage("candidate-discovery")
            candidate, pin = acquisition.discover_candidate(sys.argv[2])
            check_interrupted()
            integration.observe_v5(root, sys.modules[__name__], candidate, pin)
        else:
            integration.ios_runtime.require(len(sys.argv) == 1, "unexpected arguments")
            integration.observe_v4(root, sys.modules[__name__])
        set_stage("final-check")
        check_interrupted()
        output = b'{"status":"observed"}\n'
        status = 0
    except KeyboardInterrupt:
        output = b'{"diagnostic":"Interrupted","status":"failed"}\n'
        status = 130
    except BaseException as error:
        # Never publish exception text, context, traceback or the envelope.
        try:
            refused = ("integration" in globals()
                       and issubclass(type(error), integration.ios_runtime.Refusal))
        except BaseException:
            refused = False
        if _interrupted:
            output = b'{"diagnostic":"Interrupted","status":"failed"}\n'
            status = 130
        elif refused:
            reason = _reason_bytes(error)
            output = (b'{"diagnostic":"Refusal","stage":"' + _stage_bytes()
                      + (b'' if reason is None else b'","reason":"' + reason)
                      + b'","status":"refused"}\n')
            status = 1
        else:
            output = (b'{"diagnostic":"Unexpected failure","stage":"' + _stage_bytes()
                      + b'","status":"failed"}\n')
            status = 1
    try:
        # This final flag read commits the report/status pair. A later SIGINT
        # cannot change a successfully written report's exit status.
        if _interrupted:
            output = b'{"diagnostic":"Interrupted","status":"failed"}\n'
            status = 130
        if os.write(1, output) != len(output):
            return 1
    except BaseException:
        return 130 if _interrupted else 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
