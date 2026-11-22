"""Synthetic bounded producer tests; only provider probes are replaced."""

from contextlib import contextmanager, ExitStack
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import unittest
from unittest import mock
import uuid

import bounded_material as bounded
import ios_runtime
import prepare
from test_bounded_material import CHECKER, OBSERVATION
from test_prepare_ios import FIXTURE, RUN_ID


class BoundedPrepareTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for module, names in (
            (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
            (os, ("system", "fork", "posix_spawn", "posix_spawnp", "kill", "killpg")),
        ):
            for name in names:
                if hasattr(module, name):
                    self.stack.enter_context(mock.patch.object(
                        module, name, side_effect=AssertionError("process/signalling denied"),
                    ))
        self.stack.enter_context(mock.patch.object(socket, "socket", side_effect=AssertionError("network")))
        self.directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.source = self.directory / "fixture.xctestrun"
        fixture = copy.deepcopy(FIXTURE)
        fixture["FluxKlangTests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = (
            "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:" + CHECKER + ":/usr/lib/libRPAC.dylib"
        )
        fixture["FluxKlangUITests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = CHECKER
        data = plistlib.dumps(fixture, sort_keys=False)
        self.source.write_bytes(data)
        self.pin = hashlib.sha256(data).hexdigest()
        self.output, self.intent = prepare.output_paths(self.source, RUN_ID)
        self.stack.enter_context(mock.patch.object(prepare.uuid, "uuid4", return_value=uuid.UUID(RUN_ID)))
        self.events = []

        def snapshot(*, command, file_reader):
            self.assertIs(command, ios_runtime._bounded_command)
            self.assertIs(file_reader, ios_runtime._bounded_provider_file)
            self.events.append("snapshot")
            return (copy.deepcopy(OBSERVATION), CHECKER, CHECKER + "-alias")

        self.stack.enter_context(mock.patch.object(ios_runtime, "_provider_snapshot", snapshot))
        self.stack.enter_context(mock.patch.object(ios_runtime, "verified_checker",
                                                   side_effect=AssertionError("strict probe")))

    def produce(self):
        return prepare.prepare(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                               bounded_material=True)

    def test_success_real_validation_no_legacy_reads_and_both_exit_rechecks(self):
        read, write = os.read, os.write
        read_total = write_total = 0

        def reading(fd, size):
            nonlocal read_total
            result = read(fd, size)
            read_total += len(result)
            return result

        def writing(fd, data):
            nonlocal write_total
            result = write(fd, data)
            write_total += result
            return result

        with mock.patch.object(prepare, "existing_file", side_effect=AssertionError("legacy path")), \
             mock.patch.object(Path, "read_bytes", side_effect=AssertionError("legacy read")), \
             mock.patch.object(Path, "read_text", side_effect=AssertionError("legacy read")), \
             mock.patch.object(bounded.os, "read", side_effect=reading), \
             mock.patch.object(bounded.os, "write", side_effect=writing):
            record = self.produce()
        self.assertEqual(self.events, ["snapshot"] * 4)
        self.assertEqual(record["provider_observation"], OBSERVATION)
        self.assertEqual(json.loads(self.intent.read_text()), record)
        self.assertEqual(read_total, 2 * self.source.stat().st_size +
                         self.output.stat().st_size + self.intent.stat().st_size)
        self.assertLessEqual(read_total, 4 * (bounded.MATERIAL_BYTES + 1))
        self.assertLessEqual(write_total, 2 * bounded.MATERIAL_BYTES)

    def test_cli_and_profile_boundaries(self):
        for profile in (prepare.PROFILE, prepare.IOS_PROFILE, prepare.IOS_RUNTIME_PROFILE, "unknown"):
            with self.subTest(profile=profile), self.assertRaisesRegex(ValueError, "only available"):
                prepare.prepare(self.source, self.pin, profile, bounded_material=True)
        with self.assertRaisesRegex(ValueError, "boolean"):
            prepare.prepare(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                            bounded_material=1)
        with mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(prepare.main([
                "prepare", "--bounded-material", "--input", str(self.source),
                "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            ]), 0)
        self.assertEqual(json.loads(stdout.getvalue())["status"], "prepared")

    def test_input_pin_path_and_size_limits(self):
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            prepare.prepare(self.source, "0" * 64, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                            bounded_material=True)
        with self.assertRaisesRegex(ValueError, "noncanonical"):
            prepare.prepare(str(self.directory) + "/./fixture.xctestrun", self.pin,
                            prepare.IOS_PROVIDER_RUNTIME_PROFILE, bounded_material=True)
        self.source.write_bytes(b"x" * (bounded.MATERIAL_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "byte limit"):
            self.produce()
        self.assertFalse(self.output.exists())

    def test_exact_input_cap_is_accepted(self):
        data = self.source.read_bytes()
        data += b" " * (bounded.MATERIAL_BYTES - len(data))
        self.source.write_bytes(data)
        self.pin = hashlib.sha256(data).hexdigest()
        self.assertEqual(self.produce()["run_id"], RUN_ID)

    def test_output_and_intent_serialization_limits_before_publication(self):
        with mock.patch.object(bounded, "MATERIAL_BYTES", self.source.stat().st_size + 1):
            with self.assertRaisesRegex(ValueError, "serialization"):
                self.produce()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.intent.exists())
        huge = copy.deepcopy(OBSERVATION)
        huge["nested"]["build"] = "x" * (bounded.MATERIAL_BYTES // 16 + 1)

        @contextmanager
        def authority(*, bounded_cleanup=False):
            yield [CHECKER], huge

        with mock.patch.object(ios_runtime, "provider_verified_checker", authority):
            with self.assertRaisesRegex(ValueError, "scalar limit"):
                self.produce()
        self.assertFalse(self.output.exists())
        huge["nested"]["build"] = ["x" * 128] * 20000
        with mock.patch.object(ios_runtime, "provider_verified_checker", authority):
            with self.assertRaisesRegex(ValueError, "serialization byte limit"):
                self.produce()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.intent.exists())

    def test_collisions_preserved_and_partial_publication_retained(self):
        self.output.write_bytes(b"existing output")
        with self.assertRaises(ios_runtime.Refusal) as caught:
            self.produce()
        self.assertIsInstance(caught.exception.__cause__, FileExistsError)
        self.assertEqual(self.output.read_bytes(), b"existing output")
        self.output.unlink()
        self.intent.write_bytes(b"existing intent")
        with self.assertRaises(ios_runtime.Refusal) as caught:
            self.produce()
        self.assertIsInstance(caught.exception.__cause__, FileExistsError)
        self.assertGreater(self.output.stat().st_size, 0)
        self.assertEqual(self.intent.read_bytes(), b"existing intent")
        self.output.unlink()
        self.intent.unlink()
        self.output.symlink_to(self.directory / "missing")
        with self.assertRaises(ios_runtime.Refusal) as caught:
            self.produce()
        self.assertIsInstance(caught.exception.__cause__, FileExistsError)
        self.assertTrue(self.output.is_symlink())

    def test_short_writes_complete_and_zero_write_retains_partial(self):
        write = os.write
        with mock.patch.object(os, "write", side_effect=lambda fd, data: write(fd, data[:7])):
            self.produce()
        self.output.unlink()
        self.intent.unlink()
        calls = 0

        def zero(fd, data):
            nonlocal calls
            calls += 1
            return write(fd, data[:11]) if calls == 1 else 0

        with mock.patch.object(os, "write", side_effect=zero):
            with self.assertRaisesRegex(ValueError, "invalid material write"):
                self.produce()
        self.assertEqual(self.output.stat().st_size, 11)
        self.assertFalse(self.intent.exists())
        self.output.unlink()
        calls = 0

        def zero_intent(fd, data):
            nonlocal calls
            calls += 1
            return write(fd, data) if calls == 1 else 0

        with mock.patch.object(os, "write", side_effect=zero_intent):
            with self.assertRaisesRegex(ValueError, "invalid material write"):
                self.produce()
        self.assertGreater(self.output.stat().st_size, 0)
        self.assertEqual(self.intent.stat().st_size, 0)

    def test_provider_mismatch_and_exit_failures_retain_pair_without_success(self):
        for failure in ("mismatch", "inner-exit", "outer-exit"):
            with self.subTest(failure=failure):
                calls = 0

                @contextmanager
                def authority(*, bounded_cleanup=False):
                    nonlocal calls
                    calls += 1
                    number = calls
                    observation = copy.deepcopy(OBSERVATION)
                    if failure == "mismatch" and number == 2:
                        observation["nested"]["build"] = "different"
                    yield [CHECKER], observation
                    if (failure, number) in (("inner-exit", 2), ("outer-exit", 1)):
                        raise ValueError(failure)

                with mock.patch.object(ios_runtime, "provider_verified_checker", authority), \
                     mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, \
                     mock.patch("sys.stderr", new_callable=io.StringIO):
                    self.assertEqual(prepare.main([
                        "prepare", "--bounded-material", "--input", str(self.source),
                        "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                    ]), 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.output.unlink()
                self.intent.unlink()

    def test_real_provider_context_rechecks_both_snapshots(self):
        for changed in (3, 4):
            with self.subTest(changed=changed):
                calls = 0

                def snapshot(*, command, file_reader):
                    nonlocal calls
                    calls += 1
                    observation = copy.deepcopy(OBSERVATION)
                    if calls == changed:
                        observation["nested"]["build"] = "changed"
                    return (observation, CHECKER, CHECKER + "-alias")

                with mock.patch.object(ios_runtime, "_provider_snapshot", snapshot):
                    with self.assertRaisesRegex(ValueError, "observation changed"):
                        self.produce()
                self.assertEqual(calls, changed)
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.output.unlink()
                self.intent.unlink()

    def test_real_provider_context_rejects_mismatched_fresh_observation(self):
        calls = 0

        def snapshot(*, command, file_reader):
            nonlocal calls
            calls += 1
            observation = copy.deepcopy(OBSERVATION)
            if calls == 2:
                observation["nested"]["build"] = "different"
            return (observation, CHECKER, CHECKER + "-alias")

        with mock.patch.object(ios_runtime, "_provider_snapshot", snapshot):
            with self.assertRaisesRegex(ValueError, "intent"):
                self.produce()
        self.assertEqual(calls, 2)
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())

    def test_provider_cleanup_faults_through_real_production_and_validation_contexts(self):
        probe = self.directory / "provider-fixture"
        probe.write_bytes(b"fixture")
        for operation, phases in (("prepare", (1, 2, 3, 4)), ("validate", (1, 2))):
            for kind, precedence in (("file", "active"), ("command", "active"),
                                     ("file", "cleanup"), ("command", "cleanup")):
                for phase in phases:
                    with self.subTest(operation=operation, kind=kind, precedence=precedence, phase=phase):
                        if operation == "validate":
                            self.produce()
                        count = 0
                        interrupt = (KeyboardInterrupt("provider interruption") if precedence == "active"
                                     else ValueError("provider failure"))
                        cleanup_control = SystemExit("provider cleanup")
                        expected = interrupt if precedence == "active" else cleanup_control
                        cleanup_events = []

                        def snapshot(*, command, file_reader):
                            nonlocal count
                            count += 1
                            if count == phase:
                                if kind == "file":
                                    close = os.close

                                    def closing(fd):
                                        cleanup_events.append("file-close")
                                        close(fd)
                                        if precedence == "cleanup":
                                            raise cleanup_control
                                        raise OSError("file close")

                                    with mock.patch.object(ios_runtime, "_read", side_effect=interrupt), \
                                         mock.patch.object(os, "close", side_effect=closing):
                                        file_reader(str(probe), 100)
                                else:
                                    process = mock.Mock()
                                    process.poll.return_value = None
                                    selector = mock.Mock()
                                    selector.select.side_effect = interrupt

                                    def fail(name):
                                        def action(*args, **kwargs):
                                            cleanup_events.append(name)
                                            if name == "selector" and precedence == "cleanup":
                                                raise cleanup_control
                                            raise OSError(name)
                                        return action

                                    selector.close.side_effect = fail("selector")
                                    process.kill.side_effect = fail("kill")
                                    process.wait.side_effect = fail("wait")
                                    process.stdout.close.side_effect = fail("stdout")
                                    with mock.patch.object(ios_runtime.subprocess, "Popen",
                                                           return_value=process), \
                                         mock.patch.object(ios_runtime.selectors, "DefaultSelector",
                                                           return_value=selector):
                                        command(["synthetic"])
                            return (copy.deepcopy(OBSERVATION), CHECKER, CHECKER + "-alias")

                        with mock.patch.object(ios_runtime, "_provider_snapshot", snapshot):
                            with self.assertRaises(type(expected)) as caught:
                                if operation == "prepare":
                                    self.produce()
                                else:
                                    prepare.validate(
                                        self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                                        self.output, self.intent, bounded_material=True,
                                    )
                        self.assertIs(caught.exception, expected)
                        self.assertEqual(count, phase)
                        self.assertEqual(cleanup_events, ["file-close"] if kind == "file" else
                                         ["selector", "kill", "wait", "stdout"])
                        if phase > 1 or operation == "validate":
                            self.assertTrue(self.output.exists())
                            self.assertTrue(self.intent.exists())
                        for path in (self.output, self.intent):
                            if path.exists():
                                path.unlink()

    def test_replacements_and_mutations_are_not_removed(self):
        for target in ("input", "output", "intent"):
            with self.subTest(target=target):
                calls = 0
                selected = {"input": self.source, "output": self.output, "intent": self.intent}[target]

                @contextmanager
                def authority(*, bounded_cleanup=False):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        replacement = self.directory / "replacement"
                        replacement.write_bytes(b"replacement")
                        os.replace(replacement, selected)
                    yield [CHECKER], copy.deepcopy(OBSERVATION)

                original = self.source.read_bytes()
                with mock.patch.object(ios_runtime, "provider_verified_checker", authority):
                    with self.assertRaises((ValueError, OSError)):
                        self.produce()
                self.assertEqual(selected.read_bytes(), b"replacement")
                if target == "input":
                    self.source.write_bytes(original)
                for path in (self.output, self.intent):
                    if path.exists():
                        path.unlink()

    def test_outer_exit_replacements_and_mutations_refuse(self):
        for target in ("input", "output", "intent"):
            for action in ("replace", "mutate"):
                with self.subTest(target=target, action=action):
                    calls = 0
                    selected = {"input": self.source, "output": self.output, "intent": self.intent}[target]
                    original = self.source.read_bytes()

                    @contextmanager
                    def authority(*, bounded_cleanup=False):
                        nonlocal calls
                        calls += 1
                        number = calls
                        yield [CHECKER], copy.deepcopy(OBSERVATION)
                        if number == 1:
                            if action == "replace":
                                replacement = self.directory / "replacement"
                                replacement.write_bytes(b"replacement")
                                os.replace(replacement, selected)
                            else:
                                with selected.open("ab") as stream:
                                    stream.write(b"changed")

                    with mock.patch.object(ios_runtime, "provider_verified_checker", authority):
                        with self.assertRaises((ValueError, OSError)):
                            self.produce()
                    self.assertTrue(self.output.exists())
                    self.assertTrue(self.intent.exists())
                    self.assertEqual(
                        selected.read_bytes() if action == "replace" else selected.read_bytes()[-7:],
                        b"replacement" if action == "replace" else b"changed",
                    )
                    self.source.write_bytes(original)
                    self.output.unlink()
                    self.intent.unlink()

    def test_created_replacement_during_input_exit_recheck_is_refused(self):
        for selected in (self.output, self.intent):
            with self.subTest(selected=selected):
                self.events.clear()
                replacement = self.directory / "replacement"
                replacement.write_bytes(b"replacement")
                stat_file = os.stat
                replaced = False

                def replacing(path, *args, **kwargs):
                    nonlocal replaced
                    result = stat_file(path, *args, **kwargs)
                    if (path == self.source.name and kwargs.get("dir_fd") is not None
                            and len(self.events) == 4 and not replaced):
                        os.replace(replacement, selected)
                        replaced = True
                    return result

                with mock.patch.object(os, "stat", side_effect=replacing), \
                     mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, \
                     mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
                    result = prepare.main([
                        "prepare", "--bounded-material", "--input", str(self.source),
                        "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                    ])
                self.assertTrue(replaced)
                self.assertEqual(result, 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertIn("created material path changed", stderr.getvalue())
                self.assertEqual(selected.read_bytes(), b"replacement")
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.output.unlink()
                self.intent.unlink()

    def test_created_replacement_during_input_ancestor_close_is_refused(self):
        replacement = self.directory / "replacement"
        replacement.write_bytes(b"replacement")
        open_fd, close_fd = os.open, os.close
        root = None
        replaced = False

        def opening(path, flags, *args, **kwargs):
            nonlocal root
            fd = open_fd(path, flags, *args, **kwargs)
            if path == "/" and root is None:
                root = fd
            return fd

        def closing(fd):
            nonlocal replaced
            close_fd(fd)
            if fd == root and len(self.events) == 4 and not replaced:
                os.replace(replacement, self.output)
                replaced = True

        with mock.patch.object(os, "open", side_effect=opening), \
             mock.patch.object(os, "close", side_effect=closing), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            result = prepare.main([
                "prepare", "--bounded-material", "--input", str(self.source),
                "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            ])
        self.assertTrue(replaced)
        self.assertEqual(result, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("created material path changed", stderr.getvalue())
        self.assertEqual(self.output.read_bytes(), b"replacement")
        self.assertTrue(self.intent.exists())

    def test_input_and_ancestor_replacement_during_ancestor_close_are_refused(self):
        source_data = self.source.read_bytes()
        parent = self.directory / "parent"
        nested = parent / "inside"
        nested.mkdir(parents=True)
        self.source = nested / "fixture.xctestrun"
        self.source.write_bytes(source_data)
        self.output, self.intent = prepare.output_paths(self.source, RUN_ID)

        for scenario in ("input", "ancestor"):
            with self.subTest(scenario=scenario):
                self.events.clear()
                replacement = self.directory / "replacement"
                if scenario == "input":
                    replacement.write_bytes(source_data)
                else:
                    replacement_nested = replacement / "inside"
                    replacement_nested.mkdir(parents=True)
                    (replacement_nested / self.source.name).write_bytes(source_data)
                    (replacement_nested / self.output.name).write_bytes(b"replacement output")
                    (replacement_nested / self.intent.name).write_bytes(b"replacement intent")
                open_fd, close_fd, dup_fd = os.open, os.close, os.dup
                root = None
                root_identity = None
                root_anchor = None
                changed = False

                def opening(path, flags, *args, **kwargs):
                    nonlocal root, root_identity
                    fd = open_fd(path, flags, *args, **kwargs)
                    if path == "/" and root is None:
                        root = fd
                        root_identity = bounded._identity(os.fstat(fd), True)
                    return fd

                def duplicating(fd):
                    nonlocal root_anchor
                    duplicate = dup_fd(fd)
                    if fd == root:
                        root_anchor = duplicate
                    return duplicate

                def closing(fd):
                    nonlocal changed
                    close_fd(fd)
                    if fd == root and len(self.events) == 4 and not changed:
                        self.assertIsNotNone(root_anchor)
                        self.assertEqual(bounded._identity(os.fstat(root_anchor), True), root_identity)
                        if scenario == "input":
                            os.replace(replacement, self.source)
                        else:
                            os.rename(parent, self.directory / "parked")
                            os.rename(replacement, parent)
                        changed = True

                with mock.patch.object(os, "open", side_effect=opening), \
                     mock.patch.object(os, "close", side_effect=closing), \
                     mock.patch.object(os, "dup", side_effect=duplicating), \
                     mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, \
                     mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
                    result = prepare.main([
                        "prepare", "--bounded-material", "--input", str(self.source),
                        "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                    ])
                self.assertTrue(changed)
                self.assertEqual(result, 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertIn("material path changed", stderr.getvalue())
                self.assertEqual(self.source.read_bytes(), source_data)
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                if scenario == "ancestor":
                    self.assertEqual(self.output.read_bytes(), b"replacement output")
                    self.assertEqual(self.intent.read_bytes(), b"replacement intent")
                    parked = self.directory / "parked" / "inside"
                    self.assertTrue((parked / self.output.name).exists())
                    self.assertTrue((parked / self.intent.name).exists())
                else:
                    self.output.unlink()
                    self.intent.unlink()

    def test_rewalk_failure_preserves_exception_precedence_and_attempts_all_closes(self):
        for active_control in (False, True):
            with self.subTest(active_control=active_control):
                self.events.clear()
                active = KeyboardInterrupt("rewalk") if active_control else ValueError("rewalk")
                cleanup = OSError("close") if active_control else SystemExit("close")
                expected = active if active_control else cleanup
                opened, closed = [], []
                final_walk = False
                open_fd, close_fd, dup_fd = os.open, os.close, os.dup

                def opening(path, flags, *args, **kwargs):
                    nonlocal final_walk
                    if path == "/" and len(self.events) == 4:
                        final_walk = True
                    elif final_walk:
                        raise active
                    fd = open_fd(path, flags, *args, **kwargs)
                    opened.append(fd)
                    return fd

                def closing(fd):
                    closed.append(fd)
                    close_fd(fd)
                    if final_walk and len(closed) <= len(opened):
                        raise cleanup

                def duplicating(fd):
                    duplicate = dup_fd(fd)
                    opened.append(duplicate)
                    return duplicate

                with mock.patch.object(os, "open", side_effect=opening), \
                     mock.patch.object(os, "close", side_effect=closing), \
                     mock.patch.object(os, "dup", side_effect=duplicating):
                    with self.assertRaises(type(expected)) as caught:
                        self.produce()
                self.assertIs(caught.exception, expected)
                self.assertTrue(final_walk)
                self.assertEqual(sorted(opened), sorted(closed))
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.output.unlink()
                self.intent.unlink()

    def test_anchor_duplication_failure_attempts_closes_and_preserves_precedence(self):
        for active_control in (False, True):
            with self.subTest(active_control=active_control):
                self.events.clear()
                active = KeyboardInterrupt("dup") if active_control else ValueError("dup")
                cleanup = OSError("close") if active_control else SystemExit("close")
                expected = active if active_control else cleanup
                acquired, closed = [], []
                duplications = 0
                failed = False
                open_fd, close_fd, dup_fd = os.open, os.close, os.dup

                def opening(*args, **kwargs):
                    fd = open_fd(*args, **kwargs)
                    acquired.append(fd)
                    return fd

                def duplicating(fd):
                    nonlocal duplications, failed
                    duplications += 1
                    if duplications == 2:
                        failed = True
                        raise active
                    duplicate = dup_fd(fd)
                    acquired.append(duplicate)
                    return duplicate

                def closing(fd):
                    closed.append(fd)
                    close_fd(fd)
                    if failed:
                        raise cleanup

                with mock.patch.object(os, "open", side_effect=opening), \
                     mock.patch.object(os, "dup", side_effect=duplicating), \
                     mock.patch.object(os, "close", side_effect=closing):
                    with self.assertRaises(type(expected)) as caught:
                        self.produce()
                self.assertIs(caught.exception, expected)
                self.assertEqual(duplications, 2)
                self.assertEqual(sorted(acquired), sorted(closed))
                self.assertTrue(self.output.exists())
                self.assertTrue(self.intent.exists())
                self.output.unlink()
                self.intent.unlink()

    def test_maximum_nested_material_descriptors(self):
        prefix = len(str(self.directory).split("/")) - 1
        directory = self.directory
        for _ in range(bounded.PATH_COMPONENTS - prefix - 1):
            directory = directory / "d"
            directory.mkdir()
        self.source = directory / "fixture.xctestrun"
        self.source.write_bytes((self.directory / "fixture.xctestrun").read_bytes())
        self.output, self.intent = prepare.output_paths(self.source, RUN_ID)
        open_fd, close_fd, dup_fd = os.open, os.close, os.dup
        held = set()
        highwater = 0
        open_count = 0
        dup_count = 0

        def opening(*args, **kwargs):
            nonlocal highwater, open_count
            fd = open_fd(*args, **kwargs)
            open_count += 1
            held.add(fd)
            highwater = max(highwater, len(held))
            return fd

        def closing(fd):
            close_fd(fd)
            held.remove(fd)

        def duplicating(fd):
            nonlocal highwater, dup_count
            duplicate = dup_fd(fd)
            held.add(duplicate)
            dup_count += 1
            highwater = max(highwater, len(held))
            return duplicate

        with mock.patch.object(os, "open", side_effect=opening), \
             mock.patch.object(os, "close", side_effect=closing), \
             mock.patch.object(os, "dup", side_effect=duplicating):
            self.produce()
        self.assertEqual(highwater, 4 * (bounded.PATH_COMPONENTS + 1) + 2)
        self.assertEqual(open_count, 5 * (bounded.PATH_COMPONENTS + 1) + 1)
        self.assertEqual(dup_count, bounded.PATH_COMPONENTS)
        self.assertEqual(held, set())

    def test_close_failures_attempt_all_and_preserve_control_precedence(self):
        for active in (None, ValueError("active"), KeyboardInterrupt("active")):
            with self.subTest(active=active):
                opened, closed = [], []
                open_fd, close_fd = os.open, os.close
                cleanup = SystemExit("cleanup")

                def opening(*args, **kwargs):
                    fd = open_fd(*args, **kwargs)
                    opened.append(fd)
                    return fd

                def closing(fd):
                    closed.append(fd)
                    close_fd(fd)
                    if len(closed) == 1:
                        raise cleanup

                @contextmanager
                def authority(*, bounded_cleanup=False):
                    if active is not None:
                        raise active
                    yield [CHECKER], copy.deepcopy(OBSERVATION)

                expected = active if isinstance(active, KeyboardInterrupt) else cleanup
                with mock.patch.object(os, "open", side_effect=opening), \
                     mock.patch.object(os, "close", side_effect=closing), \
                     mock.patch.object(ios_runtime, "provider_verified_checker", authority):
                    with self.assertRaises(type(expected)) as caught:
                        self.produce()
                self.assertIs(caught.exception, expected)
                self.assertEqual(sorted(opened), sorted(closed))
                for path in (self.output, self.intent):
                    if path.exists():
                        path.unlink()

    def test_interrupted_write_retains_debris_and_closes_descriptors(self):
        opened, closed = [], []
        open_fd, close_fd, write = os.open, os.close, os.write
        interrupt = KeyboardInterrupt("write interrupted")
        calls = 0

        def opening(*args, **kwargs):
            fd = open_fd(*args, **kwargs)
            opened.append(fd)
            return fd

        def closing(fd):
            closed.append(fd)
            close_fd(fd)

        def writing(fd, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return write(fd, data[:7])
            raise interrupt

        with mock.patch.object(os, "open", side_effect=opening), \
             mock.patch.object(os, "close", side_effect=closing), \
             mock.patch.object(os, "write", side_effect=writing):
            with self.assertRaises(KeyboardInterrupt) as caught:
                self.produce()
        self.assertIs(caught.exception, interrupt)
        self.assertEqual(sorted(opened), sorted(closed))
        self.assertEqual(self.output.stat().st_size, 7)
        self.assertFalse(self.intent.exists())

    def test_cli_close_failure_refuses_without_success_and_retains_pair(self):
        closed = []
        close_fd = os.close

        def closing(fd):
            closed.append(fd)
            close_fd(fd)
            if len(closed) == 1:
                raise OSError("close failed")

        with mock.patch.object(os, "close", side_effect=closing), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            result = prepare.main([
                "prepare", "--bounded-material", "--input", str(self.source),
                "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            ])
        self.assertEqual(result, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("refused:", stderr.getvalue())
        self.assertGreater(len(closed), 3)
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())

    def test_created_descriptor_close_failure_after_both_provider_rechecks(self):
        created, closed = [], []
        open_fd, close_fd = os.open, os.close

        def opening(path, flags, *args, **kwargs):
            fd = open_fd(path, flags, *args, **kwargs)
            if flags & os.O_CREAT and flags & os.O_EXCL:
                created.append(fd)
            return fd

        def closing(fd):
            closed.append(fd)
            close_fd(fd)
            if created and fd == created[-1]:
                raise OSError("created close failed")

        with mock.patch.object(os, "open", side_effect=opening), \
             mock.patch.object(os, "close", side_effect=closing), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            result = prepare.main([
                "prepare", "--bounded-material", "--input", str(self.source),
                "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            ])
        self.assertEqual(result, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("created close failed", stderr.getvalue())
        self.assertEqual(self.events, ["snapshot"] * 4)
        self.assertEqual(len(created), 2)
        self.assertTrue(all(fd in closed for fd in created))
        self.assertTrue(self.output.exists())
        self.assertTrue(self.intent.exists())


if __name__ == "__main__":
    unittest.main()
