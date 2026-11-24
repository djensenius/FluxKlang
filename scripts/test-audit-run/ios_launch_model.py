"""Illustrative synthetic data model, not a simulator command or authority."""

from dataclasses import dataclass


INVENTORY_ARGV = ("ILLUSTRATIVE-ONLY", "synthetic-inventory")
CREATE_ARGV = (
    "ILLUSTRATIVE-ONLY", "synthetic-create",
    "synthetic-device-parameter", "synthetic-runtime-parameter",
)


@dataclass(frozen=True)
class Event:
    argv: tuple
    output: tuple


@dataclass(frozen=True)
class Result:
    states: tuple
    events: tuple
    reason: str
    eligible_for_simulated_cleanup: bool = False


def _synthetic_uuid(value):
    """Accept symbolic fixture tokens, never actual device identifiers."""
    prefix = "synthetic-uuid-"
    return (
        type(value) is str
        and value.startswith(prefix)
        and bool(value[len(prefix):])
        and all(char in "abcdefghijklmnopqrstuvwxyz0123456789"
                for char in value[len(prefix):])
    )


def model_invocation(candidate, inventory_complete, inventory,
                     create_returncode, created_uuids, cleanup_returncode):
    """Evaluate one synthetic transcript; the returned status is not authority.

    All outcomes are supplied as data. Nothing is executed, and no eligibility
    can be passed into another invocation to authorize a cleanup.
    """
    if not _synthetic_uuid(candidate):
        return Result(("refused",), (), "invalid-candidate")

    events = (Event(INVENTORY_ARGV, (inventory_complete, inventory)),)
    if (inventory_complete is not True or type(inventory) is not tuple
            or not all(_synthetic_uuid(item) for item in inventory)
            or len(set(inventory)) != len(inventory)):
        return Result(("inventory", "refused"), events, "invalid-inventory")
    if candidate in inventory:
        return Result(("inventory", "refused"), events, "candidate-present")

    states = ("inventory", "inventory-accepted", "create")
    events += (Event(CREATE_ARGV, (create_returncode, created_uuids)),)
    if type(create_returncode) is not int or create_returncode != 0:
        return Result(states + ("refused",), events, "creation-failed-or-ambiguous")
    if (type(created_uuids) is not tuple or len(created_uuids) != 1
            or not _synthetic_uuid(created_uuids[0])):
        return Result(states + ("refused",), events, "creation-failed-or-ambiguous")
    if created_uuids[0] != candidate:
        return Result(states + ("refused",), events, "created-uuid-mismatch")

    states += ("creation-confirmed", "cleanup")
    events += (Event(("ILLUSTRATIVE-ONLY", "synthetic-cleanup", candidate),
                     (cleanup_returncode,)),)
    if type(cleanup_returncode) is not int or cleanup_returncode != 0:
        return Result(states + ("cleanup-failed",), events, "cleanup-failed", True)
    return Result(states + ("cleanup-succeeded",), events, "ok", True)
