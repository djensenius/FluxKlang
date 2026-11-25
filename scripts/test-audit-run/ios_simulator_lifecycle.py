"""Source-only, callback-driven iOS Simulator ownership lifecycle.

This module describes a bounded direct-argv command contract. It has no
executor; any future adapter requires separate review and authorization.
"""

from dataclasses import dataclass
import json
import uuid
from typing import Callable, TypeVar

import ios_launch_plan as launch_plan
import ios_runtime
from ios_launch_plan import Refusal


TIMEOUT_SECONDS = 30
MAX_OUTPUT_BYTES = 2 * 1024 * 1024
MAX_RUNTIME_GROUPS = 128
MAX_DEVICES = 4096
MAX_DEVICE_TYPES = 1024
MAX_FIELD_LENGTH = 256
DEVICE_TYPE_NAME = "iPhone 17"
DEVICE_NAME_PREFIX = "FluxKlang-Audit-"


@dataclass(frozen=True)
class CommandResult:
    """The bounded stdout and exit status returned by an injected command fake."""

    returncode: int
    stdout: bytes


CommandCallback = Callable[..., CommandResult]
T = TypeVar("T")
Operation = Callable[[str], T]


def _canonical_uuid(value: object, *, require_v4: bool = False) -> str:
    if type(value) is not str:
        raise Refusal("UUID must be text")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise Refusal("invalid UUID") from error
    if str(parsed) != value:
        raise Refusal("noncanonical UUID")
    if require_v4 and parsed.version != 4:
        raise Refusal("run UUID must be UUID4")
    return value


def _bounded_text(value: object, label: str, *, ascii_only: bool = False) -> str:
    if type(value) is not str or not 1 <= len(value) <= MAX_FIELD_LENGTH:
        raise Refusal(f"{label} must be bounded non-empty text")
    try:
        encoded = value.encode("ascii" if ascii_only else "utf-8")
    except UnicodeError as error:
        raise Refusal(f"{label} has invalid encoding") from error
    if len(encoded) > MAX_FIELD_LENGTH or any(
        ord(char) < 0x20 or ord(char) == 0x7f for char in value
    ):
        raise Refusal(f"{label} contains invalid or oversized text")
    return value


def _unique_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal("duplicate JSON key")
        result[key] = value
    return result


def _invalid_constant(value: str) -> None:
    raise Refusal(f"invalid JSON constant {value}")


def _command_result(value: object) -> CommandResult:
    if type(value) is not CommandResult:
        raise Refusal("command callback must return CommandResult")
    if type(value.returncode) is not int:
        raise Refusal("command return code must be an integer")
    if type(value.stdout) is not bytes or len(value.stdout) > MAX_OUTPUT_BYTES:
        raise Refusal("command output must be bounded bytes")
    return value


def _invoke(command: CommandCallback, argv: tuple[str, ...]) -> CommandResult:
    """Invoke only the injected callback, with explicit resource limits."""
    result = command(
        argv,
        timeout=TIMEOUT_SECONDS,
        max_output_bytes=MAX_OUTPUT_BYTES,
    )
    return _command_result(result)


def _json_output(data: bytes, label: str) -> object:
    if type(data) is not bytes or len(data) > MAX_OUTPUT_BYTES:
        raise Refusal(f"{label} output must be bounded bytes")
    try:
        text = data.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=_unique_pairs,
            parse_constant=_invalid_constant,
        )
    except (UnicodeError, RecursionError, ValueError) as error:
        if isinstance(error, Refusal):
            raise
        raise Refusal(f"{label} output must be strict UTF-8 JSON") from error


def _device_uuids(data: bytes) -> frozenset[str]:
    inventory = _json_output(data, "device inventory")
    if type(inventory) is not dict or set(inventory) != {"devices"}:
        raise Refusal("device inventory has an incomplete shape")
    groups = inventory["devices"]
    if (type(groups) is not dict or not 1 <= len(groups) <= MAX_RUNTIME_GROUPS):
        raise Refusal("device inventory runtime groups are invalid")

    found = set()
    count = 0
    for runtime, devices in groups.items():
        _bounded_text(runtime, "runtime identifier", ascii_only=True)
        if type(devices) is not list:
            raise Refusal("device inventory group must be a list")
        for device in devices:
            count += 1
            if count > MAX_DEVICES:
                raise Refusal("device inventory device limit exceeded")
            if type(device) is not dict or not {"udid", "name", "state"} <= set(device):
                raise Refusal("device inventory entry is incomplete")
            device_uuid = _canonical_uuid(device["udid"])
            _bounded_text(device["name"], "device name")
            _bounded_text(device["state"], "device state", ascii_only=True)
            if device_uuid in found:
                raise Refusal("device inventory contains duplicate UUIDs")
            found.add(device_uuid)
    return frozenset(found)


