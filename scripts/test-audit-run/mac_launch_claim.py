"""Library-only local one-use reservation. No execution or launch authority."""

import sys

sys.dont_write_bytecode = True

import os
from pathlib import Path

import build_receipt as receipt
from build_mac import exclusive, sync_directory


def _local_path(path, existing_parent):
    """Preflight spelling and local limits, including the syscall terminator."""
    value = receipt.path_text(path)
    fd = receipt.open_fd(existing_parent, directory=True)
    try:
        name_max = os.fpathconf(fd, "PC_NAME_MAX")
        path_max = os.fpathconf(fd, "PC_PATH_MAX")
        receipt.require(type(name_max) is int and name_max > 0 and
                        type(path_max) is int and path_max > 0,
                        "unsupported local path limits")
        # NAME_MAX excludes NUL; PATH_MAX includes it. Never shorten a name.
        receipt.require(all(len(part.encode("utf-8")) + 1 <= name_max + 1
                            for part in value.split("/")[1:]), "local component limit")
        receipt.require(len(value.encode("utf-8")) + 1 <= path_max, "local path limit")
    finally:
        os.close(fd)


def claim(receipt_path, expected_sha256):
    """Record a reservation, not permission. Any uncertain mkdir needs quarantine.

    Requires external custody of W, its parent and stable ancestor/name mappings,
    and permanent preservation of the reserved slot. Never retry after uncertain
    creation, even if later inspection finds no marker. No crash-proof guarantee.
    """
    intent = receipt.validate(receipt_path, expected_sha256)
    original = Path(receipt.path_text(intent["input"]["path"]))
    output = Path(receipt.path_text(intent["output"]["path"]))
    intent_path = Path(receipt.path_text(intent["intent_path"]))
    receipt.require(len(original.parts) >= 6 and
                    original.parent.parts[-3:] == ("DerivedData", "Build", "Products"),
                    "original Products layout")
    w = original.parents[3]
    products = w / receipt.PRODUCTS
    receipt.equal(original.parent, products, "original sibling")
    receipt.equal(output.parent, products, "prepared sibling")
    receipt.equal(intent_path.parent, products, "intent sibling")
    final = w / "build-evidence/receipt.json"
    receipt.equal(receipt.path_text(receipt_path), str(final), "exact receipt path")
    slot = w.parent / (w.name + ".mac-launch-evidence")
    record_path = slot / "prelaunch.json"

    # No absence probe arbitrates. Check real ancestors and every derived path
    # before the exclusive mkdir. The absent slot/record inherit parent's limits.
    for path, parent in (
        (w.parent, w.parent), (w, w.parent), (products, products),
        (original, products), (output, products), (intent_path, products),
        (final.parent, final.parent), (final, final.parent),
        (slot, w.parent), (record_path, w.parent),
    ):
        _local_path(path, parent)
    receipt.check_directory(w)
    record = {
        "schema_version": 1, "status": "reservation-recorded",
        "workspace": str(w), "reservation": str(slot),
        "receipt": {"path": str(final), "sha256": expected_sha256},
        "intent": intent,
    }
    data = receipt.encode(record)
    receipt.require(len(data) <= receipt.METADATA_BYTES, "reservation record byte limit")

    # mkdir consumes, even if interrupted before returning. Deliberately no
    # created flag, cleanup, unlink, repair or retry on ANY subsequent exception.
    # Failed/interrupted parent sync cannot promise survival after power loss.
    slot.mkdir(mode=0o700)
    sync_directory(w.parent)
    exclusive(record_path, data)
    sync_directory(slot)
    sync_directory(w.parent)
    _, reread = receipt.bounded(record_path, receipt.METADATA_BYTES)
    receipt.equal(reread, data, "reservation bytes")
    receipt.equal(receipt.json_bytes(reread), record, "reservation record")
    with os.scandir(slot) as entries:
        first = next(entries, None)
        receipt.require(first is not None and first.name == "prelaunch.json",
                        "reservation entry")
        receipt.require(next(entries, None) is None, "extra reservation entry")
    receipt.equal(receipt.validate(receipt_path, expected_sha256), intent,
                  "post-reservation intent")
    return record
