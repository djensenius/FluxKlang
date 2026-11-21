"""Synthetic fixed-source filesystem and real Git object-format fixtures."""

from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import checkout_head
import git_delta
import git_loose
import git_loose_acquire
import git_pack
import git_pack_acquire
import git_snapshot_reader
import ios_runtime
import provider_attribution
import source_snapshot_integration as observer
from test_provider_attribution import GitObjects


MODULES = (observer, provider_attribution, ios_runtime, checkout_head,
           git_snapshot_reader, git_loose, git_loose_acquire, git_pack,
           git_pack_acquire, git_delta)
EXPECTED_PATHS = tuple(sorted((
    "scripts/test-audit-run/source_snapshot_integration.py",
    "scripts/test-audit-run/provider_attribution.py",
    "scripts/test-audit-run/ios_runtime.py",
    "scripts/test-audit-run/checkout_head.py",
    "scripts/test-audit-run/git_snapshot_reader.py",
    "scripts/test-audit-run/git_loose.py",
    "scripts/test-audit-run/git_loose_acquire.py",
    "scripts/test-audit-run/git_pack.py",
    "scripts/test-audit-run/git_pack_acquire.py",
    "scripts/test-audit-run/git_delta.py",
)))


class FixedSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fixed-sources-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.directory = self.root / "scripts" / "test-audit-run"
        self.directory.mkdir(parents=True)
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for module, name in zip(MODULES, observer._NAMES):
            self.stack.enter_context(mock.patch.object(
                module, "__file__", str(self.directory / name),
            ))
        self.data = {path: ("fixture " + path).encode() for path in observer._PATHS}
        for path, data in self.data.items():
            (self.root / path).write_bytes(data)
        self.git = GitObjects()
        entries = {
            path.rpartition("/")[2]: ("100644", self.git.add("blob", data))
            for path, data in self.data.items()
        }
        source_tree = self.git.tree(entries)
        scripts_tree = self.git.tree({"test-audit-run": ("40000", source_tree)})
        self.tree = self.git.tree({"scripts": ("40000", scripts_tree)})

    def observe(self, objects=None):
        if objects is None:
            objects = provider_attribution._Objects(self.git.read)
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")), \
                mock.patch.object(socket, "socket", side_effect=AssertionError("network")), \
                mock.patch.object(os, "listdir", side_effect=AssertionError("enumeration")), \
                mock.patch.object(os, "scandir", side_effect=AssertionError("enumeration")):
            return observer._observe_sources(str(self.root), self.tree, objects)

    def test_valid_mapping_grouped_and_shared_budget(self):
        objects = provider_attribution._Objects(self.git.read)
        objects._tree(self.tree)
        result = self.observe(objects)
        self.assertEqual(list(result), sorted(self.data))
        for path, data in self.data.items():
            oid = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
            self.assertEqual(result[path], {"blob": oid, "sha256": hashlib.sha256(data).hexdigest()})
        self.assertEqual(objects.count, 14)  # previous request + three trees + ten blobs
        self.assertEqual(len(self.git.requests), 14)
        objects.count = provider_attribution.OBJECT_COUNT - 12
        with self.assertRaisesRegex(ios_runtime.Refusal, "count limit"):
            self.observe(objects)
        objects = provider_attribution._Objects(self.git.read)
        objects.total = 1024 * 1024
        with self.assertRaisesRegex(ios_runtime.Refusal, "total size limit"):
            self.observe(objects)

    def test_exact_fixed_paths(self):
        self.assertEqual(observer._PATHS, EXPECTED_PATHS)
        self.assertEqual(tuple(self.observe()), EXPECTED_PATHS)

    def test_shadowed_object_methods_cannot_bypass_validation(self):
        for name in ("files", "_tree", "get"):
            with self.subTest(name=name):
                objects = provider_attribution._Objects(self.git.read)
                setattr(objects, name, mock.Mock(side_effect=AssertionError("shadow called")))
                result = self.observe(objects)
                self.assertEqual(tuple(result), EXPECTED_PATHS)
                self.assertEqual(objects.count, 13)
                getattr(objects, name).assert_not_called()
                objects.count = provider_attribution.OBJECT_COUNT
                with self.assertRaisesRegex(ios_runtime.Refusal, "count limit"):
                    self.observe(objects)

        objects = provider_attribution._Objects(self.git.read)

        def reader(oid):
            objects._tree = lambda tree: {}
            objects.get = lambda *args: b"bad"
            return self.git.read(oid)

        objects.reader = reader
        self.assertEqual(tuple(self.observe(objects)), EXPECTED_PATHS)
        self.assertEqual(objects.count, 13)
        objects = provider_attribution._Objects(lambda oid: ("tree", b"wrong"))
        objects.files = objects._tree = objects.get = lambda *args: {}
        with self.assertRaisesRegex(ios_runtime.Refusal, "identity mismatch"):
            self.observe(objects)

    def test_project_dependency_graph_identity(self):
        edges = (
            (provider_attribution, "runtime", ios_runtime),
            (git_snapshot_reader, "checkout_head", checkout_head),
            (git_snapshot_reader, "git_loose", git_loose),
            (git_snapshot_reader, "git_loose_acquire", git_loose_acquire),
            (git_snapshot_reader, "git_pack", git_pack),
            (git_snapshot_reader, "git_pack_acquire", git_pack_acquire),
            (git_loose_acquire, "checkout_head", checkout_head),
            (git_loose_acquire, "git_loose", git_loose),
            (git_pack_acquire, "checkout_head", checkout_head),
            (git_pack_acquire, "git_loose_acquire", git_loose_acquire),
            (git_pack_acquire, "git_pack", git_pack),
            (git_pack, "git_delta", git_delta),
        )
        for module, name, expected in edges:
            with self.subTest(module=module.__name__, name=name), \
                    mock.patch.object(module, name, SimpleNamespace(__file__=expected.__file__)):
                with self.assertRaisesRegex(ios_runtime.Refusal, "module dependency"):
                    self.observe()

        def substitute(oid):
            git_pack.git_delta = SimpleNamespace(__file__=git_delta.__file__)
            return self.git.read(oid)

        with mock.patch.object(git_pack, "git_delta", git_delta):
            with self.assertRaisesRegex(ios_runtime.Refusal, "module dependency"):
                self.observe(provider_attribution._Objects(substitute))

    def test_fresh_reads_mismatch_and_restoration(self):
        original = self.observe()
        path = self.root / observer._PATHS[0]
        data = path.read_bytes()
        path.write_bytes(b"changed")
        with self.assertRaisesRegex(ios_runtime.Refusal, "tracked blob"):
            self.observe()
        path.write_bytes(data)
        self.assertEqual(self.observe(), original)

    def test_each_source_size_missing_symlink_and_nonregular(self):
        for path in observer._PATHS:
            target = self.root / path
            data = target.read_bytes()
            with self.subTest(path=path):
                target.write_bytes(b"x" * (observer._LIMIT + 1))
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()
                target.unlink()
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()
                target.symlink_to(self.root / observer._PATHS[-1])
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()
                target.unlink()
                os.mkfifo(target)
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()
                target.unlink()
                target.write_bytes(data)

    def test_inclusive_size_limit(self):
        path = observer._PATHS[0]
        data = b"x" * observer._LIMIT
        (self.root / path).write_bytes(data)
        oid = self.git.add("blob", data)
        entries = {p.rpartition("/")[2]: ("100644", self.git.add("blob", d))
                   for p, d in self.data.items()}
        entries[path.rpartition("/")[2]] = ("100644", oid)
        self.tree = self.git.tree({"scripts": ("40000", self.git.tree({
            "test-audit-run": ("40000", self.git.tree(entries)),
        }))})
        self.assertEqual(self.observe()[path]["blob"], oid)

    def test_each_module_path_exact(self):
        for module in MODULES:
            with self.subTest(module=module.__name__), \
                    mock.patch.object(module, "__file__", str(self.root / "wrong.py")):
                with self.assertRaisesRegex(ios_runtime.Refusal, "module path"):
                    self.observe()

    def test_symlink_directory_and_root(self):
        self.directory.rename(self.root / "other")
        self.directory.symlink_to(self.root / "other", target_is_directory=True)
        with self.assertRaises(ios_runtime.Refusal):
            self.observe()
        self.directory.unlink()
        (self.root / "other").rename(self.directory)
        link = self.root.parent / (self.root.name + "-link")
        link.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(link.unlink)
        with ExitStack() as stack:
            for module, name in zip(MODULES, observer._NAMES):
                stack.enter_context(mock.patch.object(
                    module, "__file__", str(link / observer._DIRECTORY / name),
                ))
            with self.assertRaises(ios_runtime.Refusal):
                observer._observe_sources(str(link), self.tree,
                                          provider_attribution._Objects(self.git.read))

    def test_each_source_metadata_and_path_replacement(self):
        actual_open = os.open
        actual_read = os.read
        for path in observer._PATHS:
            target = self.root / path
            name = target.name
            for operation in ("mutate", "replace"):
                with self.subTest(path=path, operation=operation):
                    descriptors = []
                    triggered = []

                    def opened(filename, flags, mode=0o777, *, dir_fd=None):
                        fd = actual_open(filename, flags, mode, dir_fd=dir_fd)
                        if filename == name:
                            descriptors.append(fd)
                        return fd

                    def read(fd, size):
                        data = actual_read(fd, size)
                        if fd in descriptors and data and not triggered:
                            triggered.append(True)
                            if operation == "mutate":
                                target.write_bytes(b"new")
                            else:
                                target.unlink()
                                target.write_bytes(self.data[path])
                        return data

                    with mock.patch.object(os, "open", side_effect=opened) as opener, \
                            mock.patch.object(os, "supports_dir_fd",
                                              os.supports_dir_fd | {opener}), \
                            mock.patch.object(os, "read", side_effect=read):
                        with self.assertRaises(ios_runtime.Refusal):
                            self.observe()
                    self.assertTrue(triggered)
                    target.write_bytes(self.data[path])

    def test_detection_byte_refuses_growth(self):
        actual_open = os.open
        actual_read = os.read
        for path in observer._PATHS:
            with self.subTest(path=path):
                descriptors = []
                requests = []

                def opened(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    if name == path.rpartition("/")[2]:
                        descriptors.append(fd)
                    return fd

                def grow(fd, size):
                    if fd in descriptors:
                        requests.append(size)
                        return b"x" * size
                    return actual_read(fd, size)

                with mock.patch.object(os, "open", side_effect=opened) as opener, \
                        mock.patch.object(os, "supports_dir_fd",
                                          os.supports_dir_fd | {opener}), \
                        mock.patch.object(os, "read", side_effect=grow):
                    with self.assertRaises(ios_runtime.Refusal):
                        self.observe()
                self.assertEqual(sum(requests), observer._LIMIT + 1)

    def test_mutation_and_path_replacement_during_read(self):
        path = self.root / observer._PATHS[0]
        actual_read = os.read
        for operation in ("mutate", "replace", "directory"):
            with self.subTest(operation=operation):
                triggered = []

                def read(fd, size):
                    data = actual_read(fd, size)
                    if data and not triggered:
                        triggered.append(True)
                        if operation == "mutate":
                            path.write_bytes(b"new")
                        elif operation == "replace":
                            path.unlink()
                            path.write_bytes(self.data[observer._PATHS[0]])
                        else:
                            self.directory.rename(self.root / "moved")
                            self.directory.mkdir()
                    return data

                with mock.patch.object(os, "read", side_effect=read):
                    with self.assertRaises(ios_runtime.Refusal):
                        self.observe()
                self.assertTrue(triggered)
                if operation == "directory":
                    self.directory.rmdir()
                    (self.root / "moved").rename(self.directory)
                path.write_bytes(self.data[observer._PATHS[0]])

    def test_missing_and_malformed_git_objects(self):
        oid = self.git.add("blob", self.data[observer._PATHS[0]])
        del self.git.objects[oid]
        with self.assertRaises(ios_runtime.Refusal):
            self.observe()
        self.git.objects[oid] = ("blob", b"wrong")
        with self.assertRaisesRegex(ios_runtime.Refusal, "identity mismatch"):
            self.observe()
        self.git.objects[oid] = ("tree", self.data[observer._PATHS[0]])
        with self.assertRaisesRegex(ios_runtime.Refusal, "shape/size"):
            self.observe()
        missing_tree = self.git.tree({})
        with self.assertRaisesRegex(ios_runtime.Refusal, "tracked source unavailable"):
            observer._observe_sources(str(self.root), missing_tree,
                                      provider_attribution._Objects(self.git.read))
        malformed_tree = self.git.add("tree", b"broken")
        with self.assertRaisesRegex(ios_runtime.Refusal, "malformed Git tree"):
            observer._observe_sources(str(self.root), malformed_tree,
                                      provider_attribution._Objects(self.git.read))

    def test_cleanup_error_refuses(self):
        actual_close = os.close
        actual_open = os.open
        for error in (OSError, RuntimeError):
            with self.subTest(error=error):
                targets = []

                def opened(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    if name == observer._NAMES[0]:
                        targets.append(fd)
                    return fd

                def closed(fd):
                    actual_close(fd)
                    if fd in targets:
                        raise error("injected cleanup error")

                with mock.patch.object(os, "open", side_effect=opened) as opener, \
                        mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opener}), \
                        mock.patch.object(os, "close", side_effect=closed):
                    with self.assertRaises(ios_runtime.Refusal):
                        self.observe()
                self.assertTrue(targets)

    def test_simultaneous_operation_and_cleanup_errors_are_retained(self):
        actual_open, actual_read, actual_close = os.open, os.read, os.close
        for fault in ("read", "mismatch"):
            with self.subTest(fault=fault):
                target = self.root / observer._PATHS[0]
                if fault == "mismatch":
                    target.write_bytes(b"mismatch")
                descriptors, close_calls = [], []

                def opened(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    if name == target.name:
                        descriptors.append(fd)
                    return fd

                def read(fd, size):
                    if fault == "read" and fd in descriptors:
                        raise OSError("injected read fault")
                    return actual_read(fd, size)

                def closed(fd):
                    if fd in descriptors:
                        close_calls.append(fd)
                        actual_close(fd)
                        raise OSError("injected close fault")
                    return actual_close(fd)

                with mock.patch.object(os, "open", side_effect=opened) as opener, \
                        mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opener}), \
                        mock.patch.object(os, "read", side_effect=read), \
                        mock.patch.object(os, "close", side_effect=closed):
                    with self.assertRaisesRegex(ios_runtime.Refusal, "descriptor cleanup failed") as raised:
                        self.observe()
                self.assertEqual(str(raised.exception.__cause__), "injected close fault")
                original = raised.exception.original_error
                self.assertIn("injected read fault" if fault == "read" else
                              "source differs from tracked blob", str(original))
                self.assertEqual(close_calls, descriptors)
                with self.assertRaises(OSError):
                    os.fstat(descriptors[0])
                target.write_bytes(self.data[observer._PATHS[0]])

    def test_root_walk_open_and_close_errors_are_retained(self):
        actual_open, actual_close = os.open, os.close
        root_fds = []
        close_calls = []

        def opened(name, flags, mode=0o777, *, dir_fd=None):
            if name == self.root.parts[1]:
                raise OSError("injected traversal fault")
            fd = actual_open(name, flags, mode, dir_fd=dir_fd)
            if name == "/":
                root_fds.append(fd)
            return fd

        def closed(fd):
            actual_close(fd)
            if fd in root_fds:
                close_calls.append(fd)
                raise OSError("injected close fault")

        with mock.patch.object(os, "open", side_effect=opened) as opener, \
                mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opener}), \
                mock.patch.object(os, "close", side_effect=closed):
            with self.assertRaisesRegex(ios_runtime.Refusal, "descriptor cleanup failed") as raised:
                self.observe()
        self.assertEqual(str(raised.exception.__cause__), "injected close fault")
        self.assertEqual(str(raised.exception.original_error), "injected traversal fault")
        self.assertEqual(close_calls, root_fds)
        with self.assertRaises(OSError):
            os.fstat(root_fds[0])

    def test_cleanup_interruptions_preserve_operation_error(self):
        actual_open, actual_close = os.open, os.close
        for interruption in (KeyboardInterrupt, SystemExit):
            with self.subTest(interruption=interruption):
                descriptors, close_calls = [], []

                def opened(name, flags, mode=0o777, *, dir_fd=None):
                    fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                    if name == observer._PATHS[0].rpartition("/")[2]:
                        descriptors.append(fd)
                    return fd

                def closed(fd):
                    actual_close(fd)
                    if fd in descriptors:
                        close_calls.append(fd)
                        raise interruption("injected interruption")

                with mock.patch.object(os, "open", side_effect=opened) as opener, \
                        mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opener}), \
                        mock.patch.object(os, "read", side_effect=OSError("read fault")), \
                        mock.patch.object(os, "close", side_effect=closed):
                    with self.assertRaises(interruption) as raised:
                        self.observe()
                self.assertEqual(str(raised.exception.original_error), "read fault")
                self.assertEqual(close_calls, descriptors)

    def test_invalid_inputs(self):
        for root, tree, objects in (
            (self.root, self.tree, provider_attribution._Objects(self.git.read)),
            ("relative", self.tree, provider_attribution._Objects(self.git.read)),
            (str(self.root), "A" * 40, provider_attribution._Objects(self.git.read)),
            (str(self.root), self.tree, self.git.read),
        ):
            with self.subTest(root=root, tree=tree), self.assertRaises(ios_runtime.Refusal):
                observer._observe_sources(root, tree, objects)


if __name__ == "__main__":
    unittest.main()
