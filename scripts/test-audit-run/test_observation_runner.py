"""Synthetic runner tests: all provider probes and process/network launch are denied."""

import ast
import json
import os
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

import checkout_head
import git_pack
import git_pack_acquire
import git_snapshot_reader
import ios_runtime
import observation_acquisition as acquisition
import observation_runner as runner
import provider_attribution
import source_snapshot_integration as integration
import test_source_snapshot_integration_v3 as v3


_SCANDIR = os.scandir
_PROVIDER_VERIFIED_CHECKER = ios_runtime.provider_verified_checker


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
        self.stack.enter_context(mock.patch.object(runner.sys, "argv", ["observation_runner.py"]))
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
                                  wraps=git_pack_acquire.acquire_validated_pair_v2) as pairs, \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v3") as v3_pairs, \
                mock.patch.object(acquisition, "discover_pair",
                                  wraps=acquisition.discover_pair) as discover:
            status, output = self.run_report()
        self.assertEqual((status, output), (0, b'{"status":"observed"}\n'))
        self.assertEqual(inputs.call_count, 2)
        self.assertEqual(pairs.call_count, 2)
        # The v4 path keeps the V2 pack profile; only v5/Products uses V3.
        v3_pairs.assert_not_called()
        self.assertTrue(discover.call_args_list)
        self.assertTrue(all(call.args[1:] == (git_pack._Profile.V2,)
                            for call in discover.call_args_list))
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
                stage = b"snapshot-before" if when == "read" else b"snapshot-after"
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"' + stage
                                  + b'","status":"refused"}\n'))
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
        self.assertEqual(output, b'{"diagnostic":"Refusal","stage":"pack-discovery","status":"refused"}\n')
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
        # Only an explicit V3 (v5/Products) discovery admits a larger pack.
        self.assertEqual(acquisition.discover_pair(str(self.root), git_pack._Profile.V3)[0],
                         self.pack_id)
        with pack.open("ab") as stream:
            stream.truncate(32 * 1024 * 1024)
        self.assertEqual(acquisition.discover_pair(str(self.root), git_pack._Profile.V3)[0],
                         self.pack_id)
        with pack.open("ab") as stream:
            stream.write(b"x")
        with self.assertRaises(ios_runtime.Refusal):
            acquisition.discover_pair(str(self.root), git_pack._Profile.V3)
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

    def test_closed_execution_boundaries(self):
        cases = (
            ("input", checkout_head, "_checkout_path", 1),
            ("project-checks", integration, "_context_module_graph", 1),
            ("pack-discovery", acquisition, "discover_pair", 1),
            ("snapshot-before", integration, "_snapshot", 1),
            ("snapshot-before", acquisition, "read_inputs", 1),
            ("provider-record", provider_attribution, "_provider", 1),
            ("snapshot-after", integration, "_snapshot", 2),
            ("snapshot-after", acquisition, "read_inputs", 2),
            ("consistency", provider_attribution, "_provider", 2),
            ("encoding", provider_attribution, "_encode", 1),
            ("encoding", provider_attribution, "_encode", 2),
            ("final-check", acquisition, "discover_pair", 8),
        )
        for stage, module, name, number in cases:
            for error_type in (ios_runtime.Refusal, RuntimeError):
                with self.subTest(stage=stage, name=name, number=number, error=error_type):
                    original = getattr(module, name)
                    calls = []

                    def fail_at(*args, **kwargs):
                        if name == "_encode" and runner._stage != "encoding":
                            return original(*args, **kwargs)
                        calls.append(None)
                        if len(calls) == number:
                            raise error_type("PRIVATE exception, path and native output")
                        return original(*args, **kwargs)

                    with mock.patch.object(module, name, side_effect=fail_at):
                        status, output = self.run_report()
                    diagnostic = b"Refusal" if error_type is ios_runtime.Refusal else b"Unexpected failure"
                    result = b"refused" if error_type is ios_runtime.Refusal else b"failed"
                    self.assertEqual((status, output),
                                     (1, b'{"diagnostic":"' + diagnostic + b'","stage":"'
                                      + stage.encode() + b'","status":"' + result + b'"}\n'))
                    self.assertEqual(len(calls), number)

    def test_provider_boundaries_and_cleanup_masking(self):
        for failing in ("enter", "record", "exit", "record-and-exit"):
            for error_type in (ios_runtime.Refusal, RuntimeError):
                with self.subTest(failing=failing, error=error_type):
                    @contextmanager
                    def checker():
                        if failing == "enter":
                            raise error_type("PRIVATE entry")
                        try:
                            yield tuple(self.record["checker"]["accepted_paths"]), self.record
                        finally:
                            if failing in ("exit", "record-and-exit"):
                                raise error_type("PRIVATE cleanup")

                    def record(*_args):
                        raise error_type("PRIVATE operation")

                    expected = ("provider-exit" if "exit" in failing else
                                "provider-enter" if failing == "enter" else "provider-record")
                    patch_record = (mock.patch.object(provider_attribution, "_provider", side_effect=record)
                                    if failing.startswith("record") else mock.patch.object(
                                        provider_attribution, "_provider",
                                        wraps=provider_attribution._provider))
                    with mock.patch.object(ios_runtime, "provider_verified_checker", side_effect=checker), \
                            patch_record:
                        status, output = self.run_report()
                    diagnostic = b"Refusal" if error_type is ios_runtime.Refusal else b"Unexpected failure"
                    result = b"refused" if error_type is ios_runtime.Refusal else b"failed"
                    self.assertEqual((status, output),
                                     (1, b'{"diagnostic":"' + diagnostic + b'","stage":"'
                                      + expected.encode() + b'","status":"' + result + b'"}\n'))

        @contextmanager
        def cleanup_failure():
            try:
                yield tuple(self.record["checker"]["accepted_paths"]), self.record
            finally:
                raise RuntimeError("PRIVATE cleanup")

        with mock.patch.object(ios_runtime, "provider_verified_checker", side_effect=cleanup_failure), \
                mock.patch.object(provider_attribution, "_provider",
                                  side_effect=ios_runtime.Refusal("PRIVATE operation")):
            self.assertEqual(self.run_report(),
                             (1, b'{"diagnostic":"Unexpected failure","stage":"provider-exit","status":"failed"}\n'))

    def test_real_provider_context_wraps_record_oserror_on_exit(self):
        canonical, alias = self.record["checker"]["accepted_paths"]
        snapshot = (self.record, canonical, alias)
        with mock.patch.object(ios_runtime, "provider_verified_checker", _PROVIDER_VERIFIED_CHECKER), \
                mock.patch.object(ios_runtime, "_provider_snapshot", return_value=snapshot) as provider_snapshot, \
                mock.patch.object(provider_attribution, "_provider",
                                  side_effect=OSError("PRIVATE record failure")) as record:
            status, output = self.run_report()
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"provider-exit",'
                          b'"reason":"verification-unavailable-oserror","status":"refused"}\n'))
        self.assertNotIn(b"PRIVATE", output)
        provider_snapshot.assert_called_once_with()
        record.assert_called_once_with(self.record, (canonical, alias))

    def test_comparison_refusal_is_consistency_boundary(self):
        self.on_exit = lambda: os.environ.update(GITHUB_RUN_ID="43")
        self.assertEqual(self.run_report(),
                         (1, b'{"diagnostic":"Refusal","stage":"consistency","status":"refused"}\n'))

    def test_unknown_stage_fails_closed(self):
        class Poisoned:
            def __hash__(self):
                raise RuntimeError("PRIVATE hash")

        for invalid in ("PRIVATE stage", Poisoned()):
            for error in (ios_runtime.Refusal, RuntimeError):
                def fail(*_args):
                    runner.set_stage(invalid)
                    raise error("PRIVATE exception")

                with self.subTest(invalid=type(invalid), error=error), \
                        mock.patch.object(integration, "observe_v4", side_effect=fail):
                    diagnostic = b"Refusal" if error is ios_runtime.Refusal else b"Unexpected failure"
                    result = b"refused" if error is ios_runtime.Refusal else b"failed"
                    self.assertEqual(self.run_report(),
                                     (1, b'{"diagnostic":"' + diagnostic
                                      + b'","stage":"observation","status":"' + result + b'"}\n'))

    def test_signal_during_complete_write_preserves_committed_report_and_status(self):
        cases = (
            (None, 0, b'{"status":"observed"}\n'),
            (ios_runtime.Refusal("private"), 1,
             b'{"diagnostic":"Refusal","stage":"input","status":"refused"}\n'),
            (ValueError("private"), 1,
             b'{"diagnostic":"Unexpected failure","stage":"input","status":"failed"}\n'),
            (KeyboardInterrupt("private"), 130,
             b'{"diagnostic":"Interrupted","status":"failed"}\n'),
        )
        for error, expected_status, expected_output in cases:
            with self.subTest(error=type(error)):
                output = []

                def observe(*_args):
                    if error is not None:
                        raise error
                    return b"private envelope"

                def write(fd, data):
                    self.assertEqual(fd, 1)
                    output.append(data)
                    runner._sigint(None, None)
                    return len(data)

                with mock.patch.object(integration, "observe_v4", side_effect=observe), \
                        mock.patch.object(os, "write", side_effect=write):
                    status = runner.main()
                self.assertEqual(status, expected_status)
                self.assertEqual(output, [expected_output])
                self.assertTrue(runner._interrupted)

    def test_signal_before_commit_and_output_failures(self):
        def interrupted(*_args):
            runner._sigint(None, None)
            return b"private envelope"

        with mock.patch.object(integration, "observe_v4", side_effect=interrupted):
            self.assertEqual(self.run_report(),
                             (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))

        def failed_write(_fd, _data):
            runner._sigint(None, None)
            raise OSError("private output failure")

        with mock.patch.object(integration, "observe_v4", return_value=b"private envelope"), \
                mock.patch.object(os, "write", side_effect=failed_write):
            self.assertEqual(runner.main(), 130)
        with mock.patch.object(integration, "observe_v4", return_value=b"private envelope"), \
                mock.patch.object(os, "write", side_effect=OSError("private output failure")):
            self.assertEqual(runner.main(), 1)

        def short_write(_fd, data):
            self.assertEqual(data, b'{"status":"observed"}\n')
            runner._sigint(None, None)
            return len(data) - 1

        with mock.patch.object(integration, "observe_v4", return_value=b"private envelope"), \
                mock.patch.object(os, "write", side_effect=short_write):
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

    def provider_failure(self, stage, error):
        """Run the real pipeline with a fake provider failing at one boundary."""
        @contextmanager
        def checker():
            if stage == "provider-enter":
                raise error
            try:
                yield tuple(self.record["checker"]["accepted_paths"]), self.record
            finally:
                if stage == "provider-exit":
                    raise error

        record = (mock.patch.object(provider_attribution, "_provider", side_effect=error)
                  if stage == "provider-record" else
                  mock.patch.object(provider_attribution, "_provider",
                                    wraps=provider_attribution._provider))
        with mock.patch.object(ios_runtime, "provider_verified_checker", side_effect=checker), \
                record:
            return self.run_report()

    @staticmethod
    def refusal_line(stage, reason=None):
        return (b'{"diagnostic":"Refusal","stage":"' + stage.encode()
                + (b"" if reason is None else b'","reason":"' + reason)
                + b'","status":"refused"}\n')

    def test_provider_stage_reason_codes_are_closed_and_exact(self):
        self.assertEqual(
            self.provider_failure("provider-enter", ios_runtime.Refusal(
                "unreviewed Xcode version/build observation")),
            (1, b'{"diagnostic":"Refusal","stage":"provider-enter","reason":"xcode-version",'
                b'"status":"refused"}\n'))
        for stage in sorted(runner._PROVIDER_STAGES):
            for message, reason in runner._PROVIDER_REASONS.items():
                with self.subTest(stage=stage, message=message):
                    status, output = self.provider_failure(stage, ios_runtime.Refusal(message))
                    self.assertEqual((status, output), (1, self.refusal_line(stage, reason)))
                    self.assertEqual(list(json.loads(output)),
                                     ["diagnostic", "stage", "reason", "status"])
                    self.assertNotIn(message.encode(), output)

    def test_provider_reason_codes_are_unique_kebab_ascii(self):
        codes = list(runner._PROVIDER_REASONS.values())
        codes += [code for _cause, code in runner._UNAVAILABLE_CAUSES]
        self.assertEqual(len(codes), len(set(codes)))
        for code in codes:
            self.assertIs(type(code), bytes)
            self.assertRegex(code.decode("ascii"), r"\A[a-z0-9]+(-[a-z0-9]+)*\Z")
        for message in runner._PROVIDER_REASONS:
            self.assertIs(type(message), str)

    def test_unlisted_provider_refusals_and_other_stages_have_no_reason(self):
        known = "unreviewed checker digest observation"

        class SubRefusal(ios_runtime.Refusal):
            pass

        class Text(str):
            pass

        for stage in sorted(runner._PROVIDER_STAGES):
            for error in (ios_runtime.Refusal("PRIVATE unknown provider message"),
                          ios_runtime.Refusal(known + " "),
                          ios_runtime.Refusal(known, "extra"),
                          ios_runtime.Refusal(),
                          ios_runtime.Refusal(Text(known)),
                          SubRefusal(known)):
                with self.subTest(stage=stage, args=error.args, error=type(error)):
                    self.assertEqual(self.provider_failure(stage, error),
                                     (1, self.refusal_line(stage)))
            with self.subTest(stage=stage, error=RuntimeError):
                self.assertEqual(
                    self.provider_failure(stage, RuntimeError(known)),
                    (1, b'{"diagnostic":"Unexpected failure","stage":"' + stage.encode()
                        + b'","status":"failed"}\n'))
        for stage, module, name in (("snapshot-before", integration, "_snapshot"),
                                    ("pack-discovery", acquisition, "discover_pair")):
            for message in (known, "provider-trusted runtime verification unavailable"):
                with self.subTest(stage=stage, message=message), \
                        mock.patch.object(module, name,
                                          side_effect=ios_runtime.Refusal(message)):
                    self.assertEqual(self.run_report(), (1, self.refusal_line(stage)))

    def test_provider_unavailable_cause_classes_are_closed(self):
        canonical, alias = self.record["checker"]["accepted_paths"]

        class FileNotFoundSubclass(FileNotFoundError):
            pass

        cases = (
            (FileNotFoundError, b"verification-unavailable-filenotfound"),
            (PermissionError, b"verification-unavailable-permission"),
            (NotADirectoryError, b"verification-unavailable-notadirectory"),
            (TimeoutError, b"verification-unavailable-timeout"),
            (ProcessLookupError, b"verification-unavailable-processlookup"),
            (OSError, b"verification-unavailable-oserror"),
            (IsADirectoryError, b"verification-unavailable"),
            (BlockingIOError, b"verification-unavailable"),
            (FileNotFoundSubclass, b"verification-unavailable"),
        )
        for cause, reason in cases:
            with self.subTest(cause=cause.__name__), \
                    mock.patch.object(ios_runtime, "provider_verified_checker",
                                      _PROVIDER_VERIFIED_CHECKER), \
                    mock.patch.object(ios_runtime, "_provider_snapshot",
                                      side_effect=cause("PRIVATE cause text")):
                status, output = self.run_report()
                self.assertEqual((status, output),
                                 (1, self.refusal_line("provider-enter", reason)))
                self.assertNotIn(b"PRIVATE", output)
        for cause in (None, RuntimeError("PRIVATE")):
            with self.subTest(cause=type(cause)):
                error = ios_runtime.Refusal("provider-trusted runtime verification unavailable")
                error.__cause__ = cause
                self.assertEqual(self.provider_failure("provider-enter", error),
                                 (1, self.refusal_line("provider-enter",
                                                       b"verification-unavailable")))
        with mock.patch.object(ios_runtime, "provider_verified_checker",
                               _PROVIDER_VERIFIED_CHECKER), \
                mock.patch.object(ios_runtime, "_provider_snapshot",
                                  return_value=(self.record, canonical, alias)), \
                mock.patch.object(provider_attribution, "_provider",
                                  side_effect=PermissionError("PRIVATE")):
            self.assertEqual(self.run_report(),
                             (1, self.refusal_line("provider-exit",
                                                   b"verification-unavailable-permission")))

    def test_interrupted_provider_refusal_has_no_reason(self):
        def interrupted():
            runner._sigint(None, None)
            raise ios_runtime.Refusal("unreviewed checker digest observation")

        with mock.patch.object(ios_runtime, "provider_verified_checker", side_effect=interrupted):
            self.assertEqual(self.run_report(),
                             (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))


