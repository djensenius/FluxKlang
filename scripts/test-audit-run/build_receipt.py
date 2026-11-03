#!/usr/bin/env python3
"""Closed compile-product evidence, not compiler closure or launch authority."""

import sys

sys.dont_write_bytecode = True  # Before importing the accepted sibling.

import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess

import prepare


Refusal = prepare.Refusal
RECEIPT_BYTES = 33554432
METADATA_BYTES = 2097152
TREE_ENTRIES = 200000
TREE_DEPTH = 64
TREE_BYTES = 68719476736
PATH_BYTES = 4096
PROFILE = "mac-compile-products-v1"
DEVELOPER = "/Applications/Xcode.app/Contents/Developer"
XCODEBUILD = DEVELOPER + "/usr/bin/xcodebuild"
IDENTITIES = (
    "swift-ascii", "swift-atomics", "swift-collections", "swift-data-parsing",
    "swift-nio", "swift-osc", "swift-osc-core", "swift-osc-io-nio", "swift-system",
)
LOCKFILE = "FluxKlang.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
REVIEWED = (
    "project.yml", "FluxKlang.xcodeproj/project.pbxproj",
    "FluxKlang.xcodeproj/xcshareddata/xcschemes/FluxKlangMacIsolatedTests.xcscheme",
    LOCKFILE,
)
INTERMEDIATES = "DerivedData/Build/Intermediates.noindex"
DERIVED_SOURCES = "DerivedData/Build/DerivedSources"
PRODUCTS = "DerivedData/Build/Products"
MANDATORY = tuple(
    f"FluxKlang.build/Debug/{target}.build/Objects-normal/arm64/{target}.SwiftFileList"
    for target in ("FluxKlangMac", "FluxKlangMacTests")
)
EXEMPLAR = "00000000-0000-4000-8000-000000000000"
NIO_FIXTURE_LINKS = {
    "Tests/NIOFSIntegrationTests/Test Data/Foo.symlink": ("Foo", "directory"),
    "Tests/NIOFSIntegrationTests/Test Data/README.md.symlink": ("README.md", "file"),
}


def require(condition, message):
    if not condition:
        raise Refusal(message)


def equal(actual, expected, label):
    prepare.require_equal(actual, expected, label)


def text(value):
    require(type(value) is str and "\0" not in value, "expected literal text")
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise Refusal("invalid UTF8") from error
    return value


def hex_value(value, length):
    require(type(value) is str and re.fullmatch(f"[0-9a-f]{{{length}}}", value),
            "invalid hexadecimal identifier")
    return value


def path_text(value, absolute=True):
    value = text(str(value) if isinstance(value, Path) else value)
    require(len(value.encode("utf-8")) <= PATH_BYTES, "path byte limit")
    if value == "." and not absolute:
        return value
    require(value.startswith("/") == absolute, "wrong path kind")
    pieces = value.split("/")[1:] if absolute else value.split("/")
    require(bool(pieces) and all(p not in ("", ".", "..") for p in pieces),
            "ambiguous path")
    return value


def inside(path, root):
    path_text(path)
    path_text(root)
    require(Path(path).is_relative_to(root), "path outside declared root")
    return Path(path)


def open_fd(path, directory=False):
    """Walk every ancestor with descriptor-relative O_NOFOLLOW, including /."""
    parts = path_text(path).split("/")[1:]
    current = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=current)
            os.close(current)
            current = child
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        if directory:
            flags |= os.O_DIRECTORY
        result = os.open(parts[-1], flags, dir_fd=current)
        try:
            info = os.fstat(result)
            require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
                    "expected directory" if directory else "expected regular file")
        except BaseException:
            os.close(result)
            raise
        return result
    finally:
        os.close(current)


def check_directory(path):
    os.close(open_fd(path, directory=True))


def absent(path):
    parent = open_fd(Path(path).parent, directory=True)
    try:
        try:
            os.stat(Path(path).name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise Refusal(f"must be absent: {path}")
    finally:
        os.close(parent)


def read_stream(stream, limit, retain=False, blob_size=None):
    """Inclusive streaming budget, including a one-byte excess probe."""
    total = 0
    sha = hashlib.sha256()
    blob = hashlib.sha1()
    if blob_size is not None:
        blob.update(f"blob {blob_size}\0".encode("ascii"))
    chunks = []
    while True:
        chunk = stream.read(min(1048576, limit - total + 1))
        if not chunk:
            break
        require(len(chunk) <= limit - total, "regular byte limit")
        total += len(chunk)
        sha.update(chunk)
        blob.update(chunk)
        if retain:
            chunks.append(chunk)
    return total, sha.hexdigest(), blob.hexdigest(), b"".join(chunks)


def file_data(path, limit=TREE_BYTES, retain=False, independent=False):
    with os.fdopen(open_fd(path), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(before.st_size <= limit, "regular byte limit")
        if independent:
            require(before.st_nlink == 1, "shared source/Git storage hardlink")
        size, digest, blob, data = read_stream(stream, limit, retain, before.st_size)
        after = os.fstat(stream.fileno())
        require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns,
                 before.st_mode) ==
                (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns,
                 after.st_mode) and size == after.st_size, "file changed while reading")
    return {"path": path_text(path), "mode": stat.S_IMODE(after.st_mode),
            "size": size, "sha256": digest}, data, blob


