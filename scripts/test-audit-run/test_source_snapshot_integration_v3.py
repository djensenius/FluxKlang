"""Synthetic explicit-input composition tests; no native provider probes."""

import copy
import json
import unittest
from unittest import mock
from types import SimpleNamespace

import git_loose_acquire
import git_pack
import git_pack_acquire
import git_snapshot_reader
import github_context
import ios_runtime
import provider_attribution
import source_snapshot_integration as observer
import test_source_snapshot_integration as v1


class CompositionV3Tests(unittest.TestCase):
    write_pack = v1.CompositionTests.write_pack
    context_reader = v1.CompositionTests.context_reader

    def setUp(self):
        v1.CompositionTests.setUp(self)
        name = "github_context.py"
        self.stack.enter_context(mock.patch.object(github_context, "__file__",
                                                   str(self.directory / name)))
        self.context_path = f"scripts/test-audit-run/{name}"
        self.data[self.context_path] = b"fixture github context"
        (self.root / self.context_path).write_bytes(self.data[self.context_path])
        entries = {
            path.rpartition("/")[2]: ("100644", self.git.add("blob", data))
            for path, data in self.data.items()
        }
        scripts = self.git.tree({"test-audit-run": ("40000", self.git.tree(entries))})
        github = provider_attribution._Objects(self.git.read)._tree(self.tree)[b".github"][1]
        self.tree = self.git.tree({".github": ("40000", github), "scripts": ("40000", scripts)})
        self.commit = self.git.commit(self.tree)
        self.context.update(event_sha=self.commit, checkout_sha=self.commit)
        self.head.write_text(self.commit + "\n")
        self.write_pack()
        self.env = {
            "GITHUB_REPOSITORY": "owner/repo", "GITHUB_EVENT_NAME": "push",
            "GITHUB_SHA": self.commit, "GITHUB_REF": "refs/heads/main",
            "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_JOB": "observation", "RUNNER_NAME": "Hosted Runner 1",
            "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS",
            "RUNNER_ARCH": "ARM64", "GITHUB_WORKFLOW_REF": None,
            "GITHUB_WORKFLOW_SHA": None,
        }
        self.event = {"repository": {"full_name": "owner/repo"},
                      "ref": "refs/heads/main", "after": self.commit}

    def inputs(self):
        self.events.append("inputs")
        return copy.deepcopy(self.env), json.dumps(self.event).encode(), self.commit

    def observe(self):
        return observer.observe_v3(str(self.root), self.pack_id, self.inputs)

    def workflow(self):
        self.env.update(GITHUB_WORKFLOW_REF="owner/repo/.github/workflows/observe.yml@refs/heads/main",
                        GITHUB_WORKFLOW_SHA=self.commit)

    def test_sequence_sources_and_shared_budgets(self):
        for workflow in (False, True):
            with self.subTest(workflow=workflow):
                if workflow:
                    self.workflow()
                self.events.clear()
                budgets, invocations = [], []
                source = observer._observe_context_sources
                snapshot = git_snapshot_reader.Invocation.snapshot

                def sources(root, tree, objects, context_module):
                    result = source(root, tree, objects, context_module)
                    budgets.append((objects.count, objects.total))
                    return result

                def next_snapshot(invocation):
                    invocations.append(invocation)
                    return snapshot(invocation)

                with mock.patch.object(observer, "_observe_context_sources", sources), \
                        mock.patch.object(git_snapshot_reader.Invocation, "snapshot", next_snapshot), \
                        mock.patch.object(github_context, "read_context",
                                          wraps=github_context.read_context) as projection, \
                        mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                          wraps=git_pack_acquire.acquire_validated_pair_v2) as pairs:
                    data = self.observe()
                result = json.loads(data)
                self.assertEqual(self.events, ["inputs", "provider-enter", "provider-exit", "inputs"])
                self.assertEqual(projection.call_count, 2)
                self.assertIs(invocations[0], invocations[1])
                self.assertIs(type(invocations[0]), git_snapshot_reader.InvocationV2)
                self.assertEqual(pairs.call_args_list, [mock.call(str(self.root), self.pack_id)] * 2)
                self.assertEqual([x[0] for x in budgets], [28 if workflow else 23] * 2)
                self.assertEqual(budgets[0][1], budgets[1][1])
                self.assertLessEqual(budgets[0][1], 1024 * 1024)
                self.assertEqual(result["schema"], observer.SCHEMA_V3)
                self.assertEqual(set(result), {"schema", "assurance", "attribution", "sources"})
                self.assertEqual(tuple(result["sources"]), tuple(sorted((*v1.EXPECTED_PATHS,
                                                                          self.context_path))))
                self.assertEqual(data, provider_attribution._encode(result))
        with mock.patch.object(provider_attribution, "OBJECT_COUNT", 27):
            with self.assertRaisesRegex(ios_runtime.Refusal, "count limit"):
                self.observe()
        with mock.patch.object(git_snapshot_reader, "OBJECT_CALL_LIMIT", 55):
            with self.assertRaises(ios_runtime.Refusal):
                self.observe()

    def test_changed_projection_and_ignored_input(self):
        self.on_exit = lambda: self.env.update(GITHUB_RUN_ID="43")
        with self.assertRaisesRegex(ios_runtime.Refusal, "changed"):
            self.observe()
        self.env["GITHUB_RUN_ID"] = "42"
        self.on_exit = lambda: self.event.update(unused="different")
        self.observe()  # Changes outside the projection are not compared.

    def test_source_and_module_identity_before_and_after(self):
        target = self.root / self.context_path
        self.on_exit = lambda: target.write_bytes(b"changed")
        with self.assertRaisesRegex(ios_runtime.Refusal, "tracked blob"):
            self.observe()
        target.write_bytes(self.data[self.context_path])
        self.on_exit = lambda: None
        for module, attribute in ((github_context, "runtime"), (github_context, "attribution"),
                                  (git_pack, "git_delta")):
            original = getattr(module, attribute)
            with self.subTest(attribute=attribute), \
                    mock.patch.object(module, attribute, SimpleNamespace(__file__=original.__file__)):
                with self.assertRaisesRegex(ios_runtime.Refusal, "module dependency"):
                    self.observe()
        with mock.patch.object(github_context, "__file__", "/wrong/github_context.py"):
            with self.assertRaisesRegex(ios_runtime.Refusal, "module path"):
                self.observe()
        original = github_context.runtime

        def mutate_in_reader():
            inputs = self.inputs()
            github_context.runtime = SimpleNamespace()
            return inputs

        try:
            with self.assertRaisesRegex(ios_runtime.Refusal, "module dependency"):
                observer.observe_v3(str(self.root), self.pack_id, mutate_in_reader)
        finally:
            github_context.runtime = original

        files = provider_attribution._Objects.files

        def mutate_after_files(objects, tree, paths):
            result = files(objects, tree, paths)
            github_context.runtime = SimpleNamespace()
            return result

        try:
            with mock.patch.object(provider_attribution._Objects, "files", mutate_after_files):
                with self.assertRaisesRegex(ios_runtime.Refusal, "module dependency"):
                    self.observe()
        finally:
            github_context.runtime = original

    def test_shared_byte_budget(self):
        entries = {}
        for path in self.data:
            data = (path.encode() * 4000)[:120000]
            (self.root / path).write_bytes(data)
            entries[path.rpartition("/")[2]] = ("100644", self.git.add("blob", data))
        scripts = self.git.tree({"test-audit-run": ("40000", self.git.tree(entries))})
        self.tree = self.git.tree({"scripts": ("40000", scripts)})
        self.commit = self.git.commit(self.tree)
        self.env["GITHUB_SHA"] = self.commit
        self.event["after"] = self.commit
        self.head.write_text(self.commit + "\n")
        self.write_pack()
        with self.assertRaisesRegex(ios_runtime.Refusal, "total size limit"):
            self.observe()

    def test_validation_cross_versions_and_bad_inputs(self):
        data = self.observe()
        v1_data = observer.observe(str(self.root), self.pack_id, self.context_reader)
        v2_data = observer.observe_v2(str(self.root), self.pack_id, self.context_reader)
        self.events.clear()
        observer.validate_v3(data, str(self.root), self.pack_id, self.inputs)
        self.assertEqual(self.events.count("inputs"), 2)
        for validate, candidate, reader in (
            (observer.validate, data, self.context_reader),
            (observer.validate_v2, data, self.context_reader),
            (observer.validate_v3, v1_data, self.inputs),
            (observer.validate_v3, v2_data, self.inputs),
            (observer.validate_v3, data + b" ", self.inputs),
        ):
            with self.subTest(validate=validate.__name__), self.assertRaises(ios_runtime.Refusal):
                validate(candidate, str(self.root), self.pack_id, reader)
        for bad in (None, (), (self.env, b"{}", self.commit, None)):
            with self.subTest(bad=bad), self.assertRaises(ios_runtime.Refusal):
                observer.observe_v3(str(self.root), self.pack_id, lambda: bad)
        self.env["GITHUB_RUN_ID"] = "43"
        with self.assertRaisesRegex(ios_runtime.Refusal, "differs from fresh"):
            observer.validate_v3(data, str(self.root), self.pack_id, self.inputs)

    def test_loose_objects_do_not_require_named_pair(self):
        with mock.patch.object(git_loose_acquire, "read_object",
                               side_effect=lambda root, oid: self.git.read(oid)), \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2") as pairs:
            observer.observe_v3(str(self.root), "0" * 40, self.inputs)
        pairs.assert_not_called()

    def test_interruptions_and_cleanup(self):
        for error in (KeyboardInterrupt(), SystemExit()):
            self.on_exit = lambda: None
            for index in (0, 1):
                reader = mock.Mock(side_effect=([self.inputs()] * index + [error]))
                with self.subTest(error=type(error), index=index), self.assertRaises(type(error)):
                    observer.observe_v3(str(self.root), self.pack_id, reader)
                self.assertEqual(reader.call_count, index + 1)
            self.on_exit = mock.Mock(side_effect=error)
            with self.assertRaises(type(error)):
                self.observe()
            self.on_exit.assert_called_once()
        self.on_exit = lambda: None
        with mock.patch.object(observer, "_observe_context_sources", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.observe()


if __name__ == "__main__":
    unittest.main()
