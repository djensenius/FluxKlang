#!/usr/bin/env python3
"""Hosted-only iOS observation support; current entrypoint is build/preflight-only.

No CLI bypasses. Fixtures inject the command boundary and use only temporary files.
See README for dependency sequencing, API/layout refusals and remaining runtime proof.
"""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
import uuid

import ios_runtime
import prepare
from ios_observation_summary import NA, receipt_counts, summarize, write_summary

DEVELOPER = "/Applications/Xcode_27.1.app/Contents/Developer"
SCHEME = "FluxKlangIsolatedTests"
PROFILE = "ios-simulator-isolated-unit-ui-v1"
APP_ID = "org.davidjensenius.FluxKlang"
MARKER = "FluxKlangAuditRequireFileReceipts-v1"
PACKAGE = "FluxKlang.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# #703 implementation edd9feb, reviewed at 00c4d510; integrated from main via #704.
# Pin implementation bytes, not just the opt-in marker. No old-code fallback.
SOURCE_PINS = {
    "FluxKlangTests/ProductionAccessScope.swift":
        "ec2269ffaf3961b25878fefc88cdc1b9d678c54b2cf5a1155792fa324127acb4",
    "FluxKlangTests/UIAuditRunPreflight.swift":
        "8f38abe97e71019c507a17fe40c533cba348ec76c21ef563167a1278a37c99fc",
    "FluxKlangUITests/UITestAppSupport.swift":
        "ab835229ba33ef793df3e5c9110864422a4d0a421c989a73181343229352ebf3",
    "Shared/MIDI/HardwareServiceFactories.swift":
        "37b543fb7d9b8e85adc133895edbe02fce947c0dcfdbaff31cb5d27c36f2af99",
}


class Refusal(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def utc():
    return datetime.now(timezone.utc).isoformat()


def load_json(value):
    return json.loads(value, object_pairs_hook=prepare.unique_pairs,
                      parse_constant=prepare.invalid_constant)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value),
            "missing/unsafe inventory identifier")
    return value


def device_uuid(value):
    require(isinstance(value, str) and re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value),
        "simctl did not return one canonical UUID")
    require(uuid.UUID(value).int != 0, "nil device UUID")
    return value


def entries(inventory, key):
    require(isinstance(inventory, dict), "malformed inventory object")
    value = inventory.get(key)
    require(isinstance(value, list) and all(isinstance(v, dict) for v in value),
            "missing/malformed inventory " + key)
    return value


def select_inventory(inventory):
    """Exact policy from docs/transformation/toolchain-inventory.md, not runner proof."""
    runtimes = entries(inventory, "runtimes")
    types = entries(inventory, "devicetypes")
    candidates = [r for r in runtimes if r.get("name") == "iOS 27.0" or (
        r.get("platform") == "iOS" and r.get("version") == "27.0")]
    require(len(candidates) == 1, "iOS 27.0 runtime absent or ambiguous")
    runtime = candidates[0]
    require(runtime.get("name") == "iOS 27.0" and runtime.get("version") == "27.0"
            and runtime.get("platform") in (None, "iOS")
            and runtime.get("isAvailable") is True and not runtime.get("availabilityError"),
            "iOS 27.0 runtime unavailable/inconsistent")
    runtime_id = identifier(runtime.get("identifier"))
    build = identifier(runtime.get("buildversion"))
    require(sum(r.get("identifier") == runtime_id for r in runtimes) == 1,
            "duplicate runtime identifier")
    matches = [d for d in types if d.get("name") == "iPhone 17"]
    require(len(matches) == 1, "iPhone 17 device type absent or ambiguous")
    device_type = matches[0]
    type_id = identifier(device_type.get("identifier"))
    require(device_type.get("productFamily") == "iPhone"
            and device_type.get("isAvailable", True) is True and not device_type.get("availabilityError"),
            "unavailable/non-iPhone type")
    require(sum(d.get("identifier") == type_id for d in types) == 1, "duplicate device type identifier")
    # simctl encodes versions as major<<16 | minor<<8 | patch. Missing range data is a refusal.
    low, high = device_type.get("minRuntimeVersion"), device_type.get("maxRuntimeVersion")
    require(type(low) is int and type(high) is int and low <= (27 << 16) <= high,
            "missing/incompatible device runtime range")
    supported = [d for d in entries(runtime, "supportedDeviceTypes") if d.get("identifier") == type_id]
    require(len(supported) == 1 and supported[0].get("name") == "iPhone 17",
            "runtime does not unambiguously support iPhone 17")
    return {"runtime_identifier": runtime_id, "runtime_version": "27.0", "runtime_build": build,
            "device_type_identifier": type_id, "device_type": "iPhone 17"}


