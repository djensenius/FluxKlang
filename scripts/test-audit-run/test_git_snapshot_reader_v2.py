"""Synthetic tests for the opt-in 16 MiB snapshot adapter."""

import copy
import os
import pickle
import socket
import subprocess
import unittest
from unittest import mock

import checkout_head
import git_loose
import git_loose_acquire
import git_pack
import git_pack_acquire
import git_snapshot_reader as reader
import test_git_loose_acquire as loose_fixtures
import test_git_pack as fixtures
import test_git_pack_v2 as large
import test_git_snapshot_reader as v1


class SnapshotReaderV2Tests(unittest.TestCase):
    setUp = v1.SnapshotReaderTests.setUp

    def invocation(self):
        return reader.InvocationV2(str(self.root), self.pack_id)

    def test_real_large_pair_fresh_snapshots_and_v1_refusal(self):
        pack, index = large.pair_of_size(16 * large.MIB)
        self.assertEqual(len(pack), 16 * large.MIB)
        self.pack_id = pack[-20:].hex()
        (self.directory / f"pack-{self.pack_id}.pack").write_bytes(pack)
        (self.directory / f"pack-{self.pack_id}.idx").write_bytes(index)
        oid = fixtures.object_id("blob", b"x").hex()
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")), \
                mock.patch.object(os, "listdir", side_effect=AssertionError("enumeration")), \
                mock.patch.object(os, "scandir", side_effect=AssertionError("enumeration")), \
                mock.patch.object(git_pack, "_parse_profile",
                                  wraps=git_pack._parse_profile) as parse, \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                  wraps=git_pack_acquire.acquire_validated_pair_v2) as acquire, \
                mock.patch.object(git_loose_acquire, "read_object",
                                  wraps=git_loose_acquire.read_object) as loose:
            with self.assertRaises(KeyError):
                reader.Invocation(str(self.root), self.pack_id).snapshot()(oid)
            self.assertEqual(parse.call_count, 0)
            self.assertEqual(acquire.call_count, 0)
            invocation = self.invocation()
            first = invocation.snapshot()
            self.assertEqual(first(self.oid), ("blob", b"loose content"))
            self.assertEqual(parse.call_count, 0)
            self.assertEqual(first(oid), ("blob", b"x"))
            self.assertEqual(first(oid), ("blob", b"x"))
            self.assertEqual(parse.call_count, 1)
            # A fresh loose lookup still wins even after the pair is cached.
            packed_loose = self.objects / oid[:2] / oid[2:]
            packed_loose.parent.mkdir(exist_ok=True)
            _, compressed = loose_fixtures.fixture(b"blob", b"x")
            packed_loose.write_bytes(compressed)
            self.assertEqual(first(oid), ("blob", b"x"))
            packed_loose.unlink()
            second = invocation.snapshot()
            self.assertEqual(second(oid), ("blob", b"x"))
            self.assertEqual(parse.call_count, 2)
            self.assertTrue(all(call.args[2] is git_pack._Profile.V2
                                for call in parse.call_args_list))
            self.assertEqual(acquire.call_args_list,
                             [mock.call(str(self.root), self.pack_id)] * 2)
            self.assertEqual(loose.call_count, 6)

    def test_reservations_and_limits(self):
        loose_attempt = git_loose.COMPRESSED_LIMIT + 1
        pair_attempt = 16 * large.MIB + git_pack.INDEX_LIMIT + 2
        self.assertEqual(reader.LOOSE_IO_LIMIT, 17_301_568)
        self.assertEqual(reader.V2_PAIR_IO_LIMIT, 35_651_588)
        self.assertEqual(reader.LOOSE_IO_LIMIT + reader.V2_PAIR_IO_LIMIT, 52_953_156)
        self.assertEqual(reader.LOOSE_IO_LIMIT, 64 * loose_attempt)
        self.assertEqual(reader.V2_PAIR_IO_LIMIT, 2 * pair_attempt)
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
                invocation.snapshot()
            self.assertEqual(loose.call_count, 64)
        with mock.patch.object(reader, "LOOSE_IO_LIMIT", 2 * loose_attempt - 1), \
                mock.patch.object(git_loose_acquire, "read_object",
                                  return_value=("blob", b"ok")) as loose:
            invocation = self.invocation()
            invocation.snapshot()(self.oid)
            with self.assertRaises(KeyError):
                invocation.snapshot()(self.oid)
            self.assertEqual(loose.call_count, 1)
        with mock.patch.object(reader, "V2_PAIR_IO_LIMIT", 2 * pair_attempt - 1), \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                  wraps=git_pack_acquire.acquire_validated_pair_v2) as acquire:
            invocation = self.invocation()
            invocation.snapshot()(fixtures.BASE_ID)
            with self.assertRaises(KeyError):
                invocation.snapshot()(fixtures.BASE_ID)
            self.assertEqual(acquire.call_count, 1)
        with self.assertRaises(TypeError):
            reader.InvocationV2(str(self.root), self.pack_id, 3)

    def test_cap_plus_one_reads_are_terminal(self):
        actual_open, actual_read = os.open, os.read
        for target, limit in ((self.oid[2:], git_loose.COMPRESSED_LIMIT),
                              (self.pack_path.name, 16 * large.MIB),
                              (self.index_path.name, git_pack.INDEX_LIMIT)):
            with self.subTest(target=target):
                descriptors, requests = [], []

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

    def test_invalid_inputs_refuse_before_io(self):
        for root, pack_id in ((self.root, self.pack_id), ("relative", self.pack_id),
                              (str(self.root), self.pack_id.upper()), (str(self.root), None)):
            with self.subTest(root=root, pack_id=pack_id), \
                    mock.patch.object(os, "open", side_effect=AssertionError("I/O")), \
                    self.assertRaises(checkout_head.Refusal):
                reader.InvocationV2(root, pack_id)
        for oid in (None, b"a" * 40, "A" * 40, "bad"):
            with self.subTest(oid=oid), \
                    mock.patch.object(git_loose_acquire, "read_object",
                                      side_effect=AssertionError("I/O")):
                snapshot = self.invocation().snapshot()
                with self.assertRaises(KeyError):
                    snapshot(oid)
                with self.assertRaises(KeyError):
                    snapshot(self.oid)

    def test_failed_attempts_and_interruptions_are_terminal(self):
        for stage in ("loose", "pair"):
            for error in (OSError("I/O"), checkout_head.Refusal("refused"),
                          KeyboardInterrupt(), SystemExit()):
                target = (git_loose_acquire if stage == "loose" else git_pack_acquire)
                name = ("read_object" if stage == "loose"
                        else "acquire_validated_pair_v2")
                with self.subTest(stage=stage, error=type(error)), \
                        mock.patch.object(target, name, side_effect=error) as attempt:
                    invocation = self.invocation()
                    snapshot = invocation.snapshot()
                    expected = KeyError if isinstance(error, (OSError, ValueError)) else type(error)
                    with self.assertRaises(expected):
                        snapshot(fixtures.BASE_ID)
                    with self.assertRaises(KeyError):
                        snapshot(fixtures.BASE_ID)
                    with self.assertRaises(KeyError):
                        invocation.snapshot()
                    self.assertEqual(attempt.call_count, 1)

    def test_nonabsence_and_cached_pair_corruption_never_fallback(self):
        for cached in (False, True):
            with self.subTest(cached=cached):
                invocation = self.invocation()
                snapshot = invocation.snapshot()
                if cached:
                    snapshot(fixtures.BASE_ID)
                self.loose_path.write_bytes(b"corrupt")
                with mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                       side_effect=AssertionError("fallback")):
                    with self.assertRaises(KeyError):
                        snapshot(self.oid)
                    self.loose_path.write_bytes(self.compressed)
                    with self.assertRaises(KeyError):
                        snapshot(self.oid)
                    with self.assertRaises(KeyError):
                        invocation.snapshot()
        with mock.patch.object(git_loose_acquire, "read_object", side_effect=OSError("I/O")), \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                  side_effect=AssertionError("fallback")):
            with self.assertRaises(KeyError):
                self.invocation().snapshot()(self.oid)

    def test_stale_reentrant_and_lifecycle(self):
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
        for reentry in ("read", "snapshot", "pair"):
            invocation = self.invocation()
            snapshot = invocation.snapshot()

            def reenter(*args):
                with self.assertRaises(KeyError):
                    snapshot(self.oid) if reentry == "read" else invocation.snapshot()
                if reentry == "pair":
                    return mock.Mock(read=mock.Mock(return_value=("blob", b"ok")))
                return ("blob", b"ok")

            target = git_pack_acquire if reentry == "pair" else git_loose_acquire
            name = "acquire_validated_pair_v2" if reentry == "pair" else "read_object"
            with self.subTest(reentry=reentry), mock.patch.object(target, name, side_effect=reenter):
                with self.assertRaises(KeyError):
                    snapshot(fixtures.BASE_ID if reentry == "pair" else self.oid)
                with self.assertRaises(KeyError):
                    invocation.snapshot()
        invocation = self.invocation()
        invocation.snapshot()
        last = invocation.snapshot()
        with self.assertRaises(KeyError):
            invocation.snapshot()
        with self.assertRaises(KeyError):
            last(self.oid)

    def test_changed_pair_fresh_acquisition_and_no_other_pair_fallback(self):
        invocation = self.invocation()
        first = invocation.snapshot()
        self.assertEqual(first(fixtures.BASE_ID)[0], "blob")
        self.index_path.write_bytes(b"corrupt")
        self.assertEqual(first(fixtures.TARGET_ID)[0], "blob")
        second = invocation.snapshot()
        with mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                               wraps=git_pack_acquire.acquire_validated_pair_v2) as acquire:
            with self.assertRaises(KeyError):
                second(fixtures.BASE_ID)
            self.index_path.write_bytes(self.index)
            with self.assertRaises(KeyError):
                second(fixtures.BASE_ID)
            self.assertEqual(acquire.call_count, 1)
        other_oid = fixtures.object_id("blob", b"other")
        other_pack, other_index = fixtures.fixture(
            [(other_oid, fixtures.plain(3, b"other"))])
        other_id = other_pack[-20:].hex()
        (self.directory / f"pack-{other_id}.pack").write_bytes(other_pack)
        (self.directory / f"pack-{other_id}.idx").write_bytes(other_index)
        invocation = self.invocation()
        with self.assertRaises(KeyError):
            invocation.snapshot()(other_oid.hex())
        with self.assertRaises(KeyError):
            invocation.snapshot()


