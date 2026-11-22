"""Opt-in fixed source and same-job snapshot observations, not authority."""

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
_CONTEXT_NAME = "github_context.py"
_PATHS_V3 = tuple(sorted((*_PATHS, f"{_DIRECTORY}/{_CONTEXT_NAME}")))
_LIMIT = 128 * 1024
SCHEMA = "ios-source-snapshot-composition-observation-v1"
SCHEMA_V2 = "ios-source-snapshot-composition-observation-v2"
SCHEMA_V3 = "ios-source-snapshot-composition-observation-v3"
ASSURANCE = "same-job-unauthenticated-observation-not-custody-or-authority"


def _module_graph():
    edges = (
        (provider_attribution.runtime, ios_runtime),
        (git_snapshot_reader.checkout_head, checkout_head),
        (git_snapshot_reader.git_loose, git_loose),
        (git_snapshot_reader.git_loose_acquire, git_loose_acquire),
        (git_snapshot_reader.git_pack, git_pack),
        (git_snapshot_reader.git_pack_acquire, git_pack_acquire),
        (git_loose_acquire.checkout_head, checkout_head),
        (git_loose_acquire.git_loose, git_loose),
        (git_pack_acquire.checkout_head, checkout_head),
        (git_pack_acquire.git_loose_acquire, git_loose_acquire),
        (git_pack_acquire.git_pack, git_pack),
        (git_pack.git_delta, git_delta),
    )
    ios_runtime.require(all(actual is expected for actual, expected in edges),
                        "project module dependency differs")


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


def _context_module_graph(context_module):
    import github_context

    _module_graph()
    ios_runtime.require(github_context is context_module
                        and context_module.runtime is ios_runtime
                        and context_module.attribution is provider_attribution,
                        "project module dependency differs")


def _context_module_paths(root, context_module):
    _module_paths(root)
    ios_runtime.require(type(context_module.__file__) is str
                        and context_module.__file__ == f"{root}/{_DIRECTORY}/{_CONTEXT_NAME}",
                        "loaded module path differs from fixed source")


class _Descriptor:
    """Close exactly once, retaining any simultaneous operation failure."""

    def __init__(self):
        self.fd = None

    def __exit__(self, exc_type, exc_value, traceback):
        descriptor, self.fd = self.fd, None
        if descriptor is not None:
            try:
                os.close(descriptor)
            except (KeyboardInterrupt, SystemExit, Exception) as error:
                if isinstance(exc_value, (KeyboardInterrupt, SystemExit)):
                    exc_value.cleanup_errors = (
                        getattr(exc_value, "cleanup_errors", ()) + (error,)
                    )
                    return False
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    error.original_error = exc_value
                    raise
                refusal = ios_runtime.Refusal("descriptor cleanup failed")
                refusal.original_error = exc_value
                raise refusal from error
        return False


def _open_owned(stack, opener, *args, **kwargs):
    owner = _Descriptor()
    stack.push(owner)
    owner.fd = opener(*args, **kwargs)
    return owner


