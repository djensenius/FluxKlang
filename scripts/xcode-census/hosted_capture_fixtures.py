"""Explicit hosted-only process fixtures; NOT unittest-discoverable tests."""

import fcntl
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
from unittest import mock

import producer_capture as capture

# All children have a finite fallback lifetime even if the collector regresses.
# The inherited-pipe leader exits immediately; its holder stays in that same
# session/group. A separately opened flock proves holder resource release
# without probing or signalling a potentially reused descendant PID.
CHILD = """
import fcntl, os, signal, sys
mode, path, control, lifetime = sys.argv[1:]
if mode == "inherited" and os.fork() != 0:
    os._exit(0)
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.alarm(30)
fd = os.open(path, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
os.write(1, b"x" * 2048 if mode == "overflow" else b"ready\\n")
# Harness closure of the private control writer requests cooperative exit.
# Keep the lifetime writer open until exit, including in the orphaned holder.
assert os.read(int(control), 1) == b""
os._exit(0)
"""


class OwnedChildren:
    """Fixture-only ownership, independent of capture's cleanup and status JSON."""

    def __init__(self, lock):
        self.lock = lock
        self.children, self.errors = [], []
        self.control_read = self.control_write = None
        self.lifetime_read = self.lifetime_write = None
        # Save before capture's interposition; wait is saved at each launch.
        self.real_spawn, self.killpg = subprocess.Popen, os.killpg
        self.close, self.read, self.select = os.close, os.read, select.select
        self.clock, self.sleep, self.flock = time.monotonic, time.sleep, fcntl.flock

    def __enter__(self):
        try:
            self.control_read, self.control_write = os.pipe()
            self.lifetime_read, self.lifetime_write = os.pipe()
            os.set_blocking(self.lifetime_read, False)
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def attempt(self, phase, operation):
        try:
            operation()
        except Exception as error:
            self.errors.append((phase, getattr(error, "errno", None)))

    def close_fd(self, name):
        fd = getattr(self, name)
        if fd is not None:
            setattr(self, name, None)  # Never retry a possibly reused descriptor.
            self.attempt(name, lambda: self.close(fd))

    def spawn(self, *args, **kwargs):
        assert not self.children and kwargs["start_new_session"] is True
        kwargs["pass_fds"] = (self.control_read, self.lifetime_write)
        kwargs["close_fds"] = True
        child = self.real_spawn(*args, **kwargs)
        self.children.append((child, child.wait))
        self.close_fd("control_read")
        self.close_fd("lifetime_write")
        return child

    def release_holder(self):
        # EOF is tied to owned open descriptions, not a reusable process ID.
        deadline = self.clock() + 5
        while True:
            remaining = deadline - self.clock()
            if remaining <= 0:
                raise TimeoutError("holder lifetime EOF deadline")
            ready = self.select([self.lifetime_read], [], [], remaining)[0]
            if self.clock() >= deadline:
                raise TimeoutError("holder lifetime EOF deadline")
            if ready:
                if self.read(self.lifetime_read, 1) != b"":
                    raise AssertionError("unexpected lifetime pipe data")
                break
        while True:
            try:
                self.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.flock(self.lock, fcntl.LOCK_UN)
                if self.clock() >= deadline:
                    raise TimeoutError("holder lock release deadline")
                return
            except BlockingIOError:
                if self.clock() >= deadline:
                    raise TimeoutError("holder lock release deadline") from None
                self.sleep(min(0.05, max(0, deadline - self.clock())))

    def reap(self, wait):
        deadline = self.clock() + 3
        wait(timeout=3)
        if self.clock() >= deadline:
            raise TimeoutError("harness reap deadline")

    def __exit__(self, exc_type, exc, traceback):
        # Runs for capture exceptions AND every subsequent validation failure.
        self.close_fd("control_write")  # Also reaches holders of reaped leaders.
        self.close_fd("control_read")
        self.close_fd("lifetime_write")
        for child, wait in self.children:
            if child.returncode is None:  # No polling/reaping before signalling.
                def terminate():
                    try:
                        self.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                self.attempt("terminate", terminate)
                self.attempt("wait", lambda: self.reap(wait))
        before = len(self.errors)
        if self.lifetime_read is not None:
            self.attempt("holder_release", self.release_holder)
        released = len(self.errors) == before
        # Cooperative exit can finish after the first bounded wait failed.
        for child, wait in self.children:
            if child.returncode is None:
                self.attempt("reap_after_release", lambda: self.reap(wait))
            self.attempt("stdout_close", child.stdout.close)
        self.close_fd("lifetime_read")
        report = {"harness_cleanup": {
            "errors": self.errors, "holder_released": released,
            "reaped": [child.returncode is not None for child, _ in self.children],
        }}
        # Never replace the original exception or overwrite capture evidence.
        self.attempt("report", lambda: print(json.dumps(report), flush=True))
        if self.errors and exc is not None and hasattr(exc, "add_note"):
            self.attempt("exception_note", lambda: exc.add_note(json.dumps(report)))
        if self.errors and exc_type is None:
            raise AssertionError("harness cleanup failed: " + json.dumps(report))
        return False