def device_entries(inventory):
    require(isinstance(inventory, dict), "malformed devices inventory object")
    devices = inventory.get("devices")
    require(isinstance(devices, dict), "missing devices inventory")
    result = []
    for runtime, values in devices.items():
        require(isinstance(values, list) and all(isinstance(v, dict) for v in values),
                "malformed devices inventory")
        for item in values:
            device_uuid(item.get("udid"))
            result.append((runtime, item))
    require(len({d["udid"].lower() for _, d in result}) == len(result), "duplicate device UUID")
    return result


def real_path(path, root, directory=False):
    """Require a nonsymlink path strictly below the selected canonical owned root."""
    path, root = Path(path), Path(root)
    require(path.is_absolute() and path != root and root in path.parents, "path outside owned root")
    require(path.resolve(strict=True) == path, "symlink/noncanonical owned path")
    info = path.lstat()
    require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            and info.st_uid == os.geteuid(), "wrong path type/owner")
    return info


def identity(info):
    return info.st_dev, info.st_ino


def verify_sources(repo):
    for relative, digest in SOURCE_PINS.items():
        path = repo / relative
        real_path(path, repo)
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest,
                "reviewed source contract absent/changed: " + relative + " (requires integrated #703)")


def commands(argv, *, cwd, env, timeout, input_text=None):
    """Never a shell. Reap the owned command group on timeout/cancellation; no command retries."""
    with subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE if input_text is not None else None,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(input=input_text, timeout=timeout)
        except BaseException as exc:
            # This process group was created above, never discovered by name.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
            exc.returncode = process.returncode  # Preserve a known killed-command exit, not a fabricated 124.
            raise
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


