"""Controlled filesystem fixtures for detached checkout HEAD observation."""

from contextlib import ExitStack
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import checkout_head as observer


FIRST = "a" * 40
SECOND = "b" * 40


class CheckoutHeadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="checkout-head-observer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / ".git").mkdir()
        self.write_head(FIRST)

    def write_head(self, value):
        (self.root / ".git" / "HEAD").write_bytes(value.encode("ascii") + b"\n")

    def observe(self, expected=FIRST):
        return observer.observe_checkout_head(str(self.root), expected)

    def tracked_open(self, actual_open, opened, heads):
        def track(path, flags, mode=0o777, *, dir_fd=None):
            descriptor = actual_open(path, flags, mode, dir_fd=dir_fd)
            opened.append(descriptor)
            if path == "HEAD":
                heads.append(descriptor)
            return descriptor

        return track

    def assert_descriptors_closed(self, descriptors):
        for descriptor in descriptors:
            with self.subTest(descriptor=descriptor):
                with self.assertRaises(OSError):
                    os.fstat(descriptor)

    def assert_refused(self, root=None, expected=FIRST):
        with self.assertRaises(observer.Refusal):
            observer.observe_checkout_head(
                str(self.root) if root is None else root, expected,
            )

    def test_reads_canonical_detached_head_and_observes_each_call(self):
        self.assertEqual(self.observe(), FIRST)
        self.write_head(SECOND)
        self.assertEqual(self.observe(SECOND), SECOND)
        self.assert_refused()

    def test_read_error_refuses_and_closes_all_descriptors(self):
        actual_open = os.open
        opened = []
        heads = []

        with mock.patch.object(
                observer.os, "open",
                side_effect=self.tracked_open(actual_open, opened, heads)) as open_patch:
            supported = observer.os.supports_dir_fd | {open_patch}
            with mock.patch.object(observer.os, "supports_dir_fd", supported):
                with mock.patch.object(
                        observer.os, "read",
                        side_effect=OSError("injected read error")):
                    with self.assertRaises(observer.Refusal) as refusal:
                        self.observe()

        self.assertEqual(str(refusal.exception.__cause__), "injected read error",
                         repr(refusal.exception))
        self.assertEqual(len(heads), 1)
        self.assert_descriptors_closed(opened)

    def test_head_fstat_error_refuses_and_closes_all_descriptors(self):
        actual_open = os.open
        actual_fstat = os.fstat
        opened = []
        heads = []

        def failing_head_fstat(descriptor):
            if descriptor in heads:
                raise OSError("injected fstat error")
            return actual_fstat(descriptor)

        with mock.patch.object(
                observer.os, "open",
                side_effect=self.tracked_open(actual_open, opened, heads)) as open_patch:
            supported = observer.os.supports_dir_fd | {open_patch}
            with mock.patch.object(observer.os, "supports_dir_fd", supported):
                with mock.patch.object(observer.os, "fstat", side_effect=failing_head_fstat):
                    with self.assertRaises(observer.Refusal) as refusal:
                        self.observe()

        self.assertEqual(str(refusal.exception.__cause__), "injected fstat error",
                         repr(refusal.exception))
        self.assertEqual(len(heads), 1)
        self.assert_descriptors_closed(opened)

    def test_short_sequential_reads_return_canonical_head(self):
        actual_read = os.read
        read_calls = []

        def short_read(descriptor, size):
            read_calls.append(size)
            return actual_read(descriptor, min(size, 7))

        with mock.patch.object(observer.os, "read", side_effect=short_read):
            self.assertEqual(self.observe(), FIRST)

        self.assertGreater(len(read_calls), 1)

    def test_rejects_symbolic_and_malformed_head_content(self):
        for content in (
            b"ref: refs/heads/main\n",
            b"A" * 40 + b"\n",
            b"a" * 39 + b"\n",
            b"a" * 40,
            b"a" * 40 + b"\r\n",
            b"a" * 40 + b"\nextra",
        ):
            with self.subTest(content=content):
                (self.root / ".git" / "HEAD").write_bytes(content)
                self.assert_refused()

    def test_rejects_mismatch_and_oversized_content(self):
        self.assert_refused(expected=SECOND)
        (self.root / ".git" / "HEAD").write_bytes(b"a" * (observer.HEAD_BYTES + 1))
        self.assert_refused()

    def test_rejects_linked_worktree_git_file(self):
        (self.root / ".git" / "HEAD").unlink()
        (self.root / ".git").rmdir()
        (self.root / ".git").write_text("gitdir: /some/other/worktree\n", encoding="ascii")
        self.assert_refused()

    def test_rejects_symlink_git_directory_and_head(self):
        external = self.root / "external"
        external.mkdir()
        (external / "HEAD").write_bytes((FIRST + "\n").encode("ascii"))

        (self.root / ".git" / "HEAD").unlink()
        (self.root / ".git").rmdir()
        (self.root / ".git").symlink_to(external, target_is_directory=True)
        self.assert_refused()

        (self.root / ".git").unlink()
        (self.root / ".git").mkdir()
        (self.root / ".git" / "HEAD").symlink_to(external / "HEAD")
        self.assert_refused()

    def test_rejects_nonregular_head_without_blocking_on_fifo(self):
        head = self.root / ".git" / "HEAD"
        head.unlink()
        head.mkdir()
        self.assert_refused()
        head.rmdir()
        os.mkfifo(head)
        self.assert_refused()

    def test_rejects_invalid_roots_and_expected_ids(self):
        (self.root / ".git" / "HEAD").write_bytes((FIRST + "\n").encode("ascii"))
        for root in (str(self.root.relative_to(self.root)), "/"):
            with self.subTest(root=root):
                self.assert_refused(root=root)
        symlink_root = self.root.parent / (self.root.name + "-link")
        symlink_root.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(symlink_root.unlink)
        self.assert_refused(root=str(symlink_root))
        self.assert_refused(root=self.root)
        for expected in (FIRST.upper(), "a" * 39, "a" * 41, 1, None):
            with self.subTest(expected=expected):
                self.assert_refused(expected=expected)

    def test_rejects_oversized_path_before_encoding(self):
        oversized = "/" + "x" * observer.PATH_BYTES + "\0"
        with mock.patch.object(observer, "_encode_path",
                               side_effect=AssertionError("path was encoded")) as encode, \
                mock.patch.object(observer, "_contains_nul",
                                  side_effect=AssertionError("path was scanned")) as contains_nul:
            with self.assertRaisesRegex(observer.Refusal, "path limit"):
                observer._checkout_path(oversized)
        encode.assert_not_called()
        contains_nul.assert_not_called()

    def test_cleanup_propagates_keyboard_interrupt_and_system_exit(self):
        for interruption in (KeyboardInterrupt, SystemExit):
            with self.subTest(interruption=interruption.__name__):
                with mock.patch.object(observer.os, "close", side_effect=interruption):
                    with self.assertRaises(interruption):
                        observer._close_quietly(0)

                with mock.patch.object(observer.os, "close", side_effect=interruption):
                    with self.assertRaises(interruption):
                        with ExitStack() as stack:
                            observer._register_close(stack, 0)
                            raise observer.Refusal("original refusal")

    def test_root_close_failure_closes_child_and_preserves_original_error(self):
        actual_close = os.close
        actual_open_directory = observer._open_directory
        opened_directories = []
        close_calls = []

        def track_directory(parent, name):
            descriptor = actual_open_directory(parent, name)
            opened_directories.append(descriptor)
            return descriptor

        def injected_close(descriptor):
            close_calls.append(descriptor)
            if len(close_calls) == 1:
                raise OSError("injected parent close failure")
            if len(close_calls) == 2:
                actual_close(descriptor)
                raise OSError("injected child cleanup failure")
            return actual_close(descriptor)

        try:
            with mock.patch.object(observer, "_open_directory", side_effect=track_directory), \
                    mock.patch.object(observer.os, "close", side_effect=injected_close):
                with self.assertRaises(observer.Refusal) as refusal:
                    self.observe()
            self.assertEqual(str(refusal.exception.__cause__), "injected parent close failure")
            self.assertEqual(len(opened_directories), 1)
            self.assertEqual(close_calls[1], opened_directories[0])
            with self.assertRaises(OSError):
                os.fstat(opened_directories[0])
        finally:
            # The injected first close failed without closing the root descriptor.
            if close_calls:
                try:
                    actual_close(close_calls[0])
                except OSError:
                    pass

    def test_interrupted_child_cleanup_does_not_close_reused_descriptor(self):
        actual_close = os.close
        actual_open_directory = observer._open_directory
        opened_directories = []
        close_calls = []
        reused = []
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(b"descriptor must remain open")

        def track_directory(parent, name):
            descriptor = actual_open_directory(parent, name)
            opened_directories.append(descriptor)
            return descriptor

        def injected_close(descriptor):
            close_calls.append(descriptor)
            if len(close_calls) == 1:
                raise OSError("injected parent close failure")
            if len(close_calls) == 2:
                actual_close(descriptor)
                replacement = os.open(sentinel, os.O_RDONLY)
                reused.append(replacement)
                raise KeyboardInterrupt("injected child cleanup interruption")
            return actual_close(descriptor)

        try:
            with mock.patch.object(observer, "_open_directory", side_effect=track_directory), \
                    mock.patch.object(observer.os, "close", side_effect=injected_close):
                with self.assertRaisesRegex(KeyboardInterrupt, "child cleanup interruption"):
                    self.observe()
            self.assertEqual(len(opened_directories), 1)
            self.assertEqual(reused, [opened_directories[0]])
            self.assertEqual(len(close_calls), 2)
            self.assertEqual(os.read(reused[0], 1), b"d")
        finally:
            for descriptor in (*reused, *close_calls[:1]):
                try:
                    actual_close(descriptor)
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
