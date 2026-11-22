"""Fresh, read-only authority for the closed Xcode 27.1 / iOS 27.0 profile.

No context/receipt input, caching, destination selection, or launch capability.
Only independently discovered paths reach filesystem or native-tool probes.
"""

from contextlib import ExitStack, contextmanager
import hashlib
import json
import os
import plistlib
import selectors
import stat
import struct
import subprocess
import sys
import time
from typing import TypedDict


RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEVELOPER = "/Applications/Xcode_27.1.app/Contents/Developer"
LIBRARY_SHA256 = "1ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8"
LIBRARY_SIZE = 338880
REQUIREMENT = '=identifier "com.apple.libMainThreadChecker" and anchor apple'
OUTPUT_LIMIT = 2 * 1024 * 1024
TIMEOUT = 30
ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}


class ProviderXcodeObservation(TypedDict):
    developer_directory: str
    version: str
    build: str
    simulator_sdk_version: str
    xcodebuild_path: str
    xcodebuild_file_identity: list
    xcodebuild_apple_anchor_check: str
    simctl_path: str
    simctl_file_identity: list
    simctl_apple_anchor_check: str


class ProviderRuntimeObservationDetails(TypedDict):
    identifier: str
    version: str
    build: str
    available: bool
    bundle_path: str
    runtime_root: str


class ProviderCheckerObservation(TypedDict):
    canonical_path: str
    accepted_paths: list
    size: int
    sha256: str
    architecture: str
    signature_requirement: str
    signature_check: str


class ProviderRuntimeObservation(TypedDict):
    schema: str
    xcode: ProviderXcodeObservation
    runtime: ProviderRuntimeObservationDetails
    checker: ProviderCheckerObservation


