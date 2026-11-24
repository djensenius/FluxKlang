"""Offline policy tests for the manual Products observation workflow (#893).

No real xcodebuild, observation runner or simulator is invoked: step scripts
run only against temporary fixtures and fake executables.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ios-provider-products-observation.yml"
V4_WORKFLOW = ROOT / ".github/workflows/ios-provider-observation.yml"
SHA = "a" * 40
BASH = ["/bin/bash", "--noprofile", "--norc", "-e", "-c"]
KEYS = (
    "GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REF GITHUB_RUN_ID "
    "GITHUB_RUN_ATTEMPT GITHUB_JOB GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA "
    "GITHUB_WORKSPACE GITHUB_EVENT_PATH RUNNER_NAME RUNNER_ENVIRONMENT "
    "RUNNER_OS RUNNER_ARCH RUNNER_TEMP"
).split()
STEP_NAMES = [
    "Require the reviewed dispatch context",
    None,  # the pinned checkout action
    "Create the fresh disposable workspace",
    "Compile iOS Products for testing only (no launch)",
    "Observe Products once (no launch)",
    "Remove only the recorded workspace",
]


def steps(text):
    body = text.split("    steps:\n", 1)[1]
    return [(" " * 6 + "- " + part) if index else part
            for index, part in enumerate(body.split("\n      - "))]


def run_block(step):
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


def code_lines(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


class ProductsObservationWorkflowTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.steps = steps(self.text)
        self.by_name = {}
        for step in self.steps:
            match = re.match(r" *- name: (.*)\n", step)
            if match:
                self.by_name[match.group(1)] = step

    def bash(self, script, environment, **kwargs):
        return subprocess.run(BASH + [script], env=environment, capture_output=True,
                              check=False, **kwargs)

    # Invariant 1: manual-only trigger with a required reviewed head.
    def test_manual_only_trigger_with_required_reviewed_head(self):
        trigger = self.text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(trigger, """\
  workflow_dispatch:
    inputs:
      reviewed_head:
        description: Full 40-character lowercase main head SHA that was reviewed
        required: true
        type: string
