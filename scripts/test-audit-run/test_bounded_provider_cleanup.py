"""Synthetic provider cleanup faults; no process, native tool or hardware runs."""

from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import ios_runtime as runtime


class BoundedProviderCleanupTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for module, names in (
            (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
            (os, ("system", "fork", "posix_spawn", "posix_spawnp", "kill", "killpg")),
        ):
            for name in names:
                if hasattr(module, name):
                    self.stack.enter_context(mock.patch.object(
                        module, name, side_effect=AssertionError("process/signalling denied"),
                    ))

    def test_file_read_interrupt_and_cleanup_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"fixture")
            for active, cleanup, expected in (
                (KeyboardInterrupt("read"), OSError("close"), KeyboardInterrupt),
                (ValueError("read"), SystemExit("close"), SystemExit),
                (ValueError("read"), OSError("close"), ValueError),
            ):
                with self.subTest(active=type(active), cleanup=type(cleanup)):
                    close = os.close
                    closed = []

                    def closing(fd):
                        closed.append(fd)
                        close(fd)
                        raise cleanup

                    with mock.patch.object(runtime, "_read", side_effect=active), \
                         mock.patch.object(runtime.os, "close", side_effect=closing):
                        with self.assertRaises(expected) as caught:
                            runtime._bounded_provider_file(str(path), 100)
                    self.assertIs(caught.exception, cleanup if expected is SystemExit else active)
                    self.assertEqual(len(closed), 1)

    def test_file_close_failure_refuses_and_legacy_behavior_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"fixture")
            close = os.close
            interrupt = KeyboardInterrupt("read")

            def closing(fd):
                close(fd)
                raise OSError("close")

            with mock.patch.object(runtime.os, "close", side_effect=closing):
                with self.assertRaises(runtime.Refusal) as caught:
                    runtime._bounded_provider_file(str(path), 100)
            self.assertIsInstance(caught.exception.__cause__, OSError)
            with mock.patch.object(runtime, "_read", side_effect=interrupt), \
                 mock.patch.object(runtime.os, "close", side_effect=closing):
                with self.assertRaisesRegex(OSError, "close"):
                    runtime._provider_file(str(path), 100)

    def run_command(self, active=None, selector_error=None, poll_error=None,
                    kill_error=None, wait_error=None, stdout_error=None, data=(b"ok", b"")):
        events = []
        process = mock.Mock()
        process.stdout.fileno.return_value = 41

        def action(name, error=None, result=None):
            def call(*args, **kwargs):
                events.append((name, args, kwargs))
                if error is not None:
                    raise error
                return result
            return call

        process.poll.side_effect = action("poll", poll_error, None)
        process.kill.side_effect = action("kill", kill_error)
        process.wait.side_effect = action("wait", wait_error, 0)
        process.stdout.close.side_effect = action("stdout", stdout_error)
        selector = mock.Mock()
        selector.register.side_effect = action("register")
        selector.select.side_effect = action("select", active, [True])
        selector.close.side_effect = action("selector", selector_error)
        popen = mock.Mock(return_value=process)
        with mock.patch.object(runtime.subprocess, "Popen", popen), \
             mock.patch.object(runtime.selectors, "DefaultSelector", return_value=selector), \
             mock.patch.object(runtime.os, "read", side_effect=list(data)):
            try:
                result = runtime._bounded_command(["synthetic"], "/fixed/developer")
                error = None
            except BaseException as caught:
                result, error = None, caught
        return result, error, events, popen

    def test_command_success_limits_and_cleanup_sequence(self):
        result, error, events, popen = self.run_command()
        self.assertIsNone(error)
        self.assertEqual(result, "ok")
        self.assertEqual([name for name, _, _ in events],
                         ["register", "select", "select", "selector", "wait", "poll",
                          "kill", "wait", "stdout"])
        self.assertEqual(events[-2][2], {"timeout": runtime.TIMEOUT})
        self.assertLessEqual(events[4][2]["timeout"], runtime.TIMEOUT)
        self.assertEqual(popen.call_args.kwargs["env"],
                         {**runtime.ENV, "DEVELOPER_DIR": "/fixed/developer"})
        with mock.patch.object(runtime, "OUTPUT_LIMIT", 4):
            _, error, events, _ = self.run_command(data=(b"12345",))
        self.assertIsInstance(error, runtime.Refusal)
        self.assertIn("output limit", str(error))
        self.assertEqual([name for name, _, _ in events][-5:],
                         ["selector", "poll", "kill", "wait", "stdout"])

    def test_command_attempts_all_cleanups_and_preserves_precedence(self):
        original = KeyboardInterrupt("select")
        _, error, events, _ = self.run_command(
            active=original, selector_error=OSError("selector"),
            kill_error=SystemExit("kill"), wait_error=OSError("wait"),
            stdout_error=SystemExit("stdout"),
        )
        self.assertIs(error, original)
        self.assertEqual([name for name, _, _ in events],
                         ["register", "select", "selector", "poll", "kill", "wait", "stdout"])
        control = SystemExit("kill")
        _, error, events, _ = self.run_command(
            active=ValueError("select"), selector_error=OSError("selector"),
            kill_error=control, wait_error=KeyboardInterrupt("wait"), stdout_error=OSError("stdout"),
        )
        self.assertIs(error, control)
        self.assertEqual([name for name, _, _ in events][-4:], ["poll", "kill", "wait", "stdout"])
        active = ValueError("select")
        _, error, _, _ = self.run_command(
            active=active, selector_error=OSError("selector"),
            kill_error=OSError("kill"), wait_error=OSError("wait"), stdout_error=OSError("stdout"),
        )
        self.assertIs(error, active)

    def test_poll_failure_still_attempts_kill_wait_and_stdout_close(self):
        original = KeyboardInterrupt("poll")
        _, error, events, _ = self.run_command(
            active=ValueError("select"), poll_error=original,
            kill_error=OSError("kill"), wait_error=OSError("wait"), stdout_error=OSError("stdout"),
        )
        self.assertIs(error, original)
        self.assertEqual([name for name, _, _ in events][-4:], ["poll", "kill", "wait", "stdout"])
        self.assertEqual(events[-2][2], {"timeout": runtime.TIMEOUT})

    def test_command_detection_byte_and_timeout_remain_bounded(self):
        process = mock.Mock()
        process.poll.return_value = None
        process.stdout.fileno.return_value = 41
        selector = mock.Mock()
        selector.select.return_value = [True]
        with mock.patch.object(runtime.subprocess, "Popen", return_value=process), \
             mock.patch.object(runtime.selectors, "DefaultSelector", return_value=selector), \
             mock.patch.object(runtime.os, "read", return_value=b"12345") as read, \
             mock.patch.object(runtime, "OUTPUT_LIMIT", 4):
            with self.assertRaisesRegex(runtime.Refusal, "output limit"):
                runtime._bounded_command(["synthetic"])
        read.assert_called_once_with(41, 5)
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=runtime.TIMEOUT)
        selector.close.assert_called_once()
        process.stdout.close.assert_called_once()

        process.reset_mock()
        selector.reset_mock()
        selector.select.return_value = []
        with mock.patch.object(runtime.subprocess, "Popen", return_value=process), \
             mock.patch.object(runtime.selectors, "DefaultSelector", return_value=selector):
            with self.assertRaisesRegex(runtime.Refusal, "timed out"):
                runtime._bounded_command(["synthetic"])
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=runtime.TIMEOUT)
        selector.close.assert_called_once()
        process.stdout.close.assert_called_once()

    def test_legacy_command_keeps_existing_cleanup_behavior(self):
        process = mock.Mock()
        process.poll.return_value = 0
        process.stdout.close.side_effect = OSError("close")
        selector = mock.MagicMock()
        selector.__enter__.return_value = selector
        selector.select.side_effect = KeyboardInterrupt("select")
        with mock.patch.object(runtime.subprocess, "Popen", return_value=process), \
             mock.patch.object(runtime.selectors, "DefaultSelector", return_value=selector):
            with self.assertRaises(runtime.Refusal) as caught:
                runtime._command(["synthetic"])
        self.assertIsInstance(caught.exception.__cause__, OSError)


if __name__ == "__main__":
    unittest.main()
