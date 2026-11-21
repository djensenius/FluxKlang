"""Bounded filesystem acquisition of one explicitly named loose Git object."""

from contextlib import ExitStack
import os
import stat

import checkout_head
import git_loose


Refusal = checkout_head.Refusal


def _metadata(info):
    # Do not compare atime: the read itself may update it.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_object(checkout_root, oid):
    """Freshly read and decode one loose object, or raise Refusal."""
    pieces = checkout_head._checkout_path(checkout_root)
    expected = checkout_head._expected_oid(oid)
    if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
            or not hasattr(os, "O_NONBLOCK") or os.open not in os.supports_dir_fd):
        raise Refusal("descriptor-relative no-follow acquisition unavailable")

    try:
        with ExitStack() as stack:
            root = checkout_head._open_checkout_root(pieces)
            checkout_head._register_close(stack, root)
            parent = root
            for component in (".git", "objects", expected[:2]):
                parent = checkout_head._open_directory(parent, component)
                checkout_head._register_close(stack, parent)
            descriptor = os.open(
                expected[2:], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent,
            )
            checkout_head._register_close(stack, descriptor)
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode):
                raise Refusal("loose object must be a regular file")
            if before.st_size < 0 or before.st_size > git_loose.COMPRESSED_LIMIT:
                raise Refusal("compressed object size limit")

            content = bytearray()
            while len(content) <= git_loose.COMPRESSED_LIMIT:
                chunk = os.read(descriptor, git_loose.COMPRESSED_LIMIT + 1 - len(content))
                if not chunk:
                    break
                content.extend(chunk)
            after = os.fstat(descriptor)
            if (_metadata(before) != _metadata(after) or len(content) != before.st_size):
                raise Refusal("loose object changed while reading")
            if len(content) > git_loose.COMPRESSED_LIMIT:
                raise Refusal("compressed object size limit")
            return git_loose.read_object(bytes(content), expected)
    except Refusal:
        raise
    except (OSError, TypeError, ValueError) as error:
        raise Refusal("loose object acquisition refused") from error
