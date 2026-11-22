"""Synthetic fixed-source filesystem and real Git object-format fixtures."""

from contextlib import contextmanager, ExitStack
import copy
import hashlib
import json
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
from test_provider_attribution import GitObjects, provider_record
import test_git_pack as pack_fixture


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

    def test_multiple_close_faults_preserve_interruptions_and_diagnostics(self):
        actual_open, actual_read, actual_close = os.open, os.read, os.close
        names = [path.rpartition("/")[2] for path in observer._PATHS[:2]]
        target = self.root / observer._PATHS[0]
        for interruption in (KeyboardInterrupt, SystemExit):
            for scenario in ("active", "earlier close", "ordinary"):
                with self.subTest(interruption=interruption, scenario=scenario):
                    descriptors, closes, faults = [], [], []
                    signal = interruption("interrupted")
                    if scenario != "active":
                        target.write_bytes(b"mismatch")

                    def opened(name, flags, mode=0o777, *, dir_fd=None):
                        fd = actual_open(name, flags, mode, dir_fd=dir_fd)
                        if name in names:
                            descriptors.append(fd)
                        return fd

                    def read(fd, size):
                        if scenario == "active" and len(descriptors) == 2 and fd == descriptors[1]:
                            raise signal
                        return actual_read(fd, size)

                    def closed(fd):
                        actual_close(fd)
                        if fd in descriptors:
                            closes.append(fd)
                            if scenario == "earlier close" and len(closes) == 1:
                                raise signal
                            error = OSError(f"close fault {len(closes)}")
                            faults.append(error)
                            raise error

                    with mock.patch.object(os, "open", side_effect=opened) as opener, \
                            mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opener}), \
                            mock.patch.object(os, "read", side_effect=read), \
                            mock.patch.object(os, "close", side_effect=closed):
                        expected = ios_runtime.Refusal if scenario == "ordinary" else interruption
                        with self.assertRaises(expected) as raised:
                            self.observe()
                    self.assertEqual(closes, list(reversed(descriptors)))
                    for fd in descriptors:
                        with self.assertRaises(OSError):
                            os.fstat(fd)
                    if scenario == "ordinary":
                        later = raised.exception
                        self.assertIs(later.__cause__, faults[1])
                        earlier = later.original_error
                        self.assertIs(earlier.__cause__, faults[0])
                        self.assertIn("source differs", str(earlier.original_error))
                    else:
                        self.assertIs(raised.exception, signal)
                        self.assertEqual(signal.cleanup_errors, tuple(faults))
                        if scenario == "earlier close":
                            self.assertIn("source differs", str(signal.original_error))
                    target.write_bytes(self.data[observer._PATHS[0]])

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


