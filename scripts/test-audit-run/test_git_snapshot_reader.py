"""Synthetic tests for the opt-in invocation/snapshot reader."""

import copy
import errno
import os
from pathlib import Path
import pickle
import socket
import subprocess
import tempfile
import unittest
from unittest import mock
import zlib

import checkout_head
import git_loose
import git_loose_acquire
import git_pack
import git_pack_acquire
import git_snapshot_reader as reader
import test_git_loose_acquire as loose_fixtures
import test_git_pack as fixtures


class SnapshotReaderTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="snapshot-reader-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.objects = self.root / ".git" / "objects"
        self.directory = self.objects / "pack"
        self.directory.mkdir(parents=True)
        self.pack = fixtures.decode(fixtures.REF_PACK)
        self.index = zlib.decompress(fixtures.decode(fixtures.REF_INDEX))
        self.pack_id = self.pack[-20:].hex()
        self.pack_path = self.directory / f"pack-{self.pack_id}.pack"
        self.index_path = self.directory / f"pack-{self.pack_id}.idx"
        self.pack_path.write_bytes(self.pack)
        self.index_path.write_bytes(self.index)
        self.oid, self.compressed = loose_fixtures.fixture(b"blob", b"loose content")
        self.loose_path = self.objects / self.oid[:2] / self.oid[2:]
        self.loose_path.parent.mkdir(exist_ok=True)
        self.loose_path.write_bytes(self.compressed)

    def invocation(self):
        return reader.Invocation(str(self.root), self.pack_id)

    def test_loose_first_pair_cache_and_fresh_next_snapshot(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")), \
                mock.patch.object(os, "listdir", side_effect=AssertionError("enumeration")), \
                mock.patch.object(os, "scandir", side_effect=AssertionError("enumeration")), \
                mock.patch.object(git_pack, "_parse", wraps=git_pack._parse) as parse, \
                mock.patch.object(git_loose_acquire, "read_object",
                                  wraps=git_loose_acquire.read_object) as loose:
            invocation = self.invocation()
            first = invocation.snapshot()
            self.assertEqual(first(self.oid), ("blob", b"loose content"))
            self.assertEqual(parse.call_count, 0)
            base = first(fixtures.BASE_ID)
            first(fixtures.TARGET_ID)
            self.assertEqual(first(fixtures.BASE_ID), base)
            self.assertEqual(parse.call_count, 1)
            self.assertEqual(loose.call_count, 4)
            # A newly present loose object wins over a cached pack lookup.
            packed_loose = self.objects / fixtures.BASE_ID[:2] / fixtures.BASE_ID[2:]
            packed_loose.parent.mkdir(exist_ok=True)
            packed_loose.write_bytes(fixtures.decode(fixtures.LOOSE))
            self.assertEqual(first(fixtures.BASE_ID), base)
            self.assertEqual(parse.call_count, 1)
            packed_loose.unlink()
            second = invocation.snapshot()
            self.assertEqual(second(fixtures.BASE_ID), base)
            self.assertEqual(parse.call_count, 2)
            self.assertEqual(loose.call_count, 6)

    def test_pack_mutation_is_observed_only_on_new_snapshot(self):
        invocation = self.invocation()
        first = invocation.snapshot()
        original = first(fixtures.BASE_ID)
        self.index_path.write_bytes(b"corrupt")
        self.assertEqual(first(fixtures.TARGET_ID)[0], "blob")
        second = invocation.snapshot()
        with self.assertRaises(KeyError):
            second(fixtures.BASE_ID)
        self.index_path.write_bytes(self.index)
        with mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                               side_effect=AssertionError("retry")):
            with self.assertRaises(KeyError):
                second(fixtures.BASE_ID)
        self.assertEqual(original[0], "blob")

    def test_corruption_and_cleanup_error_do_not_fallback(self):
        self.loose_path.write_bytes(b"corrupt")
        with mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                               side_effect=AssertionError("fallback")):
            snapshot = self.invocation().snapshot()
            with self.assertRaises(KeyError):
                snapshot(self.oid)
            self.loose_path.unlink()
            with self.assertRaises(KeyError):
                snapshot(self.oid)

            actual_close = os.close
            actual_open = os.open
            fanout = []

            def track(name, flags, mode=0o777, *, dir_fd=None):
                fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                if name == self.oid[:2]:
                    fanout.append(fd)
                return fd

            def fail_close(fd):
                actual_close(fd)
                if fd in fanout:
                    raise OSError(errno.ENOENT, "close")

            with mock.patch.object(os, "open", side_effect=track) as opened, \
                    mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                    mock.patch.object(os, "close", side_effect=fail_close):
                with self.assertRaises(KeyError):
                    self.invocation().snapshot()(self.oid)
            self.assertTrue(fanout)

    def test_loose_corruption_refuses_even_after_pair_was_cached(self):
        snapshot = self.invocation().snapshot()
        snapshot(fixtures.BASE_ID)
        path = self.objects / fixtures.TARGET_ID[:2] / fixtures.TARGET_ID[2:]
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(b"corrupt")
        with self.assertRaises(KeyError):
            snapshot(fixtures.TARGET_ID)
        path.unlink()
        with self.assertRaises(KeyError):
            snapshot(fixtures.TARGET_ID)

    def test_pair_miss_and_acquisition_failure_are_terminal(self):
        other_pack = fixtures.decode(fixtures.OFS_PACK)
        other_index = zlib.decompress(fixtures.decode(fixtures.OFS_INDEX))
        other_id = other_pack[-20:].hex()
        (self.directory / f"pack-{other_id}.pack").write_bytes(other_pack)
        (self.directory / f"pack-{other_id}.idx").write_bytes(other_index)
        for fault in ("miss", "missing pair"):
            with self.subTest(fault=fault):
                if fault == "missing pair":
                    self.index_path.unlink()
                invocation = self.invocation()
                snapshot = invocation.snapshot()
                with mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                                       wraps=git_pack_acquire.acquire_validated_pair) as acquire:
                    with self.assertRaises(KeyError) as raised:
                        snapshot("0" * 40)
                    self.assertNotIsInstance(raised.exception.__cause__,
                                             git_loose_acquire.LooseAbsent)
                    self.index_path.write_bytes(self.index)
                    with self.assertRaises(KeyError):
                        snapshot(fixtures.BASE_ID)
                    with self.assertRaises(KeyError):
                        invocation.snapshot()
                    self.assertEqual(acquire.call_count, 1)

    def test_shared_call_limit_and_snapshot_limit(self):
        with mock.patch.object(git_loose_acquire, "read_object",
                               return_value=("blob", b"ok")) as loose:
            invocation = self.invocation()
            first = invocation.snapshot()
            for _ in range(32):
                first(self.oid)
            second = invocation.snapshot()
            for _ in range(32):
                second(self.oid)
            with self.assertRaises(KeyError):
                second(self.oid)
            with self.assertRaises(KeyError):
                second(self.oid)
            self.assertEqual(loose.call_count, 64)
        invocation = self.invocation()
        invocation.snapshot()
        second = invocation.snapshot()
        with self.assertRaises(KeyError):
            invocation.snapshot()
        with self.assertRaises(KeyError):
            second(self.oid)

    def test_reservations_include_detection_bytes_before_attempts(self):
        loose_attempt = git_loose.COMPRESSED_LIMIT + 1
        pair_attempt = git_pack.PACK_LIMIT + git_pack.INDEX_LIMIT + 2
        self.assertEqual(reader.LOOSE_IO_LIMIT, reader.OBJECT_CALL_LIMIT * loose_attempt)
        self.assertEqual(reader.PAIR_IO_LIMIT, reader.SNAPSHOT_LIMIT * pair_attempt)
        with mock.patch.object(reader, "LOOSE_IO_LIMIT", loose_attempt * 2 - 1), \
                mock.patch.object(git_loose_acquire, "read_object",
                                  return_value=("blob", b"ok")) as loose:
            invocation = self.invocation()
            invocation.snapshot()(self.oid)
            second = invocation.snapshot()
            with self.assertRaises(KeyError):
                second(self.oid)
            self.assertEqual(loose.call_count, 1)
        with mock.patch.object(reader, "PAIR_IO_LIMIT", pair_attempt * 2 - 1), \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                                  wraps=git_pack_acquire.acquire_validated_pair) as acquire:
            invocation = self.invocation()
            invocation.snapshot()(fixtures.BASE_ID)
            with self.assertRaises(KeyError):
                invocation.snapshot()(fixtures.BASE_ID)
            self.assertEqual(acquire.call_count, 1)

    def test_cap_plus_one_reads_refuse_and_do_not_retry(self):
        actual_read = os.read
        actual_open = os.open
        for target, limit in ((self.oid[2:], git_loose.COMPRESSED_LIMIT),
                              (self.pack_path.name, git_pack.PACK_LIMIT),
                              (self.index_path.name, git_pack.INDEX_LIMIT)):
            with self.subTest(target=target):
                descriptors = []
                requests = []

                def track(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    if name == target:
                        descriptors.append(fd)
                    return fd

                def grow(fd, size):
                    if fd in descriptors:
                        requests.append(size)
                        return b"x" * size
                    return actual_read(fd, size)

                snapshot = self.invocation().snapshot()
                oid = self.oid if target == self.oid[2:] else fixtures.BASE_ID
                with mock.patch.object(os, "open", side_effect=track) as opened, \
                        mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                        mock.patch.object(os, "read", side_effect=grow):
                    with self.assertRaises(KeyError):
                        snapshot(oid)
                    with self.assertRaises(KeyError):
                        snapshot(oid)
                self.assertEqual(requests, [limit + 1])

    def test_failed_attempts_and_interruptions_are_terminal(self):
        for error in (OSError("I/O"), KeyboardInterrupt(), SystemExit()):
            with self.subTest(error=type(error)), \
                    mock.patch.object(git_loose_acquire, "read_object",
                                      side_effect=error) as loose:
                invocation = self.invocation()
                snapshot = invocation.snapshot()
                expected = KeyError if isinstance(error, OSError) else type(error)
                with self.assertRaises(expected):
                    snapshot(self.oid)
                with self.assertRaises(KeyError):
                    snapshot(self.oid)
                with self.assertRaises(KeyError):
                    invocation.snapshot()
                self.assertEqual(loose.call_count, 1)
        with mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                               side_effect=checkout_head.Refusal("I/O")) as acquire:
            snapshot = self.invocation().snapshot()
            with self.assertRaises(KeyError):
                snapshot(fixtures.BASE_ID)
            with self.assertRaises(KeyError):
                snapshot(fixtures.BASE_ID)
            self.assertEqual(acquire.call_count, 1)

    def test_reentrant_refusal_cannot_be_hidden_by_outer_read(self):
        invocation = self.invocation()
        snapshot = invocation.snapshot()

        def reenter(*args):
            with self.assertRaises(KeyError):
                snapshot(self.oid)
            return ("blob", b"ok")

        with mock.patch.object(git_loose_acquire, "read_object", side_effect=reenter):
            with self.assertRaises(KeyError):
                snapshot(self.oid)

    def test_invalid_inputs_and_immutable_no_reset_or_reuse(self):
        for root, pack_id in ((self.root, self.pack_id), ("relative", self.pack_id),
                              (str(self.root), self.pack_id.upper()),
                              (str(self.root), None)):
            with self.subTest(root=root, pack_id=pack_id), \
                    mock.patch.object(os, "open", side_effect=AssertionError("I/O")), \
                    self.assertRaises(checkout_head.Refusal):
                reader.Invocation(root, pack_id)
        for oid in (None, b"a" * 40, "A" * 40, "bad"):
            with self.subTest(oid=oid), \
                    mock.patch.object(git_loose_acquire, "read_object",
                                      side_effect=AssertionError("I/O")):
                snapshot = self.invocation().snapshot()
                with self.assertRaises(KeyError):
                    snapshot(oid)
                with self.assertRaises(KeyError):
                    snapshot(self.oid)
        invocation = self.invocation()
        first = invocation.snapshot()
        second = invocation.snapshot()
        for operation in (lambda: copy.copy(invocation),
                          lambda: copy.deepcopy(invocation),
                          lambda: pickle.dumps(invocation),
                          lambda: invocation.__init__(str(self.root), self.pack_id)):
            with self.assertRaises(TypeError):
                operation()
        with self.assertRaises(AttributeError):
            invocation._Invocation__next_snapshot = lambda: first
        with self.assertRaises(AttributeError):
            del invocation._Invocation__next_snapshot
        with self.assertRaises(KeyError):
            first(self.oid)
        with self.assertRaises(KeyError):
            second(self.oid)


if __name__ == "__main__":
    unittest.main()
