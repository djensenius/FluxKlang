"""Opt-in bounded acquisition of three explicitly selected regular files."""

from contextlib import ExitStack, contextmanager
import os
from pathlib import Path
import stat


MATERIAL_BYTES = 2 * 1024 * 1024
PATH_BYTES = 4096
PATH_COMPONENTS = 64


class Refusal(ValueError):
    """Material could not be acquired within the closed limits."""


def _require(condition, message):
    if not condition:
        raise Refusal(message)


def _path(value):
    value = os.fspath(value)
    _require(type(value) is str, "material path must be text")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as error:
        raise Refusal("invalid material path") from error
    _require(len(encoded) <= PATH_BYTES and value.startswith("/") and "\0" not in value,
             "invalid material path")
    parts = value.split("/")[1:]
    _require(all(part not in ("", ".", "..") for part in parts),
             "noncanonical material path")
    _require(len(parts) <= PATH_COMPONENTS, "material path component limit")
    return value


def _register_close(stack, descriptor):
    def close_on_exit(exc_type, exc_value, traceback):
        try:
            os.close(descriptor)
        except BaseException as error:
            # Control-flow exceptions outrank ordinary failures, but never
            # replace an already-active control-flow exception.
            if exc_type is None or (
                isinstance(exc_value, Exception) and not isinstance(error, Exception)
            ):
                raise
        return False

    stack.push(close_on_exit)


def _identity(info, directory):
    identity = (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
    if not directory:
        identity += (info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    return identity


def _recheck_links(links):
    for parent, part, fd, identity, directory in links:
        info = (os.stat(part, follow_symlinks=False) if parent is None else
                os.stat(part, dir_fd=parent, follow_symlinks=False))
        _require(_identity(info, directory) == identity and
                 _identity(os.fstat(fd), directory) == identity,
                 "material path changed")


def _retain_anchors(links, stack):
    """Keep original directory identities alive while their walk descriptors close."""
    _require(stack is not None, "retained descriptors required")
    anchors = []
    for _, _, fd, identity, directory in links:
        if directory:
            anchor = os.dup(fd)
            _register_close(stack, anchor)
            _require(_identity(os.fstat(anchor), True) == identity, "material path changed")
            anchors.append((anchor, identity))
    return tuple(anchors)


def _reopen_input(links, anchors, stack):
    """Rewalk the original input chain without rereading material bytes."""
    _require(stack is not None, "retained descriptors required")
    root = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    _register_close(stack, root)
    root_identity = links[0][3]
    reopened = [(None, "/", root, root_identity, True)]
    _recheck_links(reopened)
    current = root
    for _, part, original_fd, identity, directory in links[1:]:
        before = os.stat(part, dir_fd=current, follow_symlinks=False)
        _require(_identity(before, directory) == identity, "material path changed")
        if directory:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=current)
            _register_close(stack, child)
        else:
            child = original_fd
        _require(_identity(os.fstat(child), directory) == identity, "material path changed")
        reopened.append((current, part, child, identity, directory))
        if directory:
            current = child

    def recheck():
        _recheck_links(reopened)
        for fd, identity in anchors:
            _require(_identity(os.fstat(fd), True) == identity, "material path changed")

    recheck()
    return current, recheck


@contextmanager
def acquire(selected):
    """Hold and recheck all path components across acquisition and validation."""
    _require(len(selected) == 3, "three material paths required")
    with _acquire(selected) as (materials, _, _):
        yield materials


@contextmanager
def acquire_input(selected, *, retained_descriptors=None):
    """Hold one input and its parent directory across bounded production."""
    with _acquire((selected,), retained_descriptors=retained_descriptors) as (materials, parents, links):
        def retain_anchors():
            anchors = _retain_anchors(links, retained_descriptors)
            return lambda: _reopen_input(links, anchors, retained_descriptors)

        yield materials[0], parents[0], retain_anchors


@contextmanager
def _acquire(selected, *, retained_descriptors=None):
    paths = [_path(path) for path in selected]
    with ExitStack() as stack:
        links = []
        files = []
        parents = []
        for path in paths:
            parts = path.split("/")[1:]
            root = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            root_stack = retained_descriptors if retained_descriptors is not None and len(parts) == 1 else stack
            _register_close(root_stack, root)
            root_identity = _identity(os.fstat(root), True)
            _require(root_identity == _identity(os.stat("/", follow_symlinks=False), True),
                     "material root changed")
            links.append((None, "/", root, root_identity, True))
            current = root
            for index, part in enumerate(parts):
                directory = index < len(parts) - 1
                before = os.stat(part, dir_fd=current, follow_symlinks=False)
                _require(stat.S_ISDIR(before.st_mode) if directory else stat.S_ISREG(before.st_mode),
                         "material path is not a regular file or directory")
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if directory:
                    flags |= os.O_DIRECTORY
                child = os.open(part, flags, dir_fd=current)
                retain = retained_descriptors is not None and index >= len(parts) - 2
                _register_close(retained_descriptors if retain else stack, child)
                identity = _identity(before, directory)
                _require(_identity(os.fstat(child), directory) == identity,
                         "material path changed during open")
                links.append((current, part, child, identity, directory))
                if not directory:
                    parents.append(current)
                current = child
            _require(before.st_size <= MATERIAL_BYTES, "material byte limit")
            files.append((Path(path), current, before.st_size))

        materials = []
        for path, fd, size in files:
            chunks = []
            total = 0
            while True:
                chunk = os.read(fd, min(65536, MATERIAL_BYTES + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                _require(total <= MATERIAL_BYTES, "material byte limit")
                chunks.append(chunk)
            _require(total == size, "material changed during read")
            materials.append((path, b"".join(chunks)))

        _recheck_links(links)
        yield tuple(materials), tuple(parents), tuple(links)
        _recheck_links(links)