def bounded(path, limit=METADATA_BYTES):
    return file_data(path, limit, retain=True)[:2]


def json_bytes(data):
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=prepare.unique_pairs,
                          parse_constant=prepare.invalid_constant)
    except (UnicodeError, RecursionError, ValueError) as error:
        raise Refusal(f"invalid JSON: {error}") from error


def encode(value):
    chunks = []
    remaining = RECEIPT_BYTES - 1
    for chunk in json.JSONEncoder(indent=2, sort_keys=True, ensure_ascii=True).iterencode(value):
        data = chunk.encode("utf-8")
        require(len(data) <= remaining, "receipt byte limit")
        remaining -= len(data)
        chunks.append(data)
    return b"".join(chunks) + b"\n"


class Budget:
    def __init__(self):
        self.entries = 0
        self.bytes = 0

    def entry(self, depth):
        require(depth <= TREE_DEPTH, "tree depth limit")
        require(self.entries < TREE_ENTRIES, "tree entry limit")
        self.entries += 1

    def regular(self, size):
        require(type(size) is int and 0 <= size <= TREE_BYTES - self.bytes,
                "tree byte limit")
        self.bytes += size


def nio_link_spec(root, workspace, relative):
    """Fixed layout exception only; revision authority remains the actual pin."""
    require(workspace is not None and root is not None and
            Path(root) == Path(workspace) / "Packages/checkouts/swift-nio" and
            relative in NIO_FIXTURE_LINKS, "unsupported package fixture link")
    return NIO_FIXTURE_LINKS[relative]


def nio_link_data(root, workspace, relative):
    target, kind = nio_link_spec(root, workspace, relative)
    path = Path(root) / relative
    path_text(path)
    parent = open_fd(path.parent, directory=True)
    try:
        before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISLNK(before.st_mode), "expected tracked package link")
        require(before.st_size <= PATH_BYTES, "link target byte limit")
        raw = os.readlink(os.fsencode(path.name), dir_fd=parent)
        require(len(raw) <= PATH_BYTES, "link target byte limit")
        equal(raw, target.encode("utf-8"), "literal package link target")
        referent = os.stat(target, dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISDIR(referent.st_mode) if kind == "directory" else
                stat.S_ISREG(referent.st_mode), "package link referent type")
        if kind == "file":
            require(referent.st_nlink == 1, "shared source/Git storage hardlink")
        after = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns,
                 before.st_mode) ==
                (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns,
                 after.st_mode), "link changed while reading")
    finally:
        os.close(parent)
    blob = hashlib.sha1(f"blob {len(raw)}\0".encode("ascii") + raw).hexdigest()
    return {"path": relative, "type": "symlink", "mode": stat.S_IMODE(after.st_mode),
            "target": target}, blob


def nio_link_bindings(root, workspace, entries, tracked):
    """Shared live/schema check: link labels alone cannot authorize an alias."""
    by_path = {entry["path"]: entry for entry in entries}
    modes = {entry["path"]: entry["git_mode"] for entry in tracked}
    require(len(modes) == len(tracked), "duplicate tracked path")
    for name, mode in modes.items():
        if mode == "120000":
            nio_link_spec(root, workspace, name)
            require(by_path.get(name, {}).get("type") == "symlink",
                    "expected tracked package link")
    for entry in entries:
        if entry["type"] != "symlink":
            continue
        name = entry["path"]
        target, kind = nio_link_spec(root, workspace, name)
        equal(entry["target"], target, "literal package link target")
        equal(modes.get(name), "120000", "package link Git mode")
        referent = str(Path(name).with_name(target))
        require(by_path.get(referent, {}).get("type") == kind, "package link referent type")
        if kind == "file":
            require(modes.get(referent) in ("100644", "100755"), "untracked link referent")
        else:
            require(any(path.startswith(referent + "/") and mode in ("100644", "100755")
                        for path, mode in modes.items()), "link directory lacks tracked descendant")


