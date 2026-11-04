"""Library-only, single-attempt Mac process operation. Invocation unqualified."""

import sys

sys.dont_write_bytecode = True

import os
from pathlib import Path
import signal
import stat
import subprocess

import build_mac
import build_receipt as receipt
import mac_launch_claim


def _spawn(argv, **kwargs):
    """Private Xcode syscall boundary; not a configurable execution backend."""
    return subprocess.Popen(argv, **kwargs)


def _signal_group(pid, signum):
    receipt.require(type(pid) is int and pid > 0, "invalid child session")
    os.killpg(pid, signum)


def _cleanup(child, pid):
    """Best effort only, while an unreaped session leader still anchors identity.

    Never discover descendants or signal after observing/reaping leader exit.
    A poll/signal race still requires external custody, not a closure claim.
    """
    try:
        if child.poll() is not None:
            return
        try:
            _signal_group(pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            child.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            pass
        if child.poll() is not None:
            return
        try:
            _signal_group(pid, signal.SIGKILL)
        except OSError:
            pass
        child.wait(timeout=5)
    except BaseException:
        # Preserve the original failure/interrupt. Repeated interruption or
        # failed reaping leaves uncertainty for external quarantine.
        pass


def _wait(argv, environment, slot, stdout, stderr):
    child = None
    pid = None
    try:
        child = _spawn(argv, env=environment, cwd=str(slot), stdout=stdout,
                       stderr=stderr, stdin=subprocess.DEVNULL, close_fds=True,
                       shell=False, start_new_session=True)
        candidate = child.pid
        receipt.require(type(candidate) is int and candidate > 0, "invalid child PID")
        pid = candidate
        code = child.wait(timeout=1800)
        receipt.require(type(code) is int, "invalid process return code")
        return pid, code
    except BaseException:
        # Ambiguous spawn without a returned valid handle permits NO discovery
        # or signaling. The invocation is consumed regardless.
        if child is not None and pid is not None:
            _cleanup(child, pid)
        raise


def _close_best_effort(stream):
    try:
        stream.close()
    except BaseException:
        pass


def _open_log(path):
    receipt.check_directory(path.parent)
    stream = path.open("xb")
    try:
        receipt.require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode),
                        "expected regular log")
        return stream
    except BaseException:
        _close_best_effort(stream)
        raise


def _publish(path, outcome):
    data = receipt.encode(outcome)
    receipt.require(len(data) <= receipt.METADATA_BYTES, "outcome byte limit")
    receipt.check_directory(path.parent)
    stream = path.open("xb")
    try:
        build_mac.write_all(stream, data)
        build_mac.finalize(stream)
    except BaseException:
        _close_best_effort(stream)
        raise
    build_mac.sync_directory(path.parent)
    _, reread = receipt.bounded(path, receipt.METADATA_BYTES)
    receipt.equal(reread, data, "process outcome bytes")
    receipt.equal(receipt.json_bytes(reread), outcome, "process outcome")


def launch(receipt_path, expected_sha256):
    """Consume once, spawn once, return only a published observed process exit.

    Requires separately authorized execution, qualified argv, exclusive custody,
    isolation and external descendant/storage/privacy procedures. No resume.
    """
    record = mac_launch_claim.claim(receipt_path, expected_sha256)
    intent = record["intent"]
    slot = Path(record["reservation"])
    names = ("prelaunch.json", "home", "tmp", "stdout.log", "stderr.log",
             "DerivedData", "result.xcresult", "process-outcome.json")
    # Claim success does not imply these longer paths fit. Refusal consumes.
    for path in (slot, *(slot / name for name in names)):
        mac_launch_claim._local_path(path, slot)
    for name in names[1:]:
        receipt.absent(slot / name)  # No-follow, including dangling links.
    for name in ("home", "tmp"):
        (slot / name).mkdir(mode=0o700)

    argv = [
        receipt.XCODEBUILD, "test-without-building", "-xctestrun", intent["output"]["path"],
        "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
        "-test-iterations", "1", "-derivedDataPath", str(slot / "DerivedData"),
        "-resultBundlePath", str(slot / "result.xcresult"),
    ]
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": receipt.DEVELOPER,
        "HOME": str(slot / "home"), "TMPDIR": str(slot / "tmp"), "LC_ALL": "C",
    }
    logs = []
    try:
        for name in ("stdout.log", "stderr.log"):
            logs.append(_open_log(slot / name))
        # Do not finalize (close) the logs before handing their FDs to Xcode.
        for stream in logs:
            stream.flush()
            os.fsync(stream.fileno())
        for directory in (slot / "home", slot / "tmp", slot, slot.parent):
            build_mac.sync_directory(directory)
        receipt.equal(receipt.validate(receipt_path, expected_sha256), intent,
                      "final pre-spawn intent")
        pid, code = _wait(argv, environment, slot, *logs)
        for stream in logs:
            build_mac.finalize(stream)
    except BaseException:
        for stream in logs:
            _close_best_effort(stream)
        raise

    outcome = {
        "schema_version": 1, "state": "process-exited",
        "reservation": record["reservation"], "receipt_sha256": expected_sha256,
        "prepared_xctestrun": intent["output"]["path"], "pid": pid, "returncode": code,
        "descendant_closure": "unproven", "artifacts_sealed": False,
    }
    _publish(slot / "process-outcome.json", outcome)
    return outcome
