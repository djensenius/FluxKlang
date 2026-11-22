"""Bounded aggregate-only census of a detached checkout's Git object layout."""

from contextlib import ExitStack
import errno
import json
import os
import re
import stat

import checkout_head
import git_loose_acquire
import git_pack


OBJECTS_ENTRY_LIMIT = 512
PACK_ENTRY_LIMIT = 128
ENTRY_NAME_BYTES = 64
OUTPUT_BYTES = 2048
_PACK_NAME = re.compile(r"pack-([0-9a-f]{40})\.(pack|idx)\Z")
_FANOUT_NAME = re.compile(r"[0-9a-f]{2}\Z")

Refusal = checkout_head.Refusal


def _validate_name(name):
    try:
        encoded = name.encode("utf-8")
    except UnicodeError as error:
        raise Refusal("directory entry name encoding refused") from error
    if not encoded or len(encoded) > ENTRY_NAME_BYTES:
        raise Refusal("directory entry name limit")


def _validate_names(names, limit, role):
    if len(names) > limit:
        raise Refusal(f"{role} directory entry limit")
    for name in names:
        _validate_name(name)
    return tuple(sorted(names))


def _entry_metadata(info):
    return git_loose_acquire._metadata(info)


def _snapshot_directory(descriptor, limit, role):
    before = os.fstat(descriptor)
    if not stat.S_ISDIR(before.st_mode):
        raise Refusal("expected a real directory")
    names = []
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            names.append(entry.name)
            if len(names) > limit:
                raise Refusal(f"{role} directory entry limit")
            _validate_name(entry.name)
    names = _validate_names(names, limit, role)
    observed_entries = []
    for name in names:
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISLNK(info.st_mode):
            raise Refusal("symbolic-link directory entry refused")
        if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise Refusal("nonregular directory entry refused")
        observed_entries.append((name, info))

    middle = os.fstat(descriptor)
    names_again = []
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            names_again.append(entry.name)
            if len(names_again) > limit:
                raise Refusal(f"{role} directory entry limit")
            _validate_name(entry.name)
    again = _validate_names(names_again, limit, role)
    if names != again or _entry_metadata(before) != _entry_metadata(middle):
        raise Refusal("directory changed during census")
    for name, info in observed_entries:
        current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if _entry_metadata(info) != _entry_metadata(current):
            raise Refusal("directory entry changed during census")
    after = os.fstat(descriptor)
    if _entry_metadata(before) != _entry_metadata(after):
        raise Refusal("directory changed during census")
    return observed_entries


def _open_optional_directory(parent, name):
    try:
        return os.open(
            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent,
        )
    except OSError as error:
        if error.errno == errno.ENOENT:
            return None
        raise


def _alternates_present(objects, stack, listed_info):
    info = git_loose_acquire._open_owned(
        stack, _open_optional_directory, objects, "info",
    )
    if info is None:
        if listed_info is not None:
            raise Refusal("info directory changed during census")
        return False
    before = os.fstat(info)
    if (not stat.S_ISDIR(before.st_mode) or listed_info is None
            or _entry_metadata(listed_info) != _entry_metadata(before)):
        raise Refusal("expected a real directory")
    try:
        entry = os.stat("alternates", dir_fd=info, follow_symlinks=False)
    except OSError as error:
        if error.errno == errno.ENOENT:
            try:
                os.stat("alternates", dir_fd=info, follow_symlinks=False)
            except OSError as second_error:
                if second_error.errno != errno.ENOENT:
                    raise Refusal("alternates entry changed during census") from second_error
            else:
                raise Refusal("alternates entry changed during census")
            after = os.fstat(info)
            if _entry_metadata(before) != _entry_metadata(after):
                raise Refusal("alternates metadata changed during census")
            return False
        raise
    if stat.S_ISLNK(entry.st_mode):
        raise Refusal("symbolic-link alternates entry refused")
    if not stat.S_ISREG(entry.st_mode):
        raise Refusal("nonregular alternates entry refused")
    current = os.stat("alternates", dir_fd=info, follow_symlinks=False)
    after = os.fstat(info)
    if (_entry_metadata(entry) != _entry_metadata(current)
            or _entry_metadata(before) != _entry_metadata(after)):
        raise Refusal("alternates metadata changed during census")
    return True