def inventory(root, exclude_control=False, independent=False, workspace=None):
    """Exact root-inclusive inventory. scandir is streamed, never listdir/rglob."""
    root = Path(path_text(root))
    result = []
    budget = Budget()

    def visit(path, relative, depth):
        path_text(path)
        path_text(relative, absolute=False)
        budget.entry(depth)
        parent = open_fd(path.parent, directory=True)
        try:
            info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        finally:
            os.close(parent)
        entry = {"path": relative, "mode": stat.S_IMODE(info.st_mode)}
        if stat.S_ISDIR(info.st_mode):
            entry["type"] = "directory"
            result.append(entry)
            fd = open_fd(path, directory=True)
            try:
                with os.scandir(fd) as children:
                    for child in children:
                        if exclude_control and depth == 0 and child.name == ".git":
                            continue
                        rel = child.name if relative == "." else relative + "/" + child.name
                        visit(path / child.name, rel, depth + 1)
            finally:
                os.close(fd)
        elif stat.S_ISREG(info.st_mode):
            witness, _, _ = file_data(path, TREE_BYTES - budget.bytes,
                                      independent=independent)
            budget.regular(witness["size"])
            entry.update(type="file", size=witness["size"], sha256=witness["sha256"])
            equal(entry["mode"], witness["mode"], "inventory mode")
            result.append(entry)
        elif stat.S_ISLNK(info.st_mode):
            witness, _ = nio_link_data(root, workspace, relative)
            equal(entry["mode"], witness["mode"], "inventory link mode")
            result.append(witness)  # Never recurse through or flatten the alias.
        else:
            raise Refusal("links and special entries are unsupported")

    visit(root, ".", 0)
    return sorted(result, key=lambda entry: entry["path"])


def recipe(workspace):
    w = Path(workspace)
    return [XCODEBUILD, "-project", str(w / "source/FluxKlang.xcodeproj"),
            "-scheme", "FluxKlangMacIsolatedTests", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-jobs", "2",
            "-derivedDataPath", str(w / "DerivedData"),
            "-clonedSourcePackagesDirPath", str(w / "Packages"),
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
            "build-for-testing", "CODE_SIGNING_ALLOWED=NO"]


def environment(workspace):
    evidence = Path(workspace) / "build-evidence"
    account = pwd.getpwuid(os.getuid()).pw_name
    return {"DEVELOPER_DIR": DEVELOPER,
            "PATH": DEVELOPER + "/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(evidence / "home"), "TMPDIR": str(evidence / "tmp") + "/",
            "LANG": "C", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1",
            "USER": account, "LOGNAME": account}


def git(root, *arguments):
    # No inherited Git variables, global/system config, index refresh, helpers,
    # hooks, replacement objects or optional locks. Local config is custody.
    env = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0",
           "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"}
    argv = ["/usr/bin/git", "--no-pager", "--no-optional-locks", "--no-replace-objects",
            "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
            "-c", "core.untrackedCache=false", "-c", "core.preloadindex=false",
            "-c", "core.attributesFile=/dev/null", "-c", "core.worktree=" + str(root),
            "-C", str(root), *arguments]
    process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    try:
        with process.stdout:
            _, _, _, data = read_stream(process.stdout, RECEIPT_BYTES, retain=True)
        require(process.wait() == 0, "read-only Git observation failed")
        return data
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.wait()
        raise


def git_control(root, workspace):
    """Check control paths BEFORE Git can follow pointers or object alternates."""
    marker = root / ".git"
    parent = open_fd(root, directory=True)
    try:
        mode = os.stat(".git", dir_fd=parent, follow_symlinks=False).st_mode
    finally:
        os.close(parent)
    if stat.S_ISDIR(mode):
        directory = marker
    else:
        _, data = bounded(marker)
        line = data.decode("utf-8")
        require(line.startswith("gitdir: ") and line.endswith("\n") and line.count("\n") == 1,
                "unsupported Git control pointer")
        target = line[8:-1]
        path_text(target, absolute=target.startswith("/"))
        directory = root / target
    inside(directory, workspace)
    check_directory(directory)
    common = directory
    commondir = directory / "commondir"
    if os.path.lexists(commondir):
        _, data = bounded(commondir)
        line = data.decode("utf-8")
        require(line.endswith("\n") and line.count("\n") == 1, "invalid commondir")
        target = line[:-1]
        path_text(target, absolute=target.startswith("/"))
        common = directory / target
        inside(common, workspace)
    controls = []
    for location in sorted({directory, common}):
        entries = inventory(location, independent=True)
        require(not any(entry["path"] in ("objects/info/alternates",
                                         "objects/info/http-alternates")
                        for entry in entries), "Git alternates are unsupported")
        for name in ("config", "config.worktree"):
            if any(entry["path"] == name for entry in entries):
                _, data = bounded(location / name)
                config = data.decode("utf-8")
                # Refuse external includes and lazy acquisition before invoking
                # Git at all. No escaped/multiline local config in this profile.
                require("\\" not in config and "\0" not in config and
                        not re.search(r"\[\s*include|partialclone|promisor",
                                      config, flags=re.IGNORECASE),
                        "external/partial Git configuration is unsupported")
        controls.append({"root": str(location), "entries": entries})
    return controls


