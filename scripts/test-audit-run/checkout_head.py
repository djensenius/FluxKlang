"""Bounded, read-only observation of a real checkout's detached Git HEAD."""

from contextlib import ExitStack
import os
import re
import stat


HEAD_BYTES = 41
PATH_BYTES = 4096


class Refusal(ValueError):
    """The requested checkout HEAD observation is unavailable or invalid."""


def _encode_path(value):
    return value.encode("utf-8")


def _contains_nul(value):
    return "\0" in value


def _checkout_path(value):
    if type(value) is not str:
        raise Refusal("checkout root must be an absolute path string")
    if len(value) > PATH_BYTES:
        raise Refusal("checkout root path limit")
    if _contains_nul(value) or not value.startswith("/"):
        raise Refusal("checkout root must be an absolute path")
    try:
        encoded = _encode_path(value)
    except UnicodeError as error:
        raise Refusal("checkout root must be valid UTF-8") from error
    if len(encoded) > PATH_BYTES:
        raise Refusal("checkout root path limit")
    pieces = value.split("/")[1:]
    if not pieces or any(piece in ("", ".", "..") for piece in pieces):
        raise Refusal("ambiguous checkout root")
    return pieces


def _expected_oid(value):
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise Refusal("expected checkout object ID must be 40 lowercase hex digits")
    return value


def _open_directory(parent, name):
    descriptor = os.open(
        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent,
    )
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise Refusal("expected a real directory")
    except BaseException:
        _close_quietly(descriptor)
        raise
    return descriptor


def _close_quietly(descriptor):
    try:
        os.close(descriptor)
    except Exception:
        pass


def _register_close(stack, descriptor):
    def close_on_exit(exc_type, exc_value, traceback):
        try:
            os.close(descriptor)
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception:
            if exc_type is None:
                raise
        return False

    stack.push(close_on_exit)


def _open_checkout_root(pieces):
    current = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in pieces:
            child = _open_directory(current, component)
            parent = current
            current = child
            try:
                os.close(parent)
            except BaseException:
                child = current
                current = None
                _close_quietly(child)
                raise
        return current
    except BaseException:
        if current is not None:
            _close_quietly(current)
        raise


def observe_checkout_head(checkout_root, expected_oid):
    """Return the freshly observed detached HEAD OID, or raise Refusal.

    The root must be an absolute path string and ``expected_oid`` must be a
    lowercase SHA-1 object ID. Only a real ``.git`` directory and canonical
    detached ``HEAD`` file are accepted.
    """
    pieces = _checkout_path(checkout_root)
    expected = _expected_oid(expected_oid)
    if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
            or os.open not in os.supports_dir_fd):
        raise Refusal("descriptor-relative no-follow observation unavailable")

    try:
        with ExitStack() as stack:
            current = _open_checkout_root(pieces)
            _register_close(stack, current)
            git_directory = _open_directory(current, ".git")
            _register_close(stack, git_directory)
            head = os.open(
                "HEAD",
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=git_directory,
            )
            _register_close(stack, head)
            info = os.fstat(head)
            if not stat.S_ISREG(info.st_mode):
                raise Refusal("HEAD must be a regular file")
            if info.st_size < 0 or info.st_size > HEAD_BYTES:
                raise Refusal("HEAD content size limit")

            content = bytearray()
            while len(content) <= HEAD_BYTES:
                chunk = os.read(head, HEAD_BYTES + 1 - len(content))
                if not chunk:
                    break
                content.extend(chunk)
            if len(content) > HEAD_BYTES:
                raise Refusal("HEAD content size limit")
            if re.fullmatch(rb"[0-9a-f]{40}\n", content) is None:
                raise Refusal("HEAD is not a canonical detached object ID")
            observed = content[:-1].decode("ascii")
            if observed != expected:
                raise Refusal("checkout HEAD does not match expected object ID")
            return observed
    except Refusal:
        raise
    except (OSError, TypeError, ValueError) as error:
        raise Refusal("checkout HEAD observation refused") from error
