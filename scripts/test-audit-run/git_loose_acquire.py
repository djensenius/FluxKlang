"""Bounded filesystem acquisition of one explicitly named loose Git object."""

from contextlib import ExitStack
import errno
import os
import stat

import checkout_head
import git_loose


Refusal = checkout_head.Refusal


class LooseAbsent(Refusal):
    """The explicitly requested loose path was absent, not the repository object."""


class _Descriptor:
    def __init__(self):
        self.fd = None

    def __exit__(self, exc_type, exc_value, traceback):
        descriptor = self.fd
        self.fd = None
        if descriptor is not None:
            try:
                os.close(descriptor)
            except (KeyboardInterrupt, SystemExit):
                raise
            except Exception:
                if exc_type is None:
                    raise
        return False


def _open_owned(stack, opener, *args, **kwargs):
    # Register an empty owner first, before opening this descriptor.
    owner = _Descriptor()
    stack.push(owner)
    owner.fd = opener(*args, **kwargs)
    return owner.fd


def _metadata(info):
    # Do not compare atime: the read itself may update it.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _open_target(parent, name, flags):
    # Only an ENOENT from this particular open identifies an absent target.
    try:
        return os.open(name, flags, dir_fd=parent)
    except OSError as error:
        if error.errno == errno.ENOENT:
            raise LooseAbsent("loose object path absent") from error
        raise


def _open_fanout(parent, name):
    descriptor = _open_target(parent, name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise Refusal("expected a real directory")
    except BaseException:
        checkout_head._close_quietly(descriptor)
        raise
    return descriptor


def read_object(checkout_root, oid):
    """Freshly decode a loose object; LooseAbsent is a Refusal subclass."""
    pieces = checkout_head._checkout_path(checkout_root)
    expected = checkout_head._expected_oid(oid)
    if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
            or not hasattr(os, "O_NONBLOCK") or os.open not in os.supports_dir_fd):
        raise Refusal("descriptor-relative no-follow acquisition unavailable")

    try:
        missing = None
        with ExitStack() as stack:
            root = _open_owned(stack, checkout_head._open_checkout_root, pieces)
            parent = root
            for component in (".git", "objects"):
                parent = _open_owned(stack, checkout_head._open_directory, parent, component)
            try:
                parent = _open_owned(stack, _open_fanout, parent, expected[:2])
                descriptor = _open_owned(
                    stack, _open_target, parent, expected[2:],
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                )
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
            except LooseAbsent as error:
                missing = error
        raise missing
    except Refusal:
        raise
    except (OSError, TypeError, ValueError) as error:
        raise Refusal("loose object acquisition refused") from error