class Observation:
    def __init__(self, repo, env, execute=commands):
        self.repo = Path(repo).resolve(strict=True)
        self.env = dict(env)
        self.execute = execute
        self.deadline = time.monotonic() + 80 * 60  # Leave 20 minutes for evidence/cleanup/upload.
        self.finalizing = False
        self.work = self.summary_dir = self.device = self.device_root = self.receipts = None
        self.work_identity = self.device_identity = self.receipt_identity = None
        self.container = self.container_identity = None
        self.results = None
        self.result_error = "no result bundle"
        self.counts = dict.fromkeys(
            ("receipts_published", "receipts_partial_leftovers", "receipts_other_entries"), NA)
        self.state = {
            "head_sha": NA, "event_sha": env.get("GITHUB_SHA", NA),
            "pr_head_sha": env.get("PR_HEAD_SHA") or "not applicable",
            "start_utc": utc(), "end_utc": NA, "test_start_utc": NA, "test_end_utc": NA,
            "test_exit_code": NA, "observation_exit_code": 1, "test_launch_calls": 0,
            "phase": "setup", "preparation": NA, "guard": "not verified", "refusal": None,
            "cleanup_failures": [], "run_id": NA, "test_argv": [],
            "receipt_strategy": "fresh 0700 directory in installed unit-host app's own data container",
            "pin_provenance": "computed once for this run; NOT independently reviewed",
        }
        for key in ("xcode", "macos", "python", "simulator_sdk", "xctestrun", "xctestrun_sha256",
                    "runtime_identifier", "runtime_version", "runtime_build",
                    "device_type_identifier", "device_type", "device_udid"):
            self.state[key] = NA

    def run(self, argv, timeout=120, checked=True, extra_env=None, input_text=None):
        if not self.finalizing:
            remaining = self.deadline - time.monotonic()
            require(remaining > 0, "observation deadline exhausted; no retry")
            timeout = min(timeout, remaining)
        if argv[:2] == [DEVELOPER + "/usr/bin/xcodebuild", "test-without-building"]:
            require(self.state["test_launch_calls"] == 0, "a second test invocation is forbidden")
            self.state.update(test_launch_calls=1, test_start_utc=utc())
        result = self.execute([str(v) for v in argv], cwd=str(self.repo),
                              env=dict(self.env, **(extra_env or {})), timeout=timeout, input_text=input_text)
        if checked:
            require(result.returncode == 0,
                    "%s exited %s: %s" % (argv[0], result.returncode, result.stderr or result.stdout))
        return result

    def sim(self, *args, **kwargs):
        return self.run(["xcrun", "simctl", *args], **kwargs)

    def snapshot(self):
        if self.summary_dir is not None:
            write_summary(self.summary_dir, self.state, self.results, self.result_error, self.counts)

    def setup(self):
        # Summary is allocated before dependency/tool checks, and retained outside generated work.
        temp = Path(self.env["RUNNER_TEMP"]).resolve(strict=True)
        require(temp.is_dir() and temp.stat().st_uid == os.geteuid(), "unowned RUNNER_TEMP")
        out = Path(tempfile.mkdtemp(prefix="ios-observation-summary-", dir=str(temp)))
        self.summary_dir = out
        self.snapshot()
        require(not any(c in str(out) for c in "\r\n"), "summary path contains a line break")
        # Advertise only files in the directory just created, never a preexisting fixed path.
        with open(self.env["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write("summary_json=%s\nsummary_markdown=%s\n" % (out / "summary.json", out / "summary.md"))
        self.work = Path(tempfile.mkdtemp(prefix="ios-observation-", dir=str(temp)))
        self.work_identity = identity(self.work.stat())
        require(self.env.get("GITHUB_ACTIONS") == "true" and self.env.get("RUNNER_OS") == "macOS",
                "hosted GitHub macOS runner required")
        require(self.env.get("DEVELOPER_DIR") == DEVELOPER, "wrong DEVELOPER_DIR")
        require(not any(k.startswith(("FLUXKLANG_", "TEST_RUNNER_FLUXKLANG_", "SIMCTL_CHILD_"))
                        or k == "SIMULATOR_DEVICE_SET_PATH" for k in self.env),
                "ambient audit/isolation/simulator overrides refused")
        self.state["head_sha"] = self.run(["git", "rev-parse", "HEAD"]).stdout.strip()
        require(re.fullmatch(r"[0-9a-f]{40}", self.state["head_sha"]), "invalid checkout SHA")
        require(self.state["pr_head_sha"] == "not applicable"
                or re.fullmatch(r"[0-9a-f]{40}", self.state["pr_head_sha"]), "invalid PR head SHA")
        require(self.env.get("SETUP_OUTCOME") == "success/success", "checkout/mise setup failed")
        verify_sources(self.repo)  # Verify integrated source; marker alone is never authority.
        self.state["guard"] = "reviewed integrated source verified; build not yet verified"
        self.state["python"] = sys.version
        require(sys.version_info >= (3, 7), "Python 3.7+ required")
        self.state["xcode"] = self.run([DEVELOPER + "/usr/bin/xcodebuild", "-version"]).stdout
        require(self.state["xcode"].startswith("Xcode 27.1\n"), "not Xcode 27.1")
        self.state["macos"] = self.run(["sw_vers", "-productVersion"]).stdout.strip()
        sdk = self.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).stdout.strip()
        require(re.fullmatch(r"\d+\.\d+(?:\.\d+)?", sdk) and int(sdk.split(".")[0]) >= 27,
                "iOS simulator SDK below 27 or unparseable")
        self.state["simulator_sdk"] = sdk
        want = self.run(["mise", "current", "xcodegen"]).stdout.strip()
        have = self.run(["xcodegen", "--version"]).stdout.strip()
        require(want and have == "Version: " + want, "xcodegen is not the mise.toml pin")
        self.run(["xcodegen", "generate"])
        require(not self.run(["git", "status", "--porcelain", "--untracked-files=all"]).stdout,
                "generated project changed the tree")
        real_path(self.repo / PACKAGE, self.repo)
        require(self.run(["git", "ls-files", "--", PACKAGE]).stdout.strip() == PACKAGE,
                "committed package pins missing")
        self.package_digest = hashlib.sha256((self.repo / PACKAGE).read_bytes()).hexdigest()

    def packages_unchanged(self):
        self.run(["git", "--no-pager", "diff", "--exit-code", "--", "*Package.resolved"])
        require(not self.run(["git", "status", "--porcelain", "--untracked-files=all",
                              "--", "*Package.resolved"]).stdout, "package pin drift")
        require(hashlib.sha256((self.repo / PACKAGE).read_bytes()).hexdigest() == self.package_digest,
                "package pins changed")

    def allocate_device(self):
        self.state["phase"] = "inventory"
        inventory = load_json(self.sim("list", "--json").stdout)
        self.selection = select_inventory(inventory)
        self.state.update(self.selection)
        prior = {d["udid"].lower() for _, d in device_entries(inventory)}
        self.device_name = "FluxKlang-observation-" + str(uuid.uuid4())
        # A UUID printed by a failed create is not evidence of ownership, even if previously unseen.
        try:
            created = self.sim("create", self.device_name, self.selection["device_type_identifier"],
                               self.selection["runtime_identifier"], checked=False)
        except Exception:
            self.state["cleanup_failures"].append("create did not complete successfully; ownership uncertain; no device cleanup")
            raise
        if created.returncode != 0:
            self.state["cleanup_failures"].append("create failed; ownership uncertain; no device cleanup")
            raise Refusal("simctl create exited %s; no device adopted" % created.returncode)
        try:
            candidate = device_uuid(created.stdout.strip())
        except ValueError:
            self.state["cleanup_failures"].append("create returned no usable UUID; cannot reclaim an unknown device")
            raise
        require(candidate.lower() not in prior, "create returned a preexisting device; not adopted")
        self.device = candidate
        self.state["device_udid"] = candidate
        self.verify_device("Shutdown")

    def verify_device(self, expected_state):
        found = [(r, d) for r, d in device_entries(load_json(self.sim("list", "devices", "--json").stdout))
                 if d["udid"].lower() == self.device.lower()]
        require(len(found) == 1, "owned device absent/ambiguous")
        runtime, device = found[0]
        require(runtime == self.selection["runtime_identifier"] and device.get("name") == self.device_name
                and device.get("deviceTypeIdentifier") == self.selection["device_type_identifier"]
                and device.get("isAvailable") is True and device.get("state") == expected_state,
                "owned device inventory mismatch")
        base = (Path(self.env["HOME"]) / "Library/Developer/CoreSimulator/Devices").resolve(strict=True)
        root = base / self.device
        info = real_path(root, base, directory=True)
        if self.device_identity is not None:
            require(identity(info) == self.device_identity, "owned device directory replaced")
        self.device_root, self.device_identity = root, identity(info)
        require(device.get("dataPath") == str(root / "data"), "unexpected device dataPath")
        real_path(root / "data", root, directory=True)

    def build(self):
        self.state["phase"] = "build"
        self.dd = self.work / "dd"
        self.dd.mkdir(mode=0o700)
        common = [DEVELOPER + "/usr/bin/xcodebuild", "-project", "FluxKlang.xcodeproj",
                  "-scheme", SCHEME, "-configuration", "Debug",
                  "-destination", "platform=iOS Simulator,id=" + self.device,
                  "-disableAutomaticPackageResolution", "-derivedDataPath", str(self.dd)]
        self.run(common + ["-resolvePackageDependencies"], timeout=600)
        self.packages_unchanged()
        self.run(common + ["build-for-testing", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"], timeout=1800)
        self.packages_unchanged()
        products = self.dd / "Build/Products"
        real_path(products, self.work, directory=True)
        found = list(products.rglob("*.xctestrun"))
        require(len(found) == 1, "expected exactly one generated xctestrun")
        self.original = found[0]
        real_path(self.original, self.work)
        self.pin = hashlib.sha256(self.original.read_bytes()).hexdigest()  # Select once; never repin.
        self.state.update(xctestrun=str(self.original), xctestrun_sha256=self.pin, phase="prepare")
        return products

    def build_prepare(self):
        products = self.build()
        record = prepare.prepare(self.original, self.pin, PROFILE)
        self.prepared, self.intent = Path(record["output"]["path"]), Path(record["intent_path"])
        self.state["run_id"] = record["run_id"]
        self.validate_metadata()
        self.state["preparation"] = "prepared and validated: " + PROFILE
        # Paths below are the closed profile's exact unit host/bundle, never the UI runner.
        self.app = products / "Debug-iphonesimulator/FluxKlang.app"
        self.unit = self.app / "PlugIns/FluxKlangTests.xctest"
        for bundle, bundle_id in ((self.app, APP_ID), (self.unit, APP_ID + ".tests")):
            real_path(bundle, self.work, directory=True)
            real_path(bundle / "Info.plist", self.work)
            info = plistlib.loads((bundle / "Info.plist").read_bytes())
            require(info.get("CFBundleIdentifier") == bundle_id, "built bundle identity mismatch")
            executable = identifier(info.get("CFBundleExecutable"))
            binary = bundle / executable
            real_path(binary, self.work)
            if bundle == self.unit:
                lines = self.run(["xcrun", "nm", "-a", str(binary)]).stdout.splitlines()
                # Defined symbols, not undefined references to a guard in some other image.
                symbols = [parts[2] for line in lines for parts in [line.split(maxsplit=2)]
                           if len(parts) == 3 and re.fullmatch(r"[0-9a-fA-F]+", parts[0])
                           and len(parts[1]) == 1 and parts[1] not in ("U", "u")]
                # Swift word substitutions can encode provideScope as 07provideF0. Demangle
                # definitions only, via stdin rather than an argv proportional to the bundle.
                symbols = self.run(["xcrun", "swift-demangle", "--compact"],
                                   input_text="\n".join(symbols) + "\n").stdout.splitlines()
                for pattern, symbol in (
                    (r"static FluxKlangTests\.ProductionAccessObservation\.requiresFileReceipts\(",
                     "requiresFileReceipts"),
                    (r"type metadata(?: accessor)? for FluxKlangTests\.ProductionAccessObservation\."
                     r"\(BundleAnchor in _[0-9a-fA-F]+\)$", "BundleAnchor"),
                    (r"FluxKlangTests\.ProductionAccessScope\.provideScope\(", "provideScope"),
                ):
                    require(any(re.match(pattern, line) for line in symbols),
                            "built unit guard symbol absent: " + symbol)
                contents = binary.read_bytes()
                require(MARKER.encode() in contents, "built unit guard marker string absent")
                self.unit_executable = executable
                self.unit_digest = hashlib.sha256(contents).hexdigest()
        verify_sources(self.repo)
        self.marker = self.unit / MARKER
        with self.marker.open("xb"):
            pass
        self.marker_identity = identity(self.marker.lstat())
        self.verify_marker(self.unit)
        self.state["guard"] = "reviewed source + fresh unit executable symbols/string + root marker verified"

    def validate_metadata(self):
        record = prepare.validate(self.original, self.pin, PROFILE, self.prepared, self.intent)
        require(record["run_id"] == self.state["run_id"], "audit run identity changed")

    def verify_marker(self, bundle):
        info = real_path(bundle / MARKER, bundle)
        require(info.st_size == 0, "marker must be empty")
        binary = bundle / self.unit_executable
        real_path(binary, bundle)
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == self.unit_digest,
                "unit executable changed since guard verification")
        if bundle == self.unit:
            require(identity(info) == self.marker_identity, "built marker replaced")

    def app_container(self, kind):
        raw = self.sim("get_app_container", self.device, APP_ID, kind).stdout.strip()
        require(raw and "\n" not in raw and "\r" not in raw, "ambiguous app container path")
        path = Path(raw)
        base = self.device_root / "data/Containers" / ("Data" if kind == "data" else "Bundle") / "Application"
        # Standard CoreSimulator layout only. No guessed container UUID, fallback, or chmod repair.
        container = path if kind == "data" else path.parent
        require(container.parent == base, "container outside owned device's application containers")
        device_uuid(container.name)
        real_path(container, self.device_root, directory=True)
        real_path(path, self.device_root, directory=True)
        return path

    def install_receipts(self):
        self.state["phase"] = "boot/install/receipt preflight"
        self.sim("boot", self.device, timeout=180)
        self.sim("bootstatus", self.device, "-b", timeout=300)
        self.verify_device("Booted")
        self.sim("install", self.device, str(self.app), timeout=180)  # Install only, never simctl launch.
        installed = self.app_container("app")
        self.verify_marker(installed / "PlugIns/FluxKlangTests.xctest")
        self.container = self.app_container("data")
        self.container_identity = identity(self.container.stat())
        self.receipts = self.container / ("FluxKlangAuditReceipts-" + self.state["run_id"])
        self.receipts.mkdir(mode=0o700)
        self.receipt_identity = identity(self.receipts.lstat())
        self.verify_receipts(empty=True)

    def verify_receipts(self, empty=False):
        require(self.app_container("data") == self.container, "unit host data container changed")
        require(identity(real_path(self.container, self.device_root, directory=True)) == self.container_identity,
                "unit host data container replaced")
        info = real_path(self.receipts, self.container, directory=True)
        require(identity(info) == self.receipt_identity and stat.S_IMODE(info.st_mode) == 0o700,
                "receipt directory replaced or not 0700")
        if empty:
            require(not any(self.receipts.iterdir()), "receipt directory is not fresh/empty")

    def launch(self):
        self.state["phase"] = "final launch preflight"
        verify_sources(self.repo)
        self.packages_unchanged()
        self.validate_metadata()
        self.verify_marker(self.unit)
        self.verify_marker(self.app_container("app") / "PlugIns/FluxKlangTests.xctest")
        self.verify_device("Booted")
        self.verify_receipts(empty=True)
        self.result_bundle = self.work / "observation.xcresult"
        require(not os.path.lexists(self.result_bundle), "result bundle already exists")
        argv = [DEVELOPER + "/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(self.prepared),
                "-destination", "platform=iOS Simulator,id=" + self.device, "-parallel-testing-enabled", "NO",
                "-resultBundlePath", str(self.result_bundle)]
        self.state.update(phase="test", test_argv=argv)
        self.snapshot()
        try:
            result = self.run(argv, timeout=2700, checked=False,
                              extra_env={"TEST_RUNNER_FLUXKLANG_AUDIT_RECEIPT_DIR": str(self.receipts)})
            self.state["test_exit_code"] = result.returncode
        except Exception as exc:
            if type(getattr(exc, "returncode", None)) is int:
                self.state["test_exit_code"] = exc.returncode
            raise
        finally:
            self.state["test_end_utc"] = utc()
        # A reinstallation/container change is a refusal, not a reason to recreate permissions.
        self.verify_receipts()
        self.verify_marker(self.app_container("app") / "PlugIns/FluxKlangTests.xctest")

    def collect(self):
        if self.receipt_identity is not None:
            try:
                self.verify_receipts()
                self.counts = receipt_counts(self.receipts)
            except Exception as exc:
                self.state["receipt_evidence_error"] = str(exc)
        bundle = getattr(self, "result_bundle", None)
        if bundle is not None and bundle.exists():
            try:
                real_path(bundle, self.work, directory=True)
                result = self.run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                   "--path", str(bundle), "--compact"], timeout=120)
                self.results = load_json(result.stdout)
                require(isinstance(self.results, dict), "malformed xcresult summary")
                self.result_error = None
            except Exception as exc:
                self.result_error = str(exc)

    def cleanup(self):
        # Only a valid new UUID returned by a successful create is adopted.
        # Even boot/install/build failures reach both shutdown and delete; never 'all'/'unavailable'.
        owned = bool(self.device)
        if self.device_root is not None:
            try:
                require(identity(self.device_root.lstat()) == self.device_identity
                        and not self.device_root.is_symlink(), "owned device directory replaced")
            except Exception as exc:
                owned = False
                self.state["cleanup_failures"].append("device ownership: " + str(exc))
        if owned:
            for operation in ("shutdown", "delete"):
                try:
                    if operation == "shutdown":
                        try:
                            self.verify_device("Shutdown")
                        except Exception as exc:
                            # Failure to confirm Shutdown is not permission to ignore a shutdown error.
                            self.state["cleanup_shutdown_precheck"] = "not confirmed: " + str(exc)
                        else:
                            self.state["cleanup_shutdown"] = "not needed: owned device observed Shutdown"
                            continue
                    # The inventory probe may have observed replacement; recheck before either command.
                    if self.device_root is not None:
                        try:
                            require(identity(self.device_root.lstat()) == self.device_identity
                                    and not self.device_root.is_symlink(), "owned device directory replaced")
                        except Exception as exc:
                            self.state["cleanup_failures"].append("device ownership: " + str(exc))
                            break
                    self.sim(operation, self.device, timeout=120)
                    self.state["cleanup_" + operation] = (
                        "command exited 0; absence not independently verified" if operation == "delete"
                        else "command exited 0")
                except Exception as exc:
                    self.state["cleanup_failures"].append(operation + ": " + str(exc))
        # Receipt/container files belong to the owned simulator and are removed by simctl delete.
        # Do not recursively remove a simulator data path ourselves if deletion fails.
        if self.work is not None:
            try:
                require(identity(self.work.lstat()) == self.work_identity and not self.work.is_symlink(),
                        "work directory identity changed; not removed")
                shutil.rmtree(self.work)
            except Exception as exc:
                self.state["cleanup_failures"].append("generated work: " + str(exc))

    def observe(self):
        try:
            self.setup()
            self.allocate_device()
            self.build_prepare()
            self.install_receipts()
            self.launch()
        except Exception as exc:
            self.state["refusal"] = str(exc)
        finally:
            self.finalizing = True
            try:
                self.collect()
            except Exception as exc:
                self.result_error = str(exc)
            finally:
                self.cleanup()
            evidence, _ = summarize(self.state, self.results, self.result_error, self.counts)
            code = self.state["test_exit_code"]
            if code == 0 and not self.state["refusal"]:
                complete = (type(evidence["total"]) is int and evidence["total"] > 0
                            and type(evidence["passed"]) is int and evidence["passed"] > 0
                            and evidence["failed"] == 0 and evidence["failure_count"] == 0
                            and evidence["audit_failure_count"] == 0
                            and type(evidence["receipts_published"]) is int and evidence["receipts_published"] > 0
                            and evidence["receipts_partial_leftovers"] == 0
                            and evidence["receipts_other_entries"] == 0)
                if not complete:
                    self.state["refusal"] = "missing/failed test or unit file-publication evidence"
            status = code if type(code) is int and code != 0 else (
                1 if code != 0 or self.state["refusal"] or self.state["cleanup_failures"] else 0)
            if status < 0:
                status = 128 - status  # Shell exit convention; retain the actual negative test exit above.
            self.state.update(observation_exit_code=status, end_utc=utc())
            if self.summary_dir:
                write_summary(self.summary_dir, self.state, self.results, self.result_error, self.counts,
                              self.env.get("GITHUB_STEP_SUMMARY"))
        return status


