"""Bounded runner inputs and candidate/pack discovery; observations, not custody."""

from contextlib import ExitStack
import hashlib
import os
import re
import stat

import checkout_head
import git_loose_acquire
import git_pack
import github_context
import ios_runtime
import source_snapshot_integration as integration


_PACK = re.compile(r"pack-([0-9a-f]{40})\.(pack|idx)\Z")
_metadata = git_loose_acquire._metadata
_PRODUCT_ENTRIES = 256
_PRODUCT_COMPONENT_BYTES = 255
_PRODUCT_PATH_BYTES = 4096
_PRODUCT_PATH_COMPONENTS = 64
_CANDIDATE_BYTES = 2 * 1024 * 1024


def _directories(stack, root, components):
    pieces = checkout_head._checkout_path(root)
    descriptor = integration._root(stack, pieces)
    root_info = os.fstat(descriptor)
    links = []
    for component in components:
        parent = descriptor
        descriptor = integration._directory(stack, parent, component).fd
        links.append((parent, component, descriptor, os.fstat(descriptor)))
    return pieces, descriptor, root_info, links


def _check_directories(stack, pieces, root_info, links):
    for parent, name, descriptor, before in links:
        ios_runtime.require(_metadata(os.fstat(descriptor)) == _metadata(before)
                            and _metadata(os.stat(name, dir_fd=parent,
                                                  follow_symlinks=False)) == _metadata(before),
                            "input directory changed")
    root = integration._root(stack, pieces)
    ios_runtime.require(_metadata(os.fstat(root)) == _metadata(root_info),
                        "input root changed")


def _names(descriptor):
    names = []
    with os.scandir(descriptor) as entries:
        for entry in entries:
            names.append(entry.name)
            ios_runtime.require(len(names) <= 2 and len(entry.name) <= 50,
                                "pack entry limit")
    return tuple(sorted(names))


