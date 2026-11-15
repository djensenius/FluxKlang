"""Fresh, read-only authority for the closed Xcode 27.1 / iOS 27.0 profile.

No context/receipt input, caching, destination selection, or launch capability.
Only independently discovered paths reach filesystem or native-tool probes.
"""

from contextlib import contextmanager
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


RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEVELOPER = "/Applications/Xcode_27.1.app/Contents/Developer"
LIBRARY_SHA256 = "1ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8"
LIBRARY_SIZE = 338880
REQUIREMENT = '=identifier "com.apple.libMainThreadChecker" and anchor apple'
OUTPUT_LIMIT = 2 * 1024 * 1024
TIMEOUT = 30
ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}


class Refusal(ValueError):
    """Live authority was unavailable, changed, or outside the closed pins."""

    def __init__(self, message, context=None):
        super().__init__(message)
        self.context = context or {}  # Observations only; never accepted as authority input.


def require(condition, message, context=None):
    if not condition:
        raise Refusal(message, context)


def _command(argv, developer=None):
    """Fixed callers only; bounded merged output, deadline, no inherited env."""
    env = dict(ENV)
    if developer is not None:
        env["DEVELOPER_DIR"] = developer
    process, exit_code = None, None
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
            exit_code = process.wait(timeout=remaining)
            require(exit_code == 0, "runtime verification command failed")
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
    except (Refusal, OSError, UnicodeError, subprocess.SubprocessError) as error:
        code = getattr(process, "returncode", exit_code)
        context = {"stage": "command", "argv_sanitized": list(argv),
                   "exit_code": code if type(code) is int else "not available",
                   "errno": getattr(error, "errno", None)}
        if isinstance(error, Refusal):
            error.context = error.context or context
            raise
        raise Refusal("runtime verification command unavailable", context) from error


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


def _file_context(stage, component, info=None):
    context = {"stage": stage, "component": component}
    if info is not None:
        context.update(type_mode=stat.filemode(info.st_mode), mode=oct(stat.S_IMODE(info.st_mode)),
                       uid=info.st_uid, gid=info.st_gid)
    return context


def _owned(info, directory=False, component="not available"):
    context = _file_context("ownership", component, info)
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            "non-directory ancestor" if directory else "not a regular file", context)
    require(info.st_uid == 0 and not info.st_mode & 0o022,
            "runtime/tool path must be root-owned and not group/world writable", context)


def _readonly_plist(fd, component, stage):
    info = os.fstat(fd)
    context = _file_context(stage, component, info)
    context["st_readonly"] = "not available"
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0
            and stat.S_IMODE(info.st_mode) == 0o664, "unreviewed runtime plist file shape", context)
    try:
        flags = os.fstatvfs(fd).f_flag
    except OSError as error:
        context["errno"] = error.errno
        raise Refusal("runtime/tool filesystem verification unavailable", context) from error
    context["st_readonly"] = bool(flags & os.ST_RDONLY)
    require(flags & os.ST_RDONLY, "runtime plist requires a read-only filesystem", context)


@contextmanager
def _open_file(path, *, runtime_plist=False):
    """Descriptor-relative no-follow walk, as in build_receipt, standalone here.

    Hold all ancestors and reject path replacement on return. No candidate
    path is used here; even root-owned symlink components are refused.
    """
    parts = _path(path).split("/")[1:]
    descriptors = []
    links = []
    stage, component, info = "filesystem entry", "/", None
    try:
        current = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(current)
        _owned(os.fstat(current), directory=True, component="/")
        for index, part in enumerate(parts):
            component, info = "/" + "/".join(parts[:index + 1]), None
            directory = index < len(parts) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if directory:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=current)
            descriptors.append(child)
            info = os.fstat(child)
            if runtime_plist and not directory:
                _readonly_plist(child, component, "plist entry")
            else:
                _owned(info, directory, component)
            # Directory timestamps can change for unrelated children. Their
            # identity/ownership/mode must not; the file also binds timestamps.
            identity = _identity(info)[:5] if directory else _identity(info)
            links.append((current, part, child, identity, directory))
            current = child
        yield current
        if runtime_plist:
            _readonly_plist(current, path, "plist exit")
        stage = "filesystem exit"
        for index, (parent, part, child, identity, directory) in enumerate(links):
            component, info = "/" + "/".join(parts[:index + 1]), None
            for info in (os.fstat(child), os.stat(part, dir_fd=parent, follow_symlinks=False)):
                observed = _identity(info)[:5] if directory else _identity(info)
                require(observed == identity, "runtime/tool path replaced during verification",
                        _file_context(stage, component, info))
    except OSError as error:
        context = _file_context(stage, component, info)
        context["errno"] = error.errno
        raise Refusal("runtime/tool filesystem verification unavailable", context) from error
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
            raise Refusal("invalid runtime inventory", getattr(error, "context", None)) from error
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
    _owned(private, directory=True, component="/private")
    _owned(target, directory=True, component="/private/var")
    require(_identity(os.stat("/var")) == _identity(target), "standard /var identity mismatch")
    alias = canonical[len("/private"):]
    require(_identity(os.stat(alias)) == _identity(os.stat(canonical, follow_symlinks=False)),
            "checker alias identity mismatch")
    return alias, _identity(info), _identity(private)[:5], _identity(target)[:5]


def _library(fd, canonical):
    info = os.fstat(fd)
    context = _file_context("checker", canonical, info)
    require(info.st_size == LIBRARY_SIZE and stat.S_IMODE(info.st_mode) == 0o755
            and info.st_uid == 0, "unreviewed checker file shape", context)
    data = _read(fd, LIBRARY_SIZE)
    require(hashlib.sha256(data).hexdigest() == LIBRARY_SHA256, "unreviewed checker digest", context)
    require(data[:8] == struct.pack("<II", 0xFEEDFACF, 0x0100000C),
            "checker must be thin arm64 Mach-O", context)
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
    stage, component = "inventory entry", DEVELOPER
    try:
        before = _inventory()
        bundle, root = before[-2:]
        canonical = root + "/usr/lib/libMainThreadChecker.dylib"
        stage, component = "runtime plist", bundle + "/Contents/Info.plist"
        with _open_file(bundle + "/Contents/Info.plist", runtime_plist=True) as plist_fd, \
                _open_file(canonical) as fd:
            plist_bytes = _read(plist_fd, OUTPUT_LIMIT)
            try:
                info = plistlib.loads(plist_bytes)
            except (ValueError, plistlib.InvalidFileException) as error:
                raise Refusal("invalid runtime Info.plist") from error
            require(type(info) is dict and info.get("CFBundleIdentifier") == RUNTIME,
                    "runtime plist identifier mismatch")
            stage, component = "checker/alias entry", canonical
            identity = _library(fd, canonical)
            alias = _alias(canonical)
            yield canonical, alias[0]
            stage, component = "inventory exit", DEVELOPER
            require(_inventory() == before, "runtime/toolchain inventory changed")
            stage, component = "runtime plist exit", bundle + "/Contents/Info.plist"
            require(_read(plist_fd, OUTPUT_LIMIT) == plist_bytes, "runtime plist changed")
            stage, component = "checker/alias exit", canonical
            require(_library(fd, canonical) == identity, "checker identity changed")
            require(_alias(canonical) == alias, "standard alias changed")
    except Refusal as error:
        error.context = error.context or {"stage": stage, "component": component}
        raise
    except OSError as error:
        raise Refusal("live runtime verification unavailable",
                      {"stage": stage, "component": component, "errno": error.errno}) from error
