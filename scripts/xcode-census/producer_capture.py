"""Producer-only POSIX child capture; no import-time execution or C authority."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

EVIDENCE = Path(__file__).parent / "build" / "evidence"
CLEANUP_SECONDS = 3


def capture(argv, *, timeout=60, limit=131072, output="capture.txt"):
    """Persist bounded output/status before rejecting exit, timeout or overflow.

    Single-owner child: never poll/reap its leader while collecting the pipe.
    The unreaped leader anchors the new session/group ID even if descendants
    retain stdout after it exits. No signal is sent after wait reaps the leader.
    """
    if not 0 < timeout <= 660 or not 0 < limit <= 262144:
        raise ValueError("invalid capture budget")
    if output not in ("capture.txt", "producer.log", "census.txt"):
        raise ValueError("invalid evidence output")
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise RuntimeError("capture requires default SIGCHLD; no external reaper")
    deadline = time.monotonic() + timeout
    child = selector = None
    data = bytearray()
    outcome = "io_error"
    error_errno = cleanup_errno = None
    cleanup_timeout = False
    try:
        child = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0, start_new_session=True)
        fd = child.stdout.fileno()
        os.set_blocking(fd, False)
        selector = selectors.DefaultSelector()
        selector.register(fd, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                outcome = "timeout"
                break
            if not selector.select(remaining):
                continue
            if time.monotonic() >= deadline:
                outcome = "timeout"
                break
            try:
                chunk = os.read(fd, min(65536, limit - len(data) + 1))
            except BlockingIOError:
                continue
            if not chunk:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    outcome = "timeout"
                    break
                code = child.wait(timeout=remaining)
                # POSIX wait can observe exit after a scheduling delay before
                # checking its timeout. Preserve that reaped exit code, but
                # never let it override the absolute collection deadline.
                if time.monotonic() >= deadline:
                    outcome = "timeout"
                else:
                    outcome = "ok" if code == 0 else "exit"
                break
            available = limit - len(data)
            data.extend(chunk[:available])
            if len(chunk) > available:
                outcome = "output_limit"
                break
    except subprocess.TimeoutExpired:
        outcome = "timeout"
    except OSError as error:
        error_errno = error.errno
        outcome = "spawn_error" if child is None else "io_error"
    finally:
        # No Popen context manager: its __exit__ could wait without a deadline.
        if child is not None and child.returncode is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                cleanup_errno = error.errno
            try:
                child.wait(timeout=CLEANUP_SECONDS)
            except subprocess.TimeoutExpired:
                cleanup_timeout = True
            except OSError as error:
                cleanup_errno = error.errno
        for resource in (selector, child.stdout if child is not None else None):
            if resource is not None:
                try:
                    resource.close()
                except OSError as error:
                    cleanup_errno = error.errno
                    if outcome == "ok":
                        outcome = "io_error"
    status = {
        "status": outcome, "returncode": child.returncode if child else None,
        "reaped": child is not None and child.returncode is not None,
        "error_errno": error_errno, "cleanup_errno": cleanup_errno,
        "cleanup_timeout": cleanup_timeout, "captured_bytes": len(data),
        "timeout_seconds": timeout, "output_limit": limit, "output": output,
    }
    # These paths are prepared by the workflow, never by the native scanner.
    (EVIDENCE / output).write_bytes(data)
    (EVIDENCE / "capture.json").write_text(json.dumps(status) + "\n", encoding="utf-8")
    if outcome != "ok":
        raise RuntimeError(f"producer capture {outcome}; see {output} and capture.json")
    return bytes(data)
