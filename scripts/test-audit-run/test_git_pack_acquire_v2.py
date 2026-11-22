"""Synthetic explicit-pair acquisition tests for the 16 MiB profile."""

import os
import socket
import subprocess
from types import SimpleNamespace
import unittest
from unittest import mock

import git_pack
import git_pack_acquire as reader
import test_git_pack as fixtures
import test_git_pack_acquire as v1
import test_git_pack_v2 as large


class PackAcquireV2Tests(unittest.TestCase):
    setUp = v1.PackAcquireTests.setUp
    restore = v1.PackAcquireTests.restore
    refused = v1.PackAcquireTests.refused
    test_missing_layouts_no_fallback = v1.PackAcquireTests.test_missing_layouts_no_fallback
    test_symlinks_at_all_components = v1.PackAcquireTests.test_symlinks_at_all_components
    test_metadata_only_change_and_file_replacement_refuse = (
        v1.PackAcquireTests.test_metadata_only_change_and_file_replacement_refuse
    )
    test_registration_failures_unwind_without_double_close = (
        v1.PackAcquireTests.test_registration_failures_unwind_without_double_close
    )

    def acquire(self):
        return reader.acquire_validated_pair_v2(str(self.root), self.pack_id)

    def install(self, pack, index):
        self.pack_id = pack[-20:].hex()
        self.paths = [self.directory / f"pack-{self.pack_id}.{suffix}"
                      for suffix in ("pack", "idx")]
        self.pack, self.index = pack, index
        self.restore()

    def test_large_pairs_v1_refusal_and_single_v2_parse(self):
        oid = fixtures.object_id("blob", b"x").hex()
        for size in (8 * large.MIB + 1, 16 * large.MIB):
            with self.subTest(size=size):
                pack, index = large.pair_of_size(size)
                self.install(pack, index)
                with mock.patch.object(os, "read", side_effect=AssertionError("read")):
                    with self.assertRaises(reader.Refusal):
                        reader.acquire_validated_pair(str(self.root), self.pack_id)
                    with self.assertRaises(reader.Refusal):
                        reader.acquire_pair(str(self.root), self.pack_id)
                with mock.patch.object(git_pack, "_parse_profile",
                                       wraps=git_pack._parse_profile) as parse, \
                        mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                        mock.patch.object(socket, "socket", side_effect=AssertionError("network")), \
                        mock.patch.object(os, "listdir", side_effect=AssertionError("enumeration")), \
                        mock.patch.object(os, "scandir", side_effect=AssertionError("enumeration")):
                    result = self.acquire()
                    self.assertEqual(parse.call_count, 1)
                    self.assertEqual(parse.call_args.args, (pack, index, git_pack._Profile.V2))
                    self.assertEqual(result.read(oid), ("blob", b"x"))
                    self.assertEqual(result.read(oid), ("blob", b"x"))
                    with self.assertRaises(ValueError):
                        result.read("0" * 40)
                    self.assertEqual(parse.call_count, 1)
                self.paths[1].unlink()
                self.refused()
                self.assertEqual(result.read(oid), ("blob", b"x"))

    def test_initial_caps_and_special_files_before_read(self):
        for path, limit in zip(self.paths, (16 * large.MIB, git_pack.INDEX_LIMIT)):
            for kind in ("oversize", "directory", "fifo"):
                with self.subTest(path=path, kind=kind):
                    path.unlink()
                    if kind == "oversize":
                        with path.open("wb") as stream:
                            stream.truncate(limit + 1)
                    elif kind == "directory":
                        path.mkdir()
                    else:
                        os.mkfifo(path)
                    with mock.patch.object(os, "read", side_effect=AssertionError("read")):
                        self.refused()
                    if kind == "directory":
                        path.rmdir()
                    else:
                        path.unlink()
                    self.restore()

    def test_exact_index_cap_is_read_then_fully_validated(self):
        self.paths[1].write_bytes(b"x" * git_pack.INDEX_LIMIT)
        actual_read = os.read
        requests, delivered = [], []

        def track(fd, size):
            requests.append(size)
            data = actual_read(fd, size)
            delivered.append(len(data))
            return data

        with mock.patch.object(os, "read", side_effect=track), \
                mock.patch.object(git_pack, "_parse_profile",
                                  wraps=git_pack._parse_profile) as parse:
            with self.assertRaises(reader.Refusal) as raised:
                self.acquire()
        self.assertEqual(parse.call_count, 1)
        self.assertEqual(str(raised.exception.__cause__), "unsupported index header")
        self.assertIn(git_pack.INDEX_LIMIT + 1, requests)
        self.assertEqual(sum(delivered), len(self.pack) + git_pack.INDEX_LIMIT)

    def test_actual_read_requests_and_cap_plus_one_growth(self):
        pack, index = large.pair_of_size(16 * large.MIB)
        self.install(pack, index)
        actual_open, actual_read, actual_fstat = os.open, os.read, os.fstat
        for target in (0, 1):
            with self.subTest(target=target):
                # Simulate growth after both initial size checks. The index case
                # reads a full-size valid pack first, exercising the pair bound.
                self.restore()
                fds, requests, delivered = {}, [], []

                def track(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    for i, path in enumerate(self.paths):
                        if name == path.name:
                            fds[fd] = i
                    return fd

                def grow(fd, size):
                    already = sum(n for i, n in delivered if i == fds[fd])
                    limit = 16 * large.MIB if fds[fd] == 0 else git_pack.INDEX_LIMIT
                    self.assertLessEqual(size, limit + 1 - already)
                    requests.append((fds[fd], size))
                    if fds[fd] == target and not any(i == target for i, _ in delivered):
                        with self.paths[target].open("wb") as stream:
                            stream.truncate((16 * large.MIB if target == 0
                                             else git_pack.INDEX_LIMIT) + 1)
                    data = actual_read(fd, size)
                    delivered.append((fds[fd], len(data)))
                    return data

                def size_at_cap(fd):
                    info = actual_fstat(fd)
                    if fds.get(fd) == target:
                        info = SimpleNamespace(**{
                            name: getattr(info, name) for name in
                            ("st_dev", "st_ino", "st_mode", "st_nlink", "st_uid",
                             "st_gid", "st_size", "st_mtime_ns", "st_ctime_ns")
                        })
                        info.st_size = 16 * large.MIB if target == 0 else git_pack.INDEX_LIMIT
                    return info

                with mock.patch.object(os, "open", side_effect=track) as opened, \
                        mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                        mock.patch.object(os, "read", side_effect=grow), \
                        mock.patch.object(os, "fstat", side_effect=size_at_cap):
                    self.refused()
                self.assertEqual(requests[0], (0, 16 * large.MIB + 1))
                if target == 1:
                    self.assertIn((1, git_pack.INDEX_LIMIT + 1), requests)
                    self.assertEqual(sum(n for _, n in delivered),
                                     16 * large.MIB + git_pack.INDEX_LIMIT + 1)
                else:
                    self.assertEqual(sum(n for _, n in delivered), 16 * large.MIB + 1)
                self.assertLessEqual(sum(n for _, n in delivered), 17_825_794)

    def test_short_reads_and_both_metadata_checked_after_pair_read(self):
        actual_read = os.read
        sizes = []

        def short_read(fd, size):
            sizes.append(size)
            return actual_read(fd, min(size, 3))

        with mock.patch.object(os, "read", side_effect=short_read):
            self.assertEqual(self.acquire().read(fixtures.BASE_ID)[0], "blob")
        self.assertGreater(len(sizes), 2)
        calls = []

        def change_pack(fd, size):
            calls.append(fd)
            data = actual_read(fd, size)
            if fd != calls[0]:
                self.paths[0].write_bytes(self.pack + b"x")
            return data

        with mock.patch.object(os, "read", side_effect=change_pack):
            self.refused()

    def test_invalid_identity_before_open(self):
        class String(str):
            pass

        with mock.patch.object(os, "open", side_effect=AssertionError("opened")):
            for pack_id in (String(self.pack_id), self.pack_id.upper(), "../" + self.pack_id,
                            "0" * 39, b"0" * 40, None):
                with self.subTest(pack_id=pack_id), self.assertRaises(reader.Refusal):
                    reader.acquire_validated_pair_v2(str(self.root), pack_id)
            for root in (self.root, String(str(self.root)), "relative", str(self.root) + "/.."):
                with self.subTest(root=root), self.assertRaises(reader.Refusal):
                    reader.acquire_validated_pair_v2(root, self.pack_id)

    def test_identity_and_unrequested_corruption(self):
        a = fixtures.object_id("blob", b"a")
        b = fixtures.object_id("blob", b"b")
        for other in (fixtures.header(3, 1) + b"bad", fixtures.plain(3, b"b")):
            bad_name = b if other.endswith(b"bad") else b[:-1] + bytes([b[-1] ^ 1])
            pack, index = fixtures.fixture([(a, fixtures.plain(3, b"a")), (bad_name, other)])
            self.install(pack, index)
            with self.assertRaises(reader.Refusal) as raised:
                self.acquire()
            self.assertIsInstance(raised.exception.__cause__, ValueError)
        pack, index = fixtures.fixture([(a, fixtures.plain(3, b"a"))])
        self.install(pack, index)
        self.assertEqual(self.acquire().read(a.hex()), ("blob", b"a"))
        wrong_id = "0" * 40
        for suffix, data in (("pack", pack), ("idx", index)):
            (self.directory / f"pack-{wrong_id}.{suffix}").write_bytes(data)
        with self.assertRaisesRegex(reader.Refusal, "filename identity mismatch"):
            reader.acquire_validated_pair_v2(str(self.root), wrong_id)
        self.paths[1].write_bytes(index[:-1] + bytes([index[-1] ^ 1]))
        self.refused()

    def test_cleanup_io_parse_and_close_failures_without_retry(self):
        actual_open, actual_close, actual_fstat = os.open, os.close, os.fstat
        for stage in ("open-index", "fstat", "read", "parse", "close"):
            for error_type in (OSError, KeyboardInterrupt, SystemExit):
                with self.subTest(stage=stage, error=error_type):
                    opened_fds, file_fds, live = [], [], set()
                    error = error_type("fault")

                    def track(name, flags, mode=0o777, *, dir_fd=None):
                        if stage == "open-index" and name == self.paths[1].name:
                            raise error
                        fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                        opened_fds.append(fd)
                        self.assertNotIn(fd, live)
                        live.add(fd)
                        if name in [path.name for path in self.paths]:
                            file_fds.append(fd)
                        return fd

                    def fstat(fd):
                        if stage == "fstat" and fd in file_fds:
                            raise error
                        return actual_fstat(fd)

                    def close(fd):
                        self.assertIn(fd, live)
                        live.remove(fd)
                        actual_close(fd)
                        if stage == "close" and file_fds and fd == file_fds[-1]:
                            raise error

                    with mock.patch.object(os, "open", side_effect=track) as opened, \
                            mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                            mock.patch.object(os, "fstat", side_effect=fstat), \
                            mock.patch.object(os, "close", side_effect=close), \
                            reader.ExitStack() as patches:
                        if stage == "read":
                            patches.enter_context(mock.patch.object(os, "read", side_effect=error))
                        if stage == "parse":
                            patches.enter_context(mock.patch.object(git_pack, "_parse_profile",
                                                                    side_effect=error))
                        expected = reader.Refusal if error_type is OSError else error_type
                        with self.assertRaises(expected):
                            self.acquire()
                    self.assertEqual(live, set())
                    for fd in opened_fds:
                        with self.assertRaises(OSError):
                            actual_fstat(fd)


if __name__ == "__main__":
    unittest.main()