class ProviderReasonAllowlistTests(unittest.TestCase):
    def provider_messages(self):
        """Literal refusal messages reachable from provider_verified_checker."""
        tree = ast.parse(Path(ios_runtime.__file__).read_text(encoding="utf-8"))
        functions = {node.name: node for node in tree.body
                     if isinstance(node, ast.FunctionDef)}
        reachable, pending = set(), ["provider_verified_checker"]
        while pending:
            name = pending.pop()
            if name in reachable:
                continue
            reachable.add(name)
            pending.extend(node.id for node in ast.walk(functions[name])
                           if isinstance(node, ast.Name) and node.id in functions)
        for name in ("_provider_inventory", "_provider_snapshot", "_bounded_provider_file",
                     "_provider_file", "_provider_alias", "_command", "_bounded_command",
                     "_path", "_read", "_json_pairs", "require"):
            self.assertIn(name, reachable)
        for name in ("verified_checker", "_inventory", "_alias", "_library", "_open_file"):
            self.assertNotIn(name, reachable)
        messages = set()
        for name in reachable - {"require"}:
            for node in ast.walk(functions[name]):
                if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)):
                    continue
                if node.func.id == "require":
                    self.assertEqual(len(node.args), 2, name)
                    message = node.args[1]
                elif node.func.id == "Refusal":
                    self.assertEqual(len(node.args), 1, name)
                    message = node.args[0]
                else:
                    continue
                self.assertIsInstance(message, ast.Constant, name)
                self.assertIs(type(message.value), str, name)
                messages.add(message.value)
        return messages

    def test_every_provider_refusal_message_has_a_reason_code(self):
        messages = self.provider_messages()
        self.assertIn("provider-trusted runtime verification unavailable", messages)
        self.assertEqual(sorted(messages - set(runner._PROVIDER_REASONS)), [])
        self.assertEqual(sorted(set(runner._PROVIDER_REASONS) - messages), [])



