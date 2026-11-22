"""Offline policy tests: the real observation runner is never invoked."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ios-provider-observation.yml"
SHA = "a" * 40
KEYS = (
    "GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REF GITHUB_RUN_ID "
    "GITHUB_RUN_ATTEMPT GITHUB_JOB GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA "
    "GITHUB_WORKSPACE GITHUB_EVENT_PATH RUNNER_NAME RUNNER_ENVIRONMENT "
    "RUNNER_OS RUNNER_ARCH RUNNER_TEMP"
).split()


def block(text, start, end=None):
    part = text.split(start, 1)[1]
    if end:
        part = part.split(end, 1)[0]
    return textwrap.dedent(part)


class ObservationWorkflowTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.guard = block(self.text, "        run: |\n", "\n      - uses:")
        self.command = block(self.text, "      - name: Observe once (no launch)\n        run: |\n")

    def test_exact_workflow_policy_and_invocation(self):
        # A closed structural assertion also rejects extra triggers, steps,
        # permissions, inputs, artifacts, retries and secret-bearing env.
        expected = """\
name: iOS provider observation (no launch)

on:
  workflow_dispatch:

permissions:
  contents: read

defaults:
  run:
    shell: bash --noprofile --norc -e {0}

env:
  BASH_ENV: /dev/null
  ENV: /dev/null
  PATH: /usr/bin:/bin

jobs:
  observe:
    runs-on: xcode-27
    # Twelve 30-second probes and their bounded cleanup, plus other work.
    timeout-minutes: 30
    steps:
      - name: Require the reviewed dispatch context
        env:
          CHECK_REPOSITORY: ${{ github.repository }}
          CHECK_EVENT: ${{ github.event_name }}
          CHECK_REF: ${{ github.ref }}
          CHECK_SHA: ${{ github.sha }}
          CHECK_WORKFLOW_SHA: ${{ github.workflow_sha }}
        run: |
          [[ "$CHECK_REPOSITORY" == 'djensenius/FluxKlang' &&
             "$CHECK_EVENT" == 'workflow_dispatch' &&
             "$CHECK_REF" == 'refs/heads/main' &&
             "$CHECK_SHA" =~ ^[0-9a-f]{40}$ &&
             "$CHECK_WORKFLOW_SHA" == "$CHECK_SHA" ]] || exit 1

      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3 (peeled commit)
        with:
          ref: ${{ github.sha }}
          fetch-depth: 1
          persist-credentials: false

      - name: Observe once (no launch)
        run: |
          exec /usr/bin/env -i \\
            PATH=/usr/bin:/bin LANG=C LC_ALL=C \\
            GITHUB_REPOSITORY="${GITHUB_REPOSITORY-}" \\
            GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME-}" \\
            GITHUB_SHA="${GITHUB_SHA-}" GITHUB_REF="${GITHUB_REF-}" \\
            GITHUB_RUN_ID="${GITHUB_RUN_ID-}" GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT-}" \\
            GITHUB_JOB="${GITHUB_JOB-}" GITHUB_WORKFLOW_REF="${GITHUB_WORKFLOW_REF-}" \\
            GITHUB_WORKFLOW_SHA="${GITHUB_WORKFLOW_SHA-}" \\
            GITHUB_WORKSPACE="${GITHUB_WORKSPACE-}" GITHUB_EVENT_PATH="${GITHUB_EVENT_PATH-}" \\
            RUNNER_NAME="${RUNNER_NAME-}" RUNNER_ENVIRONMENT="${RUNNER_ENVIRONMENT-}" \\
            RUNNER_OS="${RUNNER_OS-}" RUNNER_ARCH="${RUNNER_ARCH-}" RUNNER_TEMP="${RUNNER_TEMP-}" \\
            /usr/bin/python3 -B -S scripts/test-audit-run/observation_runner.py
"""
        self.assertEqual(self.text, expected)

    def test_guard_refuses_wrong_or_missing_context_without_output(self):
        valid = dict(CHECK_REPOSITORY="djensenius/FluxKlang", CHECK_EVENT="workflow_dispatch",
                     CHECK_REF="refs/heads/main", CHECK_SHA=SHA, CHECK_WORKFLOW_SHA=SHA)
        for key, value in ((None, None), ("CHECK_REPOSITORY", "other/repo"),
                           ("CHECK_EVENT", "push"), ("CHECK_REF", "refs/heads/topic"),
                           ("CHECK_SHA", ""), ("CHECK_SHA", "A" * 40),
                           ("CHECK_WORKFLOW_SHA", ""), ("CHECK_WORKFLOW_SHA", "b" * 40)):
            with self.subTest(key=key, value=value):
                environment = dict(valid)
                if key:
                    environment[key] = value
                result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-c", self.guard],
                                        env=environment, capture_output=True, check=False)
                self.assertEqual(result.returncode, 0 if key is None else 1)
                self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_once_sanitized_and_preserves_exit_and_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            capture = path / "capture.json"
            fake = path / "python"
            environment = {key: "fixture-" + key for key in KEYS}
            environment.update(PYTHONPATH="/hostile", PYTHONHOME="/hostile",
                               PYTHONSTARTUP="/hostile", SECRET_TOKEN="secret", PATH="/hostile",
                               __CF_USER_TEXT_ENCODING="hostile")
            clean = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
            # macOS may add __CF_USER_TEXT_ENCODING at interpreter startup.
            baseline = subprocess.run(
                [sys.executable, "-S", "-c", "import json, os; print(json.dumps(dict(os.environ)))"],
                env=clean, capture_output=True, check=True,
            )
            startup = json.loads(baseline.stdout)
            for status, output in ((0, '{"status":"observed"}'),
                                   (1, '{"diagnostic":"Refusal","status":"refused"}'),
                                   (130, '{"diagnostic":"Interrupted","status":"failed"}')):
                with self.subTest(status=status):
                    capture.unlink(missing_ok=True)
                    fake.write_text(
                        f"#!{sys.executable}\n"
                        "import json, os, sys\n"
                        f"open({str(capture)!r}, 'x').write(json.dumps([sys.argv[1:], dict(os.environ)]))\n"
                        f"print({output!r})\n"
                        f"sys.exit({status})\n"
                    )
                    fake.chmod(0o700)
                    command = self.command.replace("/usr/bin/python3", str(fake))
                    result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-c", command],
                                            env=environment, capture_output=True, check=False)
                    self.assertEqual((result.returncode, result.stdout, result.stderr),
                                     (status, (output + "\n").encode(), b""))
                    args, received = json.loads(capture.read_text())
                    self.assertEqual(args, ["-B", "-S", "scripts/test-audit-run/observation_runner.py"])
                    self.assertEqual(received, {**{key: environment[key] for key in KEYS},
                                                **startup})


if __name__ == "__main__":
    unittest.main()
