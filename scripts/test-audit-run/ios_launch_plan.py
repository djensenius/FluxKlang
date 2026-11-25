"""Pure iOS launch planning; no simulator execution or receipt creation."""

from dataclasses import dataclass, field
import uuid


CORE_SIMULATOR_SIMCTL = (
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/"
    "Versions/A/Resources/bin/simctl"
)
RECEIPT_ENVIRONMENT_KEY = "FLUXKLANG_AUDIT_RECEIPT_DIR"
RECEIPT_RELATIVE_PREFIX = "Library/Caches/FluxKlangAuditReceipts"


class Refusal(ValueError):
    """A supplied planning value is incomplete or ambiguous."""


def _canonical_uuid(value, *, require_v4=False):
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


def _safe_relative_path(value):
    if type(value) is not str or value.startswith("/") or "\0" in value:
        raise Refusal("receipt location must be relative")
    components = value.split("/")
    if any(part in ("", ".", "..") for part in components):
        raise Refusal("receipt location must be canonical")
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise Refusal("receipt location must be UTF-8") from error
    return value


@dataclass(frozen=True)
class LaunchPlan:
    """Validated shape with an untrusted device candidate, not cleanup authority.

    The receipt location is relative to the future app container. A later
    executor must create and verify a fresh in-container directory before
    using an overlay formed by receipt_environment_overlay; this plan does
    none of those things and contains no ownership or custody claim.
    """

    run_uuid: str
    candidate_device_uuid: str
    receipt_directory_relative: str
    simctl_path: str = field(init=False, default=CORE_SIMULATOR_SIMCTL)

    def __post_init__(self):
        run_uuid = _canonical_uuid(self.run_uuid, require_v4=True)
        _canonical_uuid(self.candidate_device_uuid)
        expected_relative = f"{RECEIPT_RELATIVE_PREFIX}/{run_uuid}"
        relative = _safe_relative_path(self.receipt_directory_relative)
        if relative != expected_relative:
            raise Refusal("receipt location must be fixed and run-keyed")
        if self.simctl_path != CORE_SIMULATOR_SIMCTL:
            raise Refusal("simctl path must be the fixed signed CoreSimulator tool")


def _canonical_absolute_root(value):
    if type(value) is not str or not value.startswith("/"):
        raise Refusal("container root must be an absolute path")
    if any(ord(char) < 0x20 or ord(char) == 0x7f for char in value):
        raise Refusal("container root must not contain control characters")
    components = value[1:].split("/")
    if any(part in ("", ".", "..") for part in components):
        raise Refusal("container root must be canonical")
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise Refusal("container root must be UTF-8") from error
    return value


def receipt_environment_overlay(plan, container_root):
    """Return a new one-key, unprefixed receipt environment overlay.

    This is pure string composition of a supplied canonical absolute root and
    the plan's run-keyed relative receipt location. It does not inspect,
    create or verify any filesystem path, choose or invoke any transport, add
    any forwarding prefix, or prove delivery to a launched app.
    """
    if type(plan) is not LaunchPlan:
        raise Refusal("plan must be a LaunchPlan")
    root = _canonical_absolute_root(container_root)
    run_uuid = _canonical_uuid(plan.run_uuid, require_v4=True)
    relative = _safe_relative_path(plan.receipt_directory_relative)
    if relative != f"{RECEIPT_RELATIVE_PREFIX}/{run_uuid}":
        raise Refusal("receipt location must be fixed and run-keyed")
    return {RECEIPT_ENVIRONMENT_KEY: f"{root}/{relative}"}


def plan_launch(run_uuid, candidate_device_uuid):
    """Return a pure plan recording a candidate UUID observation only.

    This does not inspect inventory or verify create success. A future executor
    must establish complete pre-inventory and successful creation itself before
    any narrowly scoped cleanup. The signed CoreSimulator simctl path is fixed;
    no tool is invoked here.
    """
    run_uuid = _canonical_uuid(run_uuid, require_v4=True)
    candidate = _canonical_uuid(candidate_device_uuid)
    return LaunchPlan(
        run_uuid=run_uuid,
        candidate_device_uuid=candidate,
        receipt_directory_relative=f"{RECEIPT_RELATIVE_PREFIX}/{run_uuid}",
    )