def case(root, mode):
    directory = root / mode
    directory.mkdir()
    signals = []

    def kill_group(pid, signum):
        assert len(owner.children) == 1
        child = owner.children[0][0]
        assert pid == child.pid and child.returncode is None
        assert signum == signal.SIGKILL
        signals.append((pid, signum))
        return owner.killpg(pid, signum)

    timeout, limit = 8, 1024
    expected = "output_limit" if mode == "overflow" else "timeout"
    expected_data = b"x" * limit if mode == "overflow" else b"ready\n"
    print("HOSTED process fixture:", mode, flush=True)
    with (directory / "holder.lock").open("x+b") as lock, OwnedChildren(lock) as owner:
        # These wrappers assert ownership, but delegate to REAL process/signal
        # primitives. Clock, selector, pipe reads, wait and evidence I/O are real.
        with mock.patch.object(capture, "EVIDENCE", directory), \
                mock.patch.object(subprocess, "Popen", side_effect=owner.spawn), \
                mock.patch.object(os, "killpg", side_effect=kill_group):
            started = time.monotonic()
            failed = False
            try:
                capture.capture(
                    [sys.executable, "-I", "-B", "-c", CHILD, mode,
                     str(directory / "holder.lock"), str(owner.control_read),
                     str(owner.lifetime_write)],
                    timeout=timeout, limit=limit, output="census.txt")
            except RuntimeError as error:
                if str(error) != f"producer capture {expected}; see census.txt and capture.json":
                    raise
                failed = True
            elapsed = time.monotonic() - started
        # These must already exist when the caller receives the failure.
        assert (directory / "capture.json").stat().st_size <= 4096
        assert (directory / "census.txt").stat().st_size <= limit
        status = json.loads((directory / "capture.json").read_text())
        data = (directory / "census.txt").read_bytes()
        print(json.dumps({"case": mode, "elapsed_ms": round(elapsed * 1000),
                          "capture": status}), flush=True)
        assert failed and status["status"] == expected
        assert data == expected_data and status["captured_bytes"] == len(data)
        assert status["output"] == "census.txt"
        assert status["timeout_seconds"] == timeout and status["output_limit"] == limit
        assert elapsed <= timeout + capture.CLEANUP_SECONDS + 5
        if expected == "timeout":
            assert elapsed >= timeout
        assert status["reaped"] and not status["cleanup_timeout"]
        assert status["error_errno"] is None and status["cleanup_errno"] is None
        # Exit 0 proves the inherited leader exited BEFORE group termination.
        expected_code = 0 if mode == "inherited" else -signal.SIGKILL
        child = owner.children[0][0]
        assert status["returncode"] == child.returncode == expected_code
        assert signals == [(child.pid, signal.SIGKILL)]
        try:
            os.waitpid(child.pid, os.WNOHANG)
        except ChildProcessError:
            pass  # Real Popen.wait already reaped our direct child.
        else:
            raise AssertionError("collector did not reap its leader")
        # Before harness control closure: capture itself must release the holder.
        owner.release_holder()
    # Only known files in this freshly created owned directory; no tree removal.
    for name in ("holder.lock", "census.txt", "capture.json"):
        (directory / name).unlink()
    directory.rmdir()
    print("PASS HOSTED", mode, "classification/output/owned cleanup/reap/persistence", flush=True)


def main(argv):
    # Accidental-execution guard, not a trust/authority claim about environment.
    # Imports and ordinary unittest discovery never enter this function.
    if (argv != ["--hosted-process-fixtures"]
            or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or os.environ.get("RUNNER_OS") != "macOS"
            or sys.platform != "darwin" or os.getuid() == 0 or os.geteuid() == 0
            or signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL):
        raise SystemExit("requires explicit hosted-only opt-in on nonroot GitHub macOS runner")
    root = Path(tempfile.mkdtemp(prefix="xcode-census-process-"))
    for mode in ("quiet", "inherited", "overflow"):
        case(root, mode)
    root.rmdir()  # Failure leaves owned evidence for runner teardown.
    print("PASS 3 HOSTED process fixtures", flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