class CompositionTests(unittest.TestCase):
    def setUp(self):
        FixedSourceTests.setUp(self)
        git_dir = self.root / ".git"
        self.pack_dir = git_dir / "objects" / "pack"
        self.pack_dir.mkdir(parents=True)
        self.head = git_dir / "HEAD"
        workflow = self.git.tree({
            "observe.yml": ("100644", self.git.add("blob", b"fixture workflow")),
        })
        github = self.git.tree({"workflows": ("40000", workflow)})
        # Retain the same scripts subtree constructed by FixedSourceTests.
        scripts = provider_attribution._Objects(self.git.read)._tree(self.tree)[b"scripts"][1]
        self.tree = self.git.tree({".github": ("40000", github), "scripts": ("40000", scripts)})
        self.commit = self.git.commit(self.tree)
        self.context = {
            "repository": "owner/repo", "event_name": "push",
            "event_sha": self.commit, "checkout_sha": self.commit,
            "event_ref": "refs/heads/main", "pull_request": None,
            "workflow": None, "run_id": 42, "run_attempt": 1, "job": "observation",
            "runner": {"name": "Hosted Runner 1", "environment": "github-hosted"},
            "platform": {"os": "macOS", "arch": "ARM64"},
        }
        self.record = provider_record()
        self.events = []
        self.on_exit = lambda: None
        self.head.write_text(self.commit + "\n")
        self.write_pack()
        self.git.requests.clear()
        for module, names in (
            (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
            (os, ("system", "popen", "fork", "forkpty", "posix_spawn", "posix_spawnp",
                  "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve",
                  "spawnvp", "spawnvpe", "execl", "execle", "execlp", "execlpe",
                  "execv", "execve", "execvp", "execvpe", "kill", "killpg")),
            (socket, ("socket", "create_connection")),
            (os, ("listdir", "scandir", "uname")),
        ):
            for name in names:
                if hasattr(module, name):
                    self.stack.enter_context(mock.patch.object(
                        module, name, side_effect=AssertionError("forbidden operation"),
                    ))
        self.stack.enter_context(mock.patch.object(
            ios_runtime, "_command", side_effect=AssertionError("native probe forbidden"),
        ))

        @contextmanager
        def checker():
            self.events.append("provider-enter")
            try:
                yield tuple(self.record["checker"]["accepted_paths"]), self.record
            finally:
                self.events.append("provider-exit")
                self.on_exit()

        self.stack.enter_context(mock.patch.object(
            ios_runtime, "provider_verified_checker", side_effect=checker,
        ))

    def write_pack(self, omit=None):
        types = {"commit": 1, "tree": 2, "blob": 3}
        entries = [(bytes.fromhex(oid), pack_fixture.plain(types[kind], data))
                   for oid, (kind, data) in self.git.objects.items() if oid != omit]
        pack, index = pack_fixture.fixture(entries)
        self.pack_id = pack[-20:].hex()
        self.pack_path = self.pack_dir / f"pack-{self.pack_id}.pack"
        self.index_path = self.pack_dir / f"pack-{self.pack_id}.idx"
        self.pack_path.write_bytes(pack)
        self.index_path.write_bytes(index)

    def context_reader(self):
        self.events.append("context")
        return copy.deepcopy(self.context)

    def observe(self):
        return observer.observe(str(self.root), self.pack_id, self.context_reader)

    def workflow(self):
        self.context["workflow"] = {
            "sha": self.commit, "path": ".github/workflows/observe.yml",
            "ref": "owner/repo/.github/workflows/observe.yml@refs/heads/main",
        }

    def pr(self):
        base = self.git.commit(self.tree, ["1" * 40])
        head = self.git.commit(self.tree, [base])
        merge = self.git.commit(self.tree, [base, head])
        self.context.update(event_name="pull_request", event_ref="refs/pull/12/merge",
                            event_sha=merge, checkout_sha=merge,
                            pull_request={"number": 12, "base_sha": base, "head_sha": head})
        self.head.write_text(merge + "\n")
        self.write_pack()

    def test_push_and_pr_workflow_modes_sequence_budgets_and_v1(self):
        for pr in (False, True):
            for workflow in (False, True):
                with self.subTest(pr=pr, workflow=workflow):
                    if pr and self.context["pull_request"] is None:
                        self.pr()
                    self.context["workflow"] = None
                    if workflow:
                        self.workflow()
                    self.events.clear()
                    actual_head = checkout_head.observe_checkout_head
                    actual_loose = git_loose_acquire.read_object
                    actual_sources = observer._observe_sources
                    actual_source = provider_attribution._source
                    actual_snapshot = git_snapshot_reader.Invocation.snapshot
                    budgets = []

                    def head(*args):
                        self.events.append("head")
                        return actual_head(*args)

                    def loose(*args):
                        self.events.append("object")
                        return actual_loose(*args)

                    def source(path):
                        self.events.append("attribution-source")
                        return actual_source(path)

                    def sources(root, tree, objects):
                        self.events.append("fixed-sources")
                        result = actual_sources(root, tree, objects)
                        budgets.append((objects.count, objects.total))
                        return result

                    def snapshot(invocation):
                        self.events.append("snapshot")
                        return actual_snapshot(invocation)

                    with mock.patch.object(checkout_head, "observe_checkout_head", side_effect=head), \
                            mock.patch.object(git_loose_acquire, "read_object", side_effect=loose), \
                            mock.patch.object(provider_attribution, "_source", side_effect=source), \
                            mock.patch.object(observer, "_observe_sources", side_effect=sources), \
                            mock.patch.object(git_snapshot_reader.Invocation, "snapshot", snapshot), \
                            mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                                              wraps=git_pack_acquire.acquire_validated_pair) as pairs:
                        data = self.observe()
                    result = json.loads(data)
                    self.assertEqual(result["schema"], observer.SCHEMA)
                    self.assertEqual(result["assurance"], observer.ASSURANCE)
                    self.assertEqual(set(result["sources"]), set(EXPECTED_PATHS))
                    self.assertEqual(result["attribution"]["checkout"]["kind"],
                                     "pr-synthetic-merge" if pr else "event-commit")
                    self.assertEqual(result["attribution"]["workflow"]["status"],
                                     "observed" if workflow else "unavailable")
                    self.assertEqual(pairs.call_count, 2)
                    count = 27 if workflow else 22
                    self.assertEqual([item[0] for item in budgets], [count, count])
                    self.assertEqual(budgets[0][1], budgets[1][1])
                    self.assertLessEqual(budgets[0][1], 1024 * 1024)
                    self.assertEqual(self.events.count("object"), 2 * count)
                    expected = ["snapshot", "context", "head"] + ["object"] * 5
                    # Two attribution file walks: each has three trees and one blob.
                    expected += ["attribution-source"] + ["object"] * 4 + ["attribution-source"]
                    if workflow:
                        expected += ["object"] * 5
                    expected += ["fixed-sources"] + ["object"] * 13
                    self.assertEqual(self.events, expected + ["provider-enter", "provider-exit"] + expected)
                    old = provider_attribution.observe(self.context_reader, self.git.read)
                    self.assertEqual(result["attribution"], json.loads(old))
                    self.assertEqual(old, provider_attribution._encode(result["attribution"]))
                    self.assertEqual(data, provider_attribution._encode(result))

    def test_fresh_validation_and_candidate_tampering(self):
        data = self.observe()
        self.events.clear()
        observer.validate(data, str(self.root), self.pack_id, self.context_reader)
        self.assertEqual(self.events.count("context"), 2)
        for candidate in (data + b" ", b"{}", data.replace(b"same-job", b"fake-job"),
                          "not bytes", b"x" * (provider_attribution.ENVELOPE_LIMIT + 1)):
            with self.subTest(candidate=str(candidate)[:20]), self.assertRaises(ios_runtime.Refusal):
                observer.validate(candidate, str(self.root), self.pack_id, self.context_reader)

    def test_changed_observations_and_provider_mutation(self):
        for change in ("context", "head", "source", "workflow", "provider", "provider-valid"):
            with self.subTest(change=change):
                original_context = copy.deepcopy(self.context)
                original_record = copy.deepcopy(self.record)
                source = self.root / observer._PATHS[0]
                original_source = source.read_bytes()
                if change == "context":
                    self.on_exit = lambda: self.context.update(run_id=43)
                elif change == "head":
                    self.on_exit = lambda: self.head.write_text("0" * 40 + "\n")
                elif change == "source":
                    self.on_exit = lambda: source.write_bytes(b"changed")
                elif change == "workflow":
                    self.on_exit = self.workflow
                elif change == "provider":
                    self.on_exit = lambda: self.record["xcode"].update(version="changed")
                else:
                    self.on_exit = lambda: self.record["xcode"]["simctl_file_identity"].__setitem__(0, 9)
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()
                self.context = original_context
                self.record = original_record
                source.write_bytes(original_source)
                self.head.write_text(self.commit + "\n")
                self.on_exit = lambda: None

    def test_missing_corrupt_pack_and_second_snapshot_freshness(self):
        for fault in ("missing", "corrupt", "missing-object", "second-corrupt", "second-missing"):
            with self.subTest(fault=fault):
                self.write_pack(omit=self.commit if fault == "missing-object" else None)
                if fault == "missing":
                    self.index_path.unlink()
                elif fault == "corrupt":
                    self.pack_path.write_bytes(b"corrupt")
                elif fault == "second-corrupt":
                    self.on_exit = lambda: self.index_path.write_bytes(b"corrupt")
                elif fault == "second-missing":
                    self.on_exit = self.pack_path.unlink
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()
                self.on_exit = lambda: None

    def test_refusals_interruptions_and_cleanup(self):
        for fault in (KeyError("reader"), ValueError("reader"), OSError("reader"),
                      ios_runtime.Refusal("reader")):
            with self.subTest(fault=type(fault)), \
                    self.assertRaises(ios_runtime.Refusal):
                observer.observe(str(self.root), self.pack_id, mock.Mock(side_effect=fault))
        for bad in (None, {}, {**self.context, "checkout_sha": "A" * 40}):
            with self.subTest(context=bad), self.assertRaises(ios_runtime.Refusal):
                observer.observe(str(self.root), self.pack_id, lambda: bad)
        for bad in ("ref: refs/heads/main\n", "a" * 40, "a" * 40 + "\n"):
            self.head.write_text(bad)
            with self.assertRaises(ios_runtime.Refusal):
                self.observe()
        self.head.write_text(self.commit + "\n")
        for error in (ios_runtime.Refusal("cleanup"), KeyboardInterrupt("cleanup"),
                      SystemExit("cleanup")):
            self.on_exit = mock.Mock(side_effect=error)
            with self.subTest(error=type(error)), self.assertRaises(type(error)):
                self.observe()
            self.on_exit.assert_called_once()
        self.on_exit = lambda: None
        with mock.patch.object(observer, "_observe_sources", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.observe()
        self.events.clear()
        with mock.patch.object(provider_attribution, "_provider", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.observe()
        self.assertIn("provider-exit", self.events)
        self.assertEqual(self.events.count("context"), 1)
        with mock.patch.object(provider_attribution, "OBJECT_COUNT", 21):
            with self.assertRaisesRegex(ios_runtime.Refusal, "count limit"):
                self.observe()
        with mock.patch.object(git_snapshot_reader, "OBJECT_CALL_LIMIT", 43):
            with self.assertRaises(ios_runtime.Refusal):
                self.observe()

    def test_head_before_objects_and_reader_failures(self):
        self.head.write_text("ref: refs/heads/main\n")
        with mock.patch.object(git_loose_acquire, "read_object") as read:
            with self.assertRaises(ios_runtime.Refusal):
                self.observe()
            read.assert_not_called()
        self.head.write_text(self.commit + "\n")
        for error in (KeyError("reader"), ValueError("reader"), OSError("reader")):
            with self.subTest(error=type(error)), \
                    mock.patch.object(git_snapshot_reader.Invocation, "snapshot",
                                      return_value=mock.Mock(side_effect=error)):
                with self.assertRaises(ios_runtime.Refusal):
                    self.observe()

    def test_pr_parent_mismatch_and_changed_valid_commit(self):
        self.pr()
        bad = self.git.commit(self.tree, [self.context["pull_request"]["head_sha"],
                                          self.context["pull_request"]["base_sha"]])
        self.context.update(event_sha=bad, checkout_sha=bad)
        self.head.write_text(bad + "\n")
        self.write_pack()
        with self.assertRaisesRegex(ios_runtime.Refusal, "parents"):
            self.observe()
        self.pr()
        other = self.git.commit(self.tree, [self.context["pull_request"]["base_sha"],
                                            self.context["pull_request"]["head_sha"]])
        # A distinct valid commit with the same parents and tree.
        original = self.git.objects[other][1]
        other = self.git.add("commit", original + b"extra")
        self.write_pack()

        def change():
            self.context.update(event_sha=other, checkout_sha=other)
            self.head.write_text(other + "\n")

        self.on_exit = change
        with self.assertRaisesRegex(ios_runtime.Refusal, "changed"):
            self.observe()

    def test_source_mismatch_and_shared_byte_budget(self):
        target = self.root / observer._PATHS[0]
        target.write_bytes(b"not tracked")
        with self.assertRaises(ios_runtime.Refusal):
            self.observe()
        target.write_bytes(self.data[observer._PATHS[0]])

        # Each blob is legal, but duplicate attribution reads plus the ten
        # grouped reads must share the same 1 MiB aggregate budget.
        entries = {}
        for path in observer._PATHS:
            data = (path.encode() * 4000)[:120000]
            (self.root / path).write_bytes(data)
            entries[path.rpartition("/")[2]] = ("100644", self.git.add("blob", data))
        scripts = self.git.tree({"test-audit-run": ("40000", self.git.tree(entries))})
        self.tree = self.git.tree({"scripts": ("40000", scripts)})
        self.commit = self.git.commit(self.tree)
        self.context.update(event_sha=self.commit, checkout_sha=self.commit)
        self.head.write_text(self.commit + "\n")
        self.write_pack()
        with self.assertRaisesRegex(ios_runtime.Refusal, "total size limit"):
            self.observe()


if __name__ == "__main__":
    unittest.main()
