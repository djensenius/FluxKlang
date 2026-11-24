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
    "unreviewed Xcode version/build observation": b"xcode-version",
    "malformed Xcode build observation": b"xcode-build-malformed",
    "unreviewed simulator SDK observation": b"simulator-sdk",
    "invalid provider-trusted runtime inventory": b"inventory-invalid",
    "invalid provider-trusted runtime inventory shape": b"inventory-shape",
    "provider-trusted runtime missing or ambiguous": b"runtime-missing",
    "unreviewed/unavailable provider-trusted runtime observation": b"runtime-build",
    "unexpected provider-trusted runtime bundle/root relationship": b"runtime-bundle-root",
    "fixed Xcode tool changed during provider-trusted inventory": b"xcode-tool-drift",
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


def _reason_bytes(error):
    """Return a fixed allowlisted provider-stage reason code, or None."""
    try:
        if not (type(_stage) is str and _stage in _PROVIDER_STAGES
                and type(error) is integration.ios_runtime.Refusal):
            return None
        args = error.args
        if type(args) is not tuple or len(args) != 1 or type(args[0]) is not str:
            return None
        reason = _PROVIDER_REASONS.get(args[0])
        if reason is not None and args[0] == _UNAVAILABLE:
            cause = error.__cause__
            for cause_type, cause_reason in _UNAVAILABLE_CAUSES:
                if type(cause) is cause_type:
                    return cause_reason
        return reason
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