def source_observation(root, workspace, commit=None, tree=None):
    root = inside(root, workspace)
    controls = git_control(root, workspace)
    actual_commit = git(root, "rev-parse", "--verify", "HEAD").decode("ascii").strip()
    actual_tree = git(root, "rev-parse", "--verify", "HEAD^{tree}").decode("ascii").strip()
    hex_value(actual_commit, 40)
    hex_value(actual_tree, 40)
    if commit is not None:
        equal(actual_commit, commit, "commit")
    if tree is not None:
        equal(actual_tree, tree, "tree")
    # Git must agree with the inspected locations, not discover an ancestor repo.
    equal(git(root, "rev-parse", "--show-toplevel").decode().strip(), str(root), "Git root")
    actual_git = Path(git(root, "rev-parse", "--absolute-git-dir").decode().strip())
    require(str(actual_git) in {item["root"] for item in controls}, "Git directory drift")
    actual_common = Path(os.path.abspath(root / git(
        root, "rev-parse", "--git-common-dir").decode().strip()))
    require(str(actual_common) in {item["root"] for item in controls}, "Git common-dir drift")
    entries = inventory(root, exclude_control=True, independent=True, workspace=workspace)
    files = {entry["path"]: entry for entry in entries if entry["type"] != "directory"}
    tracked = []
    raw = git(root, "ls-tree", "-rz", "--full-tree", "HEAD")
    require(not raw or raw.endswith(b"\0"), "truncated Git tree")
    for record in raw.split(b"\0")[:-1]:
        header, name = record.split(b"\t", 1)
        mode, kind, oid = header.decode("ascii").split(" ")
        name = path_text(name.decode("utf-8"), absolute=False)
        require(mode in ("100644", "100755", "120000") and kind == "blob",
                "unsupported Git link/submodule/mode")
        require(name in files and name != ".git" and not name.startswith(".git/"),
                "missing tracked file")
        if mode == "120000":
            require(files[name]["type"] == "symlink", "expected tracked package link")
            witness, blob = nio_link_data(root, workspace, name)
            equal(witness, files[name], "tracked link inventory")
        else:
            require(files[name]["type"] == "file", "expected tracked regular file")
            witness, _, blob = file_data(root / name)
            equal(bool(witness["mode"] & 0o111), mode == "100755", "dirty executable mode")
        equal(blob, oid, "dirty tracked bytes")
        tracked.append({"path": name, "git_mode": mode})
    require(len(tracked) == len(files) and len({v["path"] for v in tracked}) == len(files),
            "dirty untracked or ignored source")
    nio_link_bindings(root, workspace, entries, tracked)
    # Also refuse staged changes even when the worktree happens to match HEAD.
    require(git(root, "diff-index", "--cached", "--raw", "--no-renames",
                "--no-ext-diff", "HEAD", "--") == b"", "dirty index")
    return {"root": str(root), "commit": actual_commit, "tree": actual_tree,
            "control": controls, "entries": entries,
            "tracked": sorted(tracked, key=lambda value: value["path"])}


def keys(value, names):
    require(type(value) is dict and value.keys() == set(names.split()), "unsupported keys")


def pins_from_lock(data):
    value = json_bytes(data)
    keys(value, "originHash pins version")
    equal(value["version"], 3, "lockfile version")
    text(value["originHash"])
    require(type(value["pins"]) is list and len(value["pins"]) == 9, "nine pins required")
    pins = {}
    for pin in value["pins"]:
        keys(pin, "identity kind location state")
        keys(pin["state"], "revision version")
        equal(pin["kind"], "remoteSourceControl", "pin kind")
        identity = text(pin["identity"])
        require(identity in IDENTITIES and identity not in pins, "unknown/duplicate pin")
        require(bool(text(pin["location"])) and bool(text(pin["state"]["version"])),
                "empty package pin")
        hex_value(pin["state"]["revision"], 40)
        pins[identity] = pin
    return pins


def package_observation(workspace):
    w = Path(workspace)
    lock, lock_data = bounded(w / "source" / LOCKFILE)
    pins = pins_from_lock(lock_data)
    state, state_data = bounded(w / "Packages/workspace-state.json")
    value = json_bytes(state_data)
    keys(value, "object version")
    equal(value["version"], 7, "workspace-state version")
    keys(value["object"], "artifacts dependencies prebuilts")
    equal(value["object"]["artifacts"], [], "artifacts")
    equal(value["object"]["prebuilts"], [], "prebuilts")
    dependencies = value["object"]["dependencies"]
    require(type(dependencies) is list and len(dependencies) == 9, "nine dependencies required")
    seen = set()
    for dependency in dependencies:
        keys(dependency, "basedOn packageRef state subpath")
        equal(dependency["basedOn"], None, "basedOn")
        reference = dependency["packageRef"]
        keys(reference, "identity kind location name")
        identity = text(reference["identity"])
        require(identity in pins and identity not in seen, "unknown/duplicate dependency")
        seen.add(identity)
        pin = pins[identity]
        for key in ("identity", "kind", "location"):
            equal(reference[key], pin[key], "package reference")
        require(bool(text(reference["name"])), "empty package name")
        equal(dependency["subpath"], identity, "checkout subpath")
        keys(dependency["state"], "checkoutState name")
        equal(dependency["state"]["name"], "sourceControlCheckout", "checkout state kind")
        equal(dependency["state"]["checkoutState"], pin["state"], "checkout pin")
    checkouts = []
    checkout_root = w / "Packages/checkouts"
    fd = open_fd(checkout_root, directory=True)
    try:
        names = set()
        with os.scandir(fd) as children:
            for child in children:
                require(child.name in IDENTITIES and child.name not in names,
                        "extra checkout")
                names.add(child.name)
        equal(names, set(IDENTITIES), "checkout set")
    finally:
        os.close(fd)
    for identity in IDENTITIES:
        checkouts.append(source_observation(checkout_root / identity, w,
                                           pins[identity]["state"]["revision"]))
    return {"lockfile": lock, "workspace_state": state, "checkouts": checkouts}


