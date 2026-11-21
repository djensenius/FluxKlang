"""Synthetic filesystem acquisition using static Git-produced pack fixtures."""

import os
from pathlib import Path
import socket
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zlib

import git_pack
import git_pack_acquire as reader
import test_git_pack as fixtures


class PackAcquireTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pack-acquire-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.directory = self.root / ".git" / "objects" / "pack"
        self.directory.mkdir(parents=True)
        self.pack = fixtures.decode(fixtures.REF_PACK)
        self.index = zlib.decompress(fixtures.decode(fixtures.REF_INDEX))
        self.pack_id = self.pack[-20:].hex()
        self.paths = [self.directory / f"pack-{self.pack_id}.{suffix}"
                      for suffix in ("pack", "idx")]
        self.restore()

    def restore(self):
        for path, data in zip(self.paths, (self.pack, self.index)):
            path.write_bytes(data)

    def acquire(self):
        return reader.acquire_pair(str(self.root), self.pack_id)

    def refused(self):
        with self.assertRaises(reader.Refusal):
            self.acquire()

    def test_static_pairs_fresh_reads_and_separate_lookup_no_external_calls(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")), \
                mock.patch.object(os, "listdir", side_effect=AssertionError("enumeration")), \
                mock.patch.object(os, "scandir", side_effect=AssertionError("enumeration")):
            for pack, index in ((fixtures.REF_PACK, fixtures.REF_INDEX),
                                (fixtures.OFS_PACK, fixtures.OFS_INDEX)):
                pack = fixtures.decode(pack)
                index = zlib.decompress(fixtures.decode(index))
                pack_id = pack[-20:].hex()
                for suffix, data in (("pack", pack), ("idx", index)):
                    (self.directory / f"pack-{pack_id}.{suffix}").write_bytes(data)
                pair = reader.acquire_pair(str(self.root), pack_id)
                self.assertEqual(pair, (pack, index))
                self.assertEqual(git_pack.read_object(*pair, fixtures.BASE_ID)[0], "blob")
            for path in self.paths:
                path.write_bytes(b"corrupt")
                self.refused()
                self.restore()
                self.assertEqual(self.acquire(), (self.pack, self.index))
                path.unlink()
                self.refused()
                self.restore()

    def test_invalid_inputs_before_open(self):
        class String(str):
            pass

        roots = (self.root, String(str(self.root)), "", "/", "relative",
                 str(self.root) + "/", str(self.root) + "//x",
                 str(self.root) + "/../x", str(self.root) + "/./x",
                 "/x\0y", "/\ud800", "/" + "x" * (reader.checkout_head.PATH_BYTES + 1))
        ids = (String(self.pack_id), self.pack_id.upper(), "g" * 40, "é" * 40,
               self.pack_id[:-1], self.pack_id + "0", "../" + self.pack_id,
               b"a" * 40, None, 1)
        with mock.patch.object(os, "open", side_effect=AssertionError("opened")):
            for root in roots:
                with self.subTest(root=root), self.assertRaises(reader.Refusal):
                    reader.acquire_pair(root, self.pack_id)
            for pack_id in ids:
                with self.subTest(pack_id=pack_id), self.assertRaises(reader.Refusal):
                    reader.acquire_pair(str(self.root), pack_id)

    def test_missing_layouts_no_fallback(self):
        (self.root / ".git" / "objects" / "info").mkdir()
        (self.root / ".git" / "objects" / "info" / "alternates").write_text("/elsewhere\n")
        for path in (*self.paths, self.directory, self.directory.parent,
                     self.root / ".git"):
            with self.subTest(path=path):
                moved = path.with_name(path.name + "-real")
                path.rename(moved)
                try:
                    self.refused()
                    if path == self.root / ".git":
                        path.write_text("gitdir: /elsewhere\n")
                        self.refused()
                        path.unlink()
                finally:
                    moved.rename(path)

    def test_symlinks_at_all_components(self):
        for path in (self.root, self.root / ".git", self.directory.parent,
                     self.directory, *self.paths):
            with self.subTest(path=path):
                moved = path.with_name(path.name + "-real")
                path.rename(moved)
                path.symlink_to(moved, target_is_directory=moved.is_dir())
                try:
                    self.refused()
                finally:
                    path.unlink()
                    moved.rename(path)
        nested = self.root / "nested"
        nested.mkdir()
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(reader.Refusal):
            reader.acquire_pair(str(link / "nested"), self.pack_id)

    def test_nonregular_and_oversized_files(self):
        for path, limit in zip(self.paths, (git_pack.PACK_LIMIT, git_pack.INDEX_LIMIT)):
            with self.subTest(path=path):
                path.unlink()
                path.mkdir()
                self.refused()
                path.rmdir()
                os.mkfifo(path)
                self.refused()
                path.unlink()
                with path.open("wb") as stream:
                    stream.truncate(limit + 1)
                with mock.patch.object(os, "read", side_effect=AssertionError("read")):
                    self.refused()
                self.restore()

    def test_inclusive_read_bounds_and_unavailable_acquisition(self):
        for limit in (git_pack.PACK_LIMIT, git_pack.INDEX_LIMIT):
            for length in (limit, limit + 1):
                path = self.root / "bounded"
                path.write_bytes(b"x" * length)
                fd = os.open(path, os.O_RDONLY)
                try:
                    if length == limit:
                        self.assertEqual(reader._read(fd, limit), b"x" * limit)
                    else:
                        with self.assertRaises(reader.Refusal):
                            reader._read(fd, limit)
                finally:
                    os.close(fd)
        with mock.patch.object(os, "supports_dir_fd", set()):
            self.refused()
        for flag in ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK"):
            with mock.patch.object(os, flag):
                delattr(os, flag)
                self.refused()

    def test_bad_identity_checksums_and_unrequested_entry(self):
        for pack, index in (
            (b"", self.index), (self.pack[:-1], self.index),
            (self.pack[:-21] + b"x" + self.pack[-20:], self.index),
            (self.pack, self.index[:-1]),
            (self.pack, self.index[:-21] + b"x" + self.index[-20:]),
            (self.pack, zlib.decompress(fixtures.decode(fixtures.OFS_INDEX))),
            (fixtures.decode(fixtures.OFS_PACK),
             zlib.decompress(fixtures.decode(fixtures.OFS_INDEX))),
            (self.pack, fixtures.rehash(self.index[:1032] + b"\0" * 20
                                       + self.index[1052:])),
        ):
            with self.subTest(pack=pack[-20:], index=index[-20:]):
                self.paths[0].write_bytes(pack)
                self.paths[1].write_bytes(index)
                self.refused()

    def test_short_reads_and_both_files_checked_after_pair_read(self):
        actual_read = os.read
        sizes = []

        def short_read(fd, size):
            sizes.append(size)
            return actual_read(fd, min(size, 3))

        with mock.patch.object(os, "read", side_effect=short_read):
            self.assertEqual(self.acquire(), (self.pack, self.index))
        self.assertGreater(len(sizes), 2)
        calls = []

        def change_pack_during_index(fd, size):
            calls.append(fd)
            result = actual_read(fd, size)
            if fd != calls[0]:
                self.paths[0].write_bytes(self.pack + b"x")
            return result

        with mock.patch.object(os, "read", side_effect=change_pack_during_index):
            self.refused()

    def test_read_caps_inclusive_and_growth_detection(self):
        actual_read = os.read
        actual_fstat = os.fstat
        for path, limit in zip(self.paths, (git_pack.PACK_LIMIT, git_pack.INDEX_LIMIT)):
            for length in (limit, limit + 100):
                sizes = []
                target = []
                actual_open = os.open

                def track(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    if name == path.name:
                        target.append(fd)
                    return fd

                def growing_read(fd, size):
                    if fd in target:
                        sizes.append(size)
                        if len(sizes) == 1:
                            path.write_bytes(b"x" * length)
                    return actual_read(fd, size)

                def stable_metadata(fd):
                    info = actual_fstat(fd)
                    if fd in target:
                        info = SimpleNamespace(**{
                            name: getattr(info, name) for name in
                            ("st_dev", "st_ino", "st_mode", "st_nlink", "st_uid",
                             "st_gid", "st_size", "st_mtime_ns", "st_ctime_ns")
                        })
                        info.st_size = limit
                    return info

                with self.subTest(path=path, length=length), \
                        mock.patch.object(os, "open", side_effect=track) as opened:
                    with mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                            mock.patch.object(os, "read", side_effect=growing_read), \
                            mock.patch.object(os, "fstat", side_effect=stable_metadata):
                        self.refused()
                self.assertTrue(sizes, (path, length))
                self.assertEqual(sizes[0], limit + 1)
                self.assertLessEqual(sum(min(size, length) for size in sizes), limit + 1)
                self.restore()

    def test_metadata_only_change_and_file_replacement_refuse(self):
        actual_read = os.read
        for path in self.paths:
            for replacement in (False, True):
                changed = []

                def change(fd, size):
                    result = actual_read(fd, size)
                    if not changed:
                        changed.append(True)
                        if replacement:
                            new = path.with_name("replacement")
                            new.write_bytes(path.read_bytes())
                            new.replace(path)
                        else:
                            info = path.stat()
                            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
                    return result

                with self.subTest(path=path, replacement=replacement), \
                        mock.patch.object(os, "read", side_effect=change):
                    self.refused()
                self.restore()

    def test_directory_replacement_is_not_path_custody(self):
        actual_read = os.read
        moved = self.directory.with_name("held-pack")
        changed = []

        def replace_directory(fd, size):
            result = actual_read(fd, size)
            if not changed:
                changed.append(True)
                self.directory.rename(moved)
                self.directory.mkdir()
            return result

        with mock.patch.object(os, "read", side_effect=replace_directory):
            self.assertEqual(self.acquire(), (self.pack, self.index))
        self.refused()

    def test_cleanup_on_faults_and_interruptions(self):
        actual_open = os.open
        actual_fstat = os.fstat
        for stage in ("success", "open-index", "fstat", "read", "parse", "close"):
            for error_type in (OSError, KeyboardInterrupt, SystemExit):
                opened_fds = []
                file_fds = []
                error = error_type("fault")

                def track(name, flags, mode=0o777, *, dir_fd=None):
                    if stage == "open-index" and name == self.paths[1].name:
                        raise error
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    opened_fds.append(fd)
                    if name in [path.name for path in self.paths]:
                        file_fds.append(fd)
                    return fd

                def failing_fstat(fd):
                    if fd in file_fds:
                        raise error
                    return actual_fstat(fd)

                actual_close = os.close

                def failing_close(fd):
                    actual_close(fd)
                    if file_fds and fd == file_fds[-1]:
                        raise error

                with self.subTest(stage=stage, error=error_type), \
                        mock.patch.object(os, "open", side_effect=track) as opened:
                    with mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                            reader.ExitStack() as patches:
                        if stage == "fstat":
                            patches.enter_context(mock.patch.object(os, "fstat", side_effect=failing_fstat))
                        if stage == "read":
                            patches.enter_context(mock.patch.object(os, "read", side_effect=error))
                        if stage == "parse":
                            patches.enter_context(mock.patch.object(git_pack, "_parse", side_effect=error))
                        if stage == "close":
                            patches.enter_context(mock.patch.object(os, "close", side_effect=failing_close))
                        if stage == "success":
                            self.acquire()
                        else:
                            expected = reader.Refusal if error_type is OSError else error_type
                            with self.assertRaises(expected):
                                self.acquire()
                for fd in opened_fds:
                    with self.assertRaises(OSError):
                        actual_fstat(fd)

    def test_registration_failures_unwind_without_double_close(self):
        actual_open = os.open
        actual_close = os.close
        actual_push = reader.ExitStack.push
        for stage in range(1, 7):
            for after_push in (False, True):
                for error_type in (OSError, RuntimeError, KeyboardInterrupt, SystemExit):
                    live = set()
                    double_closes = []
                    pushes = []
                    error = error_type("registration failure")

                    def track(name, flags, mode=0o777, *, dir_fd=None):
                        fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                        live.add(fd)
                        return fd

                    def close(fd):
                        if fd not in live:
                            double_closes.append(fd)
                            return
                        live.remove(fd)
                        actual_close(fd)

                    def push(stack, owner):
                        pushes.append(owner)
                        if len(pushes) == stage:
                            self.assertEqual(len(live), stage - 1)
                            if after_push:
                                actual_push(stack, owner)
                            raise error
                        return actual_push(stack, owner)

                    with self.subTest(stage=stage, after_push=after_push, error=error_type), \
                            mock.patch.object(os, "open", side_effect=track) as opened:
                        with mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                                mock.patch.object(os, "close", side_effect=close), \
                                mock.patch.object(reader.ExitStack, "push", new=push):
                            expected = reader.Refusal if error_type is OSError else error_type
                            with self.assertRaises(expected):
                                self.acquire()
                    self.assertEqual(len(pushes), stage)
                    self.assertEqual(live, set())
                    self.assertEqual(double_closes, [])