def _census(checkout_root, expected_oid):
    checkout_head.observe_checkout_head(checkout_root, expected_oid)
    pieces = checkout_head._checkout_path(checkout_root)
    features = set()
    with ExitStack() as stack:
        root = git_loose_acquire._open_owned(
            stack, checkout_head._open_checkout_root, pieces,
        )
        git_directory = git_loose_acquire._open_owned(
            stack, checkout_head._open_directory, root, ".git",
        )
        objects = git_loose_acquire._open_owned(
            stack, checkout_head._open_directory, git_directory, "objects",
        )
        object_entries = _snapshot_directory(objects, OBJECTS_ENTRY_LIMIT, "objects")
        fanout_count = 0
        pack_present = False
        pack_directory = None
        pack_entries = []
        for name, info in object_entries:
            if name == "pack":
                if not stat.S_ISDIR(info.st_mode):
                    raise Refusal("pack entry must be a directory")
                pack_present = True
            elif name == "info":
                if not stat.S_ISDIR(info.st_mode):
                    raise Refusal("info entry must be a directory")
            elif stat.S_ISDIR(info.st_mode) and _FANOUT_NAME.fullmatch(name):
                fanout_count += 1
            else:
                features.add("unexpected-objects-entry")

        listed_info = next(
            (info for name, info in object_entries if name == "info"), None,
        )
        alternates_present = _alternates_present(objects, stack, listed_info)
        if alternates_present:
            features.add("alternates")

        pack_counts = {
            "pack_file_count": 0,
            "index_file_count": 0,
            "pack_index_pair_count": 0,
            "unpaired_pack_index_file_count": 0,
            "oversized_pack_file_count": 0,
            "oversized_index_file_count": 0,
            "within_cap_pair_count": 0,
            "pack_bytes_within_cap_total": 0,
            "index_bytes_within_cap_total": 0,
        }
        candidate_classification = "no-candidates"
        if pack_present:
            pack_directory = git_loose_acquire._open_owned(
                stack, checkout_head._open_directory, objects, "pack",
            )
            listed_pack = next(info for name, info in object_entries if name == "pack")
            if _entry_metadata(listed_pack) != _entry_metadata(os.fstat(pack_directory)):
                raise Refusal("pack directory changed during census")
            pack_entries = _snapshot_directory(
                pack_directory, PACK_ENTRY_LIMIT, "pack",
            )
            packs = {}
            indexes = {}
            pack_sizes = {}
            index_sizes = {}
            for name, info in pack_entries:
                if not stat.S_ISREG(info.st_mode):
                    raise Refusal("pack entry must be a regular file")
                if name == "multi-pack-index":
                    features.add("multi-pack-index")
                    continue
                matched = _PACK_NAME.fullmatch(name)
                if matched is None:
                    features.add("unexpected-pack-entry")
                    continue
                oid, suffix = matched.groups()
                target = packs if suffix == "pack" else indexes
                sizes = pack_sizes if suffix == "pack" else index_sizes
                target[oid] = name
                sizes[oid] = info.st_size
                if suffix == "pack":
                    pack_counts["pack_file_count"] += 1
                    if info.st_size > git_pack.PACK_LIMIT:
                        pack_counts["oversized_pack_file_count"] += 1
                    else:
                        pack_counts["pack_bytes_within_cap_total"] += info.st_size
                else:
                    pack_counts["index_file_count"] += 1
                    if info.st_size > git_pack.INDEX_LIMIT:
                        pack_counts["oversized_index_file_count"] += 1
                    else:
                        pack_counts["index_bytes_within_cap_total"] += info.st_size

            pack_ids = set(packs)
            index_ids = set(indexes)
            paired_ids = pack_ids & index_ids
            pack_counts["pack_index_pair_count"] = len(paired_ids)
            pack_counts["unpaired_pack_index_file_count"] = (
                len(pack_ids - index_ids) + len(index_ids - pack_ids)
            )
            if pack_ids != index_ids:
                features.add("mismatched-pack-index-pair")
            for oid in paired_ids:
                if (pack_sizes[oid] <= git_pack.PACK_LIMIT
                        and index_sizes[oid] <= git_pack.INDEX_LIMIT):
                    pack_counts["within_cap_pair_count"] += 1

            count = len(paired_ids)
            if count == 0:
                candidate_classification = "no-candidates"
            elif count > 1:
                candidate_classification = "multiple-candidates"
            elif pack_counts["within_cap_pair_count"] == 0:
                candidate_classification = "oversized-single-candidate"
            else:
                candidate_classification = "single-candidate-within-caps"

        final_objects = _snapshot_directory(objects, OBJECTS_ENTRY_LIMIT, "objects")
        if (len(final_objects) != len(object_entries)
                or any(name != original_name
                       or _entry_metadata(info) != _entry_metadata(original_info)
                       for (name, info), (original_name, original_info)
                       in zip(final_objects, object_entries))):
            raise Refusal("objects directory changed during census")
        if pack_directory is not None:
            final_pack = _snapshot_directory(pack_directory, PACK_ENTRY_LIMIT, "pack")
            if (len(final_pack) != len(pack_entries)
                    or any(name != original_name
                           or _entry_metadata(info) != _entry_metadata(original_info)
                           for (name, info), (original_name, original_info)
                           in zip(final_pack, pack_entries))):
                raise Refusal("pack directory changed during census")
        if _alternates_present(objects, stack, listed_info) != alternates_present:
            raise Refusal("alternates changed during census")
        checkout_head.observe_checkout_head(checkout_root, expected_oid)
        return {
            "schema": "checkout-layout-census-v1",
            "scope": "shape-and-metadata-only",
            "acceptance": "not-assessed",
            "layout_status": (
                "unsupported-observed-layout" if features else "shape-only-observation"
            ),
            "candidate_classification": candidate_classification,
            "unsupported_features": sorted(features),
            "loose_fanout_directory_count": fanout_count,
            "pack_directory_present": pack_present,
            **pack_counts,
        }


def observe_checkout_layout(checkout_root, expected_oid):
    """Return bounded deterministic JSON for a detached checkout's layout.

    This is metadata-only shape observation. It neither validates Git objects
    nor selects a pack/index pair or establishes provider acceptance.
    """
    checkout_head._checkout_path(checkout_root)
    checkout_head._expected_oid(expected_oid)
    if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
            or not hasattr(os, "O_NONBLOCK") or os.open not in os.supports_dir_fd
            or os.stat not in os.supports_dir_fd or os.scandir not in os.supports_fd):
        raise Refusal("descriptor-relative no-follow census unavailable")
    try:
        observation = _census(checkout_root, expected_oid)
        result = json.dumps(observation, sort_keys=True, separators=(",", ":"))
        if len(result.encode("utf-8")) > OUTPUT_BYTES:
            raise Refusal("census output size limit")
        return result
    except Refusal:
        raise
    except (OSError, TypeError, ValueError) as error:
        raise Refusal("checkout layout census refused") from error
