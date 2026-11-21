"""Explicit GitHub context fixtures; no event files, environment or native tools."""

from contextlib import contextmanager
import copy
import json
import os
import subprocess
import unittest
from unittest import mock

import github_context as context
import ios_runtime as runtime
import provider_attribution as attribution
from test_provider_attribution import GitObjects, provider_record


class GitHubContextTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.env = {
            "GITHUB_REPOSITORY": "owner/repo", "GITHUB_EVENT_NAME": "push",
            "GITHUB_SHA": self.sha, "GITHUB_REF": "refs/heads/main",
            "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_JOB": "observation", "RUNNER_NAME": "Hosted Runner 1",
            "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS",
            "RUNNER_ARCH": "ARM64",
            "GITHUB_WORKFLOW_REF": "owner/repo/.github/workflows/observe.yml@refs/heads/main",
            "GITHUB_WORKFLOW_SHA": "b" * 40,
        }
        self.event = {"repository": {"full_name": "owner/repo"},
                      "ref": "refs/heads/main", "after": self.sha,
                      "other_provider_fields": {"allowed": [1, True, None]}}

    def read(self, *, checkout=None, payload=None):
        return context.read_context(
            self.env, json.dumps(self.event).encode() if payload is None else payload,
            self.sha if checkout is None else checkout,
        )

    def pr(self):
        self.env.update(GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/12/merge")
        self.event = {
            "repository": {"full_name": "owner/repo"},
            "number": 12,
            "pull_request": {
                "number": 12, "head": {"sha": "c" * 40},
                "base": {"sha": "d" * 40, "repo": {"full_name": "owner/repo"}},
                "merge_commit_sha": "e" * 40,
            },
        }

    def test_push_exact_projection_and_no_implicit_io(self):
        with mock.patch("builtins.open", side_effect=AssertionError("file read")), \
                mock.patch.object(os, "getenv", side_effect=AssertionError("environment read")), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process")):
            result = self.read()
        self.assertEqual(result, {
            "repository": "owner/repo", "event_name": "push", "event_sha": self.sha,
            "event_ref": "refs/heads/main", "checkout_sha": self.sha, "pull_request": None,
            "workflow": {"sha": "b" * 40,
                         "ref": self.env["GITHUB_WORKFLOW_REF"],
                         "path": ".github/workflows/observe.yml"},
            "run_id": 42, "run_attempt": 1, "job": "observation",
            "runner": {"name": "Hosted Runner 1", "environment": "github-hosted"},
            "platform": {"os": "macOS", "arch": "ARM64"},
        })

    def test_dispatch_and_explicitly_unavailable_workflow(self):
        self.env.update(GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/tags/v1",
                        GITHUB_WORKFLOW_REF=None, GITHUB_WORKFLOW_SHA=None)
        self.event = {"repository": {"full_name": "owner/repo"}, "ref": "refs/tags/v1"}
        result = self.read()
        self.assertIsNone(result["workflow"])
        self.assertIsNone(result["pull_request"])
        self.event["ref"] = "refs/tags/other"
        with self.assertRaises(runtime.Refusal):
            self.read()
        self.event["ref"] = "refs/tags/v1"
        self.event["pull_request"] = {"number": 12}
        with self.assertRaises(runtime.Refusal):
            self.read()

    def test_pr_merge_is_not_head_base_or_payload_merge_commit(self):
        self.pr()
        result = self.read()
        self.assertEqual(result["event_sha"], self.sha)
        self.assertEqual(result["checkout_sha"], self.sha)
        self.assertEqual(result["pull_request"],
                         {"number": 12, "head_sha": "c" * 40, "base_sha": "d" * 40})
        self.assertEqual(result["workflow"]["sha"], "b" * 40)

    def test_missing_extra_and_malformed_environment(self):
        original = copy.deepcopy(self.env)
        mutations = (
            lambda e: e.pop("GITHUB_JOB"),
            lambda e: e.update(SECRET="not accepted"),
            lambda e: e.update(GITHUB_SHA=None),
            lambda e: e.update(GITHUB_EVENT_NAME="pull_request_target"),
            lambda e: e.update(GITHUB_JOB="job\nbad"),
            lambda e: e.update(RUNNER_NAME="x" * (context.ENV_VALUE_LIMIT + 1)),
            lambda e: e.update(RUNNER_ENVIRONMENT="self-hosted"),
            lambda e: e.update(RUNNER_ARCH="X64"),
            lambda e: e.update(GITHUB_REF="refs/heads/../bad"),
            lambda e: e.update(GITHUB_SHA="A" * 40),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.env = copy.deepcopy(original)
                mutation(self.env)
                with self.assertRaises(runtime.Refusal):
                    self.read()
        with self.assertRaises(runtime.Refusal):
            context.read_context([], b"{}", self.sha)

    def test_integer_edges_and_types(self):
        for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
            for value in ("0", "01", "-1", "+1", " 1", "1\n", "١", "9223372036854775808",
                          "9" * 100, 1, True):
                with self.subTest(key=key, value=value):
                    old = self.env[key]
                    self.env[key] = value
                    with self.assertRaises(runtime.Refusal):
                        self.read()
                    self.env[key] = old
            self.env[key] = "9223372036854775807"
            self.assertEqual(self.read()["run_id" if key.endswith("ID") else "run_attempt"],
                             2**63 - 1)

    def test_event_missing_conflicting_and_bad_types(self):
        original = copy.deepcopy(self.event)
        mutations = (
            lambda e: e.pop("repository"),
            lambda e: e["repository"].update(full_name="other/repo"),
            lambda e: e.pop("after"),
            lambda e: e.update(after="b" * 40),
            lambda e: e.update(ref="refs/heads/other"),
            lambda e: e.update(repository=[]),
            lambda e: e.update(pull_request={"number": 12}),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.event = copy.deepcopy(original)
                mutation(self.event)
                with self.assertRaises(runtime.Refusal):
                    self.read()
        with self.assertRaises(runtime.Refusal):
            self.read(checkout="b" * 40)

    def test_pr_conflicts_missing_and_types(self):
        self.pr()
        original = copy.deepcopy(self.event)
        mutations = (
            lambda e: e.pop("number"),
            lambda e: e.update(number=True),
            lambda e: e.update(number=2**63),
            lambda e: e["pull_request"].update(number=True),
            lambda e: e["pull_request"].update(number=13),
            lambda e: e["pull_request"]["base"]["repo"].update(full_name="other/repo"),
            lambda e: e["pull_request"]["head"].pop("sha"),
            lambda e: e["pull_request"]["head"].update(sha=self.sha),
            lambda e: e["pull_request"]["base"].update(sha="c" * 40),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.event = copy.deepcopy(original)
                mutation(self.event)
                with self.assertRaises(runtime.Refusal):
                    self.read()
        self.event = original
        self.env["GITHUB_REF"] = "refs/pull/12/head"
        with self.assertRaises(runtime.Refusal):
            self.read()

    def test_workflow_pair_and_identity_refusals(self):
        original = copy.deepcopy(self.env)
        mutations = (
            lambda e: e.update(GITHUB_WORKFLOW_SHA=None),
            lambda e: e.update(GITHUB_WORKFLOW_REF=None),
            lambda e: e.update(GITHUB_WORKFLOW_SHA="invalid"),
            lambda e: e.update(GITHUB_WORKFLOW_REF="other/repo/.github/workflows/a.yml@refs/heads/main"),
            lambda e: e.update(GITHUB_WORKFLOW_REF="owner/repo/../a.yml@refs/heads/main"),
            lambda e: e.update(GITHUB_WORKFLOW_REF="owner/repo/.github/workflows/a.yml@refs/heads/../x"),
            lambda e: e.update(GITHUB_WORKFLOW_REF="owner/repo/.github/workflows/a.yml"),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.env = copy.deepcopy(original)
                mutation(self.env)
                with self.assertRaises(runtime.Refusal):
                    self.read()

    def test_payload_bounds_duplicate_json_invalid_numbers_and_encoding(self):
        bad = (
            b"", b"x" * (context.EVENT_LIMIT + 1), "{}", b"\xff", b"\xef\xbb\xbf{}",
            b"[]", b'{"a":1,"a":2}', b'{"x":{"a":1,"a":2}}',
            b'{"x":NaN}', b'{"x":Infinity}', b'{"x":1e9999}',
            b'{"x":' + b"9" * 33 + b"}",
            b"[" * 2000 + b"0" + b"]" * 2000,
            b'{"repository":',
        )
        for payload in bad:
            with self.subTest(payload=str(payload)[:80]):
                with self.assertRaises(runtime.Refusal):
                    self.read(payload=payload)

    def test_envelope_uses_fresh_context_and_git_parent_check(self):
        git = GitObjects()
        source = {path: ("source " + path).encode() for path in attribution.SOURCES}
        leaf = git.tree({path.rsplit("/", 1)[1]: ("100644", git.add("blob", data))
                         for path, data in source.items()})
        tree = git.tree({"scripts": ("40000", git.tree({"test-audit-run": ("40000", leaf)}))})
        base = git.commit(tree)
        head = git.commit(tree, [base])
        merge = git.commit(tree, [base, head])
        self.pr()
        self.sha = merge
        self.env.update(GITHUB_SHA=merge, GITHUB_WORKFLOW_REF=None, GITHUB_WORKFLOW_SHA=None)
        self.event["pull_request"]["base"]["sha"] = base
        self.event["pull_request"]["head"]["sha"] = head
        record = provider_record()

        @contextmanager
        def checker():
            yield tuple(record["checker"]["accepted_paths"]), record

        def observe():
            return attribution.observe(lambda: self.read(), git.read)

        with mock.patch.object(attribution, "_source", side_effect=lambda path: source[path]), \
                mock.patch.object(runtime, "provider_verified_checker", side_effect=checker):
            self.assertEqual(json.loads(observe())["checkout"]["parents"], [base, head])
            self.event["pull_request"]["base"]["sha"] = "f" * 40
            with self.assertRaisesRegex(runtime.Refusal, "parents"):
                observe()

    def test_envelope_refuses_context_changed_between_snapshots(self):
        git = GitObjects()
        source = {path: ("source " + path).encode() for path in attribution.SOURCES}
        leaf = git.tree({path.rsplit("/", 1)[1]: ("100644", git.add("blob", data))
                         for path, data in source.items()})
        tree = git.tree({"scripts": ("40000", git.tree({"test-audit-run": ("40000", leaf)}))})
        self.sha = git.commit(tree)
        self.env.update(GITHUB_SHA=self.sha, GITHUB_WORKFLOW_REF=None, GITHUB_WORKFLOW_SHA=None)
        self.event["after"] = self.sha
        record = provider_record()

        @contextmanager
        def checker():
            yield tuple(record["checker"]["accepted_paths"]), record
            self.env["GITHUB_RUN_ATTEMPT"] = "2"

        with mock.patch.object(attribution, "_source", side_effect=lambda path: source[path]), \
                mock.patch.object(runtime, "provider_verified_checker", side_effect=checker):
            with self.assertRaisesRegex(runtime.Refusal, "observation changed"):
                attribution.observe(lambda: self.read(), git.read)


if __name__ == "__main__":
    unittest.main()
