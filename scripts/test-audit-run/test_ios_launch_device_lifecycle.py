"""Fake-only tests for the callback-driven iOS Simulator lifecycle."""

import ast
import json
from pathlib import Path
import unittest

import ios_launch_plan as launch_plan
import ios_simulator_lifecycle as lifecycle
import ios_runtime
from ios_launch_plan import Refusal


RUN_ID = "123e4567-e89b-42d3-a456-426614174000"
OWNED = "223e4567-e89b-42d3-a456-426614174000"
OTHER = "323e4567-e89b-42d3-a456-426614174000"
THIRD = "423e4567-e89b-42d3-a456-426614174000"
TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
SIMCTL = launch_plan.CORE_SIMULATOR_SIMCTL


OWNED_NAME = f"{lifecycle.DEVICE_NAME_PREFIX}{RUN_ID}"


def inventory_bytes(*device_uuids, owned_name=OWNED_NAME,
                    owned_runtime=ios_runtime.RUNTIME):
    groups = {ios_runtime.RUNTIME: []}
    for index, item in enumerate(device_uuids):
        runtime = owned_runtime if item == OWNED else ios_runtime.RUNTIME
        name = owned_name if item == OWNED else f"Device-{index}"
        groups.setdefault(runtime, []).append(
            {"udid": item, "name": name, "state": "Shutdown"},
        )
    return json.dumps({"devices": groups}).encode("utf-8")


def device_types_bytes(items=None):
    if items is None:
        items = [{"name": "iPhone 17", "identifier": TYPE_ID}]
    return json.dumps({"devicetypes": items}).encode("utf-8")


class FakeCommand:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, argv, *, timeout, max_output_bytes):
        self.calls.append((argv, timeout, max_output_bytes))
        if not self.responses:
            raise AssertionError(f"unexpected command: {argv!r}")
        expected_argv, response = self.responses.pop(0)
        if argv != expected_argv:
            raise AssertionError(f"expected {expected_argv!r}, got {argv!r}")
        if timeout != lifecycle.TIMEOUT_SECONDS:
            raise AssertionError(f"unexpected timeout: {timeout!r}")
        if max_output_bytes != lifecycle.MAX_OUTPUT_BYTES:
            raise AssertionError(f"unexpected output limit: {max_output_bytes!r}")
        if isinstance(response, BaseException):
            raise response
        return response


def expected_inventory(data, returncode=0):
    return (
        (SIMCTL, "list", "devices", "--json"),
        lifecycle.CommandResult(returncode, data),
    )


def expected_types(data=None, returncode=0):
    return (
        (SIMCTL, "list", "devicetypes", "--json"),
        lifecycle.CommandResult(
            returncode, device_types_bytes() if data is None else data,
        ),
    )


def expected_create(data=None, returncode=0):
    return (
        (
            SIMCTL, "create", f"{lifecycle.DEVICE_NAME_PREFIX}{RUN_ID}",
            TYPE_ID, ios_runtime.RUNTIME,
        ),
        lifecycle.CommandResult(returncode, (OWNED + "\n").encode("ascii")
                                if data is None else data),
    )


def expected_delete(device_uuid=OWNED, response=None):
    return (
        (SIMCTL, "delete", device_uuid),
        lifecycle.CommandResult(0, b"") if response is None else response,
    )


def completed_responses(after=None, create_data=None, create_returncode=0,
                        cleanup=None):
    if after is None:
        after = (OTHER, OWNED)
    if cleanup is None:
        cleanup = expected_delete()
    return [
        expected_inventory(inventory_bytes(OTHER)),
        expected_types(),
        expected_create(create_data, create_returncode),
        expected_inventory(inventory_bytes(*after)),
        cleanup,
    ]


