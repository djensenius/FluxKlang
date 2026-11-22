"""Synthetic end-to-end bounded runner; only native provider probes are replaced."""

import copy
import hashlib
import json
import os
import plistlib
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest import mock
import uuid

import bounded_material
import git_snapshot_reader
import ios_runtime
import observation_acquisition as acquisition
import observation_runner as runner
import prepare
import provider_attribution
import source_snapshot_integration as integration
import test_ios_runtime as runtime_fixture
import test_observation_runner as v4


class BoundedRunnerTests(unittest.TestCase):
    write_pack = v4.RunnerTests.write_pack

    def setUp(self):
        v4.RunnerTests.setUp(self)
        for module, name in ((prepare, "prepare.py"), (bounded_material, "bounded_material.py")):
            self.stack.enter_context(mock.patch.object(module, "__file__", str(self.directory / name)))
            path = f"scripts/test-audit-run/{name}"
            self.data[path] = ("fixture " + name).encode()
            (self.root / path).write_bytes(self.data[path])
        self.rebuild()
        self.environment.update(
            GITHUB_WORKFLOW_REF="owner/repo/.github/workflows/observe.yml@refs/heads/main",
            GITHUB_WORKFLOW_SHA=self.commit,
        )
        os.environ.update(self.environment)
        material_dir = self.root / "material"
        material_dir.mkdir()
        self.source = material_dir / "private-material.xctestrun"
        data = plistlib.dumps(runtime_fixture.fixture(), sort_keys=False)
        self.source.write_bytes(data)
        self.pin = hashlib.sha256(data).hexdigest()
        self.host = runtime_fixture.Host()
        self.stack.enter_context(mock.patch.object(ios_runtime, "provider_verified_checker",
                                                   v4._PROVIDER_VERIFIED_CHECKER))
        self.stack.enter_context(mock.patch.object(ios_runtime, "os", self.host.os))
        self.stack.enter_context(mock.patch.object(sys, "platform", "darwin"))
        self.stack.enter_context(mock.patch.object(ios_runtime, "_bounded_command", self.host.command))
        self.stack.enter_context(mock.patch.object(
            ios_runtime, "LIBRARY_SHA256", hashlib.sha256(self.host.bytes).hexdigest(),
        ))
        self.serial = 0

    def rebuild(self):
        entries = {
            path.rpartition("/")[2]: ("100644", self.git.add("blob", data))
            for path, data in self.data.items()
        }
        scripts = self.git.tree({"test-audit-run": ("40000", self.git.tree(entries))})
        github = provider_attribution._Objects(self.git.read)._tree(self.tree)[b".github"][1]
        self.tree = self.git.tree({".github": ("40000", github), "scripts": ("40000", scripts)})
        self.commit = self.git.commit(self.tree)
        self.head.write_text(self.commit + "\n")
        self.env["GITHUB_SHA"] = self.commit
        self.event["after"] = self.commit
        self.event_path.write_bytes(json.dumps(self.event).encode())
        self.environment["GITHUB_SHA"] = self.commit
        for path in self.pack_dir.iterdir():
            path.unlink()
        self.write_pack()

    def report(self, input_path=None, pin=None, *, arguments=None):
        self.serial += 1
        run_id = str(uuid.UUID(int=self.serial, version=4))
        self.output, self.intent = prepare.output_paths(self.source, run_id)
        output = []
        real_write = os.write

        def write(fd, data):
            if fd == 1:
                output.append(data)
                return len(data)
            return real_write(fd, data)

        argv = ["observation_runner.py", "--bounded-prepare-v1",
                str(self.source) if input_path is None else input_path,
                self.pin if pin is None else pin]
        if arguments is not None:
            argv = ["observation_runner.py", *arguments]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(run_id)), \
                mock.patch.object(os, "write", side_effect=write):
            status = runner.main()
        self.assertEqual(len(output), 1)
        self.assertFalse(self.host.fds)
        return status, output[0]

    def test_unknown_missing_and_extra_arguments_refuse_before_observation(self):
        secret = "PRIVATE-argument"
        cases = (
            ["--bounded-prepar-v1", secret, self.pin],
            ["--unknown", secret],
            [secret],
            ["--bounded-prepare-v1"],
            ["--bounded-prepare-v1", str(self.source)],
            ["--bounded-prepare-v1", str(self.source), self.pin, secret],
        )
        with mock.patch.object(prepare, "prepare", wraps=prepare.prepare) as producer, \
                mock.patch.object(integration, "observe_v4", wraps=integration.observe_v4) as old_mode, \
                mock.patch.object(integration, "observe_v5", wraps=integration.observe_v5) as new_mode:
            for arguments in cases:
                with self.subTest(arguments=arguments):
                    status, output = self.report(arguments=arguments)
                    self.assertEqual((status, output),
                                     (1, b'{"diagnostic":"Refusal","stage":"input",'
                                      b'"status":"refused"}\n'))
                    self.assertNotIn(secret.encode(), output)
                    self.assertNotIn(str(self.source).encode(), output)
                    self.assertFalse(self.output.exists())
                    self.assertFalse(self.intent.exists())
        producer.assert_not_called()
        old_mode.assert_not_called()
        new_mode.assert_not_called()
        self.assertEqual(self.host.commands, [])

    def test_real_pipeline_order_exact_budgets_and_version(self):
        events, counts, envelopes = [], [], []
        original_sources = integration._observe_fixed_sources
        original_provider = ios_runtime._provider_snapshot
        original_validate = prepare.validate
        original_prepare = prepare.prepare
        original_pair = acquisition.discover_pair
        original_encode = provider_attribution._encode

        def sources(*args):
            result = original_sources(*args)
            counts.append((args[2].count, args[2].total))
            events.append("sources")
            self.assertEqual(args[3], integration._PATHS_V5)
            return result

        def provider(**kwargs):
            events.append("provider")
            return original_provider(**kwargs)

        def produce(*args, **kwargs):
            events.append("prepare-enter")
            result = original_prepare(*args, **kwargs)
            events.append("prepare-exit")
            return result

        def validate(*args, **kwargs):
            events.append("validate-enter")
            result = original_validate(*args, **kwargs)
            events.append("validate-exit")
            return result

        def pair(*args):
            events.append("pair")
            return original_pair(*args)

        def encode(record):
            if record.get("schema") == integration.SCHEMA_V5:
                envelopes.append(copy.deepcopy(record))
            return original_encode(record)

        with mock.patch.object(integration, "_observe_fixed_sources", side_effect=sources), \
                mock.patch.object(ios_runtime, "_provider_snapshot", side_effect=provider), \
                mock.patch.object(prepare, "prepare", side_effect=produce), \
                mock.patch.object(prepare, "validate", side_effect=validate), \
                mock.patch.object(acquisition, "discover_pair", side_effect=pair), \
                mock.patch.object(provider_attribution, "_encode", side_effect=encode):
            self.assertEqual(self.report(), (0, b'{"status":"observed"}\n'))
        self.assertEqual(events, [
            "pair", "pair", "pair", "sources", "pair", "provider", "prepare-enter",
            "provider", "validate-enter", "provider", "provider", "validate-exit",
            "provider", "prepare-exit", "provider",
            "pair", "pair", "sources", "pair", "pair",
        ])
        self.assertEqual([count for count, _ in counts], [32, 32])
        self.assertEqual(counts[0][1], counts[1][1])
        self.assertLessEqual(counts[0][1], 1024 * 1024)
        self.assertEqual(len(self.host.commands), 36)
        self.assertEqual(len(envelopes), 1)
        self.assertEqual(tuple(envelopes[0]["sources"]), integration._PATHS_V5)
        self.assertEqual(len(integration._PATHS_V5), 15)
        record = json.loads(self.intent.read_bytes())
        self.assertEqual(record["provider_observation"],
                         envelopes[0]["attribution"]["provider_runtime"])
        self.assertEqual(record["provider_observation"]["checker"]["canonical_path"],
                         runtime_fixture.LIBRARY)
        self.assertTrue(self.output.is_file())
        self.assertEqual(integration.SCHEMA_V5, "ios-source-snapshot-composition-observation-v5")

    def test_invalid_inputs_pin_and_closed_refusals(self):
        for path, pin, stage in (
            ("relative.xctestrun", self.pin, b"input"),
            (str(self.source) + "/../private", self.pin, b"input"),
            (str(self.source), self.pin.upper(), b"input"),
            (str(self.source), "0" * 64, b"prepare"),
        ):
            with self.subTest(stage=stage, path=path, pin=pin):
                status, output = self.report(path, pin)
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"' + stage
                                  + b'","status":"refused"}\n'))
                self.assertNotIn(str(self.source).encode(), output)
                self.assertFalse(self.output.exists())

    def test_without_workflow_identity_uses_27_calls_per_snapshot(self):
        os.environ.pop("GITHUB_WORKFLOW_REF")
        os.environ.pop("GITHUB_WORKFLOW_SHA")
        counts = []
        original = integration._observe_fixed_sources

        def sources(*args):
            result = original(*args)
            counts.append(args[2].count)
            return result

        with mock.patch.object(integration, "_observe_fixed_sources", side_effect=sources):
            self.assertEqual(self.report(), (0, b'{"status":"observed"}\n'))
        self.assertEqual(counts, [27, 27])

    def test_provider_mismatch_is_type_sensitive_and_retains_files(self):
        tool = self.host.nodes[ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"]

        def changed_probe(_argv):
            if len(self.host.commands) == 6:
                tool.st_ino += 1

        self.host.after_command = changed_probe
        status, output = self.report()
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","status":"refused"}\n'))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())
        tool.st_ino = 1
        command_count = len(self.host.commands)

        def changed_type(_argv):
            if len(self.host.commands) - command_count == 6:
                tool.st_ino = True

        self.host.after_command = changed_type
        status, output = self.report()
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","status":"refused"}\n'))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())
        self.assertNotIn(b"provider_observation", output)

    def test_type_change_at_each_real_provider_exit_refuses(self):
        tool = self.host.nodes[ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"]
        for boundary, trigger, total, comparisons, stage in (
            ("validator", 18, 24, 1, b"prepare"),
            ("producer", 24, 30, 2, b"prepare"),
            ("composition", 30, 36, 3, b"provider-exit"),
        ):
            with self.subTest(boundary=boundary):
                tool.st_ino = 1
                command_count = len(self.host.commands)

                def change(_argv):
                    if len(self.host.commands) - command_count == trigger:
                        tool.st_ino = True

                self.host.after_command = change
                with mock.patch.object(ios_runtime, "_bounded_snapshot_equal",
                                       wraps=ios_runtime._bounded_snapshot_equal) as compare:
                    status, output = self.report()
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"' + stage
                                  + b'","status":"refused"}\n'))
                self.assertEqual(len(self.host.commands) - command_count, total)
                self.assertEqual(compare.call_count, comparisons)
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.assertNotIn(str(self.root).encode(), output)
                self.assertNotIn(b"provider_observation", output)
                self.host.after_command = lambda _argv: None

    def test_interrupt_during_type_mismatch_retains_closed_interrupt(self):
        tool = self.host.nodes[ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"]
        tool.st_ino = 1

        def change(_argv):
            if len(self.host.commands) == 18:
                tool.st_ino = True
            if len(self.host.commands) == 19:
                runner._sigint(None, None)

        self.host.after_command = change
        self.assertEqual(self.report(),
                         (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())

    def test_mutation_and_provider_exit_failure_retain_artifacts(self):
        for case in ("input", "source", "pair", "provider", "outer-exit"):
            with self.subTest(case=case):
                command_count = len(self.host.commands)
                original_data = self.source.read_bytes()
                target = self.root / integration._PATHS_V5[0]
                target_data = target.read_bytes()
                index = self.index_path.read_bytes()

                def after_command(_argv):
                    count = len(self.host.commands) - command_count
                    if case == "input" and count == 18:
                        self.source.write_bytes(original_data + b"changed")
                    if case == "source" and count == 36:
                        target.write_bytes(b"changed")
                    if case == "pair" and count == 36:
                        self.index_path.write_bytes(index + b"changed")
                    if case == "provider" and count == 25:
                        self.host.nodes[ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"].st_ino += 1
                    if case == "outer-exit" and count == 31:
                        self.host.nodes[ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"].st_ino += 1

                self.host.after_command = after_command
                status, output = self.report()
                stage = (b"prepare" if case in ("input", "provider") else
                         b"provider-exit" if case == "outer-exit" else b"snapshot-after")
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"' + stage
                                  + b'","status":"refused"}\n'))
                self.assertNotIn(b"changed", output)
                self.assertNotIn(str(self.root).encode(), output)
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.source.write_bytes(original_data)
                target.write_bytes(target_data)
                self.index_path.write_bytes(index)
                self.host.after_command = lambda _argv: None

    def test_module_substitution_and_source_mutation_refuse(self):
        for module in (prepare, bounded_material):
            with self.subTest(module=module.__name__), \
                    mock.patch.object(module, "__file__", "/private/secret/substituted.py"):
                status, output = self.report()
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"project-checks",'
                                  b'"status":"refused"}\n'))
            with self.subTest(module=module.__name__), \
                    mock.patch.dict(sys.modules, {module.__name__: SimpleNamespace(__file__=module.__file__)}):
                status, output = self.report()
                self.assertEqual(status, 1)
                self.assertNotIn(str(self.root).encode(), output)
        target = self.root / "scripts/test-audit-run/prepare.py"
        target.write_bytes(b"changed")
        self.assertEqual(self.report()[1],
                         b'{"diagnostic":"Refusal","stage":"snapshot-before","status":"refused"}\n')

    def test_canonical_module_substitution_after_producer_refuses(self):
        for module in (prepare, bounded_material):
            with self.subTest(module=module.__name__):
                impostor = ModuleType(module.__name__)
                impostor.__file__ = module.__file__
                command_count = len(self.host.commands)

                def substitute(_argv):
                    if len(self.host.commands) - command_count == 36:
                        sys.modules[module.__name__] = impostor

                self.host.after_command = substitute
                with mock.patch.dict(sys.modules, {module.__name__: module}):
                    status, output = self.report()
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"snapshot-after",'
                                  b'"status":"refused"}\n'))
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.host.after_command = lambda _argv: None

    def test_object_call_and_byte_ceilings_refuse(self):
        with mock.patch.object(provider_attribution, "OBJECT_COUNT", 31):
            self.assertEqual(self.report()[1],
                             b'{"diagnostic":"Refusal","stage":"snapshot-before","status":"refused"}\n')
        with mock.patch.object(git_snapshot_reader, "OBJECT_CALL_LIMIT", 63):
            self.assertEqual(self.report()[1],
                             b'{"diagnostic":"Refusal","stage":"snapshot-after","status":"refused"}\n')
            self.assertTrue(self.output.exists())
            self.assertTrue(self.intent.exists())
        for path in self.data:
            self.data[path] = (path.encode() * 4000)[:120000]
            (self.root / path).write_bytes(self.data[path])
        self.rebuild()
        os.environ.update(self.environment)
        original_get = provider_attribution._Objects.get
        refusals = []

        def get(objects, *args):
            try:
                return original_get(objects, *args)
            except ios_runtime.Refusal as error:
                refusals.append(str(error))
                raise

        with mock.patch.object(provider_attribution._Objects, "get", get):
            self.assertEqual(self.report()[1],
                             b'{"diagnostic":"Refusal","stage":"snapshot-before","status":"refused"}\n')
        self.assertEqual(refusals, ["Git object total size limit"])

    def test_native_failure_is_closed_and_material_cleanup_closes_descriptors(self):
        actual_open, actual_close, actual_dup = os.open, os.close, os.dup
        held = set()

        def open_file(path, flags, mode=0o777, *, dir_fd=None):
            fd = actual_open(path, flags, mode, dir_fd=dir_fd)
            held.add(fd)
            return fd

        def close_file(fd):
            actual_close(fd)
            held.discard(fd)

        def duplicate(fd):
            result = actual_dup(fd)
            held.add(result)
            return result

        def fail(_argv):
            if len(self.host.commands) == 19:
                raise RuntimeError("PRIVATE-exception-and-intent")

        self.host.after_command = fail
        with mock.patch.object(os, "open", side_effect=open_file) as opened, \
                mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                mock.patch.object(os, "close", side_effect=close_file), \
                mock.patch.object(os, "dup", side_effect=duplicate):
            status, output = self.report()
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","status":"refused"}\n'))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())
        self.assertNotIn(b"PRIVATE", output)
        self.assertEqual(held, set())

    def test_material_byte_refusal_and_interrupt_during_preparation(self):
        data = self.source.read_bytes()
        self.source.write_bytes(b"x" * (bounded_material.MATERIAL_BYTES + 1))
        status, output = self.report()
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","status":"refused"}\n'))
        self.assertFalse(self.output.exists())
        self.source.write_bytes(data)
        command_count = len(self.host.commands)

        def interrupt(_argv):
            if len(self.host.commands) - command_count == 8:
                runner._sigint(None, None)

        self.host.after_command = interrupt
        self.assertEqual(self.report(),
                         (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())

    def test_interrupt_before_and_after_producer_and_final_check(self):
        for when in ("before", "after", "final"):
            with self.subTest(when=when):
                real = prepare.prepare
                real_check = runner.check_interrupted
                called = []

                def produce(*args, **kwargs):
                    called.append(True)
                    result = real(*args, **kwargs)
                    if when == "after":
                        runner._sigint(None, None)
                    return result

                def check():
                    if (when == "before" and runner._stage == "prepare") or (
                        when == "final" and runner._stage == "final-check"
                    ):
                        runner._sigint(None, None)
                    real_check()

                with mock.patch.object(prepare, "prepare", side_effect=produce), \
                        mock.patch.object(runner, "check_interrupted", side_effect=check):
                    status, output = self.report()
                self.assertEqual((status, output),
                                 (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))
                self.assertEqual(bool(called), when != "before")
                if when != "before":
                    self.assertTrue(self.output.exists())
                    self.assertTrue(self.intent.exists())


if __name__ == "__main__":
    unittest.main()
