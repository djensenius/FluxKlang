"""Pure synthetic Git/toolchain/compile fixtures; real preparation and sealing."""

import sys

sys.dont_write_bytecode = True

import copy
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

import build_mac
import build_receipt as receipt
import prepare
from test_prepare import FIXTURE


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def fixture_git(root, *args):
    """Writes only disposable, test-owned synthetic Git data, no hooks/network."""
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "LANG": "C", "LC_ALL": "C",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
           "GIT_AUTHOR_NAME": "Synthetic Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "Synthetic Fixture",
           "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
    return subprocess.run(
        ["/usr/bin/git", "--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
         "-C", str(root), *args], env=env, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=True,
    ).stdout.decode().strip()


def initialize(root):
    fixture_git(root, "init", "--template=")
    fixture_git(root, "add", ".")
    fixture_git(root, "commit", "-m", "pure fixture")
    return fixture_git(root, "rev-parse", "HEAD")


def snapshot(root):
    result = {}
    for path in [root, *root.rglob("*")]:
        info = path.lstat()
        data = path.read_bytes() if stat.S_ISREG(info.st_mode) else None
        result[str(path.relative_to(root))] = (
            data, info.st_mode, info.st_ino, info.st_mtime_ns, info.st_ctime_ns,
        )
    return result


class ProducerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="compile-receipt-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.scratch = Path(cls.temporary.name).resolve()
        cls.template = cls.scratch / "template"
        pins = []
        dependencies = []
        for identity in receipt.IDENTITIES:
            root = cls.template / "Packages/checkouts" / identity
            write(root / "Sources/Package Input.swift", b"struct PackageInput {}\n")
            revision = initialize(root)
            pin = {"identity": identity, "kind": "remoteSourceControl",
                   "location": "https://example.invalid/" + identity,
                   "state": {"revision": revision, "version": "1.0.0"}}
            pins.append(pin)
            dependencies.append({
                "basedOn": None, "packageRef": {key: pin[key]
                                                for key in ("identity", "kind", "location")},
                "state": {"name": "sourceControlCheckout", "checkoutState": pin["state"]},
                "subpath": identity,
            })
            dependencies[-1]["packageRef"]["name"] = "Retained " + identity
        source = cls.template / "source"
        for relative in receipt.REVIEWED:
            write(source / relative, b"synthetic reviewed project input\n")
        write(source / receipt.LOCKFILE, receipt.encode(
            {"version": 3, "originHash": "1" * 64, "pins": pins}))
        write(source / "Sources/App Input.swift", b"struct AppInput {}\n")
        write(source / ".gitignore", b"ignored\n")
        cls.commit = initialize(source)
        cls.tree = fixture_git(source, "rev-parse", "HEAD^{tree}")
        write(cls.template / "Packages/workspace-state.json", receipt.encode({
            "version": 7, "object": {"artifacts": [], "prebuilts": [],
                                     "dependencies": dependencies},
        }))

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="case-", dir=self.scratch)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.w = self.root / "W"
        shutil.copytree(self.template, self.w)
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.binary = str(self.developer / "usr/bin/xcodebuild")
        write(Path(self.binary), b"synthetic compiler witness, never executed")
        for name, fields in (
            ("Info.plist", {"CFBundleShortVersionString": "26.1", "CFBundleVersion": "24000",
                            "DTXcodeBuild": "17A100"}),
            ("version.plist", {"CFBundleShortVersionString": "26.1",
                               "CFBundleVersion": "24000", "ProductBuildVersion": "17B200"}),
        ):
            write(self.developer.parent / name, plistlib.dumps(fields))
        for target, value in (("DEVELOPER", str(self.developer)), ("XCODEBUILD", self.binary)):
            patcher = mock.patch.object(receipt, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.compile = mock.patch.object(build_mac, "compile_once", side_effect=self.fake_compile)
        self.compiler = self.compile.start()
        self.addCleanup(self.compile.stop)
        self.final = self.w / "build-evidence/receipt.json"

    def fake_compile(self, argv, environment, cwd, stdout, stderr):
        self.assertEqual(argv, receipt.recipe(self.w))
        self.assertEqual(environment, receipt.environment(self.w))
        self.assertEqual(cwd, self.w / "source")
        evidence = self.w / "build-evidence"
        for name in ("claim.json", "journal.log", "stdout.log", "stderr.log"):
            self.assertTrue((evidence / name).is_file())
        self.assertEqual(json.loads((evidence / "journal.log").read_bytes())["state"],
                         "compile-intent")
        write(self.w / receipt.PRODUCTS / "Mac.xctestrun", plistlib.dumps(FIXTURE))
        write(self.w / receipt.PRODUCTS / "Debug/FluxKlangMac.app/Contents/MacOS/FluxKlangMac",
              b"synthetic compiled bytes")
        generated = self.w / receipt.DERIVED_SOURCES / "Generated Input.swift"
        write(generated, b"struct GeneratedInput {}\n")
        paths = [self.w / "source/Sources/App Input.swift", generated]
        paths += [self.w / "Packages/checkouts" / identity / "Sources/Package Input.swift"
                  for identity in receipt.IDENTITIES]
        for relative in (*receipt.MANDATORY, "Extra/Other.SwiftFileList"):
            write(self.w / receipt.INTERMEDIATES / relative,
                  ("\n".join(str(path) for path in paths) + "\n").encode())
        stdout.write(b"synthetic compile stdout\n")
        stderr.write(b"synthetic compile stderr\n")
        return 0

    def produce(self):
        return build_mac.produce(str(self.w), self.commit, self.tree)

    def consume(self, result):
        return receipt.validate(result["receipt"], result["sha256"])

    def assert_consumed(self):
        self.assertTrue((self.w / "build-evidence").is_dir())
        self.assertFalse(self.final.exists())
        count = self.compiler.call_count
        with self.assertRaises((receipt.Refusal, OSError)):
            self.produce()
        self.assertEqual(self.compiler.call_count, count)

    def test_end_to_end_real_prepare_seal_consumer_and_read_only(self):
        result = self.produce()
        self.assertEqual(result["status"], "committed")
        self.assertEqual(self.compiler.call_count, 1)
        value = json.loads(self.final.read_bytes())
        self.assertEqual(len(value["packages"]["checkouts"]), 9)
        self.assertEqual(len(value["inputs"]["lists"]), 3)
        self.assertTrue(value["inputs"]["generated"])
        self.assertNotEqual(value["toolchain"]["info"]["fields"]["DTXcodeBuild"],
                            value["toolchain"]["version"]["fields"]["ProductBuildVersion"])
        before = snapshot(self.root)
        record = self.consume(result)
        self.assertEqual(record["profile"], prepare.RETENTION_PROFILE)
        prepared = Path(record["output"]["path"])
        parsed = plistlib.loads(prepared.read_bytes())
        self.assertEqual(parsed["FluxKlangMacTests"]["SystemAttachmentLifetime"], "keepAlways")
        self.assertEqual(snapshot(self.root), before)
        self.assertTrue(sys.dont_write_bytecode)
        self.assertFalse(list(self.root.rglob("__pycache__")))
        self.assertEqual(self.compiler.call_count, 1)
        with self.assertRaises(receipt.Refusal):
            receipt.validate(self.final.with_name("receipt.pending"), result["sha256"])
        with self.assertRaises(receipt.Refusal):
            receipt.validate(self.final, "0" * 64)
        with self.assertRaises(TypeError):
            receipt.validate(self.final)

    def test_product_mutations_and_relocation(self):
        result = self.produce()
        products = self.w / receipt.PRODUCTS
        executable = products / "Debug/FluxKlangMac.app/Contents/MacOS/FluxKlangMac"
        original = executable.read_bytes()
        mode = executable.stat().st_mode
        for operation, restore in (
            (lambda: executable.write_bytes(b"changed"), lambda: executable.write_bytes(original)),
            (lambda: executable.chmod(0o4750), lambda: executable.chmod(stat.S_IMODE(mode))),
            (lambda: (products / "extra").write_bytes(b"x"), lambda: (products / "extra").unlink()),
            (lambda: (products / "empty").mkdir(), lambda: (products / "empty").rmdir()),
            (lambda: executable.rename(executable.with_name("renamed")),
             lambda: executable.with_name("renamed").rename(executable)),
            (lambda: (products / "dangling").symlink_to("missing"),
             lambda: (products / "dangling").unlink()),
            (lambda: os.mkfifo(products / "fifo"), lambda: (products / "fifo").unlink()),
            (lambda: (products / "Debug").chmod(0o1777),
             lambda: (products / "Debug").chmod(0o755)),
        ):
            with self.subTest(operation=operation):
                operation()
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.consume(result)
                restore()
        relocated = self.root / "relocated"
        self.w.rename(relocated)
        with self.assertRaises((receipt.Refusal, OSError)):
            receipt.validate(relocated / "build-evidence/receipt.json", result["sha256"])

    def test_extra_real_prepared_pair_refused(self):
        result = self.produce()
        original = self.w / receipt.PRODUCTS / "Mac.xctestrun"
        prepare.prepare(original, prepare.digest(original.read_bytes()), prepare.RETENTION_PROFILE)
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_source_package_and_independent_toolchain_drift(self):
        result = self.produce()
        for path in [self.w / "source/Sources/App Input.swift",
                     self.w / "Packages/checkouts/swift-ascii/Sources/Package Input.swift",
                     self.developer.parent / "Info.plist", self.developer.parent / "version.plist",
                     Path(self.binary), self.w / receipt.DERIVED_SOURCES / "Generated Input.swift",
                     self.w / "build-evidence/stdout.log"]:
            with self.subTest(path=path):
                original = path.read_bytes()
                if path.suffix == ".plist":
                    parsed = plistlib.loads(original)
                    parsed["CFBundleVersion"] = "changed"
                    path.write_bytes(plistlib.dumps(parsed))
                else:
                    path.write_bytes(original + b"changed")
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.consume(result)
                path.write_bytes(original)

    def test_lists_generated_parent_modes_and_metadata_bindings_drift(self):
        result = self.produce()
        value = json.loads(self.final.read_bytes())
        extra_list = self.w / receipt.INTERMEDIATES / "Extra/Other.SwiftFileList"
        original = extra_list.read_bytes()
        extra_list.write_bytes(original.replace(b"/App Input.swift", b"/Nonexistent.swift"))
        with self.assertRaises((receipt.Refusal, OSError)):
            self.consume(result)
        extra_list.write_bytes(original)
        generated_parent = self.w / receipt.DERIVED_SOURCES
        mode = stat.S_IMODE(generated_parent.stat().st_mode)
        generated_parent.chmod(0o1777)
        with self.assertRaises(receipt.Refusal):
            self.consume(result)
        generated_parent.chmod(mode)
        for key in ("original", "prepared", "intent"):
            path = Path(value["metadata"][key]["path"])
            data = path.read_bytes()
            path.write_bytes(data + b"\n")
            with self.assertRaises(receipt.Refusal):
                self.consume(result)
            path.write_bytes(data)
        output = Path(value["metadata"]["prepared"]["path"])
        data = output.read_bytes()
        output.unlink()
        output.symlink_to("missing")
        with self.assertRaises((receipt.Refusal, OSError)):
            self.consume(result)
        output.unlink()
        output.write_bytes(data)
        # Both malformed extra evidence and a removed mandatory list are caught.
        extra_list.write_bytes(b'"/unsupported/Quoted.swift"\n')
        with self.assertRaises(receipt.Refusal):
            self.consume(result)
        extra_list.write_bytes(original)
        (self.w / receipt.INTERMEDIATES / receipt.MANDATORY[1]).unlink()
        with self.assertRaises(receipt.Refusal):
            self.consume(result)

    def test_closed_receipt_schema_and_duplicate_keys(self):
        self.produce()
        value = json.loads(self.final.read_bytes())
        for change in (
            lambda v: v.update(reviewed=True),
            lambda v: v.update(schema_version=True),
            lambda v: v["compile"].update(exit_code=False),
            lambda v: v["metadata"].update(profile=prepare.PROFILE),
            lambda v: v["products"][0].update(extra="unsupported"),
            lambda v: v["packages"]["checkouts"][0].update(root="/outside"),
            lambda v: v["inputs"]["lists"][0]["inputs"][0].update(association="generated"),
            lambda v: v["compile"]["environment"].update(OTHER="override"),
            lambda v: v["source"]["entries"][0].update(mode=True),
        ):
            with self.subTest(change=change):
                mutated = copy.deepcopy(value)
                change(mutated)
                data = receipt.encode(mutated)
                self.final.write_bytes(data)
                with self.assertRaises(receipt.Refusal):
                    receipt.validate(self.final, prepare.digest(data))
        data = receipt.encode(value).replace(b'"schema_version": 1,',
                                            b'"schema_version": 1, "schema_version": 1,')
        self.final.write_bytes(data)
        with self.assertRaisesRegex(receipt.Refusal, "duplicate"):
            receipt.validate(self.final, prepare.digest(data))

    def test_missing_extra_duplicate_and_mismatched_package_state(self):
        path = self.w / "Packages/workspace-state.json"
        raw = path.read_bytes()
        original = json.loads(raw)
        for change in (
            lambda d: d.pop(),
            lambda d: d.append(copy.deepcopy(d[0])),
            lambda d: d.__setitem__(1, copy.deepcopy(d[0])),
            lambda d: d[0]["packageRef"].update(location="https://elsewhere.invalid"),
            lambda d: d[0]["state"]["checkoutState"].update(revision="0" * 40),
            lambda d: d[0]["state"]["checkoutState"].update(version="2.0.0"),
            lambda d: d[0].update(subpath="../escape"),
            lambda d: d[0]["packageRef"].update(name=""),
        ):
            with self.subTest(change=change):
                value = copy.deepcopy(original)
                change(value["object"]["dependencies"])
                path.write_bytes(receipt.encode(value))
                with self.assertRaises(receipt.Refusal):
                    self.produce()
                self.assertEqual(self.compiler.call_count, 0)
                self.assertFalse((self.w / "build-evidence").exists())
        path.write_bytes(raw)
        (self.w / "Packages/checkouts/extra").mkdir()
        with self.assertRaises(receipt.Refusal):
            self.produce()

    def test_dirty_ignored_untracked_and_gitlink_refused(self):
        for root, name in ((self.w / "source", "ignored"),
                           (self.w / "source", "untracked"),
                           (self.w / "Packages/checkouts/swift-ascii", "untracked")):
            path = root / name
            path.write_bytes(b"dirty")
            with self.assertRaises(receipt.Refusal):
                self.produce()
            path.unlink()
        checkout = self.w / "Packages/checkouts/swift-ascii"
        (checkout / "Sources/Package Input.swift").write_bytes(b"edited")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)
        source = self.w / "source"
        fixture_git(source, "update-index", "--add", "--cacheinfo",
                    "160000," + self.commit + ",submodule")
        fixture_git(source, "commit", "-m", "synthetic unsupported gitlink")
        commit = fixture_git(source, "rev-parse", "HEAD")
        tree = fixture_git(source, "rev-parse", "HEAD^{tree}")
        with self.assertRaisesRegex(receipt.Refusal, "Git link/submodule"):
            receipt.source_observation(source, self.w, commit, tree)

    def test_git_control_escape_alternates_hardlinks_and_external_config(self):
        source = self.w / "source"
        gitdir = source / ".git"
        external = self.root / "external-git"
        gitdir.rename(external)
        gitdir.write_text("gitdir: " + str(external) + "\n")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        gitdir.unlink()
        external.rename(gitdir)
        alternate = gitdir / "objects/info/alternates"
        alternate.write_text(str(external) + "\n")
        with self.assertRaisesRegex(receipt.Refusal, "alternates"):
            self.produce()
        alternate.unlink()
        hardlink = self.root / "linked-config"
        os.link(gitdir / "config", hardlink)
        with self.assertRaisesRegex(receipt.Refusal, "hardlink"):
            self.produce()
        hardlink.unlink()
        os.link(source / "Sources/App Input.swift", hardlink)
        with self.assertRaisesRegex(receipt.Refusal, "hardlink"):
            self.produce()
        hardlink.unlink()
        with (gitdir / "config").open("a") as stream:
            stream.write('\n[include]\npath = /outside\n')
        with self.assertRaisesRegex(receipt.Refusal, "configuration"):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)

    def test_missing_checkout_and_lockfile_pin_mutations(self):
        lockfile = self.w / "source" / receipt.LOCKFILE
        original = json.loads(lockfile.read_bytes())
        for mutation in (
            lambda v: v["pins"].pop(),
            lambda v: v["pins"].append(copy.deepcopy(v["pins"][0])),
            lambda v: v["pins"].__setitem__(1, copy.deepcopy(v["pins"][0])),
            lambda v: v["pins"][0].update(identity="unsupported"),
            lambda v: v["pins"][0]["state"].update(revision="short"),
            lambda v: v.update(version=True),
            lambda v: v["pins"][0].update(unreviewed=True),
        ):
            value = copy.deepcopy(original)
            mutation(value)
            with self.assertRaises(receipt.Refusal):
                receipt.pins_from_lock(receipt.encode(value))
        checkout = self.w / "Packages/checkouts/swift-ascii"
        checkout.rename(self.root / "removed-checkout")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)

    def test_ancestor_links_and_special_entries_before_claim(self):
        source = self.w / "source"
        actual = self.w / "real-source"
        source.rename(actual)
        source.symlink_to(actual, target_is_directory=True)
        with self.assertRaises(OSError):
            self.produce()
        source.unlink()
        actual.rename(source)
        os.mkfifo(source / "special")
        with self.assertRaises(receipt.Refusal):
            self.produce()
        self.assertEqual(self.compiler.call_count, 0)

    def test_mandatory_lists_missing_empty_and_unresolved_inputs(self):
        # Individual compile attempts use fresh independently claimed workspaces.
        original_w = self.w
        for index, mutation in enumerate((
            lambda p: p.unlink(), lambda p: p.write_bytes(b""),
            lambda p: p.write_bytes(b"/outside/Missing.swift\n"),
            lambda p: p.write_bytes((str(self.w / receipt.DERIVED_SOURCES / "Missing.swift")
                                    + "\n").encode()),
            lambda p: p.write_bytes((str(self.w / "source/untracked.swift") + "\n").encode()),
        )):
            with self.subTest(index=index):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def compile_mutation(*args):
                    code = self.fake_compile(*args)
                    mutation(self.w / receipt.INTERMEDIATES / receipt.MANDATORY[0])
                    return code

                self.compiler.side_effect = compile_mutation
                with self.assertRaises((receipt.Refusal, OSError)):
                    self.produce()
                self.assert_consumed()

    def test_claim_collision_and_each_pre_spawn_publication_failure(self):
        original_w = self.w
        original_exclusive = build_mac.exclusive
        original_open = Path.open
        for index, name in enumerate(("claim.json", "journal.log", "stdout.log", "stderr.log",
                                      "directory-sync")):
            with self.subTest(name=name):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def exclusive(path, data):
                    if path.name == name:
                        raise OSError("synthetic pre-spawn write failure")
                    return original_exclusive(path, data)

                def opening(path, *args, **kwargs):
                    if path.name == name and args == ("xb",):
                        raise OSError("synthetic pre-spawn open failure")
                    return original_open(path, *args, **kwargs)

                with mock.patch.object(build_mac, "exclusive", side_effect=exclusive), \
                        mock.patch.object(Path, "open", opening):
                    if name == "directory-sync":
                        with mock.patch.object(build_mac, "sync_directory",
                                               side_effect=OSError("sync failure")):
                            with self.assertRaises(OSError):
                                self.produce()
                    else:
                        with self.assertRaises(OSError):
                            self.produce()
                self.assertEqual(self.compiler.call_count, 0)
                self.assert_consumed()

    def test_nonzero_spawn_error_and_interruption_preserve_claim(self):
        original_w = self.w
        for index, outcome in enumerate((7, OSError("spawn failure"), KeyboardInterrupt())):
            with self.subTest(index=index):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"
                if type(outcome) is int:
                    self.compiler.side_effect = None
                    self.compiler.return_value = outcome
                else:
                    self.compiler.side_effect = outcome
                with self.assertRaises((receipt.Refusal, OSError, KeyboardInterrupt)):
                    self.produce()
                self.assert_consumed()

    def test_real_preparation_failure_preserves_consumed_workspace(self):
        original_open = Path.open

        def opening(path, *args, **kwargs):
            if path.name.endswith(".intent.json") and args == ("xb",):
                raise OSError("synthetic preparer output failure")
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", opening):
            with self.assertRaisesRegex(OSError, "preparer output"):
                self.produce()
        self.assertEqual(self.compiler.call_count, 1)
        self.assert_consumed()

    def test_oversized_original_refused_before_real_preparer(self):
        def compile_oversize(*args):
            code = self.fake_compile(*args)
            path = self.w / receipt.PRODUCTS / "Mac.xctestrun"
            path.write_bytes(b" " * (receipt.METADATA_BYTES + 1))
            return code

        self.compiler.side_effect = compile_oversize
        with self.assertRaisesRegex(receipt.Refusal, "byte limit"):
            self.produce()
        self.assertEqual(list((self.w / receipt.PRODUCTS).glob("*.intent.json")), [])
        self.assert_consumed()

    def test_ambiguous_original_and_wrong_profile(self):
        original_w = self.w
        for index in range(2):
            self.w = self.root / f"W{index}"
            shutil.copytree(original_w, self.w)
            self.final = self.w / "build-evidence/receipt.json"

            def compile_invalid(*args):
                code = self.fake_compile(*args)
                path = self.w / receipt.PRODUCTS / "Mac.xctestrun"
                if index == 0:
                    path.with_name("Other.xctestrun").write_bytes(path.read_bytes())
                else:
                    parsed = copy.deepcopy(FIXTURE)
                    parsed["FluxKlangMacTests"]["SystemAttachmentLifetime"] = "keepAlways"
                    path.write_bytes(plistlib.dumps(parsed))
                return code

            self.compiler.side_effect = compile_invalid
            with self.assertRaises(receipt.Refusal):
                self.produce()
            self.assert_consumed()

    def test_exact_preparer_serialization_prediction(self):
        products = self.w / receipt.PRODUCTS
        write(products / "Mac.xctestrun", plistlib.dumps(FIXTURE))
        original, sizes = receipt.original_metadata(self.w)
        record = prepare.prepare(original["path"], original["sha256"], prepare.RETENTION_PROFILE)
        metadata = receipt.metadata_from_record(record, original, sizes)
        self.assertEqual(receipt.validate_metadata(metadata), record)
        self.assertEqual(len(record["run_id"]), len(receipt.EXEMPLAR))
        self.assertNotEqual(record["run_id"], receipt.EXEMPLAR)

    def test_pending_failure_collision_and_postcommit_sync_uncertainty(self):
        original_w = self.w
        original_exclusive = build_mac.exclusive
        original_sync = build_mac.sync_directory
        original_link = os.link
        for index, phase in enumerate(("pending", "collision", "link", "postcommit",
                                       "interrupted-link")):
            with self.subTest(phase=phase):
                self.w = self.root / f"W{index}"
                shutil.copytree(original_w, self.w)
                self.final = self.w / "build-evidence/receipt.json"

                def exclusive(path, data):
                    if phase == "pending" and path.name == "receipt.pending":
                        # Preserve a deliberately incomplete failed staging attempt.
                        path.write_bytes(data[:11])
                        raise OSError("pending failure")
                    return original_exclusive(path, data)

                def link(source, destination, **kwargs):
                    if Path(destination).name == "receipt.json":
                        if phase == "collision":
                            Path(destination).write_bytes(b"prior collision")
                        if phase == "link":
                            raise OSError("precommit link failure")
                        result = original_link(source, destination, **kwargs)
                        if phase == "interrupted-link":
                            raise KeyboardInterrupt()
                        return result
                    return original_link(source, destination, **kwargs)

                def sync(path):
                    if phase == "postcommit" and self.final.exists():
                        raise OSError("postcommit fsync failure")
                    return original_sync(path)

                with mock.patch.object(build_mac, "exclusive", side_effect=exclusive), \
                        mock.patch.object(build_mac, "sync_directory", side_effect=sync), \
                        mock.patch.object(os, "link", side_effect=link):
                    with self.assertRaises((OSError, build_mac.CommittedUncertain)):
                        self.produce()
                if phase in ("postcommit", "interrupted-link"):
                    self.assertTrue(self.final.exists())
                    pin = prepare.digest(self.final.read_bytes())  # Test consumer's explicit pin.
                    self.assertEqual(receipt.validate(self.final, pin)["profile"],
                                     prepare.RETENTION_PROFILE)
                    with self.assertRaises(receipt.Refusal):
                        self.produce()
                elif phase == "collision":
                    self.assertEqual(self.final.read_bytes(), b"prior collision")
                    with self.assertRaises(receipt.Refusal):
                        receipt.validate(self.final, prepare.digest(self.final.read_bytes()))
                else:
                    self.assert_consumed()