class _UniqueInfoDictionary(dict):
    """Enforce string/unique keys in every binary Info.plist dictionary."""

    def __setitem__(self, key, value):
        require(type(key) is str, "binary Info.plist key must be a string")
        require(key not in self, "duplicate binary Info.plist key")
        super().__setitem__(key, value)


def toolchain_observation():
    contents = Path(DEVELOPER).parent
    result = {}
    for key, name, required in (
        ("info", "Info.plist", ("CFBundleShortVersionString", "CFBundleVersion")),
        ("version", "version.plist", ("CFBundleShortVersionString", "CFBundleVersion",
                                     "ProductBuildVersion")),
    ):
        witness, data = bounded(contents / name)
        if key == "info" and data.startswith(b"bplist00"):
            try:
                parsed = plistlib.loads(data, fmt=plistlib.FMT_BINARY,
                                        dict_type=_UniqueInfoDictionary)
            except (ValueError, TypeError, OverflowError, OSError, LookupError,
                    RecursionError) as error:
                raise Refusal("invalid binary Xcode Info.plist") from error
            require(type(parsed) is _UniqueInfoDictionary, "Xcode plist must be dictionary")
            parsed = dict(parsed)
        else:
            parsed = prepare.parse_plist(data)
        require(type(parsed) is dict, "Xcode plist must be dictionary")
        fields = {}
        for field in ("CFBundleShortVersionString", "CFBundleVersion",
                      "DTXcodeBuild", "ProductBuildVersion"):
            if field in parsed:
                fields[field] = text(parsed[field])
                require(bool(fields[field]), "empty Xcode field")
        require(all(field in fields for field in required), "missing Xcode version field")
        result[key] = {"file": witness, "fields": fields}
    result["binary"] = file_data(XCODEBUILD)[0]
    return result


def swift_paths(data):
    try:
        value = data.decode("utf-8")
    except UnicodeError as error:
        raise Refusal("source list must be UTF8") from error
    require(not any(c in value for c in ('\ufeff', '\0', '\r', '"', "'")),
            "unsupported source-list grammar")
    if value.endswith("\n"):
        value = value[:-1]
    paths = []
    for line in value.split("\n") if value else []:
        decoded = []
        characters = iter(line)
        for character in characters:
            if character == "\\":
                require(next(characters, None) == " ", "unsupported source-list escape")
                character = " "
            decoded.append(character)
        path = "".join(decoded)
        path_text(path)
        require(Path(path).suffix == ".swift", "non-Swift input")
        paths.append(path)
    require(len(paths) == len(set(paths)), "duplicate Swift input")
    return paths


def input_observation(workspace, source, packages):
    w = Path(workspace)
    root = w / INTERMEDIATES
    # Traversal itself has the same root-inclusive budgets, even for files not
    # selected as evidence. Only actual SwiftFileLists are retained in the receipt.
    entries = inventory(root)
    lists = [entry["path"] for entry in entries
             if entry["type"] == "file" and entry["path"].endswith(".SwiftFileList")]
    require(all(path in lists for path in MANDATORY), "missing mandatory SwiftFileList")
    known = {}
    for record, category in [(source, "source")] + [
        (checkout, "package:" + Path(checkout["root"]).name)
        for checkout in packages["checkouts"]
    ]:
        for tracked in record["tracked"]:
            if tracked["git_mode"] == "120000":
                continue  # Fixture links never become compiler-input aliases.
            path = str(Path(record["root"]) / tracked["path"])
            require(path not in known, "ambiguous source association")
            known[path] = category
    generated = {}
    generated_budget = Budget()
    result = []
    for relative in lists:
        witness, data = bounded(root / relative)
        paths = swift_paths(data)
        if relative in MANDATORY:
            require(bool(paths), "empty mandatory SwiftFileList")
        inputs = []
        for name in paths:
            path = Path(name)
            if name in known:
                file_data(path)  # Regular/no-follow even for tracked inputs.
                category = known[name]
            else:
                parents = [base for base in (w / INTERMEDIATES, w / DERIVED_SOURCES)
                           if path.is_relative_to(base)]
                require(len(parents) == 1, "unresolved Swift input")
                category = "generated"
                base = parents[0]
                if name not in generated:
                    generated_budget.entry(len(path.relative_to(base).parts))
                    file_witness = file_data(path, TREE_BYTES - generated_budget.bytes)[0]
                    generated_budget.regular(file_witness["size"])
                    generated[name] = dict(file_witness, type="file")
                parent = path.parent
                while True:
                    if str(parent) in generated:
                        break
                    generated_budget.entry(len(parent.relative_to(base).parts))
                    fd = open_fd(parent, directory=True)
                    try:
                        generated[str(parent)] = {
                            "path": str(parent), "type": "directory",
                            "mode": stat.S_IMODE(os.fstat(fd).st_mode),
                        }
                    finally:
                        os.close(fd)
                    if parent == base:
                        break
                    parent = parent.parent
            inputs.append({"path": name, "association": category})
        result.append({"file": witness, "inputs": inputs})
    return {"lists": result, "generated": sorted(generated.values(), key=lambda e: e["path"])}


