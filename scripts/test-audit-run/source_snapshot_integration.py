"""Opt-in fixed source observation; no HEAD, context, or launch authority."""

from contextlib import ExitStack
import hashlib
import os
import stat

import checkout_head
import git_delta
import git_loose
import git_loose_acquire
import git_pack
import git_pack_acquire
import git_snapshot_reader
import ios_runtime
import provider_attribution


_DIRECTORY = "scripts/test-audit-run"
_NAMES = (
    "source_snapshot_integration.py", "provider_attribution.py", "ios_runtime.py",
    "checkout_head.py", "git_snapshot_reader.py", "git_loose.py",
    "git_loose_acquire.py", "git_pack.py", "git_pack_acquire.py", "git_delta.py",
)
_PATHS = tuple(sorted(f"{_DIRECTORY}/{name}" for name in _NAMES))
_LIMIT = 128 * 1024


def _module_paths(root):
    # These are path observations only, not evidence of loaded code integrity.
    modules = (
        (__file__, _NAMES[0]), (provider_attribution.__file__, _NAMES[1]),
        (ios_runtime.__file__, _NAMES[2]), (checkout_head.__file__, _NAMES[3]),
        (git_snapshot_reader.__file__, _NAMES[4]), (git_loose.__file__, _NAMES[5]),
        (git_loose_acquire.__file__, _NAMES[6]), (git_pack.__file__, _NAMES[7]),
        (git_pack_acquire.__file__, _NAMES[8]), (git_delta.__file__, _NAMES[9]),
    )
    for observed, name in modules:
        ios_runtime.require(type(observed) is str
                            and observed == f"{root}/{_DIRECTORY}/{name}",
                            "loaded module path differs from fixed source")


def _observe_sources(checkout_root, tree, objects):
    """Compare ten fresh fixed sources to tree blobs using the supplied _Objects."""
    try:
        pieces = checkout_head._checkout_path(checkout_root)
        checkout_head._expected_oid(tree)
        ios_runtime.require(type(objects) is provider_attribution._Objects,
                            "expected existing Git object budget")
        if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
                or not hasattr(os, "O_NONBLOCK") or os.open not in os.supports_dir_fd
                or os.stat not in os.supports_dir_fd
                or os.stat not in os.supports_follow_symlinks):
            raise ios_runtime.Refusal("descriptor-relative no-follow observation unavailable")
        _module_paths(checkout_root)
        tracked = objects.files(tree, _PATHS)
        with ExitStack() as stack:
            root = git_loose_acquire._open_owned(
                stack, checkout_head._open_checkout_root, pieces,
            )
            root_info = os.fstat(root)
            parent = root
            directories = []
            for name in ("scripts", "test-audit-run"):
                child = git_loose_acquire._open_owned(
                    stack, checkout_head._open_directory, parent, name,
                )
                directories.append((parent, name, child, os.fstat(child)))
                parent = child

            files = []
            for path in _PATHS:
                name = path.rpartition("/")[2]
                descriptor = git_loose_acquire._open_owned(
                    stack, os.open, name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=parent,
                )
                before = os.fstat(descriptor)
                ios_runtime.require(stat.S_ISREG(before.st_mode)
                                    and 0 <= before.st_size <= _LIMIT,
                                    "source shape/size limit")
                content = bytearray()
                while len(content) <= _LIMIT:
                    chunk = os.read(descriptor, min(65536, _LIMIT + 1 - len(content)))
                    if not chunk:
                        break
                    content.extend(chunk)
                ios_runtime.require(len(content) <= _LIMIT and len(content) == before.st_size,
                                    "source read size limit or change")
                files.append((path, name, descriptor, before, bytes(content)))

            metadata = git_loose_acquire._metadata
            for _, name, descriptor, before, _ in files:
                ios_runtime.require(metadata(os.fstat(descriptor)) == metadata(before)
                                    and metadata(os.stat(name, dir_fd=parent,
                                                         follow_symlinks=False))
                                    == metadata(before), "source changed or replaced")
            for directory_parent, name, descriptor, before in directories:
                ios_runtime.require(metadata(os.fstat(descriptor)) == metadata(before)
                                    and metadata(os.stat(name, dir_fd=directory_parent,
                                                         follow_symlinks=False))
                                    == metadata(before), "source directory changed or replaced")
            reopened = git_loose_acquire._open_owned(
                stack, checkout_head._open_checkout_root, pieces,
            )
            ios_runtime.require(metadata(os.fstat(root)) == metadata(root_info)
                                and metadata(os.fstat(reopened)) == metadata(root_info),
                                "checkout root changed or replaced")
            _module_paths(checkout_root)
            result = {}
            for path, _, _, _, data in files:
                blob, expected = tracked[path]
                ios_runtime.require(data == expected, "source differs from tracked blob")
                result[path] = {"blob": blob, "sha256": hashlib.sha256(data).hexdigest()}
            return result
    except ios_runtime.Refusal:
        raise
    except Exception as error:
        raise ios_runtime.Refusal("fixed source observation refused") from error
