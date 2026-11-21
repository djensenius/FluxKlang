"""Closed same-job observations, NOT authenticated provenance or launch authority.

No CLI, environment reader, Git subprocess adapter, output writer, or launch API.
The future reviewed runner supplies context and raw Git-object readers as code,
never as serialized commands. Readers must be bounded/read-only and independently
reviewed; this module does not authenticate them or the provider.
"""

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat

import ios_runtime as runtime


SCHEMA = "ios-provider-job-attribution-observation-v1"
ASSURANCE = "provider-job-reported-observation-not-authenticated-provenance"
SOURCES = (
    "scripts/test-audit-run/provider_attribution.py",
    "scripts/test-audit-run/ios_runtime.py",
)
SOURCE_LIMIT = 128 * 1024
OBJECT_LIMIT = 256 * 1024
OBJECT_COUNT = 32
ENVELOPE_LIMIT = 32 * 1024
HEX = r"[0-9a-f]{40}"
CONTEXT_KEYS = {
    "repository", "event_name", "event_sha", "event_ref", "checkout_sha",
    "pull_request", "workflow", "run_id", "run_attempt", "job",
    "runner", "platform",
}


def _shape(value, keys):
    runtime.require(type(value) is dict and len(value) == len(keys)
                    and set(value) == set(keys),
                    "missing/extra observation fields")


def _text(value, pattern, limit=256):
    runtime.require(type(value) is str and 0 < len(value) <= limit
                    and re.fullmatch(pattern, value, flags=re.ASCII) is not None,
                    "malformed observation identity")
    return value


def _oid(value):
    return _text(value, HEX, 40)


def _number(value):
    runtime.require(type(value) is int and 0 < value <= 2**63 - 1,
                    "invalid numeric observation identity")