""")
        self.assertEqual(self.text.count("\non:"), 1)
        for event in ("push:", "pull_request", "schedule:", "workflow_run", "workflow_call",
                      "repository_dispatch"):
            self.assertNotIn(event, self.text)

    def test_steps_are_closed_and_guard_is_first(self):
        names = []
        for step in self.steps:
            match = re.match(r" *- name: (.*)\n", step)
            names.append(match.group(1) if match else None)
        self.assertEqual(names, STEP_NAMES)
        self.assertIn("      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10"
                      " # v6.0.3 (peeled commit)\n        timeout-minutes: 5\n"
                      "        # Current Git also writes a pack-<id>.rev reverse index, which the\n"
                      "        # runner's exact one-pair pack discovery refuses (run 45348707621).\n"
                      "        env:\n          GIT_CONFIG_COUNT: '1'\n"
                      "          GIT_CONFIG_KEY_0: pack.writeReverseIndex\n"
                      "          GIT_CONFIG_VALUE_0: 'false'\n        with:\n"
                      "          ref: ${{ github.sha }}\n          fetch-depth: 1\n"
                      "          persist-credentials: false\n", self.steps[1])
        self.assertEqual(self.text.count("uses:"), 1)
        # Only the checkout step carries the Git override (not workflow/job env).
        self.assertEqual(self.text.count("GIT_CONFIG"), 3)
        self.assertEqual(self.text.count("pack.writeReverseIndex"), 1)
        for key in ("GIT_CONFIG", "pack.writeReverseIndex"):
            self.assertNotIn(key, "".join(self.steps[:1] + self.steps[2:]))
        guard = self.steps[0]
        self.assertIn("CHECK_REVIEWED_HEAD: ${{ inputs.reviewed_head }}\n", guard)
        self.assertIn("CHECK_WORKFLOW_SHA: ${{ github.workflow_sha }}\n", guard)
        # The input is only ever read through the guard's environment.
        self.assertEqual(self.text.count("inputs.reviewed_head"), 1)

    def test_guard_refuses_bad_reviewed_head_or_context_without_output(self):
        guard = run_block(self.steps[0])
        valid = dict(CHECK_REPOSITORY="djensenius/FluxKlang", CHECK_EVENT="workflow_dispatch",
                     CHECK_REF="refs/heads/main", CHECK_SHA=SHA, CHECK_WORKFLOW_SHA=SHA,
                     CHECK_REVIEWED_HEAD=SHA)
        cases = ((None, None), ("CHECK_REVIEWED_HEAD", ""), ("CHECK_REVIEWED_HEAD", "A" * 40),
                 ("CHECK_REVIEWED_HEAD", "a" * 39), ("CHECK_REVIEWED_HEAD", "a" * 41),
                 ("CHECK_REVIEWED_HEAD", "b" * 40), ("CHECK_REVIEWED_HEAD", "g" * 40),
                 ("CHECK_REVIEWED_HEAD", SHA + "\n"), ("CHECK_REVIEWED_HEAD", " " + SHA),
                 ("CHECK_REPOSITORY", "other/repo"), ("CHECK_EVENT", "push"),
                 ("CHECK_REF", "refs/heads/topic"), ("CHECK_SHA", ""), ("CHECK_SHA", "A" * 40),
                 ("CHECK_WORKFLOW_SHA", ""), ("CHECK_WORKFLOW_SHA", "b" * 40))
        for key, value in cases:
            with self.subTest(key=key, value=value):
                environment = dict(valid)
                if key:
                    environment[key] = value
                result = self.bash(guard, environment)
                self.assertEqual(result.returncode, 0 if key is None else 1)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))
        environment = dict(valid)
        del environment["CHECK_REVIEWED_HEAD"]
        self.assertEqual(self.bash(guard, environment).returncode, 1)

    # Invariants 2 and 3: permissions, no secrets/artifacts, fixed concurrency.
    def test_read_only_permissions_and_fixed_concurrency(self):
        self.assertEqual(self.text.count("permissions:"), 1)
        self.assertIn("\npermissions:\n  contents: read\n\nconcurrency:\n"
                      "  group: ios-provider-products-observation\n"
                      "  cancel-in-progress: false\n\n", self.text)
        for forbidden in ("secrets", "GITHUB_TOKEN", "github.token", "upload-artifact",
                          "download-artifact", "actions/cache", "continue-on-error",
                          "retry", "rerun", "re-run", "attempt <", "for attempt", "while ",
                          "set +e", "|| true", "|| :", "pipefail", "| tee", "set +o"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden.lower(), self.text.lower())
        self.assertEqual(self.text.count("if:"), 1)
        self.assertIn("if: always()", self.steps[-1])

    # Invariant 4: finite job and step timeouts.
    def test_finite_timeouts(self):
        self.assertEqual(re.findall(r"\n    timeout-minutes: (\d+)\n", self.text), ["110"])
        timeouts = {}
        for name, step in self.by_name.items():
            found = re.findall(r"\n        timeout-minutes: (\d+)\n", step)
            if found:
                timeouts[name] = int(found[0])
        self.assertEqual(timeouts, {
            "Require the reviewed dispatch context": 2,
            "Create the fresh disposable workspace": 1,
            "Compile iOS Products for testing only (no launch)": 45,
            "Observe Products once (no launch)": 45,
            "Remove only the recorded workspace": 5,
        })
        # Every step, including the unnamed checkout, has a finite limit.
        checkout = re.findall(r"\n        timeout-minutes: (\d+)\n", self.steps[1])
        self.assertEqual(checkout, ["5"])
        for step in self.steps:
            with self.subTest(step=step.splitlines()[0]):
                self.assertRegex(step, r"\n        timeout-minutes: \d+\n")
        # The job covers every step limit with headroom for the always-run cleanup.
        job = int(re.findall(r"\n    timeout-minutes: (\d+)\n", self.text)[0])
        self.assertGreaterEqual(job, sum(timeouts.values()) + int(checkout[0]) + 5)
        self.assertIn("# 45-minute compile step", self.text)
        self.assertIn("36 fixed 30-second commands", self.text)

    # Invariant 6: compile only; no launch, simulator control or privilege.
    def test_compile_only_and_forbidden_commands(self):
        code = code_lines(self.text)
        for pattern in (r"(?<![-\w])test(?![-\w])", r"test-without-building", r"simctl",
                        r"open\s+-a", r"Simulator\.app", r"launchctl", r"\bsudo\b",
                        r"\bxcrun\b", r"-xctestrun", r"\bkill(all)?\b", r"xcode-select"):
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, self.text), pattern)
                self.assertIsNone(re.search(pattern, code), pattern)
        build = run_block(self.by_name["Compile iOS Products for testing only (no launch)"])
        actions = re.findall(r"\b(build-for-testing|build|test\S*|archive|analyze|install)\b"
                             r"(?=\s+CODE_SIGNING)", build)
        self.assertEqual(actions, ["build-for-testing"])
        self.assertEqual(build.count("/usr/bin/xcodebuild -project "), 2)
        self.assertEqual(build.count("-destination 'generic/platform=iOS Simulator'"), 1)
        self.assertEqual(build.count('-derivedDataPath "$WORKSPACE_PATH"'), 2)
        self.assertEqual(build.count("-scheme FluxKlangIsolatedTests"), 2)
        # Two invocations plus the selected-Xcode presence check.
        self.assertEqual(self.text.count("xcodebuild"), 3)
        self.assertIn('[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || exit 1', build)

    def make_temp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Path(os.path.realpath(directory.name))

    # Invariant 5: fresh disposable workspace, recorded and removed.
    def test_workspace_is_fresh_recorded_and_cleanup_removes_only_it(self):
        create = run_block(self.by_name["Create the fresh disposable workspace"])
        cleanup = run_block(self.by_name["Remove only the recorded workspace"])
        self.assertIn('/usr/bin/mktemp -d "$RUNNER_TEMP/ios-products-observation.XXXXXXXX"',
                      create)
        temp = self.make_temp()
        sibling = temp / "keep"
        sibling.write_text("keep")
        output = temp / "output"
        base = {"PATH": "/usr/bin:/bin", "RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(output)}
        result = self.bash(create, base)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        record = output.read_text()
        self.assertRegex(record, r"\Apath=.*/ios-products-observation\.[A-Za-z0-9]{8}\n\Z")
        workspace = Path(record[len("path="):-1])
        self.assertEqual(workspace.parent, temp)
        self.assertTrue(workspace.is_dir())
        self.assertEqual(list(workspace.iterdir()), [])
        self.assertEqual(workspace.stat().st_mode & 0o777, 0o700)

        # Products and a read-only directory inside the workspace are removed.
        products = workspace / "Build/Products"
        products.mkdir(parents=True)
        (products / "x.xctestrun").write_text("x")
        locked = workspace / "locked"
        locked.mkdir()
        (locked / "file").write_text("x")
        locked.chmod(0o500)
        result = self.bash(cleanup, {**base, "WORKSPACE_PATH": str(workspace)})
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        self.assertFalse(workspace.exists())
        self.assertEqual(sibling.read_text(), "keep")

        # Nothing recorded: nothing removed.
        result = self.bash(cleanup, {**base, "WORKSPACE_PATH": ""})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(sibling.read_text(), "keep")

        # Any path other than a recorded workspace under RUNNER_TEMP refuses untouched.
        other = self.make_temp()
        outside = other / "ios-products-observation.ABCDEFGH"
        outside.mkdir()
        link = temp / "ios-products-observation.LINKLINK"
        link.symlink_to(outside)
        for path in (str(temp), str(sibling), str(outside), str(link),
                     str(temp / "other.ABCDEFGH"), str(temp / "ios-products-observation.ABC"),
                     str(temp) + "/../" + temp.name + "/ios-products-observation.ABCDEFGH"):
            with self.subTest(path=path):
                result = self.bash(cleanup, {**base, "WORKSPACE_PATH": path})
                self.assertEqual(result.returncode, 1)
        self.assertTrue(outside.is_dir())
        self.assertTrue(link.is_symlink())
        self.assertEqual(sibling.read_text(), "keep")

    def test_workspace_refuses_non_canonical_or_missing_runner_temp(self):
        create = run_block(self.by_name["Create the fresh disposable workspace"])
        temp = self.make_temp()
        output = temp / "output"
        (temp / "real").mkdir()
        (temp / "alias").symlink_to(temp / "real")
        for runner_temp in ("", "relative", str(temp / "missing"), str(temp / "alias")):
            with self.subTest(runner_temp=runner_temp):
                result = self.bash(create, {"PATH": "/usr/bin:/bin", "RUNNER_TEMP": runner_temp,
                                            "GITHUB_OUTPUT": str(output)})
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((temp / "real").iterdir()), [])

    def test_workspace_refuses_non_empty_or_loose_mode_but_records_it(self):
        create = run_block(self.by_name["Create the fresh disposable workspace"])
        self.assertEqual(create.count("/usr/bin/mktemp "), 1)
        for case in ("non-empty", "mode-0755"):
            with self.subTest(case=case):
                temp = self.make_temp()
                output = temp / "output"
                workspace = temp / "ios-products-observation.ABCDEFGH"
                prepare = (f"/bin/mkdir -m 700 {workspace}; echo x > {workspace}/stale"
                           if case == "non-empty" else f"/bin/mkdir -m 755 {workspace}")
                fake_mktemp = temp / "mktemp"
                fake_mktemp.write_text(f"#!/bin/sh\n{prepare}\necho {workspace}\n")
                fake_mktemp.chmod(0o700)
                script = create.replace("/usr/bin/mktemp ", f"{fake_mktemp} ")
                result = self.bash(script, {"PATH": "/usr/bin:/bin", "RUNNER_TEMP": str(temp),
                                            "GITHUB_OUTPUT": str(output)})
                self.assertEqual(result.returncode, 1)
                # Recorded so the always-run cleanup still removes it.
                self.assertEqual(output.read_text(), f"path={workspace}\n")

    def test_compile_refuses_package_resolution_drift(self):
        build = run_block(self.by_name["Compile iOS Products for testing only (no launch)"])
        temp = self.make_temp()
        developer = temp / "Developer"
        (developer / "usr/bin").mkdir(parents=True)
        fake_xcodebuild = developer / "usr/bin/xcodebuild"
        fake_xcodebuild.write_text("#!/bin/sh\nexit 0\n")
        fake_xcodebuild.chmod(0o700)
        fake_git = temp / "git"
        git_args = temp / "git-args"
        fake_git.write_text(f'#!/bin/sh\necho "$@" > {git_args}\nexit 1\n')
        fake_git.chmod(0o700)
        script = (build.replace("/usr/bin/xcodebuild -project", f"{fake_xcodebuild} -project")
                  .replace("/usr/bin/git", str(fake_git)))
        workspace = temp / "ios-products-observation.DRIFTING"
        workspace.mkdir()
        result = self.bash(script, {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": str(developer),
                                    "WORKSPACE_PATH": str(workspace)})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(git_args.read_text(),
                         "--no-pager diff --quiet --exit-code -- *Package.resolved\n")

    # Invariants 6 and 7: build output is logged inside the workspace, the
    # tail is bounded, and the compile status is preserved.
    def test_build_logs_inside_workspace_and_preserves_failure_status(self):
        build = run_block(self.by_name["Compile iOS Products for testing only (no launch)"])
        self.assertIn('log="$WORKSPACE_PATH/build.log"', build)
        self.assertIn('/usr/bin/tail -n 200 -- "$log"', build)
        temp = self.make_temp()
        developer = temp / "Developer"
        (developer / "usr/bin").mkdir(parents=True)
        fake_xcodebuild = developer / "usr/bin/xcodebuild"
        calls = temp / "calls"
        fake_xcodebuild.write_text(
            f"#!{sys.executable}\nimport json, os, sys\n"
            f"open({str(calls)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "for i in range(300): print('line', i)\n"
            "sys.exit(int(os.environ.get('FAKE_STATUS', '0')) if 'build-for-testing' in sys.argv"
            " else 0)\n")
        fake_xcodebuild.chmod(0o700)
        fake_git = temp / "git"
        fake_git.write_text("#!/bin/sh\nexit 0\n")
        fake_git.chmod(0o700)
        script = (build.replace("/usr/bin/xcodebuild -project", f"{fake_xcodebuild} -project")
                  .replace("/usr/bin/git", str(fake_git)))
        for status in (0, 65):
            with self.subTest(status=status):
                workspace = temp / f"ios-products-observation.{status:08d}"
                workspace.mkdir()
                calls.unlink(missing_ok=True)
                result = self.bash(script, {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": str(developer),
                                            "WORKSPACE_PATH": str(workspace),
                                            "FAKE_STATUS": str(status)})
                self.assertEqual(result.returncode, status)
                log = (workspace / "build.log").read_text().splitlines()
                self.assertEqual(len(log), 600)
                if status:
                    lines = result.stdout.decode().splitlines()
                    self.assertEqual(lines[0], f"::error::compile exited {status}; "
                                               "last 200 log lines follow")
                    self.assertEqual(lines[1:], log[-200:])
                else:
                    self.assertEqual(result.stdout, b"")
                argv = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertEqual(argv, [
                    ["-project", "FluxKlang.xcodeproj", "-scheme", "FluxKlangIsolatedTests",
                     "-resolvePackageDependencies", "-disableAutomaticPackageResolution",
                     "-derivedDataPath", str(workspace)],
                    ["-project", "FluxKlang.xcodeproj", "-scheme", "FluxKlangIsolatedTests",
                     "-destination", "generic/platform=iOS Simulator",
                     "-disableAutomaticPackageResolution", "-derivedDataPath", str(workspace),
                     "build-for-testing", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"],
                ])
        # A pre-existing log refuses before any compile.
        workspace = temp / "ios-products-observation.EXISTING"
        workspace.mkdir()
        (workspace / "build.log").write_text("old")
        calls.unlink(missing_ok=True)
        result = self.bash(script, {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": str(developer),
                                    "WORKSPACE_PATH": str(workspace)})
        self.assertEqual(result.returncode, 1)
        self.assertFalse(calls.exists())

    # Invariants 5 and 7: the absolute Products root is passed and the
    # runner's exit status and output are not masked.
    def test_observe_passes_products_root_and_preserves_exit(self):
        step = self.by_name["Observe Products once (no launch)"]
        self.assertIn("PRODUCTS_ROOT: ${{ steps.workspace.outputs.path }}/Build/Products\n", step)
        command = run_block(step)
        self.assertTrue(command.startswith("exec /usr/bin/env -i \\\n"))
        temp = self.make_temp()
        capture = temp / "capture.json"
        fake = temp / "python"
        products = str(temp / "ios-products-observation.ABCDEFGH/Build/Products")
        environment = {key: "fixture-" + key for key in KEYS}
        environment.update(PRODUCTS_ROOT=products, SECRET_TOKEN="secret", PYTHONPATH="/hostile",
                           DEVELOPER_DIR="/hostile", PATH="/hostile")
        for status, output in ((0, '{"status":"observed"}'),
                               (1, '{"diagnostic":"Refusal","status":"refused"}'),
                               (130, '{"diagnostic":"Interrupted","status":"failed"}')):
            with self.subTest(status=status):
                capture.unlink(missing_ok=True)
                fake.write_text(
                    f"#!{sys.executable}\nimport json, os, sys\n"
                    f"open({str(capture)!r}, 'x').write(json.dumps([sys.argv[1:], dict(os.environ)]))\n"
                    f"print({output!r})\nsys.exit({status})\n")
                fake.chmod(0o700)
                result = self.bash(command.replace("/usr/bin/python3", str(fake)), environment)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (status, (output + "\n").encode(), b""))
                args, received = json.loads(capture.read_text())
                self.assertEqual(args, ["-B", "-S", "scripts/test-audit-run/observation_runner.py",
                                        "--provider-products-v1", products])
                for key in KEYS:
                    self.assertEqual(received[key], environment[key])
                for key in ("SECRET_TOKEN", "PYTHONPATH", "DEVELOPER_DIR", "PRODUCTS_ROOT"):
                    self.assertNotIn(key, received)
                self.assertEqual(received["PATH"], "/usr/bin:/bin")

    def test_v4_workflow_trigger_and_arguments_unchanged(self):
        v4 = V4_WORKFLOW.read_text()
        self.assertIn("\non:\n  workflow_dispatch:\n\npermissions:\n  contents: read\n", v4)
        self.assertNotIn("inputs", v4)
        self.assertNotIn("--provider-products-v1", v4)
        self.assertNotIn("xcodebuild", v4)
        self.assertTrue(v4.endswith(
            "            /usr/bin/python3 -B -S scripts/test-audit-run/observation_runner.py\n"))
        self.assertIn("    timeout-minutes: 30\n", v4)


if __name__ == "__main__":
    unittest.main()