class SimulatorLifecycleTests(unittest.TestCase):
    def test_exact_argv_order_and_owned_uuid_only(self):
        fake = FakeCommand(completed_responses())
        result_value = object()
        observed = []
        result = lifecycle.with_owned_simulator(
            RUN_ID, fake, lambda device_uuid: observed.append(device_uuid) or result_value,
        )
        self.assertIs(result, result_value)
        self.assertEqual(observed, [OWNED])
        self.assertEqual([call[0] for call in fake.calls], [
            (SIMCTL, "list", "devices", "--json"),
            (SIMCTL, "list", "devicetypes", "--json"),
            (SIMCTL, "create", f"{lifecycle.DEVICE_NAME_PREFIX}{RUN_ID}",
             TYPE_ID, ios_runtime.RUNTIME),
            (SIMCTL, "list", "devices", "--json"),
            (SIMCTL, "delete", OWNED),
        ])
        self.assertEqual(len(fake.responses), 0)
        self.assertTrue(all(call[1:] == (
            lifecycle.TIMEOUT_SECONDS, lifecycle.MAX_OUTPUT_BYTES,
        ) for call in fake.calls))

    def test_all_input_validation_precedes_commands(self):
        for run_id, command, operation in (
            ("not-a-uuid", FakeCommand([]), lambda _uuid: None),
            ("123E4567-E89B-42D3-A456-426614174000", FakeCommand([]),
             lambda _uuid: None),
            (RUN_ID, None, lambda _uuid: None),
            (RUN_ID, FakeCommand([]), None),
        ):
            with self.subTest(run_id=run_id, command=command, operation=operation):
                with self.assertRaises(Refusal):
                    lifecycle.with_owned_simulator(run_id, command, operation)
                if command is not None:
                    self.assertEqual(command.calls, [])

    def test_first_inventory_failures_stop_without_creation(self):
        bad_outputs = (
            b"",
            b"\xff",
            b'{"devices":{},"devices":{}}',
            b'{"devices":{"runtime":[{"udid":"bad","name":"x","state":"y"}]}}',
            b'{"devices":{"runtime":[{"udid":"223e4567-e89b-42d3-a456-426614174000",'
            b'"name":"x","state":"y"},{"udid":"223e4567-e89b-42d3-a456-426614174000",'
            b'"name":"z","state":"y"}]}}',
            b'{"devices":{"runtime":NaN}}',
            b'{"not_devices":{}}',
        )
        for output in bad_outputs:
            with self.subTest(output=output):
                fake = FakeCommand([expected_inventory(output)])
                with self.assertRaises(Refusal):
                    lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
                self.assertEqual(len(fake.calls), 1)

        fake = FakeCommand([expected_inventory(b" " * (lifecycle.MAX_OUTPUT_BYTES + 1))])
        with self.assertRaises(Refusal):
            lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
        self.assertEqual(len(fake.calls), 1)

    def test_bad_device_type_inventory_never_creates(self):
        cases = (
            device_types_bytes([]),
            device_types_bytes([
                {"name": "iPhone 17", "identifier": TYPE_ID},
                {"name": "iPhone 17", "identifier": TYPE_ID + ".other"},
            ]),
            b'{"devicetypes":[{"name":"iPhone 17"}]}',
            b'{"devicetypes":[{"name":"iPhone 17","identifier":"bad id"}]}',
            b'{"devicetypes":[],"devicetypes":[]}',
            b'{"devicetypes":[{"name":"iPhone 17","identifier":"'
            + b"a" * (lifecycle.MAX_FIELD_LENGTH + 1) + b'"}]}',
        )
        for output in cases:
            with self.subTest(output=output):
                fake = FakeCommand([
                    expected_inventory(inventory_bytes(OTHER)),
                    expected_types(output),
                ])
                with self.assertRaises(Refusal):
                    lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
                self.assertEqual(len(fake.calls), 2)

    def test_create_returncode_and_uuid_line_must_be_unambiguous(self):
        cases = (
            (b"not-a-uuid\n", 0),
            ((OWNED + "\n" + OWNED + "\n").encode("ascii"), 0),
            ((OWNED.upper() + "\n").encode("ascii"), 0),
            ((OWNED + "\r\n").encode("ascii"), 0),
            ((OWNED + "\n").encode("ascii"), 1),
        )
        for create_output, returncode in cases:
            with self.subTest(create_output=create_output, returncode=returncode):
                fake = FakeCommand(completed_responses(
                    create_data=create_output, create_returncode=returncode,
                ))
                with self.assertRaises(Refusal):
                    lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
                self.assertEqual(len(fake.calls), 4)
                self.assertFalse(any(call[0][1] == "delete" for call in fake.calls))

    def test_inventory_delta_mismatch_never_deletes(self):
        cases = (
            (OTHER,),                  # create result absent from inventory
            (OTHER, OWNED, THIRD),     # multiple additions
            (OWNED,),                  # prior device disappeared
        )
        for after in cases:
            with self.subTest(after=after):
                fake = FakeCommand(completed_responses(after=after)[:-1])
                with self.assertRaises(Refusal):
                    lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
                self.assertEqual(len(fake.calls), 4)
                self.assertFalse(any(call[0][1] == "delete" for call in fake.calls))

    def test_create_exception_reports_possible_orphan_without_deleting(self):
        create_argv, _ = expected_create()
        fake = FakeCommand([
            expected_inventory(inventory_bytes(OTHER)),
            expected_types(),
            (create_argv, RuntimeError("create outcome unknown")),
        ])
        operated = []
        with self.assertRaisesRegex(Refusal, "possible orphan") as raised:
            lifecycle.with_owned_simulator(RUN_ID, fake, operated.append)
        self.assertIsInstance(raised.exception.__cause__, RuntimeError)
        self.assertEqual(operated, [])
        self.assertEqual(len(fake.calls), 3)
        self.assertFalse(any(call[0][1] == "delete" for call in fake.calls))

    def test_added_device_name_or_runtime_mismatch_never_operates_or_deletes(self):
        for kwargs in (
            {"owned_name": "Someone-Else"},
            {"owned_runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-0"},
        ):
            with self.subTest(**kwargs):
                fake = FakeCommand([
                    expected_inventory(inventory_bytes(OTHER)),
                    expected_types(),
                    expected_create(),
                    expected_inventory(inventory_bytes(OTHER, OWNED, **kwargs)),
                ])
                operated = []
                with self.assertRaisesRegex(Refusal, "possible orphan"):
                    lifecycle.with_owned_simulator(RUN_ID, fake, operated.append)
                self.assertEqual(operated, [])
                self.assertEqual(len(fake.calls), 4)

    def test_termination_during_create_or_post_inventory_propagates(self):
        create_argv, _ = expected_create()
        for signal in (KeyboardInterrupt, SystemExit):
            for responses in (
                [
                    expected_inventory(inventory_bytes(OTHER)),
                    expected_types(),
                    (create_argv, signal()),
                ],
                [
                    expected_inventory(inventory_bytes(OTHER)),
                    expected_types(),
                    expected_create(),
                    ((SIMCTL, "list", "devices", "--json"), signal()),
                ],
            ):
                with self.subTest(signal=signal, calls=len(responses)):
                    fake = FakeCommand(responses)
                    with self.assertRaises(signal):
                        lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
                    self.assertFalse(any(call[0][1] == "delete" for call in fake.calls))

    def test_callback_exception_is_preserved_when_cleanup_succeeds(self):
        fake = FakeCommand(completed_responses())
        operation_error = RuntimeError("operation failed")

        def fail(_device_uuid):
            raise operation_error

        with self.assertRaises(RuntimeError) as raised:
            lifecycle.with_owned_simulator(RUN_ID, fake, fail)
        self.assertIs(raised.exception, operation_error)
        self.assertEqual([call[0] for call in fake.calls][-1], (SIMCTL, "delete", OWNED))
        self.assertEqual(len(fake.calls), 5)

    def test_cleanup_failure_is_once_and_chained_over_operation_failure(self):
        cleanup = expected_delete(response=lifecycle.CommandResult(9, b"failed"))
        fake = FakeCommand(completed_responses(cleanup=cleanup))
        operation_error = RuntimeError("operation failed")
        with self.assertRaises(Refusal) as raised:
            lifecycle.with_owned_simulator(
                RUN_ID, fake, lambda _uuid: (_ for _ in ()).throw(operation_error),
            )
        self.assertIn("cleanup", str(raised.exception))
        self.assertIs(raised.exception.__cause__, operation_error)
        self.assertEqual(sum(call[0][1] == "delete" for call in fake.calls), 1)
        self.assertEqual(len(fake.calls), 5)

        fake = FakeCommand(completed_responses(
            cleanup=((SIMCTL, "delete", OWNED), RuntimeError("delete transport failed")),
        ))
        with self.assertRaises(RuntimeError) as raised:
            lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: "ok")
        self.assertEqual(str(raised.exception), "delete transport failed")
        self.assertEqual(sum(call[0][1] == "delete" for call in fake.calls), 1)

    def test_unrelated_existing_devices_are_never_deleted(self):
        fake = FakeCommand(completed_responses())
        lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
        delete_argv = [call[0] for call in fake.calls if call[0][1] == "delete"]
        self.assertEqual(delete_argv, [(SIMCTL, "delete", OWNED)])
        self.assertNotIn(OTHER, delete_argv[0])

    def test_post_create_inventory_failure_reports_possible_orphan(self):
        fake = FakeCommand([
            expected_inventory(inventory_bytes(OTHER)),
            expected_types(),
            expected_create(),
            expected_inventory(b"not-json"),
        ])
        with self.assertRaisesRegex(Refusal, "possible orphan"):
            lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
        self.assertEqual(len(fake.calls), 4)

    def test_command_output_and_field_bounds(self):
        too_long_name = "n" * (lifecycle.MAX_FIELD_LENGTH + 1)
        fake = FakeCommand([
            expected_inventory(json.dumps({"devices": {ios_runtime.RUNTIME: [{
                "udid": OTHER, "name": too_long_name, "state": "Shutdown",
            }]}}).encode("utf-8")),
        ])
        with self.assertRaises(Refusal):
            lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)

        fake = FakeCommand(completed_responses(
            create_data=b"x" * (lifecycle.MAX_OUTPUT_BYTES + 1),
        ))
        with self.assertRaises(Refusal):
            lifecycle.with_owned_simulator(RUN_ID, fake, lambda _uuid: None)
        self.assertEqual(len(fake.calls), 4)

    def test_source_has_no_execution_io_imports_or_cli(self):
        source = Path(lifecycle.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imports = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.extend(alias.name.split(".", 1)[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imports.append((node.module or "").split(".", 1)[0])
        forbidden = {
            "argparse", "os", "pathlib", "shutil", "socket", "subprocess",
            "sys", "tempfile",
        }
        self.assertFalse(forbidden.intersection(imports), imports)
        self.assertIn("ios_runtime", imports)
        self.assertNotIn("__main__", source)
        self.assertNotIn("argparse", source)


if __name__ == "__main__":
    unittest.main()