def _context(value):
    _shape(value, CONTEXT_KEYS)
    _text(value["repository"], r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
    runtime.require(type(value["event_name"]) is str
                    and value["event_name"] in ("push", "workflow_dispatch", "pull_request"),
                    "unsupported event")
    for key in ("event_sha", "checkout_sha"):
        _oid(value[key])
    runtime.require(value["event_sha"] == value["checkout_sha"],
                    "event/checkout mismatch")
    for key in ("run_id", "run_attempt"):
        _number(value[key])
    _text(value["job"], r"[A-Za-z_][A-Za-z0-9_-]*", 100)
    _shape(value["runner"], {"name", "environment"})
    _text(value["runner"]["name"], r"[A-Za-z0-9_][A-Za-z0-9_. -]*", 128)
    runtime.require(type(value["runner"]["environment"]) is str
                    and value["runner"]["environment"] == "github-hosted",
                    "only reported github-hosted context is supported")
    _shape(value["platform"], {"os", "arch"})
    runtime.require(type(value["platform"]["os"]) is str
                    and type(value["platform"]["arch"]) is str
                    and value["platform"] == {"os": "macOS", "arch": "ARM64"},
                    "unsupported reported platform")
    pr = value["pull_request"]
    if value["event_name"] == "pull_request":
        _shape(pr, {"number", "head_sha", "base_sha"})
        _number(pr["number"])
        _oid(pr["head_sha"])
        _oid(pr["base_sha"])
        runtime.require(len({pr["head_sha"], pr["base_sha"], value["checkout_sha"]}) == 3,
                        "ambiguous PR commits")
        runtime.require(type(value["event_ref"]) is str
                        and value["event_ref"] == f"refs/pull/{pr['number']}/merge",
                        "PR requires synthetic-merge event ref")
    else:
        runtime.require(pr is None, "non-PR context contains PR identity")
        _text(value["event_ref"], r"refs/(heads|tags)/[A-Za-z0-9_./-]+")
        runtime.require(not any(part in ("", ".", "..")
                                for part in value["event_ref"].split("/"))
                        and ".." not in value["event_ref"],
                        "ambiguous event ref")
    workflow = value["workflow"]
    if workflow is not None:
        _shape(workflow, {"sha", "ref", "path"})
        _oid(workflow["sha"])
        _text(workflow["path"], r"\.github/workflows/[A-Za-z0-9_-]+\.ya?ml")
        prefix = value["repository"] + "/" + workflow["path"] + "@"
        runtime.require(type(workflow["ref"]) is str
                        and workflow["ref"].startswith(prefix),
                        "workflow repository/path mismatch")
        ref = workflow["ref"][len(prefix):]
        _text(ref, r"refs/(heads|tags)/[A-Za-z0-9_./-]+|refs/pull/[1-9][0-9]*/merge")
        runtime.require(len(workflow["ref"]) <= 512 and ".." not in ref
                        and all(part not in ("", ".") for part in ref.split("/")),
                        "ambiguous workflow ref")
    return copy.deepcopy(value)


class _Objects:
    """Validate SHA-1 Git objects, with a total request and byte budget."""

    def __init__(self, reader):
        self.reader = reader
        self.count = 0
        self.total = 0

    def get(self, oid, kind):
        _oid(oid)
        self.count += 1
        runtime.require(self.count <= OBJECT_COUNT, "Git object count limit")
        try:
            result = self.reader(oid)
        except (OSError, KeyError) as error:
            raise runtime.Refusal("Git object observation unavailable") from error
        runtime.require(type(result) is tuple and len(result) == 2,
                        "invalid Git object observation")
        observed_kind, data = result
        runtime.require(type(observed_kind) is str and observed_kind == kind
                        and type(data) is bytes
                        and len(data) <= OBJECT_LIMIT, "Git object shape/size limit")
        self.total += len(data)
        runtime.require(self.total <= 1024 * 1024, "Git object total size limit")
        header = f"{kind} {len(data)}\0".encode("ascii")
        runtime.require(hashlib.sha1(header + data).hexdigest() == oid,
                        "Git object identity mismatch")
        return data

    def commit(self, oid):
        data = self.get(oid, "commit")
        headers, separator, _ = data.partition(b"\n\n")
        runtime.require(separator and len(headers) <= 16384,
                        "malformed commit headers")
        lines = headers.split(b"\n")
        runtime.require(lines and re.fullmatch(b"tree [0-9a-f]{40}", lines[0]),
                        "malformed commit tree")
        parents = []
        index = 1
        while index < len(lines) and lines[index].startswith(b"parent "):
            runtime.require(re.fullmatch(b"parent [0-9a-f]{40}", lines[index]),
                            "malformed commit parent")
            parents.append(lines[index][7:].decode("ascii"))
            index += 1
        runtime.require(len(parents) <= 2 and len(set(parents)) == len(parents)
                        and not any(line.startswith((b"tree ", b"parent "))
                                    for line in lines[index:]),
                        "ambiguous commit ancestry")
        return lines[0][5:].decode("ascii"), parents

    def _tree(self, tree):
        data = _Objects.get(self, tree, "tree")
        entries = {}
        while data:
            header, separator, rest = data.partition(b"\0")
            runtime.require(separator and len(rest) >= 20, "malformed Git tree")
            mode, space, name = header.partition(b" ")
            runtime.require(space and mode in (b"40000", b"100644", b"100755")
                            and 0 < len(name) <= 255 and b"/" not in name
                            and re.fullmatch(rb"[A-Za-z0-9_. -]+", name)
                            and name not in (b".", b"..") and name not in entries,
                            "unsupported/ambiguous Git tree entry")
            entries[name] = (mode, rest[:20].hex())
            runtime.require(len(entries) <= 1024, "Git tree entry count limit")
            data = rest[20:]
        return entries

    def file(self, tree, path):
        parts = path.split("/")
        for index, part in enumerate(parts):
            entries = self._tree(tree)
            runtime.require(part.encode("ascii") in entries, "tracked source unavailable")
            mode, tree = entries[part.encode("ascii")]
            runtime.require(mode == b"40000" if index < len(parts) - 1
                            else mode in (b"100644", b"100755"),
                            "source is not a tracked regular file")
        return tree, self.get(tree, "blob")

    def files(self, tree, paths):
        """Opt-in lookup of explicitly named files in one directory, not enumeration."""
        runtime.require(type(paths) in (tuple, list) and 0 < len(paths) <= OBJECT_COUNT,
                        "invalid grouped source paths")
        for path in paths:
            runtime.require(type(path) is str and 0 < len(path) <= 4096,
                            "invalid grouped source path")
            parts = path.split("/")
            runtime.require(len(parts) <= OBJECT_COUNT and all(
                0 < len(part) <= 255 and part not in (".", "..")
                and re.fullmatch(r"[A-Za-z0-9_. -]+", part, flags=re.ASCII)
                for part in parts), "invalid grouped source path")
        ordered = sorted(paths)
        runtime.require(len(set(ordered)) == len(ordered)
                        and len({path.rpartition("/")[0] for path in ordered}) == 1,
                        "grouped sources must be distinct and share a directory")
        parent = ordered[0].rpartition("/")[0]
        for part in parent.split("/") if parent else ():
            entries = _Objects._tree(self, tree)
            name = part.encode("ascii")
            runtime.require(name in entries, "tracked source unavailable")
            mode, tree = entries[name]
            runtime.require(mode == b"40000", "source is not a tracked regular file")
        entries = _Objects._tree(self, tree)
        blobs = {}
        for path in ordered:
            name = path.rpartition("/")[2].encode("ascii")
            runtime.require(name in entries, "tracked source unavailable")
            mode, oid = entries[name]
            runtime.require(mode in (b"100644", b"100755"),
                            "source is not a tracked regular file")
            blobs[path] = oid
        return {path: (oid, _Objects.get(self, oid, "blob")) for path, oid in blobs.items()}


def _source(path):
    """Only the two fixed executing modules; no candidate-selected paths."""
    runtime.require(type(path) is str and path in SOURCES,
                    "source outside fixed executing allowlist")
    root = Path(__file__).absolute().parents[2]
    target = root / path
    runtime.require(Path(runtime.__file__).absolute() == root / SOURCES[1],
                    "runtime imported from outside executing source allowlist")
    for component in (target, *target.parents):
        runtime.require(not component.is_symlink(), "symlink in executing source path")
    descriptor = None
    try:
        descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(descriptor)
        runtime.require(stat.S_ISREG(info.st_mode) and info.st_size <= SOURCE_LIMIT,
                        "executing source shape/size limit")
        data = bytearray()
        while len(data) <= SOURCE_LIMIT:
            chunk = os.read(descriptor, min(65536, SOURCE_LIMIT + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        runtime.require(runtime._identity(os.fstat(descriptor)) == runtime._identity(info)
                        and runtime._identity(os.stat(target, follow_symlinks=False))
                        == runtime._identity(info), "executing source changed while reading")
    except OSError as error:
        raise runtime.Refusal("executing source unavailable") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
    runtime.require(len(data) <= SOURCE_LIMIT, "executing source size limit")
    runtime.require(len(data) == info.st_size, "executing source read size mismatch")
    return bytes(data)


def _snapshot(context_reader, object_reader):
    context = _context(context_reader())
    objects = _Objects(object_reader)
    tree, parents = objects.commit(context["checkout_sha"])
    pr = context["pull_request"]
    if pr is not None:
        runtime.require(parents == [pr["base_sha"], pr["head_sha"]],
                        "PR synthetic merge parents do not match exact base/head")
    sources = {}
    for path in SOURCES:
        blob, tracked = objects.file(tree, path)
        data = _source(path)
        runtime.require(data == tracked, "executing source differs from checkout")
        sources[path] = {"blob": blob, "sha256": hashlib.sha256(data).hexdigest()}
    workflow = context["workflow"]
    if workflow is None:
        workflow_record = {"status": "unavailable", "sha": None, "ref": None,
                           "path": None, "blob": None}
    else:
        workflow_tree, _ = objects.commit(workflow["sha"])
        blob, _ = objects.file(workflow_tree, workflow["path"])
        workflow_record = {"status": "observed", **workflow, "blob": blob}
    return {
        "context": context,
        "checkout": {"commit": context["checkout_sha"], "tree": tree, "parents": parents,
                     "kind": "pr-synthetic-merge" if pr else "event-commit"},
        "workflow": workflow_record,
        "executing_sources": sources,
    }


def _provider(observation, spellings):
    """Check the existing provider record without changing that profile/schema."""
    _shape(observation, {"schema", "xcode", "runtime", "checker"})
    xcode = observation["xcode"]
    _shape(xcode, runtime.ProviderXcodeObservation.__annotations__)
    for key in ("xcodebuild_file_identity", "simctl_file_identity"):
        identity = xcode[key]
        runtime.require(type(identity) is list and len(identity) == 8
                        and all(type(n) is int and 0 <= n <= 2**63 - 1 for n in identity),
                        "malformed provider file identity")
    details = observation["runtime"]
    _shape(details, runtime.ProviderRuntimeObservationDetails.__annotations__)
    bundle = _text(details["bundle_path"], r"/[A-Za-z0-9_./ -]+", 4096)
    runtime._path(bundle)
    runtime.require(bundle.startswith("/private/var/")
                    and bundle.endswith("/iOS 27.0.simruntime"),
                    "unexpected provider bundle")
    root = bundle + "/Contents/Resources/RuntimeRoot"
    canonical = root + "/usr/lib/libMainThreadChecker.dylib"
    alias = canonical[len("/private"):]
    expected = {
        "schema": "ios-provider-trusted-runtime-observation-v1",
        "xcode": {
            "developer_directory": runtime.DEVELOPER, "version": "Xcode 27.1",
            "build": "27A9275", "simulator_sdk_version": "27.1",
            "xcodebuild_path": runtime.DEVELOPER + "/usr/bin/xcodebuild",
            "xcodebuild_file_identity": xcode["xcodebuild_file_identity"],
            "xcodebuild_apple_anchor_check": "passed",
            "simctl_path": runtime.DEVELOPER + "/usr/bin/simctl",
            "simctl_file_identity": xcode["simctl_file_identity"],
            "simctl_apple_anchor_check": "passed",
        },
        "runtime": {"identifier": runtime.RUNTIME, "version": "27.0", "build": "24A434",
                    "available": True, "bundle_path": bundle, "runtime_root": root},
        "checker": {
            "canonical_path": canonical, "accepted_paths": [canonical, alias],
            "size": runtime.LIBRARY_SIZE, "sha256": runtime.LIBRARY_SHA256,
            "architecture": "arm64", "signature_requirement": runtime.REQUIREMENT,
            "signature_check": "passed",
        },
    }
    _shape(observation["checker"], runtime.ProviderCheckerObservation.__annotations__)
    for section in ("xcode", "runtime", "checker"):
        for key, expected_value in expected[section].items():
            actual = observation[section][key]
            runtime.require(type(actual) is type(expected_value) and actual == expected_value,
                            "malformed provider observation field")
    runtime.require(type(observation["schema"]) is str
                    and observation["schema"] == expected["schema"],
                    "malformed provider observation schema")
    # Canonical JSON comparison also distinguishes bool from int.
    runtime.require(_encode(observation) == _encode(expected)
                    and type(spellings) is tuple and spellings == (canonical, alias),
                    "malformed/changed provider observation")
    return copy.deepcopy(observation)


def _encode(record):
    try:
        data = json.dumps(record, sort_keys=True, separators=(",", ":"),
                          ensure_ascii=True, allow_nan=False).encode("ascii")
    except (TypeError, ValueError, RecursionError) as error:
        raise runtime.Refusal("invalid observation encoding") from error
    runtime.require(len(data) <= ENVELOPE_LIMIT, "observation output size limit")
    return data


def observe(context_reader, object_reader):
    """Return canonical bytes only after stable source/context/runtime checks.

    Context is a closed projection, not an env dump or input authority. The
    object reader returns (kind, raw bytes), never paths/commands. No claim about
    ref freshness, provider honesty, or in-memory code integrity is made.
    """
    before = _snapshot(context_reader, object_reader)
    with runtime.provider_verified_checker() as (spellings, observation):
        provider = _provider(observation, spellings)
    runtime.require(_snapshot(context_reader, object_reader) == before,
                    "source/job observation changed")
    runtime.require(_provider(observation, spellings) == provider,
                    "provider output mutated")
    return _encode({"schema": SCHEMA, "assurance": ASSURANCE,
                    **before, "provider_runtime": provider})


def validate(data, context_reader, object_reader):
    """Fresh same-job comparison, not a receipt, attestation, or reusable token."""
    runtime.require(type(data) is bytes and len(data) <= ENVELOPE_LIMIT,
                    "invalid attribution output size/type")
    runtime.require(data == observe(context_reader, object_reader),
                    "attribution output differs from fresh observations")
