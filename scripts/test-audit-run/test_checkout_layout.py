"""Synthetic filesystem tests for the bounded checkout layout census."""

import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import traceback
import unittest
from unittest import mock

import checkout_layout as census


HEAD = "a" * 40
PACK_A = "1" * 40
PACK_B = "2" * 40


class CheckoutLayoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="checkout-layout-census-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.git = self.root / ".git"
        self.objects = self.git / "objects"
        self.objects.mkdir(parents=True)
        (self.git / "HEAD").write_text(HEAD + "\n", encoding="ascii")
        self.pack_directory = self.objects / "pack"
        self.pack_directory.mkdir()

    def observe(self):
        return json.loads(census.observe_checkout_layout(str(self.root), HEAD))

    def add_pair(self, oid=PACK_A, pack_size=12, index_size=16):
        pack = self.pack_directory / f"pack-{oid}.pack"
        index = self.pack_directory / f"pack-{oid}.idx"
        for path, size in ((pack, pack_size), (index, index_size)):
            with path.open("wb") as stream:
                stream.truncate(size)

    def test_single_pair_is_only_a_shape_observation_and_output_is_bounded(self):
        self.add_pair()
        private_name = "operator-private-pack-metadata"
        (self.pack_directory / private_name).write_bytes(b"not emitted")
        result = census.observe_checkout_layout(str(self.root), HEAD)
        observed = json.loads(result)
        self.assertEqual(observed["schema"], "checkout-layout-census-v1")
        self.assertEqual(observed["scope"], "shape-and-metadata-only")
        self.assertEqual(observed["acceptance"], "not-assessed")
        self.assertEqual(observed["layout_status"], "unsupported-observed-layout")
        self.assertEqual(observed["candidate_classification"],
                         "single-candidate-within-caps")
        self.assertEqual(observed["pack_index_pair_count"], 1)
        self.assertEqual(observed["within_cap_pair_count"], 1)
        self.assertEqual(observed["pack_bytes_within_cap_total"], 12)
        self.assertEqual(observed["index_bytes_within_cap_total"], 16)
        self.assertEqual(observed["unsupported_features"], ["unexpected-pack-entry"])
        self.assertLessEqual(len(result.encode("utf-8")), census.OUTPUT_BYTES)
        self.assertNotIn(str(self.root), result)
        self.assertNotIn(PACK_A, result)
        self.assertNotIn(private_name, result)
        self.assertEqual(result, census.observe_checkout_layout(str(self.root), HEAD))

    def test_multiple_pairs_are_counted_not_selected(self):
        self.add_pair(PACK_A)
        self.add_pair(PACK_B)
        result = self.observe()
        self.assertEqual(result["candidate_classification"], "multiple-candidates")
        self.assertEqual(result["pack_index_pair_count"], 2)
        self.assertEqual(result["within_cap_pair_count"], 2)
        self.assertNotIn("selected", str(result))

    def test_oversized_and_unpaired_files_are_classified(self):
        self.add_pair(pack_size=census.git_pack.PACK_LIMIT + 1)
        result = self.observe()
        self.assertEqual(result["candidate_classification"], "oversized-single-candidate")
        self.assertEqual(result["oversized_pack_file_count"], 1)
        self.assertEqual(result["within_cap_pair_count"], 0)

        self.add_pair(PACK_B)
        (self.pack_directory / f"pack-{'3' * 40}.idx").write_bytes(b"idx")
        result = self.observe()
        self.assertEqual(result["candidate_classification"], "multiple-candidates")
        self.assertEqual(result["oversized_pack_file_count"], 1)
        self.assertEqual(result["unpaired_pack_index_file_count"], 1)
        self.assertIn("mismatched-pack-index-pair", result["unsupported_features"])

    def test_exact_pack_and_index_caps_are_accepted(self):
        self.add_pair(
            pack_size=census.git_pack.PACK_LIMIT,
            index_size=census.git_pack.INDEX_LIMIT,
        )
        result = self.observe()
        self.assertEqual(result["candidate_classification"],
                         "single-candidate-within-caps")
        self.assertEqual(result["within_cap_pair_count"], 1)
        self.assertEqual(result["pack_bytes_within_cap_total"],
                         census.git_pack.PACK_LIMIT)
        self.assertEqual(result["index_bytes_within_cap_total"],
                         census.git_pack.INDEX_LIMIT)

    def test_each_pack_and_index_cap_plus_one_is_classified_oversized(self):
        self.add_pair(
            pack_size=census.git_pack.PACK_LIMIT + 1,
            index_size=census.git_pack.INDEX_LIMIT + 1,
        )
        result = self.observe()
        self.assertEqual(result["candidate_classification"],
                         "oversized-single-candidate")
        self.assertEqual(result["oversized_pack_file_count"], 1)
        self.assertEqual(result["oversized_index_file_count"], 1)
        self.assertEqual(result["within_cap_pair_count"], 0)

    def test_missing_pairs_and_absent_pack_directory_are_explicit(self):
        (self.pack_directory / f"pack-{PACK_A}.pack").write_bytes(b"pack")
        result = self.observe()
        self.assertEqual(result["candidate_classification"], "no-candidates")
        self.assertEqual(result["unpaired_pack_index_file_count"], 1)
        (self.pack_directory / f"pack-{PACK_A}.pack").unlink()
        self.pack_directory.rmdir()
        result = self.observe()
        self.assertFalse(result["pack_directory_present"])
        self.assertEqual(result["candidate_classification"], "no-candidates")

    def test_loose_fanout_counts_only_directory_shapes(self):
        for name in ("00", "af"):
            (self.objects / name).mkdir()
        (self.objects / "info").mkdir()
        result = self.observe()
        self.assertEqual(result["loose_fanout_directory_count"], 2)

    def test_alternates_and_multi_pack_index_are_explicitly_unsupported(self):
        (self.objects / "info").mkdir()
        (self.objects / "info" / "alternates").write_text("/private/path\n")
        (self.objects / "info" / "http-alternates").write_text(
            "https://private.example/repository\n",
        )
        (self.pack_directory / "multi-pack-index").write_bytes(b"opaque")
        actual_open = os.open
        head_descriptors = set()

        def track_open(name, flags, mode=0o777, *, dir_fd=None):
            if name in ("alternates", "http-alternates"):
                raise AssertionError("alternate file opened")
            descriptor = actual_open(name, flags, mode, dir_fd=dir_fd)
            if name == "HEAD":
                head_descriptors.add(descriptor)
            return descriptor

        actual_read = os.read

        def head_only_read(descriptor, size):
            if descriptor not in head_descriptors:
                raise AssertionError("non-HEAD file read")
            return actual_read(descriptor, size)

        with mock.patch.object(census.os, "open", side_effect=track_open) as opener, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {opener}), \
                mock.patch.object(census.os, "read", side_effect=head_only_read):
            result = self.observe()
        self.assertEqual(result["layout_status"], "unsupported-observed-layout")
        self.assertIn("alternates", result["unsupported_features"])
        self.assertIn("http-alternates", result["unsupported_features"])
        self.assertIn("multi-pack-index", result["unsupported_features"])
        rendered = census.observe_checkout_layout(str(self.root), HEAD)
        self.assertNotIn("/private/path", rendered)
        self.assertNotIn("private.example", rendered)

    def test_linked_worktree_symlinks_and_special_entries_refuse(self):
        moved_git = self.root / "real-git"
        self.git.rename(moved_git)
        self.git.write_text("gitdir: /private/worktree\n", encoding="ascii")
        with self.assertRaises(census.Refusal):
            census.observe_checkout_layout(str(self.root), HEAD)

        self.git.unlink()
        moved_git.rename(self.git)
        (self.git / "HEAD").write_text(HEAD + "\n", encoding="ascii")
        fanout = self.objects / "aa"
        fanout.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(census.Refusal):
            self.observe()
        fanout.unlink()
        (self.pack_directory / "not-a-file").mkdir()
        with self.assertRaises(census.Refusal):
            self.observe()

    def test_entry_limits_refuse_before_stat_traversal(self):
        for index in range(census.OBJECTS_ENTRY_LIMIT + 1):
            (self.objects / f"x{index:03d}").mkdir()
        actual_stat = os.stat

        def objects_stat(name, *args, **kwargs):
            if name != "pack":
                raise AssertionError("entry stat after objects overflow")
            return actual_stat(name, *args, **kwargs)

        with mock.patch.object(census.os, "stat",
                               side_effect=objects_stat) as stat_patch, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {stat_patch}):
            with self.assertRaisesRegex(census.Refusal, "objects directory entry limit"):
                self.observe()

        for path in self.objects.iterdir():
            if path.name != "pack":
                path.rmdir()
        for index in range(census.PACK_ENTRY_LIMIT + 1):
            (self.pack_directory / f"e{index:03d}").write_bytes(b"")

        def pack_stat(name, *args, **kwargs):
            if name != "pack":
                raise AssertionError("entry stat after pack overflow")
            return actual_stat(name, *args, **kwargs)

        with mock.patch.object(census.os, "stat",
                               side_effect=pack_stat) as stat_patch, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {stat_patch}):
            with self.assertRaisesRegex(census.Refusal, "pack directory entry limit"):
                self.observe()

    def test_exact_objects_and_pack_entry_limits_are_accepted(self):
        for index in range(census.OBJECTS_ENTRY_LIMIT - 1):
            (self.objects / f"x{index:03d}").mkdir()
        objects_result = self.observe()
        self.assertEqual(len(list(self.objects.iterdir())), census.OBJECTS_ENTRY_LIMIT)
        self.assertTrue(objects_result["pack_directory_present"])

        for path in self.objects.iterdir():
            if path.name != "pack":
                path.rmdir()
        for index in range(census.PACK_ENTRY_LIMIT // 2):
            oid = f"{index:040x}"
            (self.pack_directory / f"pack-{oid}.pack").write_bytes(b"")
            (self.pack_directory / f"pack-{oid}.idx").write_bytes(b"")
        pack_result = self.observe()
        self.assertEqual(len(list(self.pack_directory.iterdir())),
                         census.PACK_ENTRY_LIMIT)
        self.assertEqual(pack_result["pack_index_pair_count"],
                         census.PACK_ENTRY_LIMIT // 2)

    def test_long_entry_names_refuse_before_metadata_work(self):
        (self.pack_directory / ("x" * (census.ENTRY_NAME_BYTES + 1))).write_bytes(b"")
        actual_stat = os.stat

        def bounded_stat(name, *args, **kwargs):
            if len(name) > census.ENTRY_NAME_BYTES:
                raise AssertionError("stat before name bound")
            return actual_stat(name, *args, **kwargs)

        with mock.patch.object(census.os, "stat",
                               side_effect=bounded_stat) as stat_patch, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {stat_patch}):
            with self.assertRaisesRegex(census.Refusal, "directory entry name limit"):
                self.observe()

    def test_directory_and_entry_mutations_refuse(self):
        original_stat = os.stat
        changed = []
        entry = self.pack_directory / f"pack-{PACK_A}.pack"
        self.add_pair()

        def mutate_entry(name, *args, **kwargs):
            info = original_stat(name, *args, **kwargs)
            if name == entry.name and not changed:
                changed.append(True)
                current = entry.stat()
                os.utime(entry, ns=(current.st_atime_ns, current.st_mtime_ns + 1_000_000))
            return info

        with mock.patch.object(census.os, "stat", side_effect=mutate_entry) as stat_patch, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {stat_patch}):
            with self.assertRaisesRegex(census.Refusal, "entry changed"):
                self.observe()

    def test_process_and_network_operations_are_not_used(self):
        self.add_pair()
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(subprocess, "run", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")), \
                mock.patch.object(os, "system", side_effect=AssertionError("native operation")):
            self.observe()

    def test_interruptions_propagate(self):
        actual_open = os.open
        actual_close = os.close
        opened = []
        close_attempts = {}
        secret = str(self.root / f"pack-{PACK_A}.pack")
        interrupt_started = []
        cleanup_target = []

        def track_open(name, flags, mode=0o777, *, dir_fd=None):
            descriptor = actual_open(name, flags, mode, dir_fd=dir_fd)
            opened.append(descriptor)
            return descriptor

        def fail_cleanup_close(descriptor):
            close_attempts[descriptor] = close_attempts.get(descriptor, 0) + 1
            actual_close(descriptor)
            if interrupt_started and descriptor == cleanup_target[0]:
                raise OSError(errno.EIO, "cleanup failure", secret)

        def interrupt_during_scan(descriptor):
            interrupt_started.append(True)
            cleanup_target.append(descriptor)
            close_attempts.clear()
            raise KeyboardInterrupt("stop")

        with mock.patch.object(census.os, "open", side_effect=track_open) as opener, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {opener}), \
                mock.patch.object(census.os, "close", side_effect=fail_cleanup_close), \
                mock.patch.object(census.os, "scandir",
                                  side_effect=interrupt_during_scan) as scandir_patch, \
                mock.patch.object(census.os, "supports_fd",
                                  census.os.supports_fd | {scandir_patch}):
            with self.assertRaisesRegex(KeyboardInterrupt, "stop") as raised:
                self.observe()
        interruption = raised.exception
        rendered = "".join(traceback.format_exception(interruption))
        self.assertNotIn(secret, rendered)
        self.assertNotIn(str(self.root), rendered)
        self.assertIsNone(interruption.__cause__)
        self.assertIsNone(interruption.__context__)
        self.assertTrue(opened)
        self.assertEqual(close_attempts[cleanup_target[0]], 1)
        for descriptor in opened:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_system_exit_propagates_without_filesystem_context(self):
        with mock.patch.object(census.os, "scandir",
                               side_effect=SystemExit("stop")) as scandir_patch, \
                mock.patch.object(census.os, "supports_fd",
                                  census.os.supports_fd | {scandir_patch}):
            with self.assertRaisesRegex(SystemExit, "stop") as raised:
                self.observe()
        self.assertIsNone(raised.exception.__cause__)
        self.assertIsNone(raised.exception.__context__)

    def test_close_failure_refuses_without_retry(self):
        self.add_pair()
        actual_open = os.open
        actual_close = os.close
        opened = []
        close_attempts = {}
        secret = str(self.root / f"private-pack-{PACK_A}.pack")
        caught = []

        def track_open(name, flags, mode=0o777, *, dir_fd=None):
            descriptor = actual_open(name, flags, mode, dir_fd=dir_fd)
            opened.append(descriptor)
            return descriptor

        def fail_once(descriptor):
            close_attempts[descriptor] = close_attempts.get(descriptor, 0) + 1
            actual_close(descriptor)
            if descriptor == opened[-1]:
                raise OSError(errno.EIO, "injected close failure", secret)

        with mock.patch.object(census.os, "open", side_effect=track_open) as opener, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {opener}), \
                mock.patch.object(census.os, "close", side_effect=fail_once):
            with self.assertRaises(census.Refusal) as raised:
                self.observe()
            caught.append(raised.exception)
        self.assertEqual(close_attempts[opened[-1]], 1)
        rendered = "".join(traceback.format_exception(caught[0]))
        self.assertNotIn(secret, rendered)
        self.assertNotIn(str(self.root), rendered)
        self.assertNotIn(PACK_A, rendered)
        self.assertIsNone(caught[0].__cause__)
        self.assertIsNone(caught[0].__context__)

    def test_filesystem_failure_traceback_omits_root_and_entry_names(self):
        self.add_pair()
        secret = str(self.root / f"pack-{PACK_A}.pack")
        actual_stat = os.stat

        def fail_pack_stat(name, *args, **kwargs):
            if name == "pack":
                raise OSError(errno.EIO, "injected stat failure", secret)
            return actual_stat(name, *args, **kwargs)

        with mock.patch.object(census.os, "stat",
                               side_effect=fail_pack_stat) as stat_patch, \
                mock.patch.object(census.os, "supports_dir_fd",
                                  census.os.supports_dir_fd | {stat_patch}):
            with self.assertRaises(census.Refusal) as raised:
                self.observe()
        rendered = "".join(traceback.format_exception(raised.exception))
        self.assertNotIn(secret, rendered)
        self.assertNotIn(str(self.root), rendered)
        self.assertNotIn(PACK_A, rendered)
        self.assertEqual(str(raised.exception), "checkout layout census refused")
        self.assertIsNone(raised.exception.__cause__)
        self.assertIsNone(raised.exception.__context__)

    def test_output_cap_accepts_exact_bound_and_refuses_one_byte_less(self):
        result = census.observe_checkout_layout(str(self.root), HEAD)
        exact_bound = len(result.encode("utf-8"))
        with mock.patch.object(census, "OUTPUT_BYTES", exact_bound):
            self.assertEqual(census.observe_checkout_layout(str(self.root), HEAD), result)
        with mock.patch.object(census, "OUTPUT_BYTES", exact_bound - 1):
            with self.assertRaisesRegex(census.Refusal, "output size limit"):
                self.observe()


if __name__ == "__main__":
    unittest.main()