def discover_pair(root):
    """Return a private pair identity, refusing all other pack directory shapes."""
    try:
        ios_runtime.require(os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd
                            and os.stat in os.supports_follow_symlinks
                            and os.scandir in os.supports_fd
                            and all(hasattr(os, name) for name in
                                    ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")),
                            "descriptor operations unavailable")
        with ExitStack() as stack:
            pieces, directory, root_info, links = _directories(
                stack, root, (".git", "objects", "pack"),
            )
            names = _names(directory)
            ios_runtime.require(len(names) == 2, "expected one pair")
            matches = [_PACK.fullmatch(name) for name in names]
            ios_runtime.require(all(matches), "unexpected pack entry")
            ids = {match.group(1) for match in matches}
            suffixes = {match.group(2) for match in matches}
            ios_runtime.require(len(ids) == 1 and suffixes == {"pack", "idx"},
                                "ambiguous pack pair")
            entries = []
            for name, match in zip(names, matches):
                info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                limit = (git_pack._pack_limit(git_pack._Profile.V2)
                         if match.group(2) == "pack" else git_pack.INDEX_LIMIT)
                ios_runtime.require(stat.S_ISREG(info.st_mode) and 0 <= info.st_size <= limit,
                                    "pack entry shape or size")
                entries.append((name, _metadata(info)))
            ios_runtime.require(_names(directory) == names, "pack entries changed")
            for name, before in entries:
                ios_runtime.require(_metadata(os.stat(name, dir_fd=directory,
                                                      follow_symlinks=False)) == before,
                                    "pack entry changed")
            _check_directories(stack, pieces, root_info, links)
            return (next(iter(ids)), _metadata(root_info),
                    tuple(_metadata(link[3]) for link in links), tuple(entries))
    except ios_runtime.Refusal:
        raise
    except Exception as error:
        raise ios_runtime.Refusal("pack discovery unavailable") from error


def discover_candidate(products_root):
    """Pin the one root-level xctestrun candidate under a canonical Products root."""
    try:
        pieces = checkout_head._checkout_path(products_root)
        encoded_root = products_root.encode("utf-8")
        ios_runtime.require(len(encoded_root) <= _PRODUCT_PATH_BYTES
                            and len(pieces) + 1 <= _PRODUCT_PATH_COMPONENTS
                            and all(len(piece.encode("utf-8")) <= _PRODUCT_COMPONENT_BYTES
                                    for piece in pieces),
                            "Products path limit")
        ios_runtime.require(os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd
                            and os.stat in os.supports_follow_symlinks
                            and os.scandir in os.supports_fd
                            and all(hasattr(os, name) for name in
                                    ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")),
                            "descriptor operations unavailable")
        with ExitStack() as stack:
            path_pieces, directory, root_info, links = _directories(
                stack, products_root, (),
            )

            def names():
                result = []
                with os.scandir(directory) as entries:
                    for entry in entries:
                        name = entry.name
                        ios_runtime.require(type(name) is str, "Products entry name shape")
                        try:
                            size = len(name.encode("utf-8"))
                        except UnicodeError as error:
                            raise ios_runtime.Refusal("Products entry name encoding") from error
                        ios_runtime.require(0 < size <= _PRODUCT_COMPONENT_BYTES,
                                            "Products entry component limit")
                        result.append(name)
                        ios_runtime.require(len(result) <= _PRODUCT_ENTRIES,
                                            "Products entry limit")
                return tuple(sorted(result))

            entries = names()
            candidates = tuple(name for name in entries if name.endswith(".xctestrun"))
            ios_runtime.require(len(candidates) == 1, "expected exactly one candidate")
            name = candidates[0]
            candidate_path = products_root + "/" + name
            ios_runtime.require(len(candidate_path.encode("utf-8")) <= _PRODUCT_PATH_BYTES,
                                "candidate path limit")
            before = os.stat(name, dir_fd=directory, follow_symlinks=False)
            ios_runtime.require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                                and 0 <= before.st_size <= _CANDIDATE_BYTES,
                                "candidate shape or byte limit")
            descriptor = integration._open_owned(
                stack, os.open, name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=directory,
            ).fd
            ios_runtime.require(_metadata(os.fstat(descriptor)) == _metadata(before),
                                "candidate changed during open")
            digest = hashlib.sha256()
            total = 0
            while True:
                chunk = os.read(descriptor, min(65536, _CANDIDATE_BYTES + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                ios_runtime.require(total <= _CANDIDATE_BYTES, "candidate byte limit")
                digest.update(chunk)
            ios_runtime.require(total == before.st_size
                                and _metadata(os.fstat(descriptor)) == _metadata(before)
                                and _metadata(os.stat(name, dir_fd=directory,
                                                      follow_symlinks=False)) == _metadata(before),
                                "candidate changed during read")
            ios_runtime.require(names() == entries, "Products entries changed")
            _check_directories(stack, path_pieces, root_info, links)
            return candidate_path, digest.hexdigest()
    except ios_runtime.Refusal:
        raise
    except Exception as error:
        raise ios_runtime.Refusal("candidate discovery unavailable") from error


def read_inputs(root):
    """Read only the fixed environment projection and the bounded event file."""
    try:
        keys = github_context.ENV_KEYS | {"GITHUB_WORKSPACE", "GITHUB_EVENT_PATH", "RUNNER_TEMP"}

        def environment():
            return {key: os.environ.get(key) for key in keys}

        values = environment()
        ios_runtime.require(values["GITHUB_WORKSPACE"] == root,
                            "workspace changed")
        for key in github_context.ENV_KEYS:
            value = values[key]
            ios_runtime.require((key in ("GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA")
                                 and value is None)
                                or (type(value) is str
                                    and 0 < len(value) <= github_context.ENV_VALUE_LIMIT),
                                "environment value shape or size")
        temp = values["RUNNER_TEMP"]
        event = values["GITHUB_EVENT_PATH"]
        checkout_head._checkout_path(temp)
        ios_runtime.require(type(event) is str and event == temp + "/_github_workflow/event.json",
                            "event path policy")
        with ExitStack() as stack:
            pieces, parent, root_info, links = _directories(stack, temp, ("_github_workflow",))
            fd = integration._open_owned(
                stack, os.open, "event.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent,
            ).fd
            before = os.fstat(fd)
            ios_runtime.require(stat.S_ISREG(before.st_mode)
                                and 0 < before.st_size <= github_context.EVENT_LIMIT,
                                "event file shape or size")
            data = bytearray()
            while len(data) <= github_context.EVENT_LIMIT:
                part = os.read(fd, min(65536, github_context.EVENT_LIMIT + 1 - len(data)))
                if not part:
                    break
                data.extend(part)
            ios_runtime.require(len(data) == before.st_size
                                and len(data) <= github_context.EVENT_LIMIT
                                and _metadata(os.fstat(fd)) == _metadata(before)
                                and _metadata(os.stat("event.json", dir_fd=parent,
                                                      follow_symlinks=False)) == _metadata(before),
                                "event changed")
            _check_directories(stack, pieces, root_info, links)
        ios_runtime.require(environment() == values, "environment changed")
        projection = {key: values[key] for key in github_context.ENV_KEYS}
        return projection, bytes(data), values["GITHUB_SHA"]
    except ios_runtime.Refusal:
        raise
    except Exception as error:
        raise ios_runtime.Refusal("runner input unavailable") from error
