"""Manual hosted entry point for the closed checkout layout report."""

import os
import signal


_interrupted = False


def _record_sigint(signum, frame):
    # Do not raise asynchronously, including while handling another exception.
    global _interrupted
    _interrupted = True


def main():
    global _interrupted
    _interrupted = False
    # This process entry point runs on the main thread. Keep the handler
    # installed through process exit, including exception reporting.
    signal.signal(signal.SIGINT, _record_sigint)
    try:
        import json
        import checkout_layout

        report = checkout_layout.observe_checkout_layout_report(
            os.environ.get("GITHUB_WORKSPACE"), os.environ.get("GITHUB_SHA"),
        )
        status = json.loads(report)["status"]
        if status not in ("observed", "refused"):
            raise ValueError("unexpected report status")
        status = 0 if status == "observed" else 1
        if _interrupted:
            output = b'{"diagnostic":"Interrupted","status":"failed"}\n'
            status = 130
        else:
            output = (report + "\n").encode("utf-8")
        if os.write(1, output) != len(output):
            raise OSError("incomplete report write")
        return 130 if _interrupted else status
    except KeyboardInterrupt:
        diagnostic = b'{"diagnostic":"Interrupted","status":"failed"}\n'
        status = 130
    except BaseException:
        # Includes SystemExit: never export exception values or tracebacks.
        diagnostic = b'{"diagnostic":"Unexpected failure","status":"failed"}\n'
        status = 1
    try:
        os.write(1, diagnostic)
    except BaseException:
        pass
    return 130 if _interrupted else status


if __name__ == "__main__":
    raise SystemExit(main())
