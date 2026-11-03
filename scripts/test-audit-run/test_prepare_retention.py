"""Opt-in retention-request metadata fixtures; no native execution or results."""

import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

import prepare
from test_prepare import FIXTURE as MAC_FIXTURE, RUN_ID, set_field, sha256
from test_prepare_ios import FIXTURE as IOS_FIXTURE


# Reuse independent specimen literals, never implementation profile definitions.
CASES = (
    {
        "profile": "mac-isolated-unit-retention-request-v1",
        "old_profile": "mac-isolated-unit",
        "fixture": MAC_FIXTURE,
        "targets": ["FluxKlangMacTests"],
        "uuid_paths": [
            ("FluxKlangMacTests", "EnvironmentVariables", "FLUXKLANG_AUDIT_RUN_ID"),
        ],
        "lifetime_paths": [
            ("FluxKlangMacTests", "SystemAttachmentLifetime"),
            ("FluxKlangMacTests", "UserAttachmentLifetime"),
        ],
    },
    {
        "profile": "ios-simulator-isolated-unit-ui-retention-request-v1",
        "old_profile": "ios-simulator-isolated-unit-ui-v1",
        "fixture": IOS_FIXTURE,
        "targets": ["FluxKlangTests", "FluxKlangUITests"],
        "uuid_paths": [
            ("FluxKlangTests", "EnvironmentVariables", "FLUXKLANG_AUDIT_RUN_ID"),
            ("FluxKlangUITests", "EnvironmentVariables", "FLUXKLANG_AUDIT_RUN_ID"),
            ("FluxKlangUITests", "UITargetAppEnvironmentVariables", "FLUXKLANG_AUDIT_RUN_ID"),
        ],
        "lifetime_paths": [
            ("FluxKlangTests", "SystemAttachmentLifetime"),
            ("FluxKlangTests", "UserAttachmentLifetime"),
            ("FluxKlangUITests", "SystemAttachmentLifetime"),
            ("FluxKlangUITests", "UserAttachmentLifetime"),
        ],
    },
)
SCRIPT = Path(__file__).with_name("prepare.py").resolve()
MISSING = object()


def expected_policy(case):
    return {
        "identifier": "request-system-and-user-keepAlways-v1",
        "targets": {
            target: {
                "SystemAttachmentLifetime": "keepAlways",
                "UserAttachmentLifetime": "keepAlways",
            } for target in case["targets"]
        },
    }


def expected_changes(case, run_id, retention=True):
    changes = {path: run_id for path in case["uuid_paths"]}
    if retention:
        changes.update({path: "keepAlways" for path in case["lifetime_paths"]})
    return changes


def expected_output(case, run_id, retention=True):
    value = copy.deepcopy(case["fixture"])
    for path, replacement in expected_changes(case, run_id, retention).items():
        set_field(value, path, replacement)
    return value


def leaves(value, path=()):
    if isinstance(value, dict) and value:
        return {p: v for key, child in value.items()
                for p, v in leaves(child, (*path, key)).items()}
    if isinstance(value, list) and value:
        return {p: v for index, child in enumerate(value)
                for p, v in leaves(child, (*path, index)).items()}
    return {path: (type(value), value)}


def change(value, path, replacement):
    if replacement is MISSING:
        parent = value
        for key in path[:-1]:
            parent = parent[key]
        del parent[path[-1]]
    else:
        set_field(value, path, replacement)


class RetentionPreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="retention-request-preparer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def source(self, case):
        source = self.root / (case["old_profile"] + ".xctestrun")
        source.write_bytes(plistlib.dumps(case["fixture"], sort_keys=False))
        return source, sha256(source.read_bytes())

    def snapshot(self, directories=False):
        result = {}
        for path in (self.root, *self.root.rglob("*")):
            if path.is_symlink():
                content = path.readlink()
            elif path.is_dir():
                if not directories:
                    continue
                content = None
            else:
                content = path.read_bytes()
            stat = path.lstat()
            result[str(path.relative_to(self.root))] = (
                content, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_mode, stat.st_ino,
            )
        return result

    def expected_record(self, case, source, pin, run_id, data, retention=True):
        output = source.with_name(f"{source.stem}.audit-run-{run_id}.xctestrun")
        record = {
            "schema_version": 2 if retention else 1,
            "profile": case["profile"] if retention else case["old_profile"],
            "qualification": "partial-regression",
            "run_id": run_id,
            "targets": case["targets"],
            "input": {"path": str(source), "sha256": pin},
            "output": {"path": str(output), "sha256": sha256(data)},
            "intent_path": str(output.with_suffix(".intent.json")),
        }
        if retention:
            record["attachment_policy"] = expected_policy(case)
        return record

    def assert_validation(self, source, pin, profile, record, refusal=None):
        before = self.snapshot(directories=True)
        with mock.patch.object(prepare.uuid, "uuid4", side_effect=AssertionError("repair")):
            args = (source, pin, profile, record["output"]["path"], record["intent_path"])
            if refusal:
                with self.assertRaisesRegex(prepare.Refusal, refusal):
                    prepare.validate(*args)
            else:
                self.assertEqual(prepare.validate(*args), record)
        self.assertEqual(self.snapshot(directories=True), before)

    def rewrite_output(self, record, value):
        data = plistlib.dumps(value, sort_keys=False)
        Path(record["output"]["path"]).write_bytes(data)
        record["output"]["sha256"] = sha256(data)
        Path(record["intent_path"]).write_text(json.dumps(record), encoding="utf-8")

    def test_new_profiles_exact_changes_and_read_only_round_trip(self):
        for case in CASES:
            with self.subTest(profile=case["profile"]):
                source, pin = self.source(case)
                original = self.snapshot()[source.name]
                records = []
                for _ in range(2):
                    before = self.snapshot()
                    with mock.patch.object(prepare.uuid, "uuid4", wraps=uuid.uuid4) as fresh:
                        record = prepare.prepare(source, pin, case["profile"])
                    fresh.assert_called_once_with()
                    records.append(record)
                    for name, state in before.items():
                        self.assertEqual(self.snapshot()[name], state)
                    run_id = record["run_id"]
                    self.assertEqual(str(uuid.UUID(run_id)), run_id)
                    self.assertEqual(uuid.UUID(run_id).version, 4)
                    data = Path(record["output"]["path"]).read_bytes()
                    parsed = plistlib.loads(data)
                    old_leaves, new_leaves = leaves(case["fixture"]), leaves(parsed)
                    changed = {
                        path: new_leaves.get(path, (None, MISSING))[1]
                        for path in old_leaves.keys() | new_leaves.keys()
                        if old_leaves.get(path) != new_leaves.get(path)
                    }
                    # Exact 3/7 leaf paths AND values, plus type-sensitive
                    # preservation of every unrelated field and container.
                    self.assertEqual(changed, expected_changes(case, run_id))
                    self.assertEqual(
                        plistlib.dumps(parsed, sort_keys=True),
                        plistlib.dumps(expected_output(case, run_id), sort_keys=True),
                    )
                    expected = self.expected_record(case, source, pin, run_id, data)
                    self.assertEqual(
                        Path(record["intent_path"]).read_bytes(),
                        (json.dumps(expected, indent=2, sort_keys=True) + "\n").encode(),
                    )
                    self.assert_validation(source, pin, case["profile"], record)
                    output = Path(record["output"]["path"])
                    before = self.snapshot(directories=True)
                    with self.assertRaises(prepare.Refusal):
                        prepare.prepare(output, sha256(data), case["profile"])
                    self.assertEqual(self.snapshot(directories=True), before)
                self.assertNotEqual(records[0]["run_id"], records[1]["run_id"])
                self.assertEqual(self.snapshot()[source.name], original)

    def test_old_profiles_preserve_controlled_bytes_and_defaults(self):
        for case in CASES:
            with self.subTest(profile=case["old_profile"]):
                source, pin = self.source(case)
                data = plistlib.dumps(expected_output(case, RUN_ID, False), sort_keys=False)
                expected = self.expected_record(case, source, pin, RUN_ID, data, False)
                intent_data = (json.dumps(expected, indent=2, sort_keys=True) + "\n").encode()
                with mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(RUN_ID)):
                    record = prepare.prepare(source, pin, case["old_profile"])
                # Expected bytes use only independent fixtures, fixed UUID/path,
                # and stdlib serializers, not transformed()/intent_record().
                self.assertEqual(Path(record["output"]["path"]).read_bytes(), data)
                self.assertEqual(Path(record["intent_path"]).read_bytes(), intent_data)
                self.assert_validation(source, pin, case["old_profile"], record)
                if case["old_profile"] == "mac-isolated-unit":
                    self.assertEqual(
                        plistlib.dumps(prepare.transformed(case["fixture"], RUN_ID),
                                       sort_keys=False), data,
                    )
                    default_record = prepare.intent_record(
                        source, pin, expected["output"]["path"], sha256(data),
                        expected["intent_path"], RUN_ID,
                    )
                    self.assertEqual(
                        (json.dumps(default_record, indent=2, sort_keys=True) + "\n").encode(),
                        intent_data,
                    )

    def test_new_inputs_refuse_lifetime_drift_layout_changes_and_existing_uuid(self):
        for case in CASES:
            source, _ = self.source(case)
            variants = [
                (path, value) for path in case["lifetime_paths"]
                for value in (MISSING, "keepAlways", "keepNever", 1, True, [])
            ] + [
                (("__xctestrun_metadata__", "FormatVersion"), 2),
                (("TestConfigurations",), []),
            ]
            for target in case["targets"]:
                variants += [
                    ((target,), MISSING),
                    ((target, "OnlyTestIdentifiers"), []),
                    ((target, "SkipTestIdentifiers"), ["Owner/test"]),
                    ((target, "TestHostPath"), "/unreviewed/host"),
                    ((target, "RunOrder"), False),
                    ((target, "TestingEnvironmentVariables", "FLUXKLANG_AUDIT_RUN_ID"), RUN_ID),
                ]
            variants += [
                (path, value) for path in case["uuid_paths"]
                for value in (RUN_ID, "", "not-a-uuid", 1)
            ]
            for path, replacement in variants:
                with self.subTest(profile=case["profile"], path=path, value=replacement):
                    value = copy.deepcopy(case["fixture"])
                    change(value, path, replacement)
                    source.write_bytes(plistlib.dumps(value, sort_keys=False))
                    before = self.snapshot(directories=True)
                    with mock.patch.object(prepare.uuid, "uuid4",
                                           side_effect=AssertionError("input accepted")):
                        with self.assertRaisesRegex(prepare.Refusal, "input"):
                            prepare.prepare(source, sha256(source.read_bytes()), case["profile"])
                    self.assertEqual(self.snapshot(directories=True), before)

    def test_rehashed_outputs_require_every_lifetime_change_and_no_extra_changes(self):
        for case in CASES:
            source, pin = self.source(case)
            record = prepare.prepare(source, pin, case["profile"])
            original = plistlib.loads(Path(record["output"]["path"]).read_bytes())
            variants = [
                (path, value) for path in case["lifetime_paths"]
                for value in (MISSING, "deleteOnSuccess", "keepNever", True)
            ] + [(path, MISSING) for path in case["uuid_paths"]]
            for target in case["targets"]:
                variants += [
                    ((target, "EnvironmentVariables", "TERM"), "xterm"),
                    ((target, "EnvironmentVariables", "FLUXKLANG_RETAIN_ATTACHMENTS"), "1"),
                    ((target, "TestingEnvironmentVariables", "FLUXKLANG_AUDIT_RUN_ID"),
                     record["run_id"]),
                ]
            for path, replacement in variants:
                with self.subTest(profile=case["profile"], path=path, value=replacement):
                    value = copy.deepcopy(original)
                    change(value, path, replacement)
                    self.rewrite_output(record, value)
                    self.assert_validation(source, pin, case["profile"], record, "output")
            # UUID-only output is not a retention request, even with a fresh hash.
            self.rewrite_output(record, expected_output(case, record["run_id"], False))
            self.assert_validation(source, pin, case["profile"], record, "output")

    def test_intent_schema_and_closed_policy_are_not_supplied_authority(self):
        for case in CASES:
            source, pin = self.source(case)
            record = prepare.prepare(source, pin, case["profile"])
            variants = [
                (("schema_version",), value) for value in (MISSING, 1, 2.0, True, False, "2")
            ] + [
                (("attachment_policy",), value) for value in (MISSING, {}, [], True)
            ] + [
                (("unexpected",), True),
                (("profile",), "unreviewed-retention"),
                (("attachment_policy", "identifier"), "retained"),
                (("attachment_policy", "identifier"), MISSING),
                (("attachment_policy", "extra"), True),
                (("attachment_policy", "targets"), []),
                (("attachment_policy", "targets"), MISSING),
                (("attachment_policy", "targets", "OtherTests"), {}),
            ]
            for target in case["targets"]:
                prefix = ("attachment_policy", "targets", target)
                variants += [(prefix, MISSING), (prefix, []), ((*prefix, "extra"), True)]
                variants += [
                    ((*prefix, field), value)
                    for field in ("SystemAttachmentLifetime", "UserAttachmentLifetime")
                    for value in (MISSING, "deleteOnSuccess", "keepNever", True)
                ]
            for path, replacement in variants:
                with self.subTest(profile=case["profile"], path=path, value=replacement):
                    changed = copy.deepcopy(record)
                    change(changed, path, replacement)
                    Path(record["intent_path"]).write_text(json.dumps(changed), encoding="utf-8")
                    self.assert_validation(source, pin, case["profile"], record, "intent")
            # A matching supplied policy and rehash cannot authorize another transform.
            changed = copy.deepcopy(record)
            for target in case["targets"]:
                changed["attachment_policy"]["targets"][target]["UserAttachmentLifetime"] = (
                    "deleteOnSuccess"
                )
            value = expected_output(case, record["run_id"])
            for target in case["targets"]:
                value[target]["UserAttachmentLifetime"] = "deleteOnSuccess"
            self.rewrite_output(changed, value)
            self.assert_validation(source, pin, case["profile"], changed, "intent")

    def test_cross_profiles_and_relabelled_wrong_transforms_refuse(self):
        for case in CASES:
            source, pin = self.source(case)
            for retention in (False, True):
                profile = case["profile"] if retention else case["old_profile"]
                other = case["old_profile"] if retention else case["profile"]
                record = prepare.prepare(source, pin, profile)
                self.assert_validation(source, pin, other, record, "intent")
                # Fully relabel schema/profile/policy with the correct byte hash,
                # but keep the opposite same-platform lifetime transformation.
                data = Path(record["output"]["path"]).read_bytes()
                relabelled = self.expected_record(
                    case, source, pin, record["run_id"], data, not retention,
                )
                Path(record["intent_path"]).write_text(json.dumps(relabelled), encoding="utf-8")
                self.assert_validation(source, pin, other, relabelled, "output")
                for foreign in CASES:
                    if foreign["profile"] == case["profile"]:
                        continue
                    for foreign_profile in (foreign["profile"], foreign["old_profile"]):
                        self.assert_validation(source, pin, foreign_profile, record, "input")
                        before = self.snapshot(directories=True)
                        with self.assertRaises(prepare.Refusal):
                            prepare.prepare(source, pin, foreign_profile)
                        self.assertEqual(self.snapshot(directories=True), before)

    def test_new_profile_collisions_and_failure_cleanup_preserve_prior_files(self):
        for case in CASES:
            source, pin = self.source(case)
            output = source.with_name(f"{source.stem}.audit-run-{RUN_ID}.xctestrun")
            intent = output.with_suffix(".intent.json")
            for path in (output, intent):
                for symlink in (False, True):
                    with self.subTest(profile=case["profile"], path=path.name, symlink=symlink):
                        if symlink:
                            path.symlink_to(self.root / "missing")
                        else:
                            path.write_bytes(b"prior file")
                        before = self.snapshot()
                        with mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(RUN_ID)):
                            with self.assertRaises(FileExistsError):
                                prepare.prepare(source, pin, case["profile"])
                        self.assertEqual(self.snapshot(), before)
                        path.unlink()

            original_open, original_unlink = Path.open, Path.unlink
            events = []

            class BrokenWrite:
                def __init__(self, stream):
                    self.stream = stream

                def __enter__(self):
                    return self

                def write(self, content):
                    self.stream.write(content[:20])
                    raise OSError("fixture disk failure")

                def __exit__(self, *args):
                    self.stream.close()

            for failure in ("intent write", "final recheck"):
                def observed_open(path, mode="r", *args, **kwargs):
                    stream = original_open(path, mode, *args, **kwargs)
                    if mode == "xb":
                        events.append(("create", path.suffix))
                        if failure == "intent write" and path.suffix == ".json":
                            return BrokenWrite(stream)
                    return stream

                def observed_unlink(path, *args, **kwargs):
                    events.append(("remove", path.suffix))
                    return original_unlink(path, *args, **kwargs)

                with self.subTest(profile=case["profile"], failure=failure):
                    before = self.snapshot()
                    events.clear()
                    with mock.patch.object(Path, "open", observed_open), \
                            mock.patch.object(Path, "unlink", observed_unlink):
                        if failure == "intent write":
                            with self.assertRaisesRegex(OSError, "fixture disk failure"):
                                prepare.prepare(source, pin, case["profile"])
                        else:
                            with mock.patch.object(prepare, "validate",
                                                   side_effect=prepare.Refusal("final recheck")):
                                with self.assertRaisesRegex(prepare.Refusal, "final recheck"):
                                    prepare.prepare(source, pin, case["profile"])
                    self.assertEqual(events, [
                        ("create", ".xctestrun"), ("create", ".json"),
                        ("remove", ".json"), ("remove", ".xctestrun"),
                    ])
                    self.assertEqual(self.snapshot(), before)

    def test_cli_profiles_are_explicit_and_unknown_choices_refuse_without_writes(self):
        for case in CASES:
            source, pin = self.source(case)

            def cli(command, *args):
                return subprocess.run(
                    [sys.executable, "-B", str(SCRIPT), command, "--input", str(source),
                     "--expected-sha256", pin, *args],
                    cwd=self.root, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                    capture_output=True, text=True, timeout=10, check=False,
                )

            result = cli("prepare", "--profile", case["profile"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "prepared")
            record = json.loads(result.stdout)["intent"]
            self.assertEqual(record["attachment_policy"], expected_policy(case))
            validation_args = ("--output", record["output"]["path"],
                               "--intent", record["intent_path"])
            before = self.snapshot(directories=True)
            result = cli("validate", "--profile", case["profile"], *validation_args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "validated")
            for command, args in (("prepare", ()), ("validate", validation_args)):
                for selection in ((), ("--profile", "unknown-retention-request")):
                    result = cli(command, *args, *selection)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("--profile", result.stderr)
                    self.assertEqual(result.stdout, "")
            self.assertEqual(self.snapshot(directories=True), before)


if __name__ == "__main__":
    unittest.main()
