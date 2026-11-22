"""Synthetic opt-in v2 composition tests; no native provider probes."""

import json
import unittest
from unittest import mock

import git_pack
import git_pack_acquire
import git_snapshot_reader
import ios_runtime
import provider_attribution
import source_snapshot_integration as observer
import test_git_pack as pack_fixture
import test_git_pack_v2 as large
import test_source_snapshot_integration as v1


class CompositionV2Tests(unittest.TestCase):
    setUp = v1.CompositionTests.setUp
    write_pack = v1.CompositionTests.write_pack
    context_reader = v1.CompositionTests.context_reader
    workflow = v1.CompositionTests.workflow
    pr = v1.CompositionTests.pr

    def observe(self):
        return observer.observe_v2(str(self.root), self.pack_id, self.context_reader)

    test_duplicate_source_records_refuse_sequential_mutation = (
        v1.CompositionTests.test_duplicate_source_records_refuse_sequential_mutation)
    test_changed_observations_and_provider_mutation = (
        v1.CompositionTests.test_changed_observations_and_provider_mutation)
    test_missing_corrupt_pack_and_second_snapshot_freshness = (
        v1.CompositionTests.test_missing_corrupt_pack_and_second_snapshot_freshness)
    test_source_mismatch_and_shared_byte_budget = (
        v1.CompositionTests.test_source_mismatch_and_shared_byte_budget)
    test_pr_parent_mismatch_and_changed_valid_commit = (
        v1.CompositionTests.test_pr_parent_mismatch_and_changed_valid_commit)

    def test_v2_large_named_pair_shared_invocation_and_fresh_snapshots(self):
        types = {"commit": 1, "tree": 2, "blob": 3}
        entries = [(bytes.fromhex(oid), pack_fixture.plain(types[kind], data))
                   for oid, (kind, data) in self.git.objects.items()]
        padding, entry = large.padded_base(8 * large.MIB + 1)
        entries.append((pack_fixture.object_id("blob", padding), entry))
        pack, index = pack_fixture.fixture(entries)
        self.assertGreater(len(pack), 8 * large.MIB)
        self.pack_id = pack[-20:].hex()
        (self.pack_dir / f"pack-{self.pack_id}.pack").write_bytes(pack)
        (self.pack_dir / f"pack-{self.pack_id}.idx").write_bytes(index)
        with self.assertRaises(ios_runtime.Refusal):
            observer.observe(str(self.root), self.pack_id, self.context_reader)

        self.events.clear()
        actual_snapshot = git_snapshot_reader.Invocation.snapshot
        actual_sources = observer._observe_sources
        invocations, readers, budgets = [], [], []

        def snapshot(invocation):
            invocations.append(invocation)
            self.events.append("snapshot")
            result = actual_snapshot(invocation)
            readers.append(result)
            return result

        def sources(root, tree, objects):
            result = actual_sources(root, tree, objects)
            budgets.append((objects.count, objects.total))
            return result

        with mock.patch.object(git_snapshot_reader.Invocation, "snapshot", snapshot), \
                mock.patch.object(observer, "_observe_sources", sources), \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair",
                                  side_effect=AssertionError("v1 acquisition")), \
                mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                                  wraps=git_pack_acquire.acquire_validated_pair_v2) as pairs, \
                mock.patch.object(git_pack, "_parse_profile",
                                  wraps=git_pack._parse_profile) as parse:
            data = self.observe()
        self.assertEqual(len(invocations), 2)
        self.assertIs(invocations[0], invocations[1])
        self.assertIs(type(invocations[0]), git_snapshot_reader.InvocationV2)
        self.assertIsNot(readers[0], readers[1])
        with self.assertRaises(KeyError):
            readers[0](self.commit)
        self.assertEqual(pairs.call_args_list, [mock.call(str(self.root), self.pack_id)] * 2)
        self.assertEqual(parse.call_count, 2)
        self.assertTrue(all(call.args[2] is git_pack._Profile.V2
                            for call in parse.call_args_list))
        self.assertEqual(self.events, ["snapshot", "context", "provider-enter",
                                       "provider-exit", "snapshot", "context"])
        self.assertEqual([count for count, _ in budgets], [22, 22])
        self.assertEqual(budgets[0][1], budgets[1][1])
        result = json.loads(data)
        self.assertEqual(result["schema"], observer.SCHEMA_V2)
        self.assertEqual(result["assurance"], observer.ASSURANCE)
        self.assertEqual(set(result), {"schema", "assurance", "attribution", "sources"})
        self.assertEqual(tuple(result["sources"]), v1.EXPECTED_PATHS)
        self.assertNotIn("scripts/test-audit-run/github_context.py", result["sources"])
        self.assertEqual(result["attribution"]["schema"], provider_attribution.SCHEMA)
        self.assertEqual(data, provider_attribution._encode(result))
        self.assertEqual(provider_attribution._encode(result["attribution"]),
                         provider_attribution.observe(self.context_reader, self.git.read))

    def test_validation_versions_and_fresh_observations(self):
        v1_data = observer.observe(str(self.root), self.pack_id, self.context_reader)
        v2_data = self.observe()
        self.assertNotEqual(v1_data, v2_data)
        self.assertEqual({**json.loads(v1_data), "schema": observer.SCHEMA_V2},
                         json.loads(v2_data))
        self.events.clear()
        with mock.patch.object(git_pack_acquire, "acquire_validated_pair_v2",
                               wraps=git_pack_acquire.acquire_validated_pair_v2) as pairs:
            observer.validate_v2(v2_data, str(self.root), self.pack_id, self.context_reader)
        self.assertEqual(pairs.call_args_list, [mock.call(str(self.root), self.pack_id)] * 2)
        self.assertEqual(self.events.count("context"), 2)
        for validate, candidate in ((observer.validate, v2_data),
                                    (observer.validate_v2, v1_data)):
            with self.assertRaises(ios_runtime.Refusal):
                validate(candidate, str(self.root), self.pack_id, self.context_reader)
        for candidate in (v2_data + b" ", b"{}", "not bytes",
                          b"x" * (provider_attribution.ENVELOPE_LIMIT + 1)):
            with self.subTest(candidate=str(candidate)[:20]), self.assertRaises(ios_runtime.Refusal):
                observer.validate_v2(candidate, str(self.root), self.pack_id, self.context_reader)
        self.context["run_id"] += 1
        with self.assertRaisesRegex(ios_runtime.Refusal, "differs from fresh"):
            observer.validate_v2(v2_data, str(self.root), self.pack_id, self.context_reader)

    def test_workflow_budgets_and_terminal_refusals(self):
        self.workflow()
        actual_sources = observer._observe_sources
        budgets = []

        def sources(root, tree, objects):
            result = actual_sources(root, tree, objects)
            budgets.append((objects.count, objects.total))
            return result

        with mock.patch.object(observer, "_observe_sources", sources):
            self.observe()
        self.assertEqual([count for count, _ in budgets], [27, 27])
        self.assertEqual(budgets[0][1], budgets[1][1])
        with mock.patch.object(provider_attribution, "OBJECT_COUNT", 26):
            with self.assertRaisesRegex(ios_runtime.Refusal, "count limit"):
                self.observe()
        with mock.patch.object(git_snapshot_reader, "OBJECT_CALL_LIMIT", 53):
            with self.assertRaises(ios_runtime.Refusal):
                self.observe()

    def test_refusals_and_interruptions(self):
        for root, pack_id in (("relative", self.pack_id), (str(self.root), None),
                              (str(self.root), "A" * 40)):
            with self.subTest(root=root, pack_id=pack_id), self.assertRaises(ios_runtime.Refusal):
                observer.observe_v2(root, pack_id, self.context_reader)
        for error in (KeyError("reader"), ValueError("reader"), OSError("reader"),
                      ios_runtime.Refusal("reader"), KeyboardInterrupt(), SystemExit()):
            expected = (type(error) if isinstance(error, (KeyboardInterrupt, SystemExit))
                        else ios_runtime.Refusal)
            with self.subTest(error=type(error)), self.assertRaises(expected):
                observer.observe_v2(str(self.root), self.pack_id, mock.Mock(side_effect=error))
        for error in (ios_runtime.Refusal("cleanup"), KeyboardInterrupt(), SystemExit()):
            self.on_exit = mock.Mock(side_effect=error)
            with self.subTest(error=type(error)), self.assertRaises(type(error)):
                self.observe()
            self.on_exit.assert_called_once()
        self.on_exit = lambda: None
        self.events.clear()
        with mock.patch.object(provider_attribution, "_provider", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.observe()
        self.assertIn("provider-exit", self.events)
        self.assertEqual(self.events.count("context"), 1)
        with mock.patch.object(observer, "_observe_sources", side_effect=SystemExit):
            with self.assertRaises(SystemExit):
                self.observe()
        reader = mock.Mock(side_effect=[self.context, KeyboardInterrupt()])
        with self.assertRaises(KeyboardInterrupt):
            observer.observe_v2(str(self.root), self.pack_id, reader)
        self.assertEqual(reader.call_count, 2)


if __name__ == "__main__":
    unittest.main()
