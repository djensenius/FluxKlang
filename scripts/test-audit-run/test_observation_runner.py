"""Synthetic runner tests: all provider probes and process/network launch are denied."""

import json
import os
from types import SimpleNamespace
import unittest
from unittest import mock

import git_pack_acquire
import git_snapshot_reader
import ios_runtime
import observation_acquisition as acquisition
import observation_runner as runner
import provider_attribution
import source_snapshot_integration as integration
import test_source_snapshot_integration_v3 as v3


_SCANDIR = os.scandir


class RunnerTests(unittest.TestCase):
    write_pack = v3.CompositionV3Tests.write_pack

    def setUp(self):
        v3.CompositionV3Tests.setUp(self)
        self.stack.enter_context(mock.patch.object(os, "scandir", _SCANDIR))
        for module, name in ((runner, "observation_runner.py"),
                             (acquisition, "observation_acquisition.py")):
            self.stack.enter_context(mock.patch.object(module, "__file__", str(self.directory / name)))
            path = f"scripts/test-audit-run/{name}"
            self.data[path] = ("fixture " + name).encode()
            (self.root / path).write_bytes(self.data[path])
        self.stack.enter_context(mock.patch.object(runner, "integration", integration, create=True))
        self.stack.enter_context(mock.patch.object(runner, "acquisition", acquisition, create=True))
        entries = {
            path.rpartition("/")[2]: ("100644", self.git.add("blob", data))
            for path, data in self.data.items()
        }
        scripts = self.git.tree({"test-audit-run": ("40000", self.git.tree(entries))})
        github = provider_attribution._Objects(self.git.read)._tree(self.tree)[b".github"][1]
        self.tree = self.git.tree({".github": ("40000", github), "scripts": ("40000", scripts)})
        self.commit = self.git.commit(self.tree)
        self.head.write_text(self.commit + "\n")
        self.context.update(event_sha=self.commit, checkout_sha=self.commit)
        self.env["GITHUB_SHA"] = self.commit
        self.event["after"] = self.commit
        for path in self.pack_dir.iterdir():
            path.unlink()
        self.write_pack()
        self.temp = self.root / "runner-temp"
        (self.temp / "_github_workflow").mkdir(parents=True)
        self.event_path = self.temp / "_github_workflow" / "event.json"
        self.event_path.write_bytes(json.dumps(self.event).encode())
        self.environment = {key: value for key, value in self.env.items() if value is not None}
        self.environment.update(GITHUB_WORKSPACE=str(self.root), RUNNER_TEMP=str(self.temp),
                                GITHUB_EVENT_PATH=str(self.event_path))
        self.stack.enter_context(mock.patch.dict(os.environ, self.environment, clear=True))
        self.stack.enter_context(mock.patch.object(runner.signal, "signal"))
        runner._interrupted = False

    def run_report(self):
        output = []

        def write(fd, data):
            self.assertEqual(fd, 1)
            output.append(data)
            return len(data)

        with mock.patch.object(os, "write", side_effect=write):
            status = runner.main()
        self.assertEqual(len(output), 1)
        return status, output[0]

    def test_positive_fresh_inputs_sources_and_budgets(self):
        self.environment.update(
            GITHUB_WORKFLOW_REF="owner/repo/.github/workflows/observe.yml@refs/heads/main",
            GITHUB_WORKFLOW_SHA=self.commit,
        )
        os.environ.update(self.environment)
        counts = []
        original = integration._observe_fixed_sources

        def sources(root, tree, objects, paths, graph, module_paths):
            result = original(root, tree, objects, paths, graph, module_paths)
            counts.append(objects.count)
            return result

        with mock.patch.object(integration, "_observe_fixed_sources", side_effect=sources), \
                mock.patch.object(acquisition, "read_inputs", wraps=acquisition.read_inputs) as inputs, \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                  wraps=git_pack_acquire.acquire_validated_pair_v2) as pairs:
            status, output = self.run_report()
        self.assertEqual((status, output), (0, b'{"status":"observed"}\n'))
        self.assertEqual(inputs.call_count, 2)
        self.assertEqual(pairs.call_count, 2)
        self.assertEqual(counts, [30, 30])
        for target, limit in ((provider_attribution, "OBJECT_COUNT"),
                              (git_snapshot_reader, "OBJECT_CALL_LIMIT")):
            with self.subTest(limit=limit), mock.patch.object(target, limit, 29 if limit == "OBJECT_COUNT" else 59):
                self.assertEqual(self.run_report()[0], 1)

    def test_directory_replacement_during_pair_read_and_between_snapshots(self):
        for when in ("read", "between"):
            with self.subTest(when=when):
                original_read = git_pack_acquire._read
                contents = {path.name: path.read_bytes() for path in self.pack_dir.iterdir()}
                moved = self.pack_dir.with_name("old-pack")
                changed = []

                def replace():
                    if changed:
                        return
                    changed.append(True)
                    self.pack_dir.rename(moved)
                    self.pack_dir.mkdir()
                    for name, data in contents.items():
                        (self.pack_dir / name).write_bytes(data)

                def read(fd, limit):
                    result = original_read(fd, limit)
                    if when == "read":
                        replace()
                    return result

                self.on_exit = replace if when == "between" else lambda: None
                with mock.patch.object(git_pack_acquire, "_read", side_effect=read):
                    status, output = self.run_report()
                self.assertTrue(changed)
                self.assertEqual((status, output), (1, b'{"diagnostic":"Refusal","stage":"observation","status":"refused"}\n'))
                for path in self.pack_dir.iterdir():
                    path.unlink()
                self.pack_dir.rmdir()
                moved.rename(self.pack_dir)
            self.on_exit = lambda: None

    def test_pair_swap_and_unexpected_entries_refuse(self):
        path = self.pack_dir / f"pack-{self.pack_id}.idx"
        data = path.read_bytes()
        def swap():
            replacement = self.pack_dir / "replacement"
            replacement.write_bytes(data)
            replacement.replace(path)

        self.on_exit = swap
        self.assertEqual(self.run_report()[0], 1)
        self.on_exit = lambda: None
        extra = self.pack_dir / "unknown-secret-name"
        extra.write_bytes(b"secret")
        status, output = self.run_report()
        self.assertEqual(status, 1)
        self.assertEqual(output, b'{"diagnostic":"Refusal","stage":"observation","status":"refused"}\n')
        extra.unlink()

    def test_discovery_shapes_and_inclusive_size_boundary(self):
        pack = self.pack_dir / f"pack-{self.pack_id}.pack"
        index = self.pack_dir / f"pack-{self.pack_id}.idx"
        pack_data, index_data = pack.read_bytes(), index.read_bytes()
        index.unlink()
        self.assertEqual(self.run_report()[0], 1)
        index.write_bytes(index_data)
        extra = self.pack_dir / ("pack-" + "0" * 40 + ".idx")
        extra.write_bytes(index_data)
        self.assertEqual(self.run_report()[0], 1)
        extra.unlink()
        index.unlink()
        index.symlink_to(pack)
        self.assertEqual(self.run_report()[0], 1)
        index.unlink()
        os.mkfifo(index)
        self.assertEqual(self.run_report()[0], 1)
        index.unlink()
        index.write_bytes(index_data)
        with pack.open("wb") as stream:
            stream.truncate(16 * 1024 * 1024)
        self.assertEqual(acquisition.discover_pair(str(self.root))[0], self.pack_id)
        with pack.open("ab") as stream:
            stream.write(b"x")
        self.assertEqual(self.run_report()[0], 1)
        pack.write_bytes(pack_data)

    def test_v4_sources_and_v1_v2_v3_validation_separation(self):
        data = integration.observe_v4(str(self.root), runner)
        result = json.loads(data)
        self.assertEqual(result["schema"], integration.SCHEMA_V4)
        self.assertEqual(tuple(result["sources"]), integration._PATHS_V4)
        self.assertEqual(len(result["sources"]), 13)
        context = lambda: self.context
        inputs = lambda: acquisition.read_inputs(str(self.root))
        for observe, reader, schema in (
            (integration.observe, context, integration.SCHEMA),
            (integration.observe_v2, context, integration.SCHEMA_V2),
            (integration.observe_v3, inputs, integration.SCHEMA_V3),
        ):
            self.assertEqual(json.loads(observe(str(self.root), self.pack_id, reader))["schema"],
                             schema)
        for validate, reader in (
            (integration.validate, context),
            (integration.validate_v2, context),
            (integration.validate_v3, inputs),
        ):
            with self.subTest(version=validate.__name__), self.assertRaises(ios_runtime.Refusal):
                validate(data, str(self.root), self.pack_id, reader)

    def test_input_shape_symlink_and_interrupt(self):
        original = self.event_path.read_bytes()
        self.event_path.unlink()
        self.event_path.symlink_to(self.pack_dir / f"pack-{self.pack_id}.idx")
        self.assertEqual(self.run_report()[0], 1)
        self.event_path.unlink()
        self.event_path.write_bytes(original)
        os.environ["GITHUB_RUN_ID"] = "x" * 513
        self.assertEqual(self.run_report()[0], 1)
        os.environ["GITHUB_RUN_ID"] = "42"
        self.on_exit = lambda: runner._sigint(None, None)
        status, output = self.run_report()
        self.assertEqual((status, output),
                         (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))

    def test_event_size_and_checkout_path_bounds(self):
        data = json.dumps(self.event).encode()
        limit = 1024 * 1024
        self.event_path.write_bytes(data + b" " * (limit - len(data)))
        self.assertEqual(self.run_report()[0], 0)
        with self.event_path.open("ab") as stream:
            stream.write(b" ")
        self.assertEqual(self.run_report()[0], 1)
        os.environ["GITHUB_WORKSPACE"] = "/" + "x" * 4097
        self.assertEqual(self.run_report()[0], 1)

    def test_open_descriptors_are_bounded_and_closed(self):
        actual_open, actual_close = os.open, os.close
        held, maximum = set(), []

        def open_file(path, flags, mode=0o777, *, dir_fd=None):
            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
            held.add(fd)
            maximum.append(len(held))
            return fd

        def close_file(fd):
            actual_close(fd)
            held.discard(fd)

        with mock.patch.object(os, "open", side_effect=open_file) as opened, \
                mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                mock.patch.object(os, "close", side_effect=close_file):
            self.assertEqual(self.run_report()[0], 0)
        self.assertTrue(maximum)
        self.assertLessEqual(max(maximum), 20)
        self.assertEqual(held, set())

    def test_input_refusals_and_closed_failure_output(self):
        secret = "PRIVATE-input-path-and-exception"
        for error in (ValueError(secret), SystemExit(secret), KeyboardInterrupt(secret)):
            with self.subTest(error=type(error)), \
                    mock.patch.object(integration, "observe_v4", side_effect=error):
                status, output = self.run_report()
                self.assertNotIn(secret.encode(), output)
                self.assertEqual(status, 130 if isinstance(error, KeyboardInterrupt) else 1)

        class Poisoned(Exception):
            @property
            def __class__(self):
                raise RuntimeError(secret)

        def poisoned(*_args):
            raise Poisoned()

        with mock.patch.object(integration, "observe_v4", side_effect=poisoned):
            status, output = self.run_report()
        self.assertEqual(status, 1)
        self.assertNotIn(secret.encode(), output)
        os.environ["GITHUB_EVENT_PATH"] = secret
        self.assertEqual(self.run_report()[0], 1)
        def interrupted_failure(*_args):
            runner._sigint(None, None)
            raise RuntimeError(secret)

        with mock.patch.object(integration, "observe_v4", side_effect=interrupted_failure):
            status, output = self.run_report()
        self.assertEqual((status, output),
                         (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))
        with mock.patch.object(integration, "observe_v4", return_value=b"secret-envelope"), \
                mock.patch.object(os, "write", return_value=0):
            self.assertEqual(runner.main(), 1)

    def test_event_replacement_and_changed_projection(self):
        def replace_event():
            self.event_path.unlink()
            self.event_path.write_bytes(json.dumps(self.event).encode())

        self.on_exit = replace_event
        # A fresh event is allowed when its projection is unchanged.
        self.assertEqual(self.run_report()[0], 0)
        self.on_exit = lambda: os.environ.update(GITHUB_RUN_ID="43")
        self.assertEqual(self.run_report()[0], 1)

    def test_event_replaced_during_read_and_cleanup_failure(self):
        actual_read = os.read
        replaced = []

        def read(fd, size):
            data = actual_read(fd, size)
            if not replaced and data.startswith(b'{"repository"'):
                replaced.append(True)
                replacement = self.event_path.with_name("replacement")
                replacement.write_bytes(self.event_path.read_bytes())
                replacement.replace(self.event_path)
            return data

        with mock.patch.object(os, "read", side_effect=read):
            self.assertEqual(self.run_report()[0], 1)
        self.assertTrue(replaced)
        actual_close = os.close
        closed = []

        def close(fd):
            actual_close(fd)
            if not closed:
                closed.append(fd)
                raise OSError("private cleanup detail")

        with mock.patch.object(os, "close", side_effect=close):
            status, output = self.run_report()
        self.assertEqual(status, 1)
        self.assertNotIn(b"private", output)
        self.assertTrue(closed)

    def test_module_graph_and_source_changes_refuse(self):
        with mock.patch.object(acquisition, "git_pack", SimpleNamespace()):
            self.assertEqual(self.run_report()[0], 1)
        path = self.directory / "observation_runner.py"
        self.on_exit = lambda: path.write_bytes(b"private changed source")
        status, output = self.run_report()
        self.assertEqual(status, 1)
        self.assertNotIn(b"private", output)


if __name__ == "__main__":
    unittest.main()