def _directory(stack, parent, name):
    owner = _open_owned(stack, os.open, name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    ios_runtime.require(stat.S_ISDIR(os.fstat(owner.fd).st_mode),
                        "expected a real directory")
    return owner


def _root(stack, pieces):
    owner = _open_owned(stack, os.open, "/", os.O_RDONLY | os.O_DIRECTORY)
    for piece in pieces:
        child = _directory(stack, owner.fd, piece)
        owner.__exit__(None, None, None)
        owner = child
    return owner.fd


def _observe_sources(checkout_root, tree, objects):
    """Compare ten fresh fixed sources to tree blobs using the supplied _Objects."""
    return _observe_fixed_sources(checkout_root, tree, objects, _PATHS,
                                  _module_graph, _module_paths)


def _observe_context_sources(checkout_root, tree, objects, context_module):
    return _observe_fixed_sources(checkout_root, tree, objects, _PATHS_V3,
                                  lambda: _context_module_graph(context_module),
                                  lambda root: _context_module_paths(root, context_module))


def _observe_fixed_sources(checkout_root, tree, objects, paths, module_graph, module_paths):
    try:
        module_graph()
        pieces = checkout_head._checkout_path(checkout_root)
        checkout_head._expected_oid(tree)
        ios_runtime.require(type(objects) is provider_attribution._Objects,
                            "expected existing Git object budget")
        if (not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY")
                or not hasattr(os, "O_NONBLOCK") or os.open not in os.supports_dir_fd
                or os.stat not in os.supports_dir_fd
                or os.stat not in os.supports_follow_symlinks):
            raise ios_runtime.Refusal("descriptor-relative no-follow observation unavailable")
        module_paths(checkout_root)
        tracked = provider_attribution._Objects.files(objects, tree, paths)
        with ExitStack() as stack:
            root = _root(stack, pieces)
            root_info = os.fstat(root)
            parent = root
            directories = []
            for name in ("scripts", "test-audit-run"):
                child = _directory(stack, parent, name).fd
                directories.append((parent, name, child, os.fstat(child)))
                parent = child

            files = []
            for path in paths:
                name = path.rpartition("/")[2]
                descriptor = _open_owned(
                    stack, os.open, name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=parent,
                ).fd
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
            reopened = _root(stack, pieces)
            ios_runtime.require(metadata(os.fstat(root)) == metadata(root_info)
                                and metadata(os.fstat(reopened)) == metadata(root_info),
                                "checkout root changed or replaced")
            module_paths(checkout_root)
            module_graph()
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


def _snapshot(checkout_root, context_reader, reader, source_reader=None):
    context = provider_attribution._context(context_reader())
    checkout_head.observe_checkout_head(checkout_root, context["checkout_sha"])
    objects = provider_attribution._Objects(reader)
    attribution = provider_attribution._snapshot_objects(context, objects)
    if source_reader is None:
        source_reader = _observe_sources
    sources = source_reader(checkout_root, attribution["checkout"]["tree"], objects)
    ios_runtime.require(all(attribution["executing_sources"][path] == sources[path]
                            for path in provider_attribution.SOURCES),
                        "duplicate source observations differ")
    return attribution, sources


def observe(checkout_root, pack_id, context_reader):
    """Observe two fresh snapshots around the fixed provider verifier."""
    return _observe(checkout_root, pack_id, context_reader,
                    git_snapshot_reader.Invocation, SCHEMA)


def observe_v2(checkout_root, pack_id, context_reader):
    """Observe using the explicit 16 MiB pair profile."""
    return _observe(checkout_root, pack_id, context_reader,
                    git_snapshot_reader.InvocationV2, SCHEMA_V2)


def observe_v3(checkout_root, pack_id, input_reader):
    """Project explicit inputs anew for each snapshot, using the v2 pair profile."""
    import github_context

    def context_reader():
        _context_module_graph(github_context)
        _context_module_paths(checkout_root, github_context)
        inputs = input_reader()
        ios_runtime.require(type(inputs) is tuple and len(inputs) == 3,
                            "expected explicit context inputs")
        _context_module_graph(github_context)
        _context_module_paths(checkout_root, github_context)
        return github_context.read_context(*inputs)

    def sources(root, tree, objects):
        return _observe_context_sources(root, tree, objects, github_context)

    return _observe(checkout_root, pack_id, context_reader,
                    git_snapshot_reader.InvocationV2, SCHEMA_V3,
                    sources)


def _observe(checkout_root, pack_id, context_reader, invocation_type, schema,
             source_reader=None):
    try:
        invocation = invocation_type(checkout_root, pack_id)
        before, sources = _snapshot(checkout_root, context_reader, invocation.snapshot(),
                                    source_reader)
        with ios_runtime.provider_verified_checker() as (spellings, observation):
            provider = provider_attribution._provider(observation, spellings)
        after, later_sources = _snapshot(checkout_root, context_reader, invocation.snapshot(),
                                         source_reader)
        ios_runtime.require((after, later_sources) == (before, sources),
                            "source/job observation changed")
        ios_runtime.require(provider_attribution._provider(observation, spellings) == provider,
                            "provider output mutated")
        attribution = {"schema": provider_attribution.SCHEMA,
                       "assurance": provider_attribution.ASSURANCE,
                       **before, "provider_runtime": provider}
        # Preserve the v1 envelope's own encoding/size check as well.
        provider_attribution._encode(attribution)
        return provider_attribution._encode({
            "schema": schema, "assurance": ASSURANCE,
            "attribution": attribution, "sources": sources,
        })
    except ios_runtime.Refusal:
        raise
    except (OSError, KeyError, ValueError) as error:
        raise ios_runtime.Refusal("snapshot composition observation unavailable") from error


def validate(data, checkout_root, pack_id, context_reader):
    """Compare only with a fresh observation, never with parsed candidate claims."""
    ios_runtime.require(type(data) is bytes and len(data) <= provider_attribution.ENVELOPE_LIMIT,
                        "invalid composition output size/type")
    ios_runtime.require(data == observe(checkout_root, pack_id, context_reader),
                        "composition output differs from fresh observations")


def validate_v2(data, checkout_root, pack_id, context_reader):
    """Compare v2 bytes only with a fresh v2 observation."""
    ios_runtime.require(type(data) is bytes and len(data) <= provider_attribution.ENVELOPE_LIMIT,
                        "invalid composition output size/type")
    ios_runtime.require(data == observe_v2(checkout_root, pack_id, context_reader),
                        "composition output differs from fresh observations")


def validate_v3(data, checkout_root, pack_id, input_reader):
    """Compare v3 bytes only with a fresh v3 observation."""
    ios_runtime.require(type(data) is bytes and len(data) <= provider_attribution.ENVELOPE_LIMIT,
                        "invalid composition output size/type")
    ios_runtime.require(data == observe_v3(checkout_root, pack_id, input_reader),
                        "composition output differs from fresh observations")
