"""Synthetic, adversarial filesystem fixtures for loose-object acquisition."""

import errno
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest import mock
import zlib

import git_loose
import git_loose_acquire as reader


def fixture(kind, content):
    data = kind + b" " + str(len(content)).encode("ascii") + b"\0" + content
    return hashlib.sha1(data).hexdigest(), zlib.compress(data)


class LooseAcquireTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="loose-acquire-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.objects = self.root / ".git" / "objects"
        self.objects.mkdir(parents=True)
        self.oid, self.compressed = fixture(b"blob", b"hello\0world")
        self.path = self.objects / self.oid[:2] / self.oid[2:]
        self.path.parent.mkdir()
        self.path.write_bytes(self.compressed)

    def read(self, root=None, oid=None):
        return reader.read_object(str(self.root) if root is None else root,
                                  self.oid if oid is None else oid)

    def refused(self, root=None, oid=None):
        with self.assertRaises(reader.Refusal):
            self.read(root, oid)

    def test_synthetic_objects_fresh_reads_and_no_external_calls(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")):
            for kind in (b"blob", b"tree", b"commit", b"tag"):
                oid, compressed = fixture(kind, b"\0content\xff")
                path = self.objects / oid[:2] / oid[2:]
                path.parent.mkdir(exist_ok=True)
                path.write_bytes(compressed)
                with self.subTest(kind=kind):
                    self.assertEqual(self.read(oid=oid), (kind.decode(), b"\0content\xff"))
            self.assertEqual(self.read(), ("blob", b"hello\0world"))
            self.path.write_bytes(b"corrupt")
            self.refused()
            self.path.write_bytes(self.compressed)
            self.assertEqual(self.read(), ("blob", b"hello\0world"))
            self.path.unlink()
            self.refused()

    def test_invalid_ids_and_roots_refuse_before_open(self):
        class StrSubclass(str):
            pass

        invalid_roots = (self.root, StrSubclass(str(self.root)), "", "/", "relative",
                         str(self.root) + "/", str(self.root) + "/../x",
                         str(self.root) + "//x", "/x\0y", "/\ud800",
                         "/" + "x" * (reader.checkout_head.PATH_BYTES + 1))
        invalid_ids = (self.oid.upper(), self.oid[:-1], self.oid + "0", "g" * 40,
                       "é" * 40, StrSubclass(self.oid), b"a" * 40, 1, None)
        with mock.patch.object(reader.os, "open", side_effect=AssertionError("opened")):
            for root in invalid_roots:
                with self.subTest(root=root):
                    self.refused(root=root)
            for oid in invalid_ids:
                with self.subTest(oid=oid):
                    with self.assertRaises(reader.Refusal):
                        reader.read_object(str(self.root), oid)

    def test_missing_and_linked_worktree_layouts(self):
        self.path.unlink()
        (self.objects / "pack").mkdir()
        (self.objects / "info").mkdir()
        (self.objects / "info" / "alternates").write_text("/elsewhere\n", encoding="ascii")
        self.refused()
        (self.objects / "info" / "alternates").unlink()
        (self.objects / "info").rmdir()
        (self.objects / "pack").rmdir()
        self.path.parent.rmdir()
        self.refused()
        self.objects.rmdir()
        self.refused()
        (self.root / ".git").rmdir()
        self.refused()
        (self.root / ".git").write_text("gitdir: /elsewhere\n", encoding="ascii")
        self.refused()

    def test_only_target_open_enoent_is_loose_absence(self):
        self.assertTrue(issubclass(reader.LooseAbsent, reader.Refusal))
        self.path.unlink()
        with self.assertRaises(reader.LooseAbsent):
            self.read()
        self.path.parent.rmdir()
        with self.assertRaises(reader.LooseAbsent):
            self.read()
        self.objects.rmdir()
        with self.assertRaises(reader.Refusal) as raised:
            self.read()
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)
        (self.root / ".git").rmdir()
        with self.assertRaises(reader.Refusal) as raised:
            self.read()
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)
        with self.assertRaises(reader.Refusal) as raised:
            self.read(root=str(self.root / "missing"))
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

    def test_other_enoent_and_permission_errors_are_not_absence(self):
        actual_open = os.open
        actual_fstat = os.fstat
        fanout_fds = []

        def track(path, flags, mode=0o777, *, dir_fd=None):
            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
            if path == self.oid[:2]:
                fanout_fds.append(fd)
            return fd

        def bad_fstat(fd):
            if fd in fanout_fds:
                raise OSError(errno.ENOENT, "synthetic fstat")
            return actual_fstat(fd)

        for operation, fault in (
                ("fstat", bad_fstat),
                ("read", OSError(errno.ENOENT, "synthetic read")),
                ("decode", OSError(errno.ENOENT, "synthetic decode")),
                ("push", OSError(errno.ENOENT, "synthetic registration"))):
            with self.subTest(operation=operation), \
                    mock.patch.object(reader.os, "open", side_effect=track) as opened:
                with mock.patch.object(reader.os, "supports_dir_fd",
                                       reader.os.supports_dir_fd | {opened}):
                    target = (git_loose if operation == "decode" else
                              reader.ExitStack if operation == "push" else reader.os)
                    name = ("read_object" if operation == "decode" else operation)
                    with mock.patch.object(target, name, side_effect=fault):
                        with self.assertRaises(reader.Refusal) as raised:
                            self.read()
                    self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

        for target in (self.oid[:2], self.oid[2:]):
            def denied(path, flags, mode=0o777, *, dir_fd=None):
                if path == target:
                    raise OSError(errno.EACCES, "denied")
                return actual_open(path, flags, mode, dir_fd=dir_fd)

            with self.subTest(target=target), \
                    mock.patch.object(reader.os, "open", side_effect=denied) as opened, \
                    mock.patch.object(reader.os, "supports_dir_fd",
                                      reader.os.supports_dir_fd | {opened}):
                with self.assertRaises(reader.Refusal) as raised:
                    self.read()
                self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

    def test_absence_does_not_hide_cleanup_failure(self):
        self.path.unlink()
        actual_close = os.close
        actual_open = os.open
        fanout = []

        def track(path, flags, mode=0o777, *, dir_fd=None):
            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
            if path == self.oid[:2]:
                fanout.append(fd)
            return fd

        def failed_close(fd):
            actual_close(fd)
            if fd in fanout:
                raise OSError(errno.ENOENT, "synthetic close")

        with mock.patch.object(reader.os, "open", side_effect=track) as opened, \
                mock.patch.object(reader.os, "supports_dir_fd",
                                  reader.os.supports_dir_fd | {opened}), \
                mock.patch.object(reader.os, "close", side_effect=failed_close):
            with self.assertRaises(reader.Refusal) as raised:
                self.read()
        self.assertTrue(fanout)
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

    def test_target_registration_enoent_is_not_absence(self):
        actual_push = reader.ExitStack.push
        for stage in (4, 5):
            pushes = []

            def failing_push(stack, owner):
                pushes.append(owner)
                if len(pushes) == stage:
                    raise OSError(errno.ENOENT, "synthetic registration")
                return actual_push(stack, owner)

            with self.subTest(stage=stage), \
                    mock.patch.object(reader.ExitStack, "push", new=failing_push):
                with self.assertRaises(reader.Refusal) as raised:
                    self.read()
            self.assertEqual(len(pushes), stage)
            self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

    def test_corruption_and_symlink_are_not_absence(self):
        self.path.write_bytes(b"corrupt")
        with self.assertRaises(reader.Refusal) as raised:
            self.read()
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)
        self.path.unlink()
        self.path.symlink_to(self.path.parent / "missing")
        with self.assertRaises(reader.Refusal) as raised:
            self.read()
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)
        self.path.unlink()
        self.path.parent.rmdir()
        self.path.parent.symlink_to(self.objects / "missing", target_is_directory=True)
        with self.assertRaises(reader.Refusal) as raised:
            self.read()
        self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

    def test_symlinks_at_every_component_refuse(self):
        link = self.root.parent / (self.root.name + "-link")
        link.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(link.unlink)
        self.refused(root=str(link))
        nested = self.root / "nested"
        nested.mkdir()
        nested_fanout = nested / ".git" / "objects" / self.oid[:2]
        nested_fanout.mkdir(parents=True)
        (nested_fanout / self.oid[2:]).write_bytes(self.compressed)
        self.assertEqual(self.read(root=str(nested)), ("blob", b"hello\0world"))
        intermediate = self.root / "intermediate"
        intermediate.symlink_to(self.root, target_is_directory=True)
        self.refused(root=str(intermediate / "nested"))

        for path in (self.root / ".git", self.objects, self.path.parent, self.path):
            with self.subTest(path=path):
                renamed = path.with_name(path.name + "-real")
                path.rename(renamed)
                path.symlink_to(renamed, target_is_directory=renamed.is_dir())
                try:
                    self.refused()
                finally:
                    path.unlink()
                    renamed.rename(path)

    def test_nonregular_and_oversized_refuse(self):
        self.path.unlink()
        self.path.mkdir()
        self.refused()
        self.path.rmdir()
        os.mkfifo(self.path)
        self.refused()
        self.path.unlink()
        self.path.write_bytes(b"x" * (git_loose.COMPRESSED_LIMIT + 1))
        self.refused()

    def test_content_limit_object_is_accepted(self):
        content = bytes(range(256)) * (git_loose.OBJECT_LIMIT // 256)
        data = b"blob " + str(len(content)).encode("ascii") + b"\0" + content
        oid = hashlib.sha1(data).hexdigest()
        path = self.objects / oid[:2] / oid[2:]
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(zlib.compress(data, level=0))
        self.assertEqual(self.read(oid=oid), ("blob", content))

    def test_truncated_corrupt_wrong_identity_and_malformed_refuse(self):
        _, other = fixture(b"blob", b"another")
        for data in (b"", self.compressed[:-1], b"not zlib", self.compressed + b"x",
                     other, zlib.compress(b"blob 00\0")):
            with self.subTest(data=data):
                self.path.write_bytes(data)
                self.refused()

    def test_short_reads_and_change_during_read(self):
        actual_read = os.read
        sizes = []

        def short_read(fd, size):
            sizes.append(size)
            return actual_read(fd, min(size, 3))

        with mock.patch.object(reader.os, "read", side_effect=short_read):
            self.assertEqual(self.read(), ("blob", b"hello\0world"))
        self.assertGreater(len(sizes), 1)

        def changing_read(fd, size):
            result = actual_read(fd, min(size, 3))
            self.path.write_bytes(self.compressed + b"x")
            return result

        with mock.patch.object(reader.os, "read", side_effect=changing_read):
            with self.assertRaises(reader.Refusal) as raised:
                self.read()
            self.assertNotIsInstance(raised.exception, reader.LooseAbsent)

    def test_read_is_capped_even_if_file_grows_after_initial_fstat(self):
        actual_read = os.read
        sizes = []

        def growing_read(fd, size):
            sizes.append(size)
            if len(sizes) == 1:
                self.path.write_bytes(b"x" * (git_loose.COMPRESSED_LIMIT + 100))
            return actual_read(fd, size)

        with mock.patch.object(reader.os, "read", side_effect=growing_read), \
                mock.patch.object(git_loose, "read_object") as decode:
            self.refused()
        self.assertEqual(sizes, [git_loose.COMPRESSED_LIMIT + 1])
        decode.assert_not_called()

    def test_metadata_changes_refuse_even_with_identical_content(self):
        actual_fstat = os.fstat
        actual_open = os.open
        objects = []
        calls = []

        def track(path, flags, mode=0o777, *, dir_fd=None):
            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
            if path == self.oid[2:]:
                objects.append(fd)
            return fd

        def changed(fd):
            info = actual_fstat(fd)
            if fd in objects:
                calls.append(fd)
                if len(calls) == 2:
                    altered = mock.Mock(wraps=info)
                    altered.st_ctime_ns = info.st_ctime_ns + 1
                    return altered
            return info

        with mock.patch.object(reader.os, "open", side_effect=track) as opened:
            with mock.patch.object(reader.os, "supports_dir_fd",
                                   reader.os.supports_dir_fd | {opened}), \
                    mock.patch.object(reader.os, "fstat", side_effect=changed):
                self.refused()
        self.assertEqual(len(calls), 2)

    def test_descriptors_closed_on_success_failures_and_interruptions(self):
        actual_open = os.open
        for failure in (None, OSError("read failure"), KeyboardInterrupt(), SystemExit(),
                        "fstat", "decode"):
            opened = []
            object_fds = []

            def track(path, flags, mode=0o777, *, dir_fd=None):
                fd = actual_open(path, flags, mode, dir_fd=dir_fd)
                opened.append(fd)
                if path == self.oid[2:]:
                    object_fds.append(fd)
                return fd

            actual_fstat = os.fstat

            def failing_fstat(fd):
                if fd in object_fds:
                    raise OSError("fstat failure")
                return actual_fstat(fd)

            with self.subTest(failure=failure), \
                    mock.patch.object(reader.os, "open", side_effect=track) as open_patch:
                with mock.patch.object(reader.os, "supports_dir_fd",
                                       reader.os.supports_dir_fd | {open_patch}):
                    if failure is None:
                        self.read()
                    elif failure == "fstat":
                        with mock.patch.object(reader.os, "fstat", side_effect=failing_fstat):
                            self.refused()
                    elif failure == "decode":
                        with mock.patch.object(git_loose, "read_object",
                                               side_effect=ValueError("decode failure")):
                            self.refused()
                    else:
                        with mock.patch.object(reader.os, "read", side_effect=failure):
                            exception = reader.Refusal if isinstance(failure, OSError) else type(failure)
                            with self.assertRaises(exception):
                                self.read()
            self.assertTrue(opened)
            for fd in opened:
                with self.assertRaises(OSError):
                    os.fstat(fd)

    def test_registration_failures_close_owned_descriptors_once(self):
        actual_open = os.open
        actual_close = os.close
        actual_push = reader.ExitStack.push

        for stage in range(1, 6):
            for after_push in (False, True):
                for error_type in (OSError, RuntimeError, KeyboardInterrupt, SystemExit):
                    with self.subTest(stage=stage, after_push=after_push, error=error_type):
                        error = error_type("registration failure")
                        live = set()
                        double_closes = []
                        pushes = []
                        opens_at_failure = []

                        def track_open(path, flags, mode=0o777, *, dir_fd=None):
                            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
                            live.add(fd)
                            return fd

                        def track_close(fd):
                            if fd not in live:
                                double_closes.append(fd)
                                return
                            live.remove(fd)
                            actual_close(fd)

                        def failing_push(stack, callback):
                            pushes.append(callback)
                            if len(pushes) == stage:
                                opens_at_failure.append(set(live))
                                if after_push:
                                    actual_push(stack, callback)
                                raise error
                            return actual_push(stack, callback)

                        with mock.patch.object(reader.os, "open", side_effect=track_open) as opened:
                            with mock.patch.object(reader.os, "supports_dir_fd",
                                                   reader.os.supports_dir_fd | {opened}), \
                                    mock.patch.object(reader.os, "close", side_effect=track_close), \
                                    mock.patch.object(reader.ExitStack, "push", new=failing_push):
                                expected = reader.Refusal if error_type is OSError else error_type
                                with self.assertRaises(expected) as raised:
                                    self.read()
                        if error_type is OSError:
                            self.assertIs(raised.exception.__cause__, error)
                        else:
                            self.assertIs(raised.exception, error)
                        self.assertEqual(len(pushes), stage)
                        self.assertEqual(len(opens_at_failure[0]), stage - 1)
                        self.assertEqual(live, set())
                        self.assertEqual(double_closes, [])

    def test_registration_unwind_close_failure_preserves_error_and_reused_fd(self):
        actual_open = os.open
        actual_close = os.close
        actual_push = reader.ExitStack.push
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(b"safe")
        for cleanup_error in (OSError("close failure"), KeyboardInterrupt(), SystemExit()):
            with self.subTest(cleanup_error=type(cleanup_error).__name__):
                fanout = []
                reused = []
                pushes = []
                registration_error = RuntimeError("registration failure")

                def track_open(path, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(path, flags, mode, dir_fd=dir_fd)
                    if path == self.oid[:2]:
                        fanout.append(fd)
                    return fd

                def failing_close(fd):
                    if fd in fanout:
                        actual_close(fd)
                        reused.append(actual_open(sentinel, os.O_RDONLY))
                        raise cleanup_error
                    return actual_close(fd)

                def failing_push(stack, callback):
                    pushes.append(callback)
                    result = actual_push(stack, callback)
                    if len(pushes) == 5:
                        raise registration_error
                    return result

                try:
                    with mock.patch.object(reader.os, "open", side_effect=track_open) as opened:
                        with mock.patch.object(reader.os, "supports_dir_fd",
                                               reader.os.supports_dir_fd | {opened}), \
                                mock.patch.object(reader.os, "close", side_effect=failing_close), \
                                mock.patch.object(reader.ExitStack, "push", new=failing_push):
                            expected = (registration_error if isinstance(cleanup_error, OSError)
                                        else cleanup_error)
                            with self.assertRaises(type(expected)) as raised:
                                self.read()
                    self.assertIs(raised.exception, expected)
                    self.assertEqual(reused, fanout)
                    self.assertEqual(os.read(reused[0], 4), b"safe")
                finally:
                    for fd in reused:
                        actual_close(fd)

    def test_unsupported_descriptor_operations_refuse(self):
        with mock.patch.object(reader.os, "supports_dir_fd", set()), \
                mock.patch.object(reader.os, "open", side_effect=AssertionError("opened")):
            self.refused()

    def test_close_failure_does_not_close_reused_object_descriptor(self):
        actual_open = os.open
        actual_close = os.close
        object_fds = []
        reused = []
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(b"safe")

        def track(path, flags, mode=0o777, *, dir_fd=None):
            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
            if path == self.oid[2:]:
                object_fds.append(fd)
            return fd

        def failing_close(fd):
            if fd in object_fds:
                actual_close(fd)
                reused.append(actual_open(sentinel, os.O_RDONLY))
                raise OSError("close failure")
            return actual_close(fd)

        try:
            with mock.patch.object(reader.os, "open", side_effect=track) as opened:
                with mock.patch.object(reader.os, "supports_dir_fd",
                                       reader.os.supports_dir_fd | {opened}), \
                        mock.patch.object(reader.os, "close", side_effect=failing_close):
                    self.refused()
            self.assertEqual(reused, object_fds)
            self.assertEqual(os.read(reused[0], 4), b"safe")
        finally:
            for fd in reused:
                actual_close(fd)


if __name__ == "__main__":
    unittest.main()
