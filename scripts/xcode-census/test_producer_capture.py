"""Pure mocked clock/pipe/process fixtures: never launch or signal a child."""

from collections import deque
from contextlib import ExitStack
import errno
import json
from pathlib import Path
import signal
import subprocess
import unittest
from unittest import mock

import producer_capture as capture
import hosted_capture_fixtures as hosted


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.now = 0.0
        self.chunks = deque()
        self.events = deque()
        self.waits = deque()
        self.files = {}
        self.child = mock.Mock(pid=31415, returncode=None)
        self.child.stdout.fileno.return_value = 101
        self.child.poll.side_effect = AssertionError("leader must remain unreaped")
        self.child.wait.side_effect = self.wait
        self.selector = mock.Mock()
        self.selector.select.side_effect = self.select
        self.spawn = self.patch("subprocess.Popen", return_value=self.child)
        self.patch("subprocess.run", side_effect=AssertionError("unexpected launch"))
        self.patch("signal.getsignal", return_value=signal.SIG_DFL)
        self.patch("time.monotonic", side_effect=lambda: self.now)
        self.patch("selectors.DefaultSelector", return_value=self.selector)
        self.blocking = self.patch("os.set_blocking")
        self.read = self.patch("os.read", side_effect=self.read_pipe)
        self.kill = self.patch("os.killpg", side_effect=self.signal_group)
        self.stack.enter_context(mock.patch.object(
            Path, "write_bytes", autospec=True, side_effect=self.write))
        self.stack.enter_context(mock.patch.object(
            Path, "write_text", autospec=True, side_effect=self.write))

    def patch(self, name, **kwargs):
        return self.stack.enter_context(mock.patch("producer_capture." + name, **kwargs))

    def write(self, path, data, **kwargs):
        self.files[path.name] = bytes(data) if isinstance(data, bytearray) else data
        return len(data)

    def select(self, timeout):
        step = self.events.popleft() if self.events else 0
        self.now += timeout if step is None else step
        return [] if step is None else [(None, 1)]

    def read_pipe(self, fd, size):
        self.blocking.assert_called_once_with(101, False)
        self.assertEqual(fd, 101)
        self.assertGreater(size, 0)
        self.assertLessEqual(size, 65536)
        value = self.chunks.popleft() if self.chunks else b""
        if isinstance(value, Exception):
            raise value
        self.assertLessEqual(len(value), size)
        return value

    def wait(self, *, timeout):
        self.assertGreater(timeout, 0)
        result = self.waits.popleft() if self.waits else 0
        if result == "hang":
            self.now += timeout
            raise subprocess.TimeoutExpired(["fixture"], timeout)
        self.child.returncode = result
        return result

    def signal_group(self, pid, signum):
        self.assertEqual((pid, signum), (31415, signal.SIGKILL))
        self.assertIsNone(self.child.returncode, "never signal a reaped/reusable PID")

    def status(self):
        return json.loads(self.files["capture.json"])

    def failed(self, status, **kwargs):
        with self.assertRaisesRegex(RuntimeError, status):
            capture.capture(["fixture"], timeout=1, **kwargs)
        self.assertEqual(self.status()["status"], status)
        self.child.poll.assert_not_called()

    def test_normal_and_exact_cap(self):
        self.chunks.extend([b"abcd", BlockingIOError(), b""])
        self.assertEqual(capture.capture(["fixture"], limit=4), b"abcd")
        self.assertEqual(self.status()["returncode"], 0)
        self.assertTrue(self.status()["reaped"])
        self.kill.assert_not_called()
        self.blocking.assert_called_once_with(101, False)
        self.assertTrue(self.spawn.call_args.kwargs["start_new_session"])
        self.assertEqual(self.spawn.call_args.kwargs["bufsize"], 0)
        self.assertEqual(self.spawn.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_nonzero_exit_is_persisted_without_signalling_reaped_pid(self):
        self.chunks.append(b"failure")
        self.waits.append(7)
        self.failed("exit")
        self.assertEqual(self.files["capture.txt"], b"failure")
        self.assertEqual(self.status()["returncode"], 7)
        self.kill.assert_not_called()

    def test_successful_wait_after_deadline_is_timeout_without_signalling(self):
        def late_wait(*, timeout):
            self.assertEqual(timeout, 1)
            self.now = 1.25
            self.child.returncode = 0
            return 0

        self.child.wait.side_effect = late_wait
        self.chunks.append(b"partial")
        self.failed("timeout", output="census.txt")
        self.assertEqual(self.files["census.txt"], b"partial")
        self.assertEqual(self.status()["returncode"], 0)
        self.assertTrue(self.status()["reaped"])
        self.kill.assert_not_called()
        self.child.wait.assert_called_once_with(timeout=1)

    def test_quiet_timeout(self):
        self.events.append(None)
        self.waits.append(-signal.SIGKILL)
        self.failed("timeout", output="census.txt")
        self.assertEqual(self.files["census.txt"], b"")
        self.assertEqual(self.status()["returncode"], -signal.SIGKILL)
        self.kill.assert_called_once_with(31415, signal.SIGKILL)
        self.child.wait.assert_called_once_with(timeout=capture.CLEANUP_SECONDS)

    def test_exited_leader_with_inherited_pipe_still_times_out(self):
        self.events.append(None)
        self.waits.append(0)  # already exited, but NOT reaped until cleanup
        self.failed("timeout", output="census.txt")
        self.assertEqual(self.status()["returncode"], 0)  # not mislabeled success
        self.kill.assert_called_once_with(31415, signal.SIGKILL)

    def test_drip_output_does_not_restart_deadline(self):
        self.events.extend([0.4, 0.4, 0.4])
        self.chunks.extend([b"a", b"b", b"c"])
        self.failed("timeout", output="census.txt")
        self.assertEqual(self.files["census.txt"], b"ab")

    def test_output_overflow_keeps_only_cap(self):
        self.chunks.append(b"abcde")
        self.failed("output_limit", limit=4)
        self.assertEqual(self.files["capture.txt"], b"abcd")
        self.assertEqual(self.status()["captured_bytes"], 4)
        self.kill.assert_called_once_with(31415, signal.SIGKILL)

    def test_eof_does_not_make_leader_wait_unbounded(self):
        self.waits.extend(["hang", "hang"])
        self.failed("timeout")
        self.assertEqual(self.now, 1 + capture.CLEANUP_SECONDS)
        self.assertEqual(self.child.wait.call_args_list, [
            mock.call(timeout=1), mock.call(timeout=capture.CLEANUP_SECONDS)])
        self.assertFalse(self.status()["reaped"])
        self.assertTrue(self.status()["cleanup_timeout"])
        self.child.stdout.close.assert_called_once()

    def test_read_and_cleanup_failures_preserve_evidence(self):
        self.chunks.extend([b"partial", OSError(errno.EIO, "fixture")])
        self.kill.side_effect = PermissionError(errno.EPERM, "fixture")
        self.waits.append("hang")
        self.failed("io_error")
        self.assertEqual(self.files["capture.txt"], b"partial")
        self.assertEqual(self.status()["error_errno"], errno.EIO)
        self.assertEqual(self.status()["cleanup_errno"], errno.EPERM)
        self.assertTrue(self.status()["cleanup_timeout"])

    def test_spawn_failure_has_no_cleanup_target(self):
        self.spawn.side_effect = OSError(errno.ENOENT, "fixture")
        self.failed("spawn_error")
        self.kill.assert_not_called()
        self.assertIsNone(self.status()["returncode"])

class HarnessCleanupTests(unittest.TestCase):
    """Every resource primitive is replaced BEFORE constructing the owner."""

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.now = 0.0
        self.child = mock.Mock(pid=31415, returncode=None)
        self.child.poll.side_effect = AssertionError("no early reaping")
        self.waiter = self.child.wait
        self.waiter.side_effect = self.wait
        self.spawn = self.patch("subprocess.Popen", return_value=self.child)
        self.patch("os.pipe", side_effect=[(101, 102), (103, 104)])
        self.close = self.patch("os.close")
        self.patch("os.set_blocking")
        self.kill = self.patch("os.killpg", side_effect=self.signal_group)
        self.read = self.patch("os.read", return_value=b"")
        self.select = self.patch("select.select", return_value=([103], [], []))
        self.flock = self.patch("fcntl.flock")
        self.patch("time.monotonic", side_effect=lambda: self.now)
        self.patch("time.sleep", side_effect=self.advance)
        self.print = self.stack.enter_context(mock.patch("builtins.print"))
        self.patch("tempfile.mkdtemp", side_effect=AssertionError("no local temp files"))
        self.stack.enter_context(mock.patch.object(
            Path, "open", side_effect=AssertionError("no local file I/O")))

    def patch(self, name, **kwargs):
        return self.stack.enter_context(mock.patch("hosted_capture_fixtures." + name, **kwargs))

    def advance(self, seconds):
        self.now += seconds

    def wait(self, *, timeout):
        self.assertEqual(timeout, 3)
        self.child.returncode = -signal.SIGKILL

    def signal_group(self, pid, signum):
        self.assertEqual((pid, signum), (31415, signal.SIGKILL))
        self.assertIsNone(self.child.returncode, "no signals after reaping")

    def report(self):
        return json.loads(self.print.call_args.args[0])["harness_cleanup"]

    def test_unexpected_capture_exception_uses_saved_cleanup_and_preserves_error(self):
        owner = hosted.OwnedChildren(mock.Mock())
        primary = ValueError("unexpected capture failure")
        with self.assertRaises(ValueError) as caught:
            with mock.patch.object(hosted.os, "killpg", side_effect=AssertionError("under test")):
                with owner:
                    owner.spawn(["fixture"], start_new_session=True)
                    self.child.wait = mock.Mock(side_effect=AssertionError("under test"))
                    with mock.patch.object(capture, "capture", side_effect=primary):
                        capture.capture(["fixture"])
        self.assertIs(caught.exception, primary)
        self.kill.assert_called_once_with(31415, signal.SIGKILL)
        self.waiter.assert_called_once_with(timeout=3)
        self.child.wait.assert_not_called()
        self.assertEqual(self.report(), {
            "errors": [], "holder_released": True, "reaped": [True]})
        self.assertCountEqual(self.close.call_args_list, [mock.call(fd) for fd in (101, 102, 103, 104)])
        self.assertEqual(self.spawn.call_args.kwargs["pass_fds"], (101, 104))

    def test_failed_termination_and_waits_do_not_mask_initial_error(self):
        self.kill.side_effect = PermissionError(errno.EPERM, "fixture")

        def hung_wait(*, timeout):
            self.advance(timeout)
            raise subprocess.TimeoutExpired(["fixture"], timeout)

        self.waiter.side_effect = hung_wait
        primary = AssertionError("capture reported unsuccessful cleanup")
        with self.assertRaises(AssertionError) as caught:
            with hosted.OwnedChildren(mock.Mock()) as owner:
                owner.spawn(["fixture"], start_new_session=True)
                raise primary
        self.assertIs(caught.exception, primary)
        self.assertEqual(self.now, 6)
        self.assertEqual(self.waiter.call_args_list, [mock.call(timeout=3)] * 2)
        self.assertEqual(self.report()["errors"], [
            ["terminate", errno.EPERM], ["wait", None], ["reap_after_release", None]])
        self.assertEqual(self.report()["reaped"], [False])
        self.assertTrue(self.report()["holder_released"])

    def test_reaped_leader_uses_control_eof_and_separate_holder_release(self):
        def ready(*args):
            self.assertIn(mock.call(102), self.close.call_args_list)
            return ([103], [], [])

        self.select.side_effect = ready
        self.flock.side_effect = [BlockingIOError(), None, None]
        with hosted.OwnedChildren(mock.Mock()) as owner:
            owner.spawn(["fixture"], start_new_session=True)
            self.child.returncode = 0
        self.kill.assert_not_called()
        self.waiter.assert_not_called()
        self.read.assert_called_once_with(103, 1)
        self.assertEqual(self.now, 0.05)
        self.assertTrue(self.report()["holder_released"])

    def test_unreleased_holder_is_bounded_failure_without_stale_signals(self):
        def quiet(readers, writers, errors, timeout):
            self.advance(timeout)
            return ([], [], [])

        self.select.side_effect = quiet
        with self.assertRaisesRegex(AssertionError, "harness cleanup failed"):
            with hosted.OwnedChildren(mock.Mock()) as owner:
                owner.spawn(["fixture"], start_new_session=True)
                self.child.returncode = 0
        self.assertEqual(self.now, 5)
        self.kill.assert_not_called()
        self.assertFalse(self.report()["holder_released"])
        self.assertEqual(self.report()["errors"], [["holder_release", None]])
        self.assertIn(mock.call(103), self.close.call_args_list)

    def test_reporting_failure_does_not_replace_initial_exception(self):
        self.print.side_effect = OSError(errno.EIO, "fixture")
        primary = ValueError("original")
        with self.assertRaises(ValueError) as caught:
            with hosted.OwnedChildren(mock.Mock()) as owner:
                owner.spawn(["fixture"], start_new_session=True)
                raise primary
        self.assertIs(caught.exception, primary)
        self.assertEqual(owner.errors, [("report", errno.EIO)])
        if hasattr(primary, "add_note"):
            self.assertIn('"report"', primary.__notes__[0])


if __name__ == "__main__":
    unittest.main()
