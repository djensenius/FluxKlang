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
            output = (b'{"diagnostic":"Refusal","stage":"' + _stage_bytes()
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
