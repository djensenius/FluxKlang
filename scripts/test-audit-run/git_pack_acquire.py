"""Bounded fresh acquisition of one explicitly named SHA-1 pack/index pair."""

from contextlib import ExitStack
import os
import stat

import checkout_head
import git_loose_acquire
import git_pack


Refusal = checkout_head.Refusal


def _read(descriptor, limit):
    content = bytearray()
    while len(content) <= limit:
        chunk = os.read(descriptor, limit + 1 - len(content))
        if not chunk:
            break
        content.extend(chunk)
    if len(content) > limit:
        raise Refusal("pack/index input size limit")
    return bytes(content)


def acquire_pair(checkout_root, pack_id):
    """Return fresh validated (pack_bytes, index_bytes), or raise Refusal.

    Lookup remains separate, via git_pack. This call fully parses the pair;
    passing it to another parser/adapter incurs that interface's own budgets.
    Descriptor metadata checks do not prove path custody or exclude all races.
    """
    pieces = checkout_head._checkout_path(checkout_root)
    expected = checkout_head._expected_oid(pack_id)
    if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
            or not hasattr(os, "O_NONBLOCK") or os.open not in os.supports_dir_fd):
        raise Refusal("descriptor-relative no-follow acquisition unavailable")

    try:
        with ExitStack() as stack:
            parent = git_loose_acquire._open_owned(
                stack, checkout_head._open_checkout_root, pieces,
            )
            for component in (".git", "objects", "pack"):
                parent = git_loose_acquire._open_owned(
                    stack, checkout_head._open_directory, parent, component,
                )
            files = []
            for suffix, limit in (("pack", git_pack.PACK_LIMIT),
                                  ("idx", git_pack.INDEX_LIMIT)):
                descriptor = git_loose_acquire._open_owned(
                    stack, os.open, f"pack-{expected}.{suffix}",
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent,
                )
                before = os.fstat(descriptor)
                if not stat.S_ISREG(before.st_mode):
                    raise Refusal("pack/index must be regular files")
                if before.st_size < 0 or before.st_size > limit:
                    raise Refusal("pack/index input size limit")
                files.append((descriptor, before, limit))

            contents = [_read(descriptor, limit) for descriptor, _, limit in files]
            # Check both held files after both reads, not just after each read.
            for (descriptor, before, _), content in zip(files, contents):
                after = os.fstat(descriptor)
                if (git_loose_acquire._metadata(before) != git_loose_acquire._metadata(after)
                        or len(content) != before.st_size):
                    raise Refusal("pack/index changed while reading")
            pack, index = contents
            if len(pack) < 20 or pack[-20:].hex() != expected:
                raise Refusal("pack filename identity mismatch")
            git_pack._parse(pack, index)
            return pack, index
    except Refusal:
        raise
    except (OSError, TypeError, ValueError) as error:
        raise Refusal("pack/index acquisition refused") from error