class SnapshotReaderV3Tests(unittest.TestCase):
    setUp = v1.SnapshotReaderTests.setUp

    def test_v3_pair_profile_and_reservations(self):
        self.assertEqual(reader.V3_PAIR_IO_LIMIT,
                         2 * (32 * large.MIB + git_pack.INDEX_LIMIT + 2))
        pack, index = large.pair_of_size(16 * large.MIB + 1)
        self.pack_id = pack[-20:].hex()
        (self.directory / f"pack-{self.pack_id}.pack").write_bytes(pack)
        (self.directory / f"pack-{self.pack_id}.idx").write_bytes(index)
        oid = fixtures.object_id("blob", b"x").hex()
        with mock.patch.object(git_pack, "_parse_profile",
                               wraps=git_pack._parse_profile) as parse, \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v3",
                                  wraps=git_pack_acquire.acquire_validated_pair_v3) as v3, \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                  wraps=git_pack_acquire.acquire_validated_pair_v2) as v2:
            with self.assertRaises(KeyError):
                reader.InvocationV2(str(self.root), self.pack_id).snapshot()(oid)
            self.assertEqual((v2.call_count, v3.call_count), (1, 0))
            invocation = reader.InvocationV3(str(self.root), self.pack_id)
            self.assertEqual(invocation.snapshot()(oid), ("blob", b"x"))
            self.assertEqual(invocation.snapshot()(oid), ("blob", b"x"))
            self.assertEqual((v2.call_count, v3.call_count), (1, 2))
            self.assertEqual([call.args[2] for call in parse.call_args_list[-2:]],
                             [git_pack._Profile.V3] * 2)
        with mock.patch.object(reader, "V3_PAIR_IO_LIMIT", reader.V3_PAIR_IO_LIMIT - 1):
            invocation = reader.InvocationV3(str(self.root), self.pack_id)
            invocation.snapshot()(oid)
            with self.assertRaises(KeyError):
                invocation.snapshot()(oid)


if __name__ == "__main__":
    unittest.main()