class PrimitiveTests(unittest.TestCase):
    def test_source_list_closed_grammar(self):
        self.assertEqual(receipt.swift_paths(b"/some/literal space.swift\n"),
                         ["/some/literal space.swift"])
        self.assertEqual(receipt.swift_paths(b"/some/literal@name.swift"),
                         ["/some/literal@name.swift"])
        for value in (b"/x.swift\r\n", b'"/x.swift"\n', b"/x\\ y.swift\n", b"@/x.swift\n",
                      b"/x.swift\n\n", b"/x.swift\n/x.swift", b"\xef\xbb\xbf/x.swift",
                      b"/x.swift\0", b"relative.swift", b"/a/../x.swift",
                      b"/x.c", b"/x.swift\n\n/y.swift", b"/x\xff.swift"):
            with self.subTest(value=value), self.assertRaises(receipt.Refusal):
                receipt.swift_paths(value)

    def test_fixed_inclusive_entry_depth_byte_and_path_limits(self):
        self.assertEqual((receipt.RECEIPT_BYTES, receipt.METADATA_BYTES, receipt.TREE_ENTRIES,
                          receipt.TREE_DEPTH, receipt.TREE_BYTES, receipt.PATH_BYTES),
                         (33554432, 2097152, 200000, 64, 68719476736, 4096))
        budget = receipt.Budget()
        for _ in range(receipt.TREE_ENTRIES):
            budget.entry(64)
        with self.assertRaises(receipt.Refusal):
            budget.entry(0)
        with self.assertRaises(receipt.Refusal):
            receipt.Budget().entry(65)
        budget.regular(receipt.TREE_BYTES)
        with self.assertRaises(receipt.Refusal):
            budget.regular(1)
        receipt.path_text("/" + "x" * 4095)
        with self.assertRaises(receipt.Refusal):
            receipt.path_text("/" + "x" * 4096)
        with self.assertRaises(receipt.Refusal):
            receipt.path_text("/" + "é" * 2048)
        with self.assertRaises(receipt.Refusal):
            receipt.path_text("/invalid\udcff")

    def test_streaming_inclusive_metadata_receipt_and_tree_budgets(self):
        class Reader:
            def __init__(self, total):
                self.remaining = total
                self.requests = []

            def read(self, size):
                self.requests.append(size)
                count = min(self.remaining, size)
                self.remaining -= count
                return b"x" * count

        for limit in (receipt.METADATA_BYTES, receipt.RECEIPT_BYTES):
            reader = Reader(limit)
            self.assertEqual(receipt.read_stream(reader, limit)[0], limit)
            self.assertLessEqual(max(reader.requests), 1048576)
            with self.assertRaises(receipt.Refusal):
                receipt.read_stream(Reader(limit + 1), limit)
        # Synthetic remaining budget exercises the 64GiB edge without allocating
        # or hashing 64GiB, and without overriding any production limit.
        budget = receipt.Budget()
        budget.regular(receipt.TREE_BYTES - 1)
        self.assertEqual(receipt.read_stream(Reader(1), receipt.TREE_BYTES - budget.bytes)[0], 1)
        with self.assertRaises(receipt.Refusal):
            receipt.read_stream(Reader(2), receipt.TREE_BYTES - budget.bytes)

    def test_short_zero_flush_and_close_failures(self):
        class Writer:
            def __init__(self, zero=False):
                self.data = b""
                self.zero = zero

            def write(self, data):
                if self.zero:
                    return 0
                self.data += data[:2]
                return len(data[:2])

        stream = Writer()
        build_mac.write_all(stream, b"abcdefg")
        self.assertEqual(stream.data, b"abcdefg")
        with self.assertRaises(receipt.Refusal):
            build_mac.write_all(Writer(zero=True), b"x")
        for phase in ("flush", "close"):
            stream = mock.Mock()
            getattr(stream, phase).side_effect = OSError(phase + " failure")
            with mock.patch.object(os, "fsync"):
                with self.assertRaisesRegex(OSError, phase):
                    build_mac.finalize(stream)

    def test_receipt_serialization_exact_limit_and_one_beyond(self):
        # JSON string quoting plus LF accounts for three bytes.
        value = "x" * (receipt.RECEIPT_BYTES - 3)
        self.assertEqual(len(receipt.encode(value)), receipt.RECEIPT_BYTES)
        with self.assertRaises(receipt.Refusal):
            receipt.encode(value + "x")

    def test_inventory_directory_depth_boundary_and_special_modes(self):
        with tempfile.TemporaryDirectory(prefix="inventory-depth-") as temporary:
            root = Path(temporary).resolve()
            directory = root
            for _ in range(receipt.TREE_DEPTH):
                directory /= "d"
                directory.mkdir()
            directory.chmod(0o1777)
            entries = receipt.inventory(root)
            self.assertEqual(len(entries), receipt.TREE_DEPTH + 1)
            self.assertEqual(entries[-1]["mode"], 0o1777)
            (root / "!before-root-in-sort-order").write_bytes(b"regular")
            receipt.entries_schema(receipt.inventory(root))
            (directory / "excess").mkdir()
            with self.assertRaisesRegex(receipt.Refusal, "depth limit"):
                receipt.inventory(root)

    def test_cli_bytecode_disabled_before_sibling_imports_and_signal_handlers_restored(self):
        before = {signum: build_mac.signal.getsignal(signum)
                  for signum in (build_mac.signal.SIGTERM, build_mac.signal.SIGHUP)}
        with tempfile.TemporaryDirectory(prefix="import-bytecode-") as temporary:
            root = Path(temporary).resolve()
            for name in ("build_mac.py", "build_receipt.py", "prepare.py"):
                shutil.copyfile(Path(__file__).with_name(name), root / name)
            env = {key: value for key, value in os.environ.items()
                   if key not in ("PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX")}
            result = subprocess.run(
                [sys.executable, str(root / "build_mac.py"), "validate",
                 "--receipt", str(root / "absent"), "--expected-sha256", "0" * 64],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertFalse(list(root.rglob("__pycache__")))
            with mock.patch.object(sys, "stderr", new=mock.Mock()):
                self.assertEqual(build_mac.main([
                    "validate", "--receipt", str(root / "absent"),
                    "--expected-sha256", "0" * 64]), 1)
        self.assertEqual({signum: build_mac.signal.getsignal(signum) for signum in before}, before)

    def test_termination_uses_only_spawned_process_group_and_reaps(self):
        child = mock.Mock(pid=123456)
        child.wait.side_effect = [KeyboardInterrupt(), 0]
        with mock.patch.object(build_mac.subprocess, "Popen", return_value=child) as spawn, \
                mock.patch.object(os, "killpg") as kill:
            with self.assertRaises(KeyboardInterrupt):
                build_mac.compile_once(["synthetic"], {}, Path("/synthetic"), None, None)
            self.assertTrue(spawn.call_args.kwargs["start_new_session"])
            kill.assert_called_once_with(child.pid, build_mac.signal.SIGTERM)
            self.assertEqual(child.wait.call_count, 2)
        with mock.patch.object(build_mac.subprocess, "Popen", side_effect=OSError("spawn")), \
                mock.patch.object(os, "killpg") as kill:
            with self.assertRaises(OSError):
                build_mac.compile_once(["synthetic"], {}, Path("/synthetic"), None, None)
            kill.assert_not_called()

    def test_metadata_size_and_path_prebound_without_api_changes(self):
        with tempfile.TemporaryDirectory(prefix="bounds-") as temporary:
            root = Path(temporary).resolve()
            path = root / "metadata"
            path.write_bytes(b"x" * receipt.METADATA_BYTES)
            self.assertEqual(len(receipt.bounded(path)[1]), receipt.METADATA_BYTES)
            with path.open("ab") as stream:
                stream.write(b"x")
            with self.assertRaises(receipt.Refusal):
                receipt.bounded(path)
            linked = root / "linked"
            linked.symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError):
                receipt.bounded(linked / "metadata")


if __name__ == "__main__":
    unittest.main()