def _inventory(command: CommandCallback) -> frozenset[str]:
    result = _invoke(command, (
        launch_plan.CORE_SIMULATOR_SIMCTL, "list", "devices", "--json",
    ))
    if result.returncode != 0:
        raise Refusal("device inventory command failed")
    return _device_uuids(result.stdout)


def _device_type_identifier(data: bytes) -> str:
    inventory = _json_output(data, "device type inventory")
    if type(inventory) is not dict or set(inventory) != {"devicetypes"}:
        raise Refusal("device type inventory has an incomplete shape")
    device_types = inventory["devicetypes"]
    if (type(device_types) is not list
            or not 1 <= len(device_types) <= MAX_DEVICE_TYPES):
        raise Refusal("device type inventory list is invalid")

    matches = []
    for item in device_types:
        if type(item) is not dict or not {"name", "identifier"} <= set(item):
            raise Refusal("device type inventory entry is incomplete")
        name = _bounded_text(item["name"], "device type name")
        identifier = _bounded_text(
            item["identifier"], "device type identifier", ascii_only=True,
        )
        if any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
               for char in identifier):
            raise Refusal("device type identifier is not a bounded ASCII token")
        if name == DEVICE_TYPE_NAME:
            matches.append(identifier)
    if len(matches) != 1:
        raise Refusal("iPhone 17 device type is missing or ambiguous")
    return matches[0]


def _created_uuid(data: bytes) -> str:
    if type(data) is not bytes or len(data) > MAX_OUTPUT_BYTES:
        raise Refusal("create output must be bounded bytes")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise Refusal("create output must be UTF-8") from error
    if text.endswith("\n"):
        text = text[:-1]
    if not text or "\n" in text or "\r" in text:
        raise Refusal("create output must be one canonical UUID line")
    return _canonical_uuid(text)


def with_owned_simulator(run_uuid: str, command: CommandCallback,
                         operation: Operation[T]) -> T:
    """Create, prove ownership of and clean one run-keyed simulator device.

    The required callback receives an argv tuple and explicit timeout/output
    limits; it must interpret argv directly, never through a shell. This module
    supplies no process backend. The operation receives exactly the proven
    owned UUID, and cleanup is attempted once after it returns or raises.
    """
    run_uuid = _canonical_uuid(run_uuid, require_v4=True)
    if not callable(command):
        raise Refusal("command callback must be callable")
    if not callable(operation):
        raise Refusal("operation callback must be callable")

    before = _inventory(command)
    type_result = _invoke(command, (
        launch_plan.CORE_SIMULATOR_SIMCTL, "list", "devicetypes", "--json",
    ))
    if type_result.returncode != 0:
        raise Refusal("device type inventory command failed")
    type_identifier = _device_type_identifier(type_result.stdout)

    device_name = f"{DEVICE_NAME_PREFIX}{run_uuid}"
    create_argv = (
        launch_plan.CORE_SIMULATOR_SIMCTL,
        "create",
        device_name,
        type_identifier,
        ios_runtime.RUNTIME,
    )
    try:
        create_result = command(
            create_argv,
            timeout=TIMEOUT_SECONDS,
            max_output_bytes=MAX_OUTPUT_BYTES,
        )
    except BaseException as error:
        raise Refusal(
            "create command outcome is unknown; ownership unproven; possible orphan"
        ) from error

    try:
        after = _inventory(command)
    except BaseException as error:
        raise Refusal(
            "post-create inventory failed; ownership unproven; possible orphan"
        ) from error

    try:
        create_result = _command_result(create_result)
        if create_result.returncode != 0:
            raise Refusal("create command failed; ownership unproven; possible orphan")
        created_uuid = _created_uuid(create_result.stdout)
        additions = after - before
        if (created_uuid in before or not before <= after
                or additions != frozenset((created_uuid,))):
            raise Refusal(
                "post-create inventory delta is ambiguous; ownership unproven; "
                "possible orphan"
            )
    except Refusal as error:
        if "possible orphan" in str(error):
            raise
        raise Refusal(
            f"{error}; ownership unproven; possible orphan"
        ) from error

    operation_error = None
    try:
        result = operation(created_uuid)
    except BaseException as error:
        operation_error = error

    cleanup_error = None
    try:
        cleanup_result = _invoke(command, (
            launch_plan.CORE_SIMULATOR_SIMCTL, "delete", created_uuid,
        ))
        if cleanup_result.returncode != 0:
            raise Refusal("simulator cleanup command failed")
    except BaseException as error:
        cleanup_error = error

    if cleanup_error is not None:
        if operation_error is not None:
            raise cleanup_error from operation_error
        raise cleanup_error
    if operation_error is not None:
        raise operation_error
    return result
