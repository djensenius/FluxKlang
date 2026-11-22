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


@contextmanager
def acquire(selected):
    """Hold and recheck all path components across acquisition and validation."""
    _require(len(selected) == 3, "three material paths required")
    paths = [_path(path) for path in selected]
    with ExitStack() as stack:
        links = []
        files = []
        for path in paths:
            root = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            _register_close(stack, root)
            root_identity = _identity(os.fstat(root), True)
            _require(root_identity == _identity(os.stat("/", follow_symlinks=False), True),
                     "material root changed")
            links.append((None, "/", root, root_identity, True))
            current = root
            parts = path.split("/")[1:]
            for index, part in enumerate(parts):
                directory = index < len(parts) - 1
                before = os.stat(part, dir_fd=current, follow_symlinks=False)
                _require(stat.S_ISDIR(before.st_mode) if directory else stat.S_ISREG(before.st_mode),
                         "material path is not a regular file or directory")
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if directory:
                    flags |= os.O_DIRECTORY
                child = os.open(part, flags, dir_fd=current)
                _register_close(stack, child)
                identity = _identity(before, directory)
                _require(_identity(os.fstat(child), directory) == identity,
                         "material path changed during open")
                links.append((current, part, child, identity, directory))
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

        def recheck():
            for parent, part, fd, identity, directory in links:
                info = (os.stat(part, follow_symlinks=False) if parent is None else
                        os.stat(part, dir_fd=parent, follow_symlinks=False))
                _require(_identity(info, directory) == identity and
                         _identity(os.fstat(fd), directory) == identity,
                         "material path changed")

        recheck()
        yield tuple(materials)
        recheck()
