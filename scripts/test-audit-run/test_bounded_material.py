"""Synthetic material fixtures; no provider, process, network or hardware probes."""

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

import bounded_material as bounded
import ios_runtime
import prepare
from test_prepare_ios import FIXTURE, RUN_ID, UUID_PATHS


CHECKER = "/synthetic/runtime/libMainThreadChecker.dylib"
OBSERVATION = {"schema": "synthetic-provider-observation", "nested": {"build": "test"}}


@contextmanager
def authority():
    yield [CHECKER], copy.deepcopy(OBSERVATION)


class BoundedMaterialTests(unittest.TestCase):
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
        self.stack.enter_context(mock.patch.object(ios_runtime, "provider_verified_checker", authority))
        self.stack.enter_context(mock.patch.object(ios_runtime, "verified_checker",
                                                   side_effect=AssertionError("strict probe")))
        directory = self.stack.enter_context(tempfile.TemporaryDirectory())
        self.directory = Path(directory).resolve()
        self.source = self.directory / "fixture.xctestrun"
        fixture = copy.deepcopy(FIXTURE)
        fixture["FluxKlangTests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = (
            "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:" + CHECKER + ":/usr/lib/libRPAC.dylib"
        )
        fixture["FluxKlangUITests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = CHECKER
        self.source.write_bytes(plistlib.dumps(fixture, sort_keys=False))
        self.pin = hashlib.sha256(self.source.read_bytes()).hexdigest()
        prepared = copy.deepcopy(fixture)
        for target, environment in UUID_PATHS:
            prepared[target][environment]["FLUXKLANG_AUDIT_RUN_ID"] = RUN_ID
        self.output = self.directory / f"fixture.audit-run-{RUN_ID}.xctestrun"
        self.intent = self.output.with_suffix(".intent.json")
        self.output.write_bytes(plistlib.dumps(prepared, sort_keys=False))
        self.record = {
            "schema_version": 3,
            "profile": prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            "qualification": "partial-regression",
            "run_id": RUN_ID,
            "targets": ["FluxKlangTests", "FluxKlangUITests"],
            "input": {"path": str(self.source), "sha256": self.pin},
            "output": {"path": str(self.output),
                       "sha256": hashlib.sha256(self.output.read_bytes()).hexdigest()},
            "intent_path": str(self.intent),
            "provider_observation": copy.deepcopy(OBSERVATION),
        }
        self.write_record()

    def write_record(self):
        self.intent.write_text(json.dumps(self.record), encoding="utf-8")

    def validate(self, **kwargs):
        return prepare.validate(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                                self.output, self.intent, bounded_material=True, **kwargs)

    def test_public_validation_uses_semantics_without_legacy_reads(self):
        with mock.patch.object(prepare, "existing_file", side_effect=AssertionError("legacy path")), \
             mock.patch.object(Path, "read_bytes", side_effect=AssertionError("legacy read")), \
             mock.patch.object(Path, "read_text", side_effect=AssertionError("legacy read")):
            self.assertEqual(self.validate(), self.record)
            with mock.patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(prepare.main([
                    "validate", "--bounded-material", "--input", str(self.source),
                    "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                    "--output", str(self.output), "--intent", str(self.intent),
                ]), 0)

    def test_real_prepare_default_and_bounded_validation(self):
        with mock.patch.object(prepare, "validate", wraps=prepare.validate) as internal:
            record = prepare.prepare(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE)
            self.assertEqual(internal.call_count, 1)
            self.assertNotIn("bounded_material", internal.call_args.kwargs)
        self.assertEqual(prepare.validate(
            self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            record["output"]["path"], record["intent_path"], bounded_material=True,
        ), record)
        with self.assertRaises(TypeError):
            prepare.prepare(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                            bounded_material=True)
        before = set(self.directory.iterdir())
        with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit) as result:
            prepare.main([
                "prepare", "--bounded-material", "--input", str(self.source),
                "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
            ])
        self.assertEqual(result.exception.code, 2)
        self.assertEqual(set(self.directory.iterdir()), before)

    def test_pin_schema_siblings_observation_and_transformation(self):
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            prepare.validate(self.source, "0" * 64, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                             self.output, self.intent, bounded_material=True)
        for key, value in (("schema_version", 1), ("run_id", "not-a-uuid"),
                           ("provider_observation", {"schema": "other"})):
            with self.subTest(key=key):
                old = self.record[key]
                self.record[key] = value
                self.write_record()
                with self.assertRaises(ValueError):
                    self.validate()
                self.record[key] = old
        self.write_record()
        other = self.directory / "other.intent.json"
        other.write_bytes(self.intent.read_bytes())
        with self.assertRaisesRegex(ValueError, "sibling"):
            prepare.validate(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                             self.output, other, bounded_material=True)
        output = plistlib.loads(self.output.read_bytes())
        output["FluxKlangTests"]["EnvironmentVariables"]["FLUXKLANG_AUDIT_RUN_ID"] = "wrong"
        data = plistlib.dumps(output, sort_keys=False)
        self.output.write_bytes(data)
        self.record["output"]["sha256"] = hashlib.sha256(data).hexdigest()
        self.write_record()
        with self.assertRaisesRegex(ValueError, "output"):
            self.validate()

    def test_bad_original_xml_and_checker_are_refused(self):
        data = self.source.read_bytes()
        self.source.write_bytes(data + b"<broken>")
        self.pin = hashlib.sha256(self.source.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "invalid plist XML"):
            self.validate()
        fixture = plistlib.loads(data)
        fixture["FluxKlangUITests"]["TestingEnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = (
            "/synthetic/unreviewed.dylib"
        )
        self.source.write_bytes(plistlib.dumps(fixture, sort_keys=False))
        self.pin = hashlib.sha256(self.source.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "UI checker"):
            self.validate()

    def test_duplicate_intent_keys_and_output_metadata_drift_refuse(self):
        data = self.intent.read_text(encoding="utf-8")
        self.intent.write_text('{"schema_version": 3, ' + data[1:], encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            self.validate()
        self.write_record()
        output = plistlib.loads(self.output.read_bytes())
        output["FluxKlangUITests"]["RunOrder"] = 99
        data = plistlib.dumps(output, sort_keys=False)
        self.output.write_bytes(data)
        self.record["output"]["sha256"] = hashlib.sha256(data).hexdigest()
        self.write_record()
        with self.assertRaisesRegex(ValueError, "output"):
            self.validate()

    def test_strict_and_legacy_opt_in_boundary(self):
        for profile in (prepare.PROFILE, prepare.RETENTION_PROFILE, prepare.IOS_PROFILE,
                        prepare.IOS_RETENTION_PROFILE, prepare.IOS_RUNTIME_PROFILE, "unknown"):
            with self.subTest(profile=profile), self.assertRaisesRegex(ValueError, "only available"):
                prepare.validate(self.source, self.pin, profile,
                                 self.output, self.intent, bounded_material=True)
        with mock.patch.object(prepare, "existing_file", side_effect=AssertionError("legacy read")):
            with self.assertRaisesRegex(ValueError, "boolean"):
                prepare.validate(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                                 self.output, self.intent, bounded_material="yes")
        with mock.patch.object(prepare, "existing_file", wraps=prepare.existing_file) as legacy:
            self.assertEqual(prepare.validate(self.source, self.pin, prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                                              self.output, self.intent), self.record)
            self.assertEqual(legacy.call_count, 3)

    def test_strict_profile_default_round_trip(self):
        @contextmanager
        def strict_authority():
            yield [CHECKER]

        with mock.patch.object(ios_runtime, "verified_checker", strict_authority):
            record = prepare.prepare(self.source, self.pin, prepare.IOS_RUNTIME_PROFILE)
            self.assertEqual(prepare.validate(
                self.source, self.pin, prepare.IOS_RUNTIME_PROFILE,
                record["output"]["path"], record["intent_path"],
            ), record)
            self.assertEqual(record["schema_version"], 1)
            self.assertNotIn("provider_observation", record)

    def test_public_validation_at_exact_cap_and_one_over_for_each_material(self):
        def pad(path):
            data = path.read_bytes()
            path.write_bytes(data + b" " * (bounded.MATERIAL_BYTES - len(data)))

        pad(self.source)
        self.pin = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.record["input"]["sha256"] = self.pin
        pad(self.output)
        self.record["output"]["sha256"] = hashlib.sha256(self.output.read_bytes()).hexdigest()
        self.write_record()
        pad(self.intent)
        self.assertEqual(self.validate(), self.record)
        for path in (self.source, self.output, self.intent):
            with self.subTest(path=path):
                data = path.read_bytes()
                path.write_bytes(data + b" ")
                with self.assertRaisesRegex(ValueError, "byte limit"):
                    self.validate()
                path.write_bytes(data)

    def test_exact_cap_and_one_over_and_read_budget(self):
        files = [self.directory / str(i) for i in range(3)]
        for file in files:
            file.write_bytes(b"x" * bounded.MATERIAL_BYTES)
        read = os.read
        count = 0

        def counting(fd, size):
            nonlocal count
            data = read(fd, size)
            count += len(data)
            return data

        with mock.patch.object(bounded.os, "read", side_effect=counting):
            with bounded.acquire(files) as values:
                self.assertEqual([len(data) for _, data in values], [bounded.MATERIAL_BYTES] * 3)
        self.assertEqual(count, 3 * bounded.MATERIAL_BYTES)
        files[1].write_bytes(b"x" * (bounded.MATERIAL_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "byte limit"):
            with bounded.acquire(files):
                pass

    def test_growth_during_read_is_bounded(self):
        file = self.directory / "growth"
        file.write_bytes(b"x" * bounded.MATERIAL_BYTES)
        read = os.read
        count = 0
        grown = False

        def growing(fd, size):
            nonlocal count, grown
            if not grown:
                grown = True
                with file.open("ab") as stream:
                    stream.write(b"y")
            data = read(fd, size)
            count += len(data)
            return data

        with mock.patch.object(bounded.os, "read", side_effect=growing):
            with self.assertRaisesRegex(ValueError, "byte limit"):
                with bounded.acquire([file] * 3):
                    pass
        self.assertEqual(count, bounded.MATERIAL_BYTES + 1)

    def test_noncanonical_symlink_special_and_path_limit(self):
        self.assertEqual(len(bounded._path("/" + "a" * 4095).encode("utf-8")), 4096)
        for path in (str(self.source) + "/../x", str(self.directory) + "//fixture.xctestrun",
                     str(self.directory) + "/./fixture.xctestrun",
                     "relative", "/" + "a" * 4096, "/" + "é" * 2048):
            with self.subTest(path=path[:40]), self.assertRaises(ValueError):
                with bounded.acquire([path] * 3):
                    pass
        link = self.directory / "link"
        link.symlink_to(self.source)
        dirlink = self.directory / "dirlink"
        dirlink.symlink_to(self.directory, target_is_directory=True)
        fifo = self.directory / "fifo"
        os.mkfifo(fifo)
        for path in (link, dirlink / self.source.name, fifo):
            with self.subTest(path=path), self.assertRaises(ValueError):
                with bounded.acquire([path] * 3):
                    pass
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(prepare.main([
                "validate", "--bounded-material", "--input",
                str(self.directory) + "/./fixture.xctestrun", "--expected-sha256", self.pin,
                "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                "--output", str(self.output), "--intent", str(self.intent),
            ]), 1)
            self.assertIn("noncanonical", stderr.getvalue())

    def test_component_limit_and_maximum_held_descriptors(self):
        prefix = len(str(self.directory).split("/")) - 1
        directory = self.directory
        for _ in range(bounded.PATH_COMPONENTS - prefix - 1):
            directory = directory / "d"
            directory.mkdir()
        file = directory / "file"
        file.write_bytes(b"x")
        self.assertEqual(len(str(file).split("/")) - 1, bounded.PATH_COMPONENTS)
        open_fd, close_fd = os.open, os.close
        held = set()
        highwater = 0

        def opening(*args, **kwargs):
            nonlocal highwater
            fd = open_fd(*args, **kwargs)
            held.add(fd)
            highwater = max(highwater, len(held))
            return fd

        def closing(fd):
            close_fd(fd)
            held.remove(fd)

        with mock.patch.object(bounded.os, "open", side_effect=opening), \
             mock.patch.object(bounded.os, "close", side_effect=closing):
            with bounded.acquire([file] * 3) as values:
                self.assertEqual([data for _, data in values], [b"x"] * 3)
            self.assertEqual(highwater, 3 * (bounded.PATH_COMPONENTS + 1))
            self.assertEqual(held, set())
        with mock.patch.object(bounded.os, "open", side_effect=AssertionError("opened")):
            with self.assertRaisesRegex(ValueError, "component limit"):
                with bounded.acquire([file, str(file) + "/extra", file]):
                    pass

    def test_replacement_during_open_and_read_error_refuse(self):
        open_fd = os.open
        replacement = self.directory / "replacement"
        replacement.write_bytes(self.source.read_bytes())
        replaced = False

        def replacing(path, flags, *args, **kwargs):
            nonlocal replaced
            if path == self.source.name and not replaced:
                os.replace(replacement, self.source)
                replaced = True
            return open_fd(path, flags, *args, **kwargs)

        with mock.patch.object(bounded.os, "open", side_effect=replacing):
            with self.assertRaisesRegex(ValueError, "changed during open"):
                self.validate()
        with mock.patch.object(bounded.os, "close", wraps=os.close) as closed, \
             mock.patch.object(bounded.os, "read", side_effect=OSError("synthetic read failure")):
            with self.assertRaisesRegex(OSError, "read failure"):
                self.validate()
            self.assertGreater(closed.call_count, 3)

    def test_replacement_and_mutation_at_validation_boundary(self):
        @contextmanager
        def replace_file():
            replacement = self.directory / "replacement"
            replacement.write_bytes(self.output.read_bytes())
            os.replace(replacement, self.output)
            yield [CHECKER], copy.deepcopy(OBSERVATION)

        with mock.patch.object(ios_runtime, "provider_verified_checker", replace_file):
            with self.assertRaisesRegex(ValueError, "material path changed"):
                self.validate()

        @contextmanager
        def mutate():
            self.intent.write_text(self.intent.read_text() + " ", encoding="utf-8")
            yield [CHECKER], copy.deepcopy(OBSERVATION)

        with mock.patch.object(ios_runtime, "provider_verified_checker", mutate):
            with self.assertRaisesRegex(ValueError, "material path changed"):
                self.validate()

    def test_metadata_change_on_provider_exit_refuses(self):
        @contextmanager
        def mutate_on_exit():
            yield [CHECKER], copy.deepcopy(OBSERVATION)
            os.chmod(self.source, 0o600 if self.source.stat().st_mode & 0o777 != 0o600 else 0o644)

        with mock.patch.object(ios_runtime, "provider_verified_checker", mutate_on_exit):
            with self.assertRaisesRegex(ValueError, "material path changed"):
                self.validate()

    def test_directory_replacement_and_cleanup_failure_refuse(self):
        subdir = self.directory / "subdir"
        subdir.mkdir()
        file = subdir / "file"
        file.write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "material path changed"):
            with bounded.acquire([file] * 3):
                subdir.rename(self.directory / "old")
                subdir.mkdir()
                (subdir / "file").write_bytes(b"x")
        close = os.close
        calls = []

        def broken_close(fd):
            calls.append(fd)
            close(fd)
            if len(calls) == 1:
                raise OSError("synthetic cleanup failure")

        with mock.patch.object(bounded.os, "close", side_effect=broken_close):
            with self.assertRaisesRegex(OSError, "cleanup"):
                self.validate()
        self.assertGreater(len(calls), 3)

    def test_cleanup_preserves_active_interrupts_and_attempts_every_close(self):
        for phase in ("acquisition", "validation"):
            for kind in (KeyboardInterrupt, SystemExit, ValueError):
                with self.subTest(phase=phase, kind=kind):
                    error = kind("original")
                    open_fd, close_fd = os.open, os.close
                    opened, closed = [], []

                    def opening(*args, **kwargs):
                        fd = open_fd(*args, **kwargs)
                        opened.append(fd)
                        return fd

                    def closing(fd):
                        closed.append(fd)
                        close_fd(fd)
                        if len(closed) <= 2:
                            raise OSError("synthetic cleanup failure")

                    with ExitStack() as stack:
                        stack.enter_context(mock.patch.object(bounded.os, "open", side_effect=opening))
                        stack.enter_context(mock.patch.object(bounded.os, "close", side_effect=closing))
                        if phase == "acquisition":
                            stack.enter_context(mock.patch.object(bounded.os, "read", side_effect=error))
                        else:
                            stack.enter_context(mock.patch.object(
                                ios_runtime, "provider_verified_checker", side_effect=error,
                            ))
                        with self.assertRaises(kind) as caught:
                            if kind is ValueError:
                                self.validate()
                            else:
                                prepare.main([
                                    "validate", "--bounded-material", "--input", str(self.source),
                                    "--expected-sha256", self.pin, "--profile",
                                    prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                                    "--output", str(self.output), "--intent", str(self.intent),
                                ])
                    self.assertIs(caught.exception, error)
                    self.assertGreater(len(opened), 2)
                    self.assertEqual(closed, list(reversed(opened)))

    def test_cleanup_failure_without_active_exception_attempts_every_close(self):
        open_fd, close_fd = os.open, os.close
        opened, closed = [], []
        first_error = OSError("first cleanup failure")

        def opening(*args, **kwargs):
            fd = open_fd(*args, **kwargs)
            opened.append(fd)
            return fd

        def closing(fd):
            closed.append(fd)
            close_fd(fd)
            if len(closed) == 1:
                raise first_error
            if len(closed) == 2:
                raise OSError("second cleanup failure")

        with mock.patch.object(bounded.os, "open", side_effect=opening), \
             mock.patch.object(bounded.os, "close", side_effect=closing):
            with self.assertRaises(OSError) as caught:
                self.validate()
        self.assertIs(caught.exception, first_error)
        self.assertGreater(len(opened), 2)
        self.assertEqual(closed, list(reversed(opened)))

        opened.clear()
        closed.clear()
        with mock.patch.object(bounded.os, "open", side_effect=opening), \
             mock.patch.object(bounded.os, "close", side_effect=closing), \
             mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(prepare.main([
                "validate", "--bounded-material", "--input", str(self.source),
                "--expected-sha256", self.pin, "--profile", prepare.IOS_PROVIDER_RUNTIME_PROFILE,
                "--output", str(self.output), "--intent", str(self.intent),
            ]), 1)
            self.assertIn("refused: first cleanup failure", stderr.getvalue())
        self.assertEqual(closed, list(reversed(opened)))


if __name__ == "__main__":
    unittest.main()