def original_metadata(workspace):
    products = Path(workspace) / PRODUCTS
    entries = inventory(products)
    candidates = [entry for entry in entries
                  if entry["type"] == "file" and entry["path"].endswith(".xctestrun")]
    require(len(candidates) == 1, "expected exactly one original xctestrun")
    path = products / candidates[0]["path"]
    require(path.parent == products, "original must be a Products sibling")
    witness, data = bounded(path)
    original = prepare.parse_plist(data)
    equal(original, prepare.OBSERVED, "original Mac metadata")
    # Actual helpers and exact serializers: fixed-width UUID/hash ASCII does
    # not alter the XML/JSON serialized sizes. No textual replacement.
    output, intent = prepare.output_paths(path, EXEMPLAR)
    for sibling in (output, intent):
        path_text(sibling)
        absent(sibling)
    output_data = plistlib.dumps(
        prepare.transformed(original, EXEMPLAR, prepare.RETENTION_PROFILE),
        fmt=plistlib.FMT_XML, sort_keys=False,
    )
    intent_data = encode(prepare.intent_record(
        path, witness["sha256"], output, prepare.digest(output_data), intent,
        EXEMPLAR, prepare.RETENTION_PROFILE,
    ))
    require(len(output_data) <= METADATA_BYTES and len(intent_data) <= METADATA_BYTES,
            "prepared serialization exceeds metadata limit")
    return witness, (len(output_data), len(intent_data))


def metadata_from_record(record, original, sizes):
    equal(record["input"], {"path": original["path"], "sha256": original["sha256"]},
          "preparer input")
    output, _ = bounded(record["output"]["path"])
    intent, _ = bounded(record["intent_path"])
    equal((output["size"], intent["size"]), sizes, "precomputed serialization sizes")
    value = {"original": original, "prepared": output, "intent": intent,
             "run_id": record["run_id"], "profile": prepare.RETENTION_PROFILE}
    validate_metadata(value)
    return value


def validate_metadata(value):
    prepare.check_run_id(value["run_id"])
    equal(value["profile"], prepare.RETENTION_PROFILE, "preparation profile")
    original = value["original"]
    output, intent = prepare.output_paths(Path(original["path"]), value["run_id"])
    equal(value["prepared"]["path"], str(output), "prepared sibling")
    equal(value["intent"]["path"], str(intent), "intent sibling")

    def recheck():
        for key in ("original", "prepared", "intent"):
            witness, _ = bounded(value[key]["path"])
            equal(witness, value[key], key)

    recheck()
    record = prepare.validate(original["path"], original["sha256"], prepare.RETENTION_PROFILE,
                              output, intent)
    equal(record["run_id"], value["run_id"], "validated UUID")
    equal(record["output"]["sha256"], value["prepared"]["sha256"], "validated output")
    recheck()
    return record


# Closed structural schema checked before any receipt-provided path is opened.
# Re-observation then enforces the exact semantic layout and associations.
def integer(value, maximum):
    require(type(value) is int and 0 <= value <= maximum, "invalid bounded integer")


def file_schema(value):
    keys(value, "path mode size sha256")
    path_text(value["path"])
    integer(value["mode"], 0o7777)
    integer(value["size"], TREE_BYTES)
    hex_value(value["sha256"], 64)


