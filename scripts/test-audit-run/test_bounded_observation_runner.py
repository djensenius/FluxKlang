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
import git_pack
import git_pack_acquire
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

    def report(self, input_path=None, pin=None, *, arguments=None, source=None):
        self.serial += 1
        run_id = str(uuid.UUID(int=self.serial, version=4))
        self.output, self.intent = prepare.output_paths(
            self.source if source is None else source, run_id,
        )
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

    def products(self, name="candidate.xctestrun", data=None):
        root = self.directory / "products"
        root.mkdir(exist_ok=True)
        path = root / name
        path.write_bytes(
            plistlib.dumps(runtime_fixture.fixture(), sort_keys=False) if data is None else data,
        )
        return root, path

    def use_products_workflow(self):
        """The fixed Products workflow path, with a distinctive private runner name."""
        self.workflow_blob = self.git.add("blob", b"fixture products workflow")
        name = runner._PRODUCTS_WORKFLOW.rpartition("/")[2]
        workflows = self.git.tree({name: ("100644", self.workflow_blob)})
        github = self.git.tree({"workflows": ("40000", workflows)})
        self.tree = self.git.tree({".github": ("40000", github)})
        self.rebuild()
        self.environment.update(
            GITHUB_WORKFLOW_REF=f"owner/repo/{runner._PRODUCTS_WORKFLOW}@refs/heads/main",
            GITHUB_WORKFLOW_SHA=self.commit, RUNNER_NAME="PRIVATE-runner-name",
        )
        os.environ.update(self.environment)

    def expected_record(self):
        def blob(data):
            return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()

        record = {
            "schema": "fluxklang-provider-products-observation-v1",
            "observation": {
                "assurance": "provider-trusted-observation-not-provenance-or-custody",
                "checkout": {"commit": self.commit, "tree": self.tree},
                "workflow": {"path": ".github/workflows/ios-provider-products-observation.yml",
                             "sha": self.commit, "blob": self.workflow_blob},
                "sources": {path: {"blob": blob(self.data[path]),
                                   "sha256": hashlib.sha256(self.data[path]).hexdigest()}
                            for path in integration._PATHS_V5},
                "runner": {"environment": "github-hosted", "os": "macOS", "arch": "ARM64"},
                "xcode": {"version": "Xcode 27.1", "build": "27A9275",
                          "simulator_sdk_version": "27.1"},
                "runtime": {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                            "version": "27.0", "build": "24A434"},
                "checker": {"size": 338880,
                            "sha256": hashlib.sha256(self.host.bytes).hexdigest()},
                "prepared": {"input_sha256": self.candidate_pin,
                             "output_sha256": hashlib.sha256(self.output.read_bytes()).hexdigest()},
            },
        }
        return json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n"

    def products_report(self):
        products_root = self.directory / "products"
        if products_root.exists():
            for entry in products_root.iterdir():
                entry.unlink()  # Earlier prepared siblings would be extra candidates.
        products_root, candidate = self.products()
        self.candidate_pin = hashlib.sha256(candidate.read_bytes()).hexdigest()
        return self.report(arguments=["--provider-products-v1", str(products_root)],
                           source=candidate)

    def test_composed_products_handoff_uses_real_v5_and_exact_pin(self):
        self.use_products_workflow()
        products_root, candidate = self.products()
        pin = hashlib.sha256(candidate.read_bytes()).hexdigest()
        self.candidate_pin = pin
        counts = []
        original_sources = integration._observe_fixed_sources

        def sources(*args):
            result = original_sources(*args)
            counts.append(args[2].count)
            self.assertEqual(args[3], integration._PATHS_V5)
            return result

        with mock.patch.object(integration, "_observe_fixed_sources", side_effect=sources), \
                mock.patch.object(acquisition, "discover_candidate",
                                  wraps=acquisition.discover_candidate) as discover, \
                mock.patch.object(integration, "observe_v5", wraps=integration.observe_v5) as v5:
            status, output = self.report(
                arguments=["--provider-products-v1", str(products_root)],
                source=candidate,
            )
        discover.assert_called_once_with(str(products_root))
        self.assertEqual(v5.call_args.args[2:], (str(candidate), pin))
        self.assertEqual(counts, [32, 32])
        self.assertTrue(self.output.is_file())
        self.assertTrue(self.intent.is_file())
        # Exactly one canonical record line, then the unchanged final status line.
        record = self.expected_record()
        self.assertEqual((status, output), (0, record + b'{"status":"observed"}\n'))
        self.assertLessEqual(len(record), 8 * 1024)
        self.assertTrue(record.startswith(
            b'{"observation":{"assurance":"provider-trusted-observation-not-provenance-or-custody",'))
        self.assertTrue(record.endswith(b'},"schema":"fluxklang-provider-products-observation-v1"}\n'))
        for private in (b"PRIVATE", b"Hosted Runner", str(self.root).encode(),
                        str(candidate).encode(), str(self.output).encode(), b"refs/",
                        b"owner/repo", b"/private/var", b"provider_observation"):
            self.assertNotIn(private, output)

    def test_products_record_fields_are_closed_and_refuse_without_partial_output(self):
        self.use_products_workflow()
        captured = []
        original = integration.observe_v5

        def capture(*args):
            captured.append(original(*args))
            return captured[-1]

        with mock.patch.object(integration, "observe_v5", side_effect=capture):
            self.assertEqual(self.products_report()[0], 0)
        envelope, prepared = captured[0]
        base = json.loads(envelope)
        refused = (1, b'{"diagnostic":"Refusal","stage":"observation-record","status":"refused"}\n')
        path = integration._PATHS_V5[0]

        def setter(*keys, value):
            def mutate(data, _prepared):
                target = data
                for key in keys[:-1]:
                    target = target[key]
                target[keys[-1]] = value
            return mutate

        def edit_prepared(key, value):
            def mutate(_data, record):
                record[key] = value
            return mutate

        def delete(*keys):
            def mutate(data, _prepared):
                target = data
                for key in keys[:-1]:
                    target = target[key]
                del target[keys[-1]]
            return mutate

        attribution = ("attribution",)
        provider = (*attribution, "provider_runtime")
        cases = {
            "schema": setter("schema", value=integration.SCHEMA_V4),
            "commit": setter(*attribution, "checkout", "commit", value=self.commit.upper()),
            "tree": setter(*attribution, "checkout", "tree", value=self.tree[:39]),
            "kind": setter(*attribution, "checkout", "kind", value="pr-synthetic-merge"),
            "workflow-status": setter(*attribution, "workflow", "status", value="unavailable"),
            "workflow-path": setter(*attribution, "workflow", "path",
                                    value=".github/workflows/observe.yml"),
            "workflow-sha": setter(*attribution, "workflow", "sha", value=self.commit + "\n"),
            "workflow-blob": setter(*attribution, "workflow", "blob", value=None),
            "source-missing": delete("sources", path),
            "source-extra": setter("sources", "scripts/test-audit-run/extra.py",
                                   value=base["sources"][path]),
            "source-blob": setter("sources", path, "blob", value="PRIVATE"),
            "source-sha256": setter("sources", path, "sha256", value="A" * 64),
            "source-extra-key": setter("sources", path, "path", value="/private"),
            "runner-environment": setter(*attribution, "context", "runner", "environment",
                                         value="self-hosted"),
            "runner-os": setter(*attribution, "context", "platform", "os", value="Linux"),
            "runner-arch": setter(*attribution, "context", "platform", "arch", value="X64"),
            "xcode-version": setter(*provider, "xcode", "version", value="Xcode 27.2"),
            "xcode-build": setter(*provider, "xcode", "build", value="27A9276"),
            "xcode-sdk": setter(*provider, "xcode", "simulator_sdk_version", value="27.0"),
            "runtime-identifier": setter(*provider, "runtime", "identifier", value="PRIVATE"),
            "runtime-version": setter(*provider, "runtime", "version", value="27.1"),
            "runtime-build": setter(*provider, "runtime", "build", value="24A435"),
            "checker-size": setter(*provider, "checker", "size", value=338881),
            "checker-size-type": setter(*provider, "checker", "size", value=338880.0),
            "checker-sha256": setter(*provider, "checker", "sha256", value="0" * 64),
            "provider-missing": delete(*provider),
            "prepared-input": edit_prepared("input", "0" * 64),
            "prepared-output": edit_prepared("output", "PRIVATE"),
            "prepared-extra": edit_prepared("path", "/private"),
        }
        for name, mutate in cases.items():
            with self.subTest(field=name):
                data, record = copy.deepcopy(base), dict(prepared)
                mutate(data, record)
                observed = (provider_attribution._encode(data), record)
                with mock.patch.object(integration, "observe_v5", return_value=observed):
                    self.assertEqual(self.products_report(), refused)
        for name, observed in (("not-tuple", [envelope, prepared]),
                               ("envelope-type", (envelope.decode(), prepared)),
                               ("envelope-json", (b"{", prepared)),
                               ("prepared-type", (envelope, None))):
            with self.subTest(field=name), \
                    mock.patch.object(integration, "observe_v5", return_value=observed):
                self.assertEqual(self.products_report(), refused)
        with self.subTest(field="size"), \
                mock.patch.object(integration, "observe_v5", return_value=captured[0]), \
                mock.patch.object(runner, "_RECORD_LIMIT", 1024):
            self.assertEqual(self.products_report(), refused)
        with self.subTest(field="interrupt"):
            real = runner._products_record

            def interrupted(*args):
                result = real(*args)
                runner._sigint(None, None)
                return result

            with mock.patch.object(integration, "observe_v5", return_value=captured[0]), \
                    mock.patch.object(runner, "_products_record", side_effect=interrupted):
                self.assertEqual(self.products_report(),
                                 (130, b'{"diagnostic":"Interrupted","status":"failed"}\n'))
        with self.subTest(field="bounded-prepare-unchanged"), \
                mock.patch.object(integration, "observe_v5", return_value=captured[0]), \
                mock.patch.object(runner, "_products_record") as record_builder:
            self.assertEqual(self.report(), (0, b'{"status":"observed"}\n'))
            record_builder.assert_not_called()

    def test_products_candidate_cardinality_and_path_policy_refuse_closed(self):
        products_root, candidate = self.products()
        candidate.unlink()
        cases = (
            (str(products_root), b"candidate-discovery"),
            (str(products_root) + "/", b"candidate-discovery"),
            ("relative/Products", b"candidate-discovery"),
            ("/" + "x" * 4097, b"candidate-discovery"),
            ("/" + "x" * 256, b"candidate-discovery"),
        )
        for root, stage in cases:
            with self.subTest(root=root[:40]):
                status, output = self.report(
                    arguments=["--provider-products-v1", root],
                    source=candidate,
                )
                self.assertEqual((status, output),
                                 (1, b'{"diagnostic":"Refusal","stage":"' + stage
                                  + b'","status":"refused"}\n'))
                self.assertFalse(self.host.commands)
        candidate.write_bytes(plistlib.dumps(runtime_fixture.fixture(), sort_keys=False))
        second = products_root / "second.xctestrun"
        second.write_bytes(candidate.read_bytes())
        status, output = self.report(
            arguments=["--provider-products-v1", str(products_root)],
            source=candidate,
        )
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"candidate-discovery",'
                          b'"status":"refused"}\n'))
        self.assertFalse(self.host.commands)

    def test_products_enumeration_and_component_inclusive_bounds(self):
        products_root, candidate = self.products("x" * 245 + ".xctestrun")
        for index in range(255):
            (products_root / f"entry-{index:03d}").write_bytes(b"")
        self.assertEqual(len(os.fsencode(candidate.name)), 255)
        selected, pin = acquisition.discover_candidate(str(products_root))
        self.assertEqual((selected, pin),
                         (str(candidate), hashlib.sha256(candidate.read_bytes()).hexdigest()))
        (products_root / "entry-255").write_bytes(b"")
        with self.assertRaises(ios_runtime.Refusal):
            acquisition.discover_candidate(str(products_root))

    def test_products_candidate_shapes_size_and_mutation_refuse(self):
        products_root, candidate = self.products()
        candidate.unlink()
        target = products_root / "not-candidate"
        target.write_bytes(b"")
        candidate.symlink_to(target)
        with self.assertRaises(ios_runtime.Refusal):
            acquisition.discover_candidate(str(products_root))
        candidate.unlink()
        os.link(target, candidate)
        with self.assertRaises(ios_runtime.Refusal):
            acquisition.discover_candidate(str(products_root))
        candidate.unlink()
        os.mkfifo(candidate)
        with self.assertRaises(ios_runtime.Refusal):
            acquisition.discover_candidate(str(products_root))
        candidate.unlink()
        candidate.write_bytes(b"x" * (bounded_material.MATERIAL_BYTES + 1))
        with self.assertRaises(ios_runtime.Refusal):
            acquisition.discover_candidate(str(products_root))
        candidate.write_bytes(b"x" * bounded_material.MATERIAL_BYTES)
        self.assertEqual(acquisition.discover_candidate(str(products_root))[1],
                         hashlib.sha256(candidate.read_bytes()).hexdigest())
        candidate.write_bytes(b"candidate")
        real_read = os.read

        def replace_after_read(fd, limit):
            result = real_read(fd, limit)
            if result:
                replacement = products_root / "replacement"
                replacement.write_bytes(b"candidate")
                replacement.replace(candidate)
            return result

        with mock.patch.object(acquisition.os, "read", side_effect=replace_after_read):
            with self.assertRaises(ios_runtime.Refusal):
                acquisition.discover_candidate(str(products_root))

    def test_products_handoff_pin_rejects_changed_candidate_without_retry(self):
        products_root, candidate = self.products()
        original = integration.observe_v5
        calls = []

        def mutate_then_observe(*args):
            calls.append(args[2:])
            candidate.write_bytes(candidate.read_bytes() + b"changed")
            return original(*args)

        with mock.patch.object(integration, "observe_v5", side_effect=mutate_then_observe):
            status, output = self.report(
                arguments=["--provider-products-v1", str(products_root)],
                source=candidate,
            )
        self.assertEqual((status, output),
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","reason":"input-sha256-mismatch","status":"refused"}\n'))
        self.assertEqual(len(calls), 1)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.intent.exists())
        self.assertEqual(len(self.host.commands), 6)

    def test_products_candidate_descriptor_cleanup_on_success_and_failure(self):
        products_root, candidate = self.products()
        actual_open, actual_close = os.open, os.close
        held = set()

        def open_file(path, flags, mode=0o777, *, dir_fd=None):
            descriptor = actual_open(path, flags, mode, dir_fd=dir_fd)
            held.add(descriptor)
            return descriptor

        def close_file(descriptor):
            actual_close(descriptor)
            held.discard(descriptor)

        with mock.patch.object(os, "open", side_effect=open_file) as opened, \
                mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {opened}), \
                mock.patch.object(os, "close", side_effect=close_file):
            acquisition.discover_candidate(str(products_root))
            self.assertEqual(held, set())
            with mock.patch.object(acquisition.os, "read", side_effect=OSError("read failed")):
                with self.assertRaises(ios_runtime.Refusal):
                    acquisition.discover_candidate(str(products_root))
            self.assertEqual(held, set())
            candidate.unlink()
            with self.assertRaises(ios_runtime.Refusal):
                acquisition.discover_candidate(str(products_root))
            self.assertEqual(held, set())

    def test_unknown_missing_and_extra_arguments_refuse_before_observation(self):
        secret = "PRIVATE-argument"
        cases = (
            ["--bounded-prepar-v1", secret, self.pin],
            ["--unknown", secret],
            [secret],
            ["--bounded-prepare-v1"],
            ["--bounded-prepare-v1", str(self.source)],
            ["--bounded-prepare-v1", str(self.source), self.pin, secret],
            ["--provider-products-v1"],
            ["--provider-products-v1", secret, "extra"],
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
            self.assertEqual(args[1:], (git_pack._Profile.V3,))
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
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v3",
                                  wraps=git_pack_acquire.acquire_validated_pair_v3) as v3_pairs, \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2") as v2_pairs, \
                mock.patch.object(provider_attribution, "_encode", side_effect=encode):
            self.assertEqual(self.report(), (0, b'{"status":"observed"}\n'))
        self.assertEqual(v3_pairs.call_count, 2)
        v2_pairs.assert_not_called()
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
            (str(self.source), "0" * 64, b'prepare","reason":"input-sha256-mismatch'),
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
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","reason":"provider-observation-mismatch-value","status":"refused"}\n'))
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
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","reason":"provider-observation-mismatch-type","status":"refused"}\n'))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())
        self.assertNotIn(b"provider_observation", output)

    def test_type_change_at_each_real_provider_exit_refuses(self):
        tool = self.host.nodes[ios_runtime.DEVELOPER + "/usr/bin/xcodebuild"]
        for boundary, trigger, total, comparisons, stage in (
            ("validator", 18, 24, 1, b'prepare","reason":"prepare-provider-observation-drift'),
            ("producer", 24, 30, 2, b'prepare","reason":"prepare-provider-observation-drift'),
            ("composition", 30, 36, 3, b'provider-exit","reason":"observation-drift'),
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
                stage = (b'prepare","reason":"material-path-drift' if case == "input" else
                         b'prepare","reason":"prepare-provider-provider-tool-drift'
                         if case == "provider" else
                         b'provider-exit","reason":"provider-tool-drift' if case == "outer-exit"
                         else b"snapshot-after")
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
                         (1, b'{"diagnostic":"Refusal","stage":"prepare","reason":"material-byte-limit","status":"refused"}\n'))
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

    def test_prepare_stage_reason_codes_are_closed_and_static(self):
        def line(stage, reason=None):
            return (b'{"diagnostic":"Refusal","stage":"' + stage
                    + (b"" if reason is None else b'","reason":"' + reason)
                    + b'","status":"refused"}\n')

        class SubRefusal(prepare.Refusal):
            pass

        private = "PRIVATE/secret key"
        cases = [(prepare.Refusal(message), reason)
                 for message, reason in runner._PREPARE_REASONS.items()]
        cases += [(prepare.Refusal(prefix + private), reason)
                  for prefix, reason in runner._PREPARE_PREFIXES]
        for suffix, kind in runner._REQUIRE_EQUAL_KINDS:
            for location, code in runner._REQUIRE_EQUAL_LOCATIONS.items():
                for actual in (location, location + "." + private, location + "[3]"):
                    cases.append((prepare.Refusal(actual + suffix),
                                  code + b"-mismatch-" + kind))
            for actual in (private, "inputs", "provider observations." + private, ""):
                cases.append((prepare.Refusal(actual + suffix), b"require-equal-" + kind))
        cases += [(bounded_material.Refusal(message), reason)
                  for message, reason in runner._MATERIAL_REASONS.items()]
        cases += [(cause(private), reason)
                  for cause, reason in runner._PREPARE_UNAVAILABLE_CAUSES]
        cases += [
            (ios_runtime.Refusal("unreviewed Xcode version/build observation"),
             b"prepare-provider-xcode-version"),
            (ios_runtime.Refusal("provider-trusted runtime/toolchain observation changed"),
             b"prepare-provider-observation-drift"),
            (prepare.Refusal(private), None),
            (prepare.Refusal("input SHA256 mismatch", private), None),
            (prepare.Refusal(), None),
            (SubRefusal("input SHA256 mismatch"), None),
            (bounded_material.Refusal("material byte limit "), None),
            (bounded_material.Refusal("input SHA256 mismatch"), None),
            (prepare.Refusal("material byte limit"), None),
            (ios_runtime.Refusal(private), None),
            (IsADirectoryError(private), b"prepare-unavailable-isadirectory"),
            (BlockingIOError(private), None),
            (ValueError("input SHA256 mismatch"), None),
            (RuntimeError(private), None),
        ]
        for cause, reason in cases:
            with self.subTest(cause=type(cause).__name__, args=cause.args), \
                    mock.patch.object(prepare, "prepare", side_effect=cause):
                status, output = self.report()
                self.assertEqual((status, output), (1, line(b"prepare", reason)))
                self.assertNotIn(b"PRIVATE", output)
                self.assertNotIn(b"secret", output)
                self.assertEqual(list(json.loads(output)),
                                 ["diagnostic", "stage"] + ([] if reason is None else ["reason"])
                                 + ["status"])

        # Only the exact producer wrapper selects a prepare reason.
        for outer in (ios_runtime.Refusal("PRIVATE producer"),
                      ios_runtime.Refusal("bounded producer refused", "extra")):
            outer.__cause__ = prepare.Refusal("input SHA256 mismatch")

            def produce(_provider, outer=outer):
                raise outer

            real = integration._observe

            def observe(*args, **kwargs):
                return real(*args[:-1], produce, **kwargs)

            with self.subTest(outer=outer.args), \
                    mock.patch.object(integration, "_observe", side_effect=observe):
                self.assertEqual(self.report(), (1, line(b"prepare")))
        # Other stages never interpret a producer-shaped refusal.
        error = ios_runtime.Refusal("bounded producer refused")
        error.__cause__ = prepare.Refusal("input SHA256 mismatch")
        with mock.patch.object(acquisition, "discover_pair", side_effect=error):
            self.assertEqual(self.report(), (1, line(b"pack-discovery")))


if __name__ == "__main__":
    unittest.main()
