"""Closed-output, source-only entry point; no launch or qualification."""

import os
import signal
import sys


_interrupted = False


def _sigint(_signum, _frame):
    global _interrupted
    _interrupted = True


def check_interrupted():
    if _interrupted:
        raise KeyboardInterrupt


def main():
    global _interrupted, integration, acquisition
    _interrupted = False
    stage = "input"
    try:
        signal.signal(signal.SIGINT, _sigint)
        import observation_acquisition as acquisition
        import source_snapshot_integration as integration

        root = os.environ.get("GITHUB_WORKSPACE")
        stage = "observation"
        integration.observe_v4(root, sys.modules[__name__])
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
            output = b'{"diagnostic":"Refusal","stage":"observation","status":"refused"}\n'
            status = 1
        else:
            output = (b'{"diagnostic":"Unexpected failure","stage":"input","status":"failed"}\n'
                      if stage == "input" else
                      b'{"diagnostic":"Unexpected failure","stage":"observation","status":"failed"}\n')
            status = 1
    try:
        if _interrupted:
            output = b'{"diagnostic":"Interrupted","status":"failed"}\n'
            status = 130
        if os.write(1, output) != len(output):
            return 1
    except BaseException:
        return 130 if _interrupted else 1
    return 130 if _interrupted else status


if __name__ == "__main__":
    raise SystemExit(main())