def entries_schema(values, absolute=False, root=None, workspace=None):
    require(type(values) is list and 0 < len(values) <= TREE_ENTRIES, "invalid inventory")
    seen = set()
    budget = Budget()
    for value in values:
        require(type(value) is dict, "invalid entry")
        kind = value.get("type")
        keys(value, "path mode type size sha256" if kind == "file" else
             "path mode type target" if kind == "symlink" else "path mode type")
        require(kind in ("file", "directory", "symlink"), "invalid entry kind")
        path = path_text(value["path"], absolute=absolute)
        require(path not in seen, "duplicate entry")
        seen.add(path)
        integer(value["mode"], 0o7777)
        budget.entry(0 if absolute or path == "." else len(path.split("/")))
        if kind == "file":
            integer(value["size"], TREE_BYTES)
            hex_value(value["sha256"], 64)
            budget.regular(value["size"])
        elif kind == "symlink":
            require(not absolute, "absolute link entries unsupported")
            target, _ = nio_link_spec(root, workspace, path)
            path_text(value["target"], absolute=False)
            equal(value["target"], target, "literal package link target")
    equal([v["path"] for v in values], sorted(seen), "inventory order")
    if not absolute:
        require(any(v["path"] == "." and v["type"] == "directory" for v in values),
                "missing inventory root")


def source_schema(value, workspace=None):
    keys(value, "root commit tree control entries tracked")
    path_text(value["root"])
    hex_value(value["commit"], 40)
    hex_value(value["tree"], 40)
    require(type(value["control"]) is list and 1 <= len(value["control"]) <= 2,
            "invalid control inventory")
    for control in value["control"]:
        keys(control, "root entries")
        path_text(control["root"])
        entries_schema(control["entries"])
    entries_schema(value["entries"], root=value["root"], workspace=workspace)
    require(type(value["tracked"]) is list and len(value["tracked"]) <= TREE_ENTRIES,
            "invalid tracked inventory")
    for tracked in value["tracked"]:
        keys(tracked, "path git_mode")
        path_text(tracked["path"], absolute=False)
        require(tracked["git_mode"] in ("100644", "100755", "120000"), "invalid Git mode")
    nio_link_bindings(value["root"], workspace, value["entries"], value["tracked"])


def schema(value):
    keys(value, "schema_version profile workspace expected_commit expected_tree source packages "
         "toolchain compile inputs metadata products")
    equal(value["schema_version"], 1, "receipt version")
    equal(value["profile"], PROFILE, "receipt profile")
    w = Path(path_text(value["workspace"]))
    hex_value(value["expected_commit"], 40)
    hex_value(value["expected_tree"], 40)
    source_schema(value["source"], w)
    equal(value["source"]["root"], str(w / "source"), "source layout")
    equal(value["source"]["commit"], value["expected_commit"], "expected commit")
    equal(value["source"]["tree"], value["expected_tree"], "expected tree")
    for required in REVIEWED:
        require(required in {item["path"] for item in value["source"]["tracked"]},
                "missing reviewed project input")
    packages = value["packages"]
    keys(packages, "lockfile workspace_state checkouts")
    for key, path in (("lockfile", w / "source" / LOCKFILE),
                      ("workspace_state", w / "Packages/workspace-state.json")):
        file_schema(packages[key])
        equal(packages[key]["path"], str(path), "package metadata layout")
        integer(packages[key]["size"], METADATA_BYTES)
    require(type(packages["checkouts"]) is list and len(packages["checkouts"]) == 9,
            "nine checkouts required")
    for checkout, identity in zip(packages["checkouts"], IDENTITIES):
        source_schema(checkout, w)
        equal(checkout["root"], str(w / "Packages/checkouts" / identity), "checkout layout")
    for source in [value["source"], *packages["checkouts"]]:
        for control in source["control"]:
            inside(control["root"], w)
    toolchain = value["toolchain"]
    keys(toolchain, "info version binary")
    for key, filename in (("info", "Info.plist"), ("version", "version.plist")):
        keys(toolchain[key], "file fields")
        file_schema(toolchain[key]["file"])
        equal(toolchain[key]["file"]["path"], str(Path(DEVELOPER).parent / filename),
              "toolchain layout")
        integer(toolchain[key]["file"]["size"], METADATA_BYTES)
        fields = toolchain[key]["fields"]
        require(type(fields) is dict and set(fields).issubset({
            "CFBundleShortVersionString", "CFBundleVersion", "DTXcodeBuild",
            "ProductBuildVersion"}), "unsupported toolchain field")
        required = {"CFBundleShortVersionString", "CFBundleVersion"}
        if key == "version":
            required.add("ProductBuildVersion")
        require(required.issubset(fields), "missing Xcode version field")
        for field in fields.values():
            require(bool(text(field)), "empty Xcode field")
    file_schema(toolchain["binary"])
    equal(toolchain["binary"]["path"], XCODEBUILD, "compiler binary")
    compile_record = value["compile"]
    keys(compile_record, "argv environment cwd exit_code evidence")
    equal(compile_record["argv"], recipe(w), "fixed recipe")
    equal(compile_record["environment"], environment(w), "fixed environment")
    equal(compile_record["cwd"], str(w / "source"), "compile cwd")
    equal(compile_record["exit_code"], 0, "compile exit")
    keys(compile_record["evidence"], "journal stdout stderr claim compile-intent")
    for key, witness in compile_record["evidence"].items():
        file_schema(witness)
        suffix = ".json" if key in ("claim", "compile-intent") else ".log"
        equal(witness["path"], str(w / "build-evidence" / (key + suffix)), "log layout")
        if key not in ("stdout", "stderr"):
            integer(witness["size"], METADATA_BYTES)
    inputs = value["inputs"]
    keys(inputs, "lists generated")
    require(type(inputs["lists"]) is list and len(inputs["lists"]) <= TREE_ENTRIES,
            "invalid source-list collection")
    for item in inputs["lists"]:
        keys(item, "file inputs")
        file_schema(item["file"])
        integer(item["file"]["size"], METADATA_BYTES)
        inside(item["file"]["path"], w / INTERMEDIATES)
        require(type(item["inputs"]) is list and len(item["inputs"]) <= TREE_ENTRIES,
                "invalid Swift input set")
        for source in item["inputs"]:
            keys(source, "path association")
            path_text(source["path"])
            require(source["association"] in
                    ("source", "generated", *("package:" + i for i in IDENTITIES)),
                    "invalid input association")
    require(type(inputs["generated"]) is list, "invalid generated set")
    if inputs["generated"]:
        entries_schema(inputs["generated"], absolute=True)
        for item in inputs["generated"]:
            roots = [w / base for base in (INTERMEDIATES, DERIVED_SOURCES)
                     if Path(item["path"]).is_relative_to(w / base)]
            require(len(roots) == 1, "generated layout")
            require(len(Path(item["path"]).relative_to(roots[0]).parts) <= TREE_DEPTH,
                    "generated depth limit")
    metadata = value["metadata"]
    keys(metadata, "original prepared intent run_id profile")
    equal(metadata["profile"], prepare.RETENTION_PROFILE, "metadata profile")
    prepare.check_run_id(metadata["run_id"])
    for key in ("original", "prepared", "intent"):
        file_schema(metadata[key])
        integer(metadata[key]["size"], METADATA_BYTES)
        require(Path(metadata[key]["path"]).parent == w / PRODUCTS, "metadata layout")
    output, intent = prepare.output_paths(Path(metadata["original"]["path"]), metadata["run_id"])
    equal(metadata["prepared"]["path"], str(output), "output layout")
    equal(metadata["intent"]["path"], str(intent), "intent layout")
    entries_schema(value["products"])
    return w