class Refusal(ValueError):
    """Live authority was unavailable, changed, or outside the closed pins."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def _command(argv, developer=None):
    """Fixed callers only; bounded merged output, deadline, no inherited env."""
    env = dict(ENV)
    if developer is not None:
        env["DEVELOPER_DIR"] = developer
    try:
        process = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=env, cwd="/", bufsize=0,
        )
        try:
            data = bytearray()
            deadline = time.monotonic() + TIMEOUT
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    require(remaining > 0, "runtime verification command timed out")
                    require(selector.select(remaining), "runtime verification command timed out")
                    chunk = os.read(process.stdout.fileno(), min(65536, OUTPUT_LIMIT + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    require(len(data) <= OUTPUT_LIMIT, "runtime verification output limit")
            remaining = deadline - time.monotonic()
            require(remaining > 0, "runtime verification command timed out")
            require(process.wait(timeout=remaining) == 0, "runtime verification command failed")
            return data.decode("utf-8", errors="strict").strip()
        finally:
            # Popen.__exit__ waits without a timeout, including after a failed
            # kill or bounded cleanup wait. Close explicitly instead.
            try:
                if process.poll() is None:
                    try:
                        process.kill()
                    finally:
                        process.wait(timeout=TIMEOUT)
            finally:
                process.stdout.close()
    except (OSError, UnicodeError, subprocess.SubprocessError) as error:
        raise Refusal("runtime verification command unavailable") from error


def _register_cleanup(stack, action):
    """Attempt cleanup without replacing a higher-priority active exception."""
    def cleanup(exc_type, exc_value, traceback):
        try:
            action()
        except BaseException as error:
            if exc_type is None or (
                isinstance(exc_value, Exception) and not isinstance(error, Exception)
            ):
                raise
        return False

    stack.push(cleanup)


def _cleanup_error(active, error):
    if active is None or (isinstance(active, Exception) and not isinstance(error, Exception)):
        return error
    return active


def _cleanup_attempt(active, action):
    """Return the higher-priority active or cleanup exception, if any."""
    try:
        action()
    except BaseException as error:
        return _cleanup_error(active, error)
    return active


def _cleanup_child(process, active):
    running = True
    try:
        running = process.poll() is None
    except BaseException as error:
        active = _cleanup_error(active, error)
    if running:
        active = _cleanup_attempt(active, lambda: process.kill())
        active = _cleanup_attempt(active, lambda: process.wait(timeout=TIMEOUT))
    return active


def _bounded_command(argv, developer=None):
    """Same fixed command limits, with opt-in precedence-aware cleanup."""
    env = dict(ENV)
    if developer is not None:
        env["DEVELOPER_DIR"] = developer
    try:
        active = None
        process = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=env, cwd="/", bufsize=0,
        )
        try:
            data = bytearray()
            deadline = time.monotonic() + TIMEOUT
            selector_active = None
            selector = selectors.DefaultSelector()
            try:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    require(remaining > 0, "runtime verification command timed out")
                    require(selector.select(remaining), "runtime verification command timed out")
                    chunk = os.read(process.stdout.fileno(), min(65536, OUTPUT_LIMIT + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    require(len(data) <= OUTPUT_LIMIT, "runtime verification output limit")
            except BaseException as error:
                selector_active = error
                raise
            finally:
                cleanup_error = _cleanup_attempt(selector_active, lambda: selector.close())
                if cleanup_error is not selector_active:
                    raise cleanup_error
            remaining = deadline - time.monotonic()
            require(remaining > 0, "runtime verification command timed out")
            require(process.wait(timeout=remaining) == 0, "runtime verification command failed")
            return data.decode("utf-8", errors="strict").strip()
        except BaseException as error:
            active = error
            raise
        finally:
            cleanup_error = _cleanup_child(process, active)
            cleanup_error = _cleanup_attempt(cleanup_error, lambda: process.stdout.close())
            if cleanup_error is not active:
                raise cleanup_error
    except (OSError, UnicodeError, subprocess.SubprocessError) as error:
        raise Refusal("runtime verification command unavailable") from error


def _path(value):
    require(type(value) is str and value.startswith("/") and len(value) <= 4096,
            "invalid inventory path")
    require(not any(c in value for c in "\0\n\r:") and
            all(part not in ("", ".", "..") for part in value.split("/")[1:]),
            "ambiguous inventory path")
    return value


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _owned(info, directory=False):
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            "non-directory ancestor" if directory else "not a regular file")
    require(info.st_uid == 0 and not info.st_mode & 0o022,
            "runtime/tool path must be root-owned and not group/world writable")


def _readonly_plist(fd):
    info = os.fstat(fd)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0
            and stat.S_IMODE(info.st_mode) == 0o664, "unreviewed runtime plist file shape")
    require(os.fstatvfs(fd).f_flag & os.ST_RDONLY,
            "runtime plist requires a read-only filesystem")


@contextmanager
def _open_file(path, *, runtime_plist=False):
    """Descriptor-relative no-follow walk, as in build_receipt, standalone here.

    Hold all ancestors and reject path replacement on return. No candidate
    path is used here; even root-owned symlink components are refused.
    """
    parts = _path(path).split("/")[1:]
    descriptors = []
    links = []
    try:
        current = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(current)
        _owned(os.fstat(current), directory=True)
        for index, part in enumerate(parts):
            directory = index < len(parts) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if directory:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=current)
            descriptors.append(child)
            info = os.fstat(child)
            if runtime_plist and not directory:
                _readonly_plist(child)
            else:
                _owned(info, directory)
            # Directory timestamps can change for unrelated children. Their
            # identity/ownership/mode must not; the file also binds timestamps.
            identity = _identity(info)[:5] if directory else _identity(info)
            links.append((current, part, child, identity, directory))
            current = child
        yield current
        if runtime_plist:
            _readonly_plist(current)
        for parent, part, child, identity, directory in links:
            for info in (os.fstat(child), os.stat(part, dir_fd=parent, follow_symlinks=False)):
                observed = _identity(info)[:5] if directory else _identity(info)
                require(observed == identity, "runtime/tool path replaced during verification")
    except OSError as error:
        raise Refusal("runtime/tool filesystem verification unavailable") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _read(fd, limit):
    os.lseek(fd, 0, os.SEEK_SET)
    result = bytearray()
    while len(result) <= limit:
        chunk = os.read(fd, min(65536, limit + 1 - len(result)))
        if not chunk:
            break
        result.extend(chunk)
    require(len(result) <= limit, "runtime file size limit")
    return bytes(result)


def _json_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate inventory key")
        result[key] = value
    return result


def _inventory():
    require(sys.platform == "darwin" and os.uname().machine == "arm64",
            "runtime profile requires live Darwin arm64 verification")
    # Use the reviewed hosted toolchain, not caller environment or a different
    # system default. No xcode-select mutation is needed.
    developer = DEVELOPER
    xcodebuild = developer + "/usr/bin/xcodebuild"
    simctl = developer + "/usr/bin/simctl"
    with _open_file(xcodebuild) as xcode_fd, _open_file(simctl) as simctl_fd:
        for tool in (xcodebuild, simctl):
            _command(["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple", tool])
        require(_command([xcodebuild, "-version"], developer) ==
                "Xcode 27.1\nBuild version 27A9275", "unreviewed Xcode version/build")
        require(_command([xcodebuild, "-version", "-sdk", "iphonesimulator", "SDKVersion"],
                         developer) == "27.1", "unreviewed simulator SDK")
        try:
            inventory = json.loads(
                _command([simctl, "list", "runtimes", "--json"], developer),
                object_pairs_hook=_json_pairs,
            )
        except (ValueError, TypeError) as error:
            raise Refusal("invalid runtime inventory") from error
        require(type(inventory) is dict and type(inventory.get("runtimes")) is list,
                "invalid runtime inventory shape")
        require(all(type(item) is dict for item in inventory["runtimes"]),
                "invalid runtime entry")
        selected = [item for item in inventory["runtimes"] if item.get("identifier") == RUNTIME]
        require(len(selected) == 1, "selected runtime missing or ambiguous")
        runtime = selected[0]
        require(runtime.get("version") == "27.0" and runtime.get("buildversion") == "24A434"
                and runtime.get("isAvailable") is True, "unreviewed/unavailable runtime")
        bundle = _path(runtime.get("bundlePath"))
        root = _path(runtime.get("runtimeRoot"))
        require(bundle.startswith("/private/var/") and bundle.endswith("/iOS 27.0.simruntime")
                and root == bundle + "/Contents/Resources/RuntimeRoot",
                "unexpected runtime bundle/root relationship")
        # No guessed cryptex suffix, device selection, or bundle-version/build
        # conflation. Inventory 24A434 is the build, not Info.plist's 392.
        return (developer, _identity(os.fstat(xcode_fd)), _identity(os.fstat(simctl_fd)),
                bundle, root)


def _alias(canonical):
    """Prove only the standard /var -> private/var alias, not general realpath."""
    info = os.lstat("/var")
    require(stat.S_ISLNK(info.st_mode) and info.st_uid == 0 and
            os.readlink("/var") in ("private/var", "/private/var"),
            "standard /var alias unavailable")
    private = os.lstat("/private")
    target = os.lstat("/private/var")
    _owned(private, directory=True)
    _owned(target, directory=True)
    require(_identity(os.stat("/var")) == _identity(target), "standard /var identity mismatch")
    alias = canonical[len("/private"):]
    require(_identity(os.stat(alias)) == _identity(os.stat(canonical, follow_symlinks=False)),
            "checker alias identity mismatch")
    return alias, _identity(info), _identity(private)[:5], _identity(target)[:5]


def _library(fd, canonical):
    info = os.fstat(fd)
    require(info.st_size == LIBRARY_SIZE and stat.S_IMODE(info.st_mode) == 0o755
            and info.st_uid == 0, "unreviewed checker file shape")
    data = _read(fd, LIBRARY_SIZE)
    require(hashlib.sha256(data).hexdigest() == LIBRARY_SHA256, "unreviewed checker digest")
    require(data[:8] == struct.pack("<II", 0xFEEDFACF, 0x0100000C),
            "checker must be thin arm64 Mach-O")
    _command(["/usr/bin/codesign", "--verify", "--strict", "-R", REQUIREMENT, canonical])
    require(_identity(os.fstat(fd)) == _identity(info), "checker changed during signature check")
    require(_identity(os.stat(canonical, follow_symlinks=False)) == _identity(info),
            "checker replaced during signature check")
    require(hashlib.sha256(_read(fd, LIBRARY_SIZE)).hexdigest() == LIBRARY_SHA256,
            "checker content changed during signature check")
    return _identity(info)


@contextmanager
def verified_checker():
    """Yield exact permitted spellings; reverify live authority on successful exit.

    This is not a reusable token: callers cannot supply context or verified flags.
    Hold the independently derived file and ancestors across the metadata work.
    """
    try:
        before = _inventory()
        bundle, root = before[-2:]
        canonical = root + "/usr/lib/libMainThreadChecker.dylib"
        with _open_file(bundle + "/Contents/Info.plist", runtime_plist=True) as plist_fd, \
                _open_file(canonical) as fd:
            plist_bytes = _read(plist_fd, OUTPUT_LIMIT)
            try:
                info = plistlib.loads(plist_bytes)
            except (ValueError, plistlib.InvalidFileException) as error:
                raise Refusal("invalid runtime Info.plist") from error
            require(type(info) is dict and info.get("CFBundleIdentifier") == RUNTIME,
                    "runtime plist identifier mismatch")
            identity = _library(fd, canonical)
            alias = _alias(canonical)
            yield canonical, alias[0]
            require(_inventory() == before, "runtime/toolchain inventory changed")
            require(_read(plist_fd, OUTPUT_LIMIT) == plist_bytes, "runtime plist changed")
            require(_library(fd, canonical) == identity, "checker identity changed")
            require(_alias(canonical) == alias, "standard alias changed")
    except OSError as error:
        raise Refusal("live runtime verification unavailable") from error


def _provider_inventory(*, command=None):
    """Observe the fixed toolchain under the separately trusted-provider model.

    These observations are not independent provenance or custody evidence. The
    caller explicitly trusts the disposable hosted image and reviewed job.
    """
    if command is None:
        def command(*args, **kwargs):
            return _command(*args, **kwargs)
    require(sys.platform == "darwin" and os.uname().machine == "arm64",
            "provider-trusted runtime requires Darwin arm64")
    developer = DEVELOPER
    xcodebuild = developer + "/usr/bin/xcodebuild"
    simctl = developer + "/usr/bin/simctl"
    tools = {}
    for tool in (xcodebuild, simctl):
        path = _path(tool)
        info = os.stat(path, follow_symlinks=False)
        require(stat.S_ISREG(info.st_mode), "fixed Xcode tool is not a regular file")
        tools[path] = _identity(info)
        command(["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple", path])
    version = command([xcodebuild, "-version"], developer)
    require(version == "Xcode 27.1\nBuild version 27A9275",
            "unreviewed Xcode version/build observation")
    xcode_version, build_line = version.splitlines()
    build_prefix = "Build version "
    require(build_line.startswith(build_prefix), "malformed Xcode build observation")
    xcode_build = build_line[len(build_prefix):]
    sdk_version = command(
        [xcodebuild, "-version", "-sdk", "iphonesimulator", "SDKVersion"], developer,
    )
    require(sdk_version == "27.1", "unreviewed simulator SDK observation")
    try:
        inventory = json.loads(
            command([simctl, "list", "runtimes", "--json"], developer),
            object_pairs_hook=_json_pairs,
        )
    except (ValueError, TypeError) as error:
        raise Refusal("invalid provider-trusted runtime inventory") from error
    require(type(inventory) is dict and type(inventory.get("runtimes")) is list
            and all(type(item) is dict for item in inventory["runtimes"]),
            "invalid provider-trusted runtime inventory shape")
    selected = [item for item in inventory["runtimes"] if item.get("identifier") == RUNTIME]
    require(len(selected) == 1, "provider-trusted runtime missing or ambiguous")
    runtime = selected[0]
    require(runtime.get("version") == "27.0" and runtime.get("buildversion") == "24A434"
            and runtime.get("isAvailable") is True,
            "unreviewed/unavailable provider-trusted runtime observation")
    bundle = _path(runtime.get("bundlePath"))
    root = _path(runtime.get("runtimeRoot"))
    require(bundle.startswith("/private/var/") and bundle.endswith("/iOS 27.0.simruntime")
            and root == bundle + "/Contents/Resources/RuntimeRoot",
            "unexpected provider-trusted runtime bundle/root relationship")
    require({path: _identity(os.stat(path, follow_symlinks=False)) for path in tools} == tools,
            "fixed Xcode tool changed during provider-trusted inventory")
    return {
        "developer_directory": developer,
        "xcodebuild_path": xcodebuild,
        "xcodebuild_identity": tools[xcodebuild],
        "xcodebuild_version": xcode_version,
        "xcodebuild_build": xcode_build,
        "simulator_sdk_version": sdk_version,
        "xcodebuild_apple_anchor_check": "passed",
        "simctl_path": simctl,
        "simctl_identity": tools[simctl],
        "simctl_apple_anchor_check": "passed",
        "runtime": {
            "identifier": runtime["identifier"],
            "version": runtime["version"],
            "build": runtime["buildversion"],
            "available": runtime["isAvailable"],
            "bundle_path": bundle,
            "runtime_root": root,
        },
    }


def _provider_file(path, limit):
    """Read only a bounded, independently derived fixed path; not custody proof."""
    descriptor = None
    try:
        path = _path(path)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_size <= limit,
                "provider-trusted runtime file shape/size mismatch")
        identity = _identity(info)
        data = _read(descriptor, limit)
        require(_identity(os.fstat(descriptor)) == identity and
                _identity(os.stat(path, follow_symlinks=False)) == identity,
                "provider-trusted runtime file changed during observation")
        return data, identity
    except OSError as error:
        raise Refusal("provider-trusted runtime file unavailable") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _bounded_provider_file(path, limit):
    """The provider file probe with opt-in precedence-aware descriptor close."""
    try:
        path = _path(path)
        with ExitStack() as cleanup:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            _register_cleanup(cleanup, lambda: os.close(descriptor))
            info = os.fstat(descriptor)
            require(stat.S_ISREG(info.st_mode) and info.st_size <= limit,
                    "provider-trusted runtime file shape/size mismatch")
            identity = _identity(info)
            data = _read(descriptor, limit)
            require(_identity(os.fstat(descriptor)) == identity and
                    _identity(os.stat(path, follow_symlinks=False)) == identity,
                    "provider-trusted runtime file changed during observation")
            return data, identity
    except OSError as error:
        raise Refusal("provider-trusted runtime file unavailable") from error


def _provider_alias(canonical):
    """Observe only the standard /var -> /private/var alias."""
    try:
        info = os.lstat("/var")
        require(stat.S_ISLNK(info.st_mode) and
                os.readlink("/var") in ("private/var", "/private/var"),
                "standard /var alias unavailable")
        private = os.lstat("/private")
        target = os.lstat("/private/var")
        require(stat.S_ISDIR(private.st_mode) and stat.S_ISDIR(target.st_mode) and
                _identity(os.stat("/var"))[:2] == _identity(target)[:2],
                "standard /var alias identity mismatch")
        alias = canonical[len("/private"):]
        require(_identity(os.stat(alias))[:2] ==
                _identity(os.stat(canonical, follow_symlinks=False))[:2],
                "checker alias identity mismatch")
        return alias, _identity(info), _identity(private)[:5], _identity(target)[:5]
    except OSError as error:
        raise Refusal("standard /var alias unavailable") from error


def _provider_snapshot(*, command=None, file_reader=None):
    """Bounded fixed-path observations; trust, not these checks, is the boundary."""
    inventory = _provider_inventory() if command is None else _provider_inventory(command=command)
    if command is None:
        def command(*args, **kwargs):
            return _command(*args, **kwargs)
    if file_reader is None:
        def file_reader(*args, **kwargs):
            return _provider_file(*args, **kwargs)
    bundle = inventory["runtime"]["bundle_path"]
    root = inventory["runtime"]["runtime_root"]
    canonical = _path(root + "/usr/lib/libMainThreadChecker.dylib")
    library, identity = file_reader(canonical, LIBRARY_SIZE)
    require(len(library) == LIBRARY_SIZE and
            hashlib.sha256(library).hexdigest() == LIBRARY_SHA256,
            "unreviewed checker digest observation")
    require(library[:8] == struct.pack("<II", 0xFEEDFACF, 0x0100000C),
            "checker observation must be thin arm64 Mach-O")
    command(["/usr/bin/codesign", "--verify", "--strict", "-R", REQUIREMENT, canonical])
    require(file_reader(canonical, LIBRARY_SIZE) == (library, identity),
            "checker changed during provider-trusted signature observation")
    plist_bytes, plist_identity = file_reader(bundle + "/Contents/Info.plist", OUTPUT_LIMIT)
    try:
        info = plistlib.loads(plist_bytes)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise Refusal("invalid provider-trusted runtime Info.plist observation") from error
    require(type(info) is dict and info.get("CFBundleIdentifier") == RUNTIME,
            "provider-trusted runtime plist identifier mismatch")
    alias = _provider_alias(canonical)
    record: ProviderRuntimeObservation = {
        "schema": "ios-provider-trusted-runtime-observation-v1",
        "xcode": {
            "developer_directory": inventory["developer_directory"],
            "version": inventory["xcodebuild_version"],
            "build": inventory["xcodebuild_build"],
            "simulator_sdk_version": inventory["simulator_sdk_version"],
            "xcodebuild_path": inventory["xcodebuild_path"],
            "xcodebuild_file_identity": list(inventory["xcodebuild_identity"]),
            "xcodebuild_apple_anchor_check": inventory["xcodebuild_apple_anchor_check"],
            "simctl_path": inventory["simctl_path"],
            "simctl_file_identity": list(inventory["simctl_identity"]),
            "simctl_apple_anchor_check": inventory["simctl_apple_anchor_check"],
        },
        "runtime": inventory["runtime"],
        "checker": {
            "canonical_path": canonical,
            "accepted_paths": [canonical, alias[0]],
            "size": len(library),
            "sha256": hashlib.sha256(library).hexdigest(),
            "architecture": "arm64",
            "signature_requirement": REQUIREMENT,
            "signature_check": "passed",
        },
    }
    return record, canonical, alias[0], identity, library, plist_identity, plist_bytes, alias


def _bounded_snapshot_equal(left, right):
    """Compare provider snapshots by exact type under fixed traversal/byte limits."""
    pending = [(left, right, 0)]
    nodes = size = 0
    while pending:
        first, second, depth = pending.pop()
        nodes += 1
        if nodes > 1024 or depth > 16 or type(first) is not type(second):
            return False
        kind = type(first)
        if kind in (tuple, list):
            if len(first) != len(second) or nodes + len(pending) + len(first) > 1024:
                return False
            pending.extend((a, b, depth + 1) for a, b in zip(first, second))
        elif kind is dict:
            if (len(first) != len(second)
                    or nodes + len(pending) + len(first) > 1024):
                return False
            for mapping in (first, second):
                for key in mapping:
                    if type(key) is not str:
                        return False
                    size += len(key)
                    if size > 8 * 1024 * 1024:
                        return False
            if first.keys() != second.keys():
                return False
            pending.extend((value, second[key], depth + 1) for key, value in first.items())
        elif kind in (str, bytes):
            size += len(first) + len(second)
            if size > 8 * 1024 * 1024 or first != second:
                return False
        elif kind is int:
            if first.bit_length() > 4096 or second.bit_length() > 4096 or first != second:
                return False
        elif kind in (bool, type(None)):
            if first != second:
                return False
        else:
            return False
    return True


@contextmanager
def provider_verified_checker(*, bounded_cleanup=False):
    """Yield fixed checker spellings under an explicit hosted-provider trust assumption.

    Filesystem, version, digest and signature results are observations on the
    trusted image, not independent provenance or defense against hostile job
    code/provider compromise. This remains a separate, lower-assurance profile.
    """
    try:
        def snapshot():
            if bounded_cleanup:
                return _provider_snapshot(command=_bounded_command, file_reader=_bounded_provider_file)
            return _provider_snapshot()

        before = snapshot()
        yield (before[1], before[2]), before[0]
        after = snapshot()
        require(_bounded_snapshot_equal(after, before) if bounded_cleanup else after == before,
                "provider-trusted runtime/toolchain observation changed")
    except OSError as error:
        raise Refusal("provider-trusted runtime verification unavailable") from error
