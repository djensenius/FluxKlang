"""Mock-only attribution tests: no native processes, tools, or source-file reads."""

from contextlib import contextmanager, ExitStack
import copy
import hashlib
import json
import os
import subprocess
import stat
from types import SimpleNamespace
import unittest
from unittest import mock

import ios_runtime as runtime
import provider_attribution as attribution
import git_pack
import test_git_pack as pack_fixture


class GitObjects:
    """Raw in-memory Git objects, including real object hashes/tree encoding."""

    def __init__(self):
        self.objects = {}
        self.requests = []

    def add(self, kind, data):
        oid = hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).hexdigest()
        self.objects[oid] = (kind, data)
        return oid

    def tree(self, entries):
        return self.add("tree", b"".join(
            mode.encode() + b" " + name.encode() + b"\0" + bytes.fromhex(oid)
            for name, (mode, oid) in sorted(entries.items())
        ))

    def commit(self, tree, parents=()):
        return self.add("commit", (
            f"tree {tree}\n" + "".join(f"parent {parent}\n" for parent in parents)
            + "author Mock <mock@example.invalid> 1 +0000\n"
            + "committer Mock <mock@example.invalid> 1 +0000\n\nfixture\n"
        ).encode())

    def read(self, oid):
        self.requests.append(oid)
        return self.objects[oid]


def provider_record():
    bundle = "/private/var/mock/iOS 27.0.simruntime"
    root = bundle + "/Contents/Resources/RuntimeRoot"
    canonical = root + "/usr/lib/libMainThreadChecker.dylib"
    return {
        "schema": "ios-provider-trusted-runtime-observation-v1",
        "xcode": {
            "developer_directory": runtime.DEVELOPER, "version": "Xcode 27.1",
            "build": "27A9275", "simulator_sdk_version": "27.1",
            "xcodebuild_path": runtime.DEVELOPER + "/usr/bin/xcodebuild",
            "xcodebuild_file_identity": list(range(8)),
            "xcodebuild_apple_anchor_check": "passed",
            "simctl_path": runtime.DEVELOPER + "/usr/bin/simctl",
            "simctl_file_identity": list(range(8)),
            "simctl_apple_anchor_check": "passed",
        },
        "runtime": {"identifier": runtime.RUNTIME, "version": "27.0", "build": "24A434",
                    "available": True, "bundle_path": bundle, "runtime_root": root},
        "checker": {
            "canonical_path": canonical,
            "accepted_paths": [canonical, canonical[len("/private"):]],
            "size": runtime.LIBRARY_SIZE, "sha256": runtime.LIBRARY_SHA256,
            "architecture": "arm64", "signature_requirement": runtime.REQUIREMENT,
            "signature_check": "passed",
        },
    }


class AttributionTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.denials = []
        for module, names in (
            (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
            (os, ("system", "popen", "fork", "forkpty", "posix_spawn", "posix_spawnp",
                  "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve",
                  "spawnvp", "spawnvpe", "execl", "execle", "execlp", "execlpe",
                  "execv", "execve", "execvp", "execvpe", "kill", "killpg")),
        ):
            for name in names:
                if hasattr(module, name):
                    self.denials.append(self.stack.enter_context(mock.patch.object(
                        module, name, side_effect=AssertionError("native operation forbidden"),
                    )))
        self.native = self.stack.enter_context(mock.patch.object(
            runtime, "_command", side_effect=AssertionError("native command forbidden"),
        ))
        self.git = GitObjects()
        self.source_bytes = {path: ("mock " + path).encode() for path in attribution.SOURCES}
        source_tree = self.git.tree({
            path.rsplit("/", 1)[1]: ("100644", self.git.add("blob", data))
            for path, data in self.source_bytes.items()
        })
        scripts_tree = self.git.tree({"test-audit-run": ("40000", source_tree)})
        workflow_tree = self.git.tree({
            "observe.yml": ("100644", self.git.add("blob", b"mock workflow")),
        })
        github_tree = self.git.tree({"workflows": ("40000", workflow_tree)})
        self.tree = self.git.tree({
            ".github": ("40000", github_tree), "scripts": ("40000", scripts_tree),
        })
        self.commit = self.git.commit(self.tree)
        self.context = {
            "repository": "owner/repo", "event_name": "push",
            "event_sha": self.commit, "event_ref": "refs/heads/main",
            "checkout_sha": self.commit, "pull_request": None,
            "workflow": {"sha": self.commit, "path": ".github/workflows/observe.yml",
                         "ref": "owner/repo/.github/workflows/observe.yml@refs/heads/main"},
            "run_id": 42, "run_attempt": 1, "job": "observation",
            "runner": {"name": "Hosted Runner 1", "environment": "github-hosted"},
            "platform": {"os": "macOS", "arch": "ARM64"},
        }
        self.record = provider_record()
        self.on_exit = lambda: None
        self.real_source = attribution._source
        self.source = self.stack.enter_context(mock.patch.object(
            attribution, "_source", side_effect=lambda path: self.source_bytes[path],
        ))

        @contextmanager
        def checker():
            yield tuple(self.record["checker"]["accepted_paths"]), self.record
            self.on_exit()

        self.checker = self.stack.enter_context(mock.patch.object(
            runtime, "provider_verified_checker", side_effect=checker,
        ))
        # Reject unexpected native/filesystem probes even if a mock boundary slips.
        for name in ("open", "stat", "lstat", "read", "fstat", "readlink", "close",
                     "lseek", "fstatvfs", "uname"):
            self.stack.enter_context(mock.patch.object(
                os, name, side_effect=AssertionError("filesystem probe forbidden"),
            ))

    def tearDown(self):
        for denial in self.denials:
            denial.assert_not_called()
        self.native.assert_not_called()

    def observe(self):
        return attribution.observe(lambda: copy.deepcopy(self.context), self.git.read)

    def test_explicit_pack_adapter_with_fresh_inputs_and_refusals(self):
        types = {"commit": 1, "tree": 2, "blob": 3, "tag": 4}
        entries = [(bytes.fromhex(oid), pack_fixture.plain(types[kind], data))
                   for oid, (kind, data) in self.git.objects.items()]
        pack, index = pack_fixture.fixture(entries)
        current = [pack, index]

        def object_reader(oid):
            # The real future caller must obtain fresh bounded input here.
            return cache.read(current[0], current[1], oid)

        cache = git_pack.BoundedReader()
        with mock.patch.object(git_pack, "_parse", wraps=git_pack._parse) as parse:
            data = attribution.observe(lambda: copy.deepcopy(self.context), object_reader)
            self.assertEqual(parse.call_count, 1)
            cache = git_pack.BoundedReader()
            attribution.validate(data, lambda: copy.deepcopy(self.context), object_reader)
            self.assertEqual(parse.call_count, 2)

        # A corrupt second observation must not fall back to the first cache.
        cache = git_pack.BoundedReader()
        self.on_exit = lambda: current.__setitem__(0, pack[:-1] + b"x")
        with self.assertRaisesRegex(runtime.Refusal, "Git object observation unavailable"):
            attribution.observe(lambda: copy.deepcopy(self.context), object_reader)

        # An independently valid pack with a missing requested object also
        # becomes Refusal through the existing envelope's KeyError boundary.
        current[:] = pack_fixture.fixture(entries[:-1])
        cache = git_pack.BoundedReader()
        with self.assertRaisesRegex(runtime.Refusal, "Git object observation unavailable"):
            attribution.observe(lambda: copy.deepcopy(self.context), object_reader)

    def test_equivalent_repacked_objects_are_observations_not_pack_custody(self):
        types = {"commit": 1, "tree": 2, "blob": 3, "tag": 4}
        entries = [(bytes.fromhex(oid), pack_fixture.plain(types[kind], data))
                   for oid, (kind, data) in self.git.objects.items()]
        first = pack_fixture.fixture(entries)
        second = pack_fixture.fixture(list(reversed(entries)))
        self.assertNotEqual(first[0], second[0])
        self.assertNotEqual(first[1], second[1])
        expected = self.observe()
        current = [first]
        seen = []
        cache = git_pack.BoundedReader()

        def object_reader(oid):
            pair = current[0]
            seen.append(pair)
            return cache.read(*pair, oid)

        self.on_exit = lambda: current.__setitem__(0, second)
        with mock.patch.object(git_pack, "_parse", wraps=git_pack._parse) as parse:
            actual = attribution.observe(lambda: copy.deepcopy(self.context), object_reader)
        self.assertEqual(actual, expected)
        self.assertEqual(parse.call_args_list, [mock.call(*first), mock.call(*second)])
        self.assertGreater(seen.count(first), 1)
        self.assertGreater(seen.count(second), 1)

    def validate(self, data):
        attribution.validate(data, lambda: copy.deepcopy(self.context), self.git.read)

    def pr(self, parents=None):
        base = self.git.commit(self.tree, ["1" * 40])
        head = self.git.commit(self.tree, [base])
        merge = self.git.commit(self.tree, parents if parents is not None else [base, head])
        self.context.update(
            event_name="pull_request", event_ref="refs/pull/12/merge",
            event_sha=merge, checkout_sha=merge,
            pull_request={"number": 12, "head_sha": head, "base_sha": base},
        )
        return base, head, merge

    def test_push_closed_record_and_fresh_validation(self):
        data = self.observe()
        result = json.loads(data)
        self.assertEqual(set(result), {"schema", "assurance", "context", "checkout",
                                      "workflow", "executing_sources", "provider_runtime"})
        self.assertEqual(result["assurance"], attribution.ASSURANCE)
        self.assertEqual(result["checkout"], {
            "commit": self.commit, "tree": self.tree, "parents": [], "kind": "event-commit",
        })
        self.assertEqual(set(result["executing_sources"]), set(attribution.SOURCES))
        for path, item in result["executing_sources"].items():
            self.assertEqual(item["sha256"], hashlib.sha256(self.source_bytes[path]).hexdigest())
        self.assertEqual(result["workflow"]["status"], "observed")
        self.validate(data)
        self.assertEqual(self.checker.call_count, 2)
        self.assertEqual({call.args[0] for call in self.source.call_args_list},
                         set(attribution.SOURCES))

    def test_dispatch_is_not_a_pr_and_workflow_can_be_explicitly_unavailable(self):
        self.context.update(event_name="workflow_dispatch", event_ref="refs/tags/v1",
                            workflow=None)
        result = json.loads(self.observe())
        self.assertIsNone(result["context"]["pull_request"])
        self.assertEqual(result["workflow"], {
            "status": "unavailable", "sha": None, "ref": None, "path": None, "blob": None,
        })

    def test_pr_is_exact_synthetic_merge_not_head_or_base(self):
        base, head, merge = self.pr()
        result = json.loads(self.observe())
        self.assertEqual(result["checkout"]["kind"], "pr-synthetic-merge")
        self.assertEqual(result["checkout"]["parents"], [base, head])
        self.assertEqual(result["context"]["event_sha"], merge)
        self.assertEqual(result["context"]["pull_request"]["head_sha"], head)

    def test_workflow_sha_is_separate_and_its_blob_is_verified(self):
        workflow_commit = self.git.commit(self.tree, ["7" * 40])
        self.context["workflow"]["sha"] = workflow_commit
        result = json.loads(self.observe())
        self.assertEqual(result["workflow"]["sha"], workflow_commit)
        self.assertEqual(result["checkout"]["commit"], self.commit)
        blob = result["workflow"]["blob"]
        self.git.objects[blob] = ("blob", b"tampered")
        with self.assertRaisesRegex(runtime.Refusal, "identity mismatch"):
            self.observe()

    def test_pr_ref_and_parent_mismatches(self):
        self.pr()
        correct = copy.deepcopy(self.context)
        for parents in ([], ["1" * 40], ["1" * 40, "2" * 40],
                        [correct["pull_request"]["head_sha"], correct["pull_request"]["base_sha"]]):
            with self.subTest(parents=parents):
                self.context = copy.deepcopy(correct)
                merge = self.git.commit(self.tree, parents)
                self.context.update(event_sha=merge, checkout_sha=merge)
                with self.assertRaises(runtime.Refusal):
                    self.observe()
        self.context = correct
        self.context["event_ref"] = "refs/pull/12/head"
        with self.assertRaises(runtime.Refusal):
            self.observe()

    def test_pr_missing_malformed_and_ambiguous_identity(self):
        self.pr()
        original = copy.deepcopy(self.context)
        for mutation in (
            lambda c: c.update(pull_request=None),
            lambda c: c["pull_request"].pop("base_sha"),
            lambda c: c["pull_request"].update(number=True),
            lambda c: c["pull_request"].update(number=13),
            lambda c: c["pull_request"].update(head_sha="bad\nidentity"),
            lambda c: c["pull_request"].update(head_sha=c["pull_request"]["base_sha"]),
            lambda c: c["pull_request"].update(head_sha=c["checkout_sha"]),
        ):
            with self.subTest(mutation=mutation):
                self.context = copy.deepcopy(original)
                mutation(self.context)
                with self.assertRaises(runtime.Refusal):
                    self.observe()

    def test_missing_extra_malformed_hostile_and_wrong_context(self):
        original = copy.deepcopy(self.context)
        mutations = [
            lambda c: c.pop("run_id"),
            lambda c: c.update(secret="not allowed"),
            lambda c: c.update(event_name="pull_request_target"),
            lambda c: c.update(event_sha="A" * 40),
            lambda c: c.update(checkout_sha="1" * 40),
            lambda c: c.update(run_attempt=True),
            lambda c: c.update(run_id=0),
            lambda c: c.update(run_attempt=2**63),
            lambda c: c.update(job="x\ninjected"),
            lambda c: c.update(job="$(command)"),
            lambda c: c.update(repository="owner/repo\n"),
            lambda c: c.update(event_ref="refs/heads/../main"),
            lambda c: c.update(event_ref="refs/heads/" + "a" * 257),
            lambda c: c["runner"].update(name="host\rspoof"),
            lambda c: c["runner"].update(environment="self-hosted"),
            lambda c: c["platform"].update(arch="X64"),
            lambda c: c.update(pull_request={"number": 1}),
            lambda c: c["workflow"].update(ref="other/repo/w.yml@refs/heads/main"),
            lambda c: c["workflow"].update(path="../execute.sh"),
            lambda c: c["workflow"].update(sha=None),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.context = copy.deepcopy(original)
                mutation(self.context)
                with self.assertRaises(runtime.Refusal):
                    self.observe()
        self.checker.assert_not_called()

    def test_tampered_noncanonical_and_oversized_output(self):
        data = self.observe()
        for bad in (data + b"\n", data.replace(b'"run_id":42', b'"run_id":43'),
                    b'{"schema":"forged","schema":"duplicate"}',
                    b"\xff", b"x" * (attribution.ENVELOPE_LIMIT + 1), "not bytes"):
            with self.subTest(bad=str(bad)[:80]):
                with self.assertRaises(runtime.Refusal):
                    self.validate(bad)

    def test_changed_job_source_workflow_or_provider_rejects_old_output(self):
        for field in ("job", "source", "workflow", "provider"):
            with self.subTest(field=field):
                data = self.observe()
                if field == "job":
                    self.context["run_attempt"] += 1
                elif field == "source":
                    self.source_bytes[attribution.SOURCES[0]] += b"changed"
                elif field == "workflow":
                    self.context["workflow"] = None
                else:
                    self.record["xcode"]["simctl_file_identity"][0] += 1
                with self.assertRaises(runtime.Refusal):
                    self.validate(data)
                if field == "source":
                    self.source_bytes[attribution.SOURCES[0]] = (
                        "mock " + attribution.SOURCES[0]).encode()

    def test_between_snapshot_mutation_refuses_without_returning_bytes(self):
        for field in ("context", "source", "provider"):
            with self.subTest(field=field):
                if field == "context":
                    self.on_exit = lambda: self.context.update(run_attempt=5)
                elif field == "source":
                    self.on_exit = lambda: self.source_bytes.update(
                        {attribution.SOURCES[0]: b"replacement"})
                else:
                    self.on_exit = lambda: self.record["checker"].update(signature_check="failed")
                with self.assertRaises(runtime.Refusal):
                    self.observe()
                self.context["run_attempt"] = 1
                self.source_bytes[attribution.SOURCES[0]] = (
                    "mock " + attribution.SOURCES[0]).encode()
                self.record = provider_record()

    def test_malformed_provider_closed_shape_paths_counts_and_types(self):
        original = provider_record()
        mutations = [
            lambda r: r.update(extra=True),
            lambda r: r["runtime"].update(bundle_path="/private/var/evil\n/iOS 27.0.simruntime"),
            lambda r: r["runtime"].update(available=1),
            lambda r: r["checker"].update(size=True),
            lambda r: r["checker"].update(accepted_paths=["unexpected"] * 100),
            lambda r: r["xcode"].update(simctl_file_identity=[0] * 9),
            lambda r: r["xcode"].update(simctl_file_identity=[True] * 8),
            lambda r: r["xcode"].update(simctl_path="/candidate/bin/simctl"),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.record = copy.deepcopy(original)
                mutation(self.record)
                with self.assertRaises(runtime.Refusal):
                    self.observe()

    def test_git_object_identity_kind_and_size_are_verified(self):
        for value in (("commit", b"forged"), ("blob", b"wrong kind"),
                      ("commit", b"x" * (attribution.OBJECT_LIMIT + 1))):
            with self.subTest(value=value[0:1]):
                saved = self.git.objects[self.commit]
                self.git.objects[self.commit] = value
                with self.assertRaises(runtime.Refusal):
                    self.observe()
                self.git.objects[self.commit] = saved

    def test_missing_git_object_refuses(self):
        del self.git.objects[self.commit]
        with self.assertRaisesRegex(runtime.Refusal, "unavailable"):
            self.observe()

    def test_git_tree_duplicate_symlink_missing_and_count_refusals(self):
        blob = self.git.add("blob", b"data")
        entry = b"100644 file\0" + bytes.fromhex(blob)
        for data in (entry + entry, b"120000 file\0" + bytes.fromhex(blob),
                     b"100644 file\0short", b"100644 bad\nname\0" + bytes.fromhex(blob), b"",
                     b"".join(b"100644 " + str(i).encode() + b"\0" + bytes.fromhex(blob)
                              for i in range(1025))):
            with self.subTest(size=len(data)):
                tree = self.git.add("tree", data)
                with self.assertRaises(runtime.Refusal):
                    attribution._Objects(self.git.read).file(tree, "file")

    def test_grouped_sources_match_sequential_with_shared_tree_reads(self):
        paths = tuple(reversed(attribution.SOURCES))
        grouped_objects = attribution._Objects(self.git.read)
        grouped = grouped_objects.files(self.tree, paths)
        grouped_requests = self.git.requests[:]
        self.git.requests.clear()
        sequential_objects = attribution._Objects(self.git.read)
        sequential = {path: sequential_objects.file(self.tree, path) for path in paths}
        self.assertEqual(grouped, sequential)
        self.assertEqual(list(grouped), sorted(paths))
        self.assertEqual(len(grouped_requests), 5)  # three trees, two blobs
        self.assertEqual(len(self.git.requests), 8)
        self.assertEqual(grouped_objects.count, 5)
        self.assertEqual(sequential_objects.count, 8)
        # A new call re-reads the trees and each blob, including identical blob IDs.
        blob = self.git.add("blob", b"same")
        root = self.git.tree({"a": ("100644", blob), "b": ("100755", blob)})
        self.git.requests.clear()
        objects = attribution._Objects(self.git.read)
        self.assertEqual(objects.files(root, ["b", "a"]),
                         {"a": (blob, b"same"), "b": (blob, b"same")})
        self.assertEqual(self.git.requests, [root, blob, blob])
        self.git.objects[blob] = ("blob", b"changed")
        with self.assertRaisesRegex(runtime.Refusal, "identity mismatch"):
            objects.files(root, ["a", "b"])
        self.assertEqual(self.git.requests, [root, blob, blob, root, blob])

    def test_grouped_sources_reject_bad_paths_before_reading(self):
        bad_inputs = (
            None, "file", (), [], ["a"] * (attribution.OBJECT_COUNT + 1),
            ["a", "a"], ["a", "dir/b"], ["dir/a", "other/b"],
            ["/a"], ["a/"], ["a//b"], ["./a"], ["a/../b"],
            ["a\\b"], ["a\nb"], ["é"], [True], ["x" * 256],
            ["/".join(["a"] * (attribution.OBJECT_COUNT + 1))],
            ["/".join(["x" * 255] * 17)],
        )
        for paths in bad_inputs:
            with self.subTest(paths=str(paths)[:80]):
                self.git.requests.clear()
                with self.assertRaises(runtime.Refusal):
                    attribution._Objects(self.git.read).files(self.tree, paths)
                self.assertEqual(self.git.requests, [])

    def test_grouped_sources_validate_all_tree_entries_and_modes(self):
        blob = self.git.add("blob", b"data")
        entry = b"100644 file\0" + bytes.fromhex(blob)
        invalid = (
            (entry + entry, "unsupported/ambiguous"),
            (entry + b"120000 other\0" + bytes.fromhex(blob), "unsupported/ambiguous"),
            (entry + b"100644 other\0short", "malformed Git tree"),
            (entry + b"100644 bad\nname\0" + bytes.fromhex(blob), "unsupported/ambiguous"),
            (b"".join(b"100644 " + str(i).encode() + b"\0" + bytes.fromhex(blob)
                      for i in range(1025)), "entry count"),
        )
        for data, message in invalid:
            with self.subTest(message=message):
                tree = self.git.add("tree", data)
                with self.assertRaisesRegex(runtime.Refusal, message):
                    attribution._Objects(self.git.read).files(tree, ["file"])
        duplicate_parent = self.git.add("tree", entry + entry)
        with self.assertRaisesRegex(runtime.Refusal, "unsupported/ambiguous"):
            attribution._Objects(self.git.read).files(duplicate_parent, ["file/child"])
        directory = self.git.tree({"file": ("100644", blob)})
        root = self.git.tree({"dir": ("40000", directory), "regular": ("100644", blob)})
        for paths, message in (
            (["missing/file"], "unavailable"),
            (["regular/file"], "regular file"),
            (["dir/missing"], "unavailable"),
            (["dir"], "regular file"),
            (["dir/file", "dir/missing"], "unavailable"),
        ):
            with self.subTest(paths=paths):
                with self.assertRaisesRegex(runtime.Refusal, message):
                    attribution._Objects(self.git.read).files(root, paths)

    def test_grouped_sources_object_identity_and_budgets(self):
        blob = self.git.add("blob", b"x" * attribution.OBJECT_LIMIT)
        root = self.git.tree({str(i): ("100644", blob) for i in range(5)})
        with self.assertRaisesRegex(runtime.Refusal, "total size"):
            attribution._Objects(self.git.read).files(root, [str(i) for i in range(5)])
        small = self.git.add("blob", b"")
        directory = self.git.tree({str(i): ("100644", small) for i in range(31)})
        root = self.git.tree({"dir": ("40000", directory)})
        with self.assertRaisesRegex(runtime.Refusal, "count limit"):
            attribution._Objects(self.git.read).files(
                root, [f"dir/{i}" for i in range(31)])
        root = self.git.tree({"file": ("100644", small)})
        for oid, replacement, message in (
            (root, ("tree", b"tampered"), "identity mismatch"),
            (small, ("blob", b"tampered"), "identity mismatch"),
            (small, ("tree", b""), "shape/size"),
            (small, ("blob", b"x" * (attribution.OBJECT_LIMIT + 1)), "shape/size"),
        ):
            with self.subTest(message=message):
                saved = self.git.objects[oid]
                self.git.objects[oid] = replacement
                with self.assertRaisesRegex(runtime.Refusal, message):
                    attribution._Objects(self.git.read).files(root, ["file"])
                self.git.objects[oid] = saved
        with self.assertRaises(runtime.Refusal):
            attribution._Objects(self.git.read).files("bad", ["file"])
        del self.git.objects[small]
        with self.assertRaisesRegex(runtime.Refusal, "observation unavailable"):
            attribution._Objects(self.git.read).files(root, ["file"])

    def test_observe_and_validate_keep_sequential_source_call_path(self):
        with mock.patch.object(attribution._Objects, "files",
                               side_effect=AssertionError("grouped path not integrated")), \
                mock.patch.object(attribution._Objects, "file",
                                  autospec=True, side_effect=attribution._Objects.file) as file:
            data = self.observe()
            self.validate(data)
        self.assertEqual([call.args[2] for call in file.call_args_list],
                         (list(attribution.SOURCES) + [self.context["workflow"]["path"]]) * 4)

    def test_git_commit_ambiguous_headers_and_parent_count(self):
        for data in (b"not a commit", f"tree {self.tree}\nparent bad\n\nx".encode(),
                     (f"tree {self.tree}\n" + "parent " + "1" * 40 + "\n"
                      + "author mock\nparent " + "2" * 40 + "\n\nx").encode(),
                     (f"tree {self.tree}\n" + "".join(
                         f"parent {i:040x}\n" for i in range(3)) + "\nx").encode()):
            with self.subTest(data=data[:60]):
                commit = self.git.add("commit", data)
                with self.assertRaises(runtime.Refusal):
                    attribution._Objects(self.git.read).commit(commit)

    def test_object_total_count_and_byte_budgets(self):
        blob = self.git.add("blob", b"x" * attribution.OBJECT_LIMIT)
        objects = attribution._Objects(self.git.read)
        for _ in range(4):
            objects.get(blob, "blob")
        with self.assertRaisesRegex(runtime.Refusal, "total size"):
            objects.get(blob, "blob")
        empty = self.git.add("blob", b"")
        objects = attribution._Objects(self.git.read)
        for _ in range(attribution.OBJECT_COUNT):
            objects.get(empty, "blob")
        with self.assertRaisesRegex(runtime.Refusal, "count"):
            objects.get(empty, "blob")

    def test_runtime_refusal_propagates_and_cannot_publish(self):
        self.checker.side_effect = runtime.Refusal("runtime changed")
        with self.assertRaisesRegex(runtime.Refusal, "runtime changed"):
            self.observe()

    def test_fixed_source_reader_uses_only_bounded_read_only_operations(self):
        with self.assertRaisesRegex(runtime.Refusal, "allowlist"):
            self.real_source("../../candidate-command")
        info = SimpleNamespace(
            st_dev=1, st_ino=2, st_mode=stat.S_IFREG | 0o644, st_uid=501,
            st_gid=20, st_size=4, st_mtime_ns=5, st_ctime_ns=6,
        )
        with mock.patch.object(attribution.Path, "is_symlink", return_value=False), \
                mock.patch.object(os, "open", return_value=17) as opened, \
                mock.patch.object(os, "fstat", return_value=info), \
                mock.patch.object(os, "stat", return_value=info), \
                mock.patch.object(os, "read", side_effect=[b"mock", b""]) as read, \
                mock.patch.object(os, "close") as close:
            self.assertEqual(self.real_source(attribution.SOURCES[0]), b"mock")
        self.assertEqual(opened.call_args.args[1],
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        self.assertTrue(str(opened.call_args.args[0]).endswith(attribution.SOURCES[0]))
        self.assertTrue(all(0 < call.args[1] <= 65536 for call in read.call_args_list))
        close.assert_called_once_with(17)

    def test_fixed_source_reader_refuses_links_special_files_size_and_replacement(self):
        good = SimpleNamespace(
            st_dev=1, st_ino=2, st_mode=stat.S_IFREG | 0o644, st_uid=501,
            st_gid=20, st_size=4, st_mtime_ns=5, st_ctime_ns=6,
        )
        for condition in ("link", "fifo", "size", "replacement", "short", "overflow"):
            with self.subTest(condition=condition):
                info = copy.copy(good)
                if condition == "fifo":
                    info.st_mode = stat.S_IFIFO | 0o600
                if condition == "size":
                    info.st_size = attribution.SOURCE_LIMIT + 1
                after = copy.copy(info)
                if condition == "replacement":
                    after.st_ino += 1
                chunks = [b"mock", b""]
                if condition == "short":
                    chunks = [b"", b""]
                if condition == "overflow":
                    chunks = [b"x" * 65536, b"x" * 65536, b"x"]
                with mock.patch.object(attribution.Path, "is_symlink",
                                       return_value=condition == "link"), \
                        mock.patch.object(os, "open", return_value=17), \
                        mock.patch.object(os, "fstat", side_effect=[info, after]), \
                        mock.patch.object(os, "stat", return_value=info), \
                        mock.patch.object(os, "read", side_effect=chunks), \
                        mock.patch.object(os, "close"):
                    with self.assertRaises(runtime.Refusal):
                        self.real_source(attribution.SOURCES[0])


if __name__ == "__main__":
    unittest.main()