def verify_evidence(value):
    w = schema(value)
    equal(source_observation(w / "source", w, value["expected_commit"], value["expected_tree"]),
          value["source"], "source observation")
    equal(package_observation(w), value["packages"], "package observation")
    equal(toolchain_observation(), value["toolchain"], "toolchain observation")
    equal(input_observation(w, value["source"], value["packages"]), value["inputs"],
          "Swift input witness")
    for witness in value["compile"]["evidence"].values():
        equal(file_data(witness["path"])[0], witness, "finalized evidence")
    # Journal contents bind the pre-spawn intent and finalized successful state.
    _, data = bounded(w / "build-evidence/journal.log")
    equal(json_bytes(data), journal_record(w, value["expected_commit"], value["expected_tree"],
                                         complete=True), "compile journal")
    _, data = bounded(w / "build-evidence/compile-intent.json")
    equal(json_bytes(data), journal_record(w, value["expected_commit"], value["expected_tree"]),
          "pre-spawn compile intent")
    _, data = bounded(w / "build-evidence/claim.json")
    equal(json_bytes(data), claim_record(w, value["expected_commit"], value["expected_tree"]),
          "one-use claim")
    equal(inventory(w / PRODUCTS), value["products"], "whole Products")
    record = validate_metadata(value["metadata"])
    equal(inventory(w / PRODUCTS), value["products"], "post-validate whole Products")
    return record


def journal_record(w, commit, tree, complete=False):
    return {"state": "compile-complete-precommit" if complete else "compile-intent",
            "workspace": str(w), "expected_commit": commit, "expected_tree": tree,
            "argv": recipe(w), "environment": environment(w), "cwd": str(w / "source"),
            "exit_code": 0 if complete else None}


def claim_record(w, commit, tree):
    return {"profile": PROFILE, "workspace": str(w),
            "expected_commit": commit, "expected_tree": tree}


def validate(receipt_path, expected_sha256):
    """External SHA pin is mandatory. Read-only; final fixed name only."""
    hex_value(expected_sha256, 64)
    witness, data = bounded(receipt_path, RECEIPT_BYTES)
    equal(witness["sha256"], expected_sha256, "externally supplied receipt SHA256")
    value = json_bytes(data)
    w = schema(value)
    equal(path_text(receipt_path), str(w / "build-evidence/receipt.json"), "final receipt name")
    record = verify_evidence(value)
    equal(bounded(receipt_path, RECEIPT_BYTES)[0], witness, "receipt recheck")
    return record