class PrepareReasonAllowlistTests(unittest.TestCase):
    @staticmethod
    def module_tree(name):
        import bounded_material
        import prepare

        module = {"prepare": prepare, "bounded_material": bounded_material,
                  "integration": integration}[name]
        return ast.parse(Path(module.__file__).read_text(encoding="utf-8"))

    def refusal_messages(self, name, helper):
        """Exact literals plus f-string (prefix, suffix) pairs passed to Refusal/helper."""
        exact, formatted = set(), set()
        tree = self.module_tree(name)
        for function in ast.walk(tree):
            if not isinstance(function, ast.FunctionDef) or function.name == helper:
                continue  # The helper forwards its already-checked message.
            assigned = {}
            for node in ast.walk(function):
                if (isinstance(node, ast.Assign) and len(node.targets) == 1
                        and isinstance(node.targets[0], ast.Name)):
                    assigned[node.targets[0].id] = node.value
            for node in ast.walk(function):
                if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)):
                    continue
                if node.func.id == "Refusal":
                    self.assertEqual(len(node.args), 1, function.name)
                    message = node.args[0]
                elif helper is not None and node.func.id == helper:
                    self.assertEqual(len(node.args), 2, function.name)
                    message = node.args[1]
                else:
                    continue
                if isinstance(message, ast.Name):
                    message = assigned[message.id]
                values = ([message.body, message.orelse] if isinstance(message, ast.IfExp)
                          else [message])
                for value in values:
                    if isinstance(value, ast.Constant):
                        self.assertIs(type(value.value), str, function.name)
                        exact.add(value.value)
                        continue
                    self.assertIsInstance(value, ast.JoinedStr, function.name)
                    parts = value.values
                    prefix = parts[0].value if isinstance(parts[0], ast.Constant) else ""
                    suffix = parts[-1].value if isinstance(parts[-1], ast.Constant) else ""
                    formatted.add((prefix, suffix))
        return exact, formatted

    def test_every_prepare_refusal_message_has_a_reason_code(self):
        exact, formatted = self.refusal_messages("prepare", None)
        self.assertIn("input SHA256 mismatch", exact)
        self.assertEqual(sorted(exact ^ set(runner._PREPARE_REASONS)), [])
        prefixes = {prefix for prefix, _suffix in formatted if prefix}
        suffixes = {suffix for prefix, suffix in formatted if not prefix}
        self.assertEqual(sorted(prefixes ^ {prefix for prefix, _ in runner._PREPARE_PREFIXES}),
                         [])
        self.assertEqual(sorted(suffixes ^ {suffix for suffix, _ in runner._REQUIRE_EQUAL_KINDS}),
                         [])
        for message in exact:
            self.assertFalse(any(message.startswith(prefix) for prefix in prefixes), message)

    def test_every_bounded_material_refusal_message_has_a_reason_code(self):
        exact, formatted = self.refusal_messages("bounded_material", "_require")
        self.assertIn("material byte limit", exact)
        self.assertEqual(formatted, set())
        self.assertEqual(sorted(exact ^ set(runner._MATERIAL_REASONS)), [])

    def test_require_equal_locations_are_the_closed_literals(self):
        locations = set()
        for name in ("prepare", "integration"):
            for node in ast.walk(self.module_tree(name)):
                if not isinstance(node, ast.Call):
                    continue
                function = node.func
                called = (function.attr if isinstance(function, ast.Attribute) else
                          function.id if isinstance(function, ast.Name) else None)
                if called != "require_equal":
                    continue
                self.assertEqual(len(node.args), 3)
                if isinstance(node.args[2], ast.JoinedStr):
                    continue  # Recursive nested locations keep a literal root.
                self.assertIsInstance(node.args[2], ast.Constant)
                locations.add(node.args[2].value)
        self.assertIn("provider observation", locations)
        self.assertEqual(sorted(locations ^ set(runner._REQUIRE_EQUAL_LOCATIONS)), [])

    def test_all_reason_codes_are_unique_kebab_ascii(self):
        codes = list(runner._PROVIDER_REASONS.values())
        codes += [code for _cause, code in runner._UNAVAILABLE_CAUSES]
        codes += [b"prepare-provider-" + code for code in codes]
        codes += list(runner._PREPARE_REASONS.values())
        codes += [code for _prefix, code in runner._PREPARE_PREFIXES]
        for _suffix, kind in runner._REQUIRE_EQUAL_KINDS:
            codes.append(b"require-equal-" + kind)
            codes += [location + b"-mismatch-" + kind
                      for location in runner._REQUIRE_EQUAL_LOCATIONS.values()]
        codes += list(runner._MATERIAL_REASONS.values())
        codes += [code for _cause, code in runner._PREPARE_UNAVAILABLE_CAUSES]
        self.assertEqual(len(codes), len(set(codes)))
        for code in codes:
            self.assertIs(type(code), bytes)
            self.assertRegex(code.decode("ascii"), r"\A[a-z0-9]+(-[a-z0-9]+)*\Z")
            self.assertNotIn(b"changed", code)


if __name__ == "__main__":
    unittest.main()