class MetadataDiagnostic(Observation):
    """Temporary production entrypoint: build/read metadata only, always stop before preparation.

    No CLI/environment switch enables tests. Restoring observation requires a reviewed code change.
    """

    def observe(self):
        self.state["attempt_kind"] = "build/preflight-only runtime verification; full observation blocked"
        self.state["runtime_evidence"] = {
            "profile": prepare.IOS_RUNTIME_PROFILE, "prebuild": NA, "generated_input": NA,
            "limitation": "completed checks only; NOT reusable launch authority",
        }
        return super().observe()

    @contextmanager
    def runtime_check(self, stage):
        self.state["phase"] = "runtime " + stage
        evidence = self.state["runtime_evidence"]
        try:
            yield
        except Exception as exc:
            evidence[stage] = "refused"
            evidence["refusal_context"] = getattr(exc, "context", {})
            raise
        else:
            # Only after the real verifier's context exit/rechecks have completed.
            evidence[stage] = "accepted"

    def allocate_device(self):
        with self.runtime_check("prebuild"):
            with ios_runtime.verified_checker():
                pass
        super().allocate_device()

    def run(self, argv, **kwargs):
        # Defense in depth if a later change accidentally reaches the inherited launch path.
        if argv[0] == DEVELOPER + "/usr/bin/xcodebuild":
            require(not any(a in ("test", "test-without-building") for a in argv),
                    "build/preflight-only diagnostic forbids test launch")
            require(argv[1:] == ["-version"] or "-resolvePackageDependencies" in argv
                    or "build-for-testing" in argv, "unsupported diagnostic xcodebuild command")
        elif argv[:2] == ["xcrun", "simctl"]:
            require(len(argv) > 2 and argv[2] in ("list", "create", "shutdown", "delete"),
                    "build/preflight-only diagnostic forbids simulator boot/install/launch")
        elif argv[0] == "xcrun":
            require(argv[1:] == ["--sdk", "iphonesimulator", "--show-sdk-version"],
                    "unsupported diagnostic xcrun command")
        else:
            require(argv[0] in ("git", "mise", "xcodegen", "sw_vers"), "unsupported diagnostic command")
        return super().run(argv, **kwargs)

    def build_prepare(self):
        self.build()
        with self.runtime_check("generated_input"):
            # A fresh verifier context, not the earlier result or a serialized binding.
            real_path(self.original, self.work)
            prepare.pinned_input(self.original, self.pin, prepare.IOS_RUNTIME_PROFILE)
        raise Refusal("build/preflight-only verification complete; full observation remains blocked")


def main():
    def interrupted(signum, _frame):
        raise Refusal("runner interrupted by signal %d; no retry" % signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    observation = MetadataDiagnostic(Path(__file__).resolve().parents[2], os.environ)
    return observation.observe()


if __name__ == "__main__":
    sys.exit(main())
