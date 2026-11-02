#!/usr/bin/env python3
"""Regression tripwire for #192's source policy, not compiler access control.

The seams remain compiled in app modules. This type-blind, non-adversarial policy
does not defend against lint suppressions or configuration edits. Its declaration
exception accepts plain/backtick function names after `func` plus one ASCII space;
noncanonical declaration spacing fails closed. Never exempt a whole body/file.

Run with the caller-pinned swiftlint on PATH. Only temporary Swift sources are
created, never compiled or executed. --keep-evidence NEW_DIRECTORY preserves the
fixtures, copied repository configs, provenance, and exact subprocess results.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[2]
RULE = "fault_latch_test_seams"
# Independent expectations, deliberately not extracted from the policy regex.
SEAMS = (
    "admitRaiseForTesting",
    "finishRaiseForTesting",
    "addRaiseForTesting",
    "publishRaiseForTesting",
    "withControlLockForTesting",
    "seedForTesting",
    "stateForTesting",
    "seedUnknownScopeFaultsForTesting",
)
DIAGNOSTIC_FIELDS = ("file", "line", "character", "rule_id", "severity")
ACTUAL_SOURCES = {
    "Shared/Audio/Kernel/Memory/FaultLatch.swift": "Shared/ActualFaultLatch.swift",
    "FluxKlangTests/RealtimeHandoffTests+Faults.swift":
        "FluxKlangTests/RealtimeHandoffTests+Faults.swift",
    "FluxKlangTests/RealtimeHandoffTests+FaultsStress.swift":
        "FluxKlangTests/RealtimeHandoffTests+FaultsStress.swift",
}


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class Fixture:
    def __init__(self, path):
        self.path = path
        self.lines = []
        self.expected = []

    def add(self, text, seam=None, case=None):
        self.lines.extend(text.splitlines())
        if seam is not None:
            # Use the final occurrence: a declaration on the same line is NOT
            # the forbidden expression in its body or default argument.
            index = next(i for i in reversed(range(len(self.lines)))
                         if seam in self.lines[i])
            self.expected.append({
                "file": self.path, "line": index + 1,
                "character": self.lines[index].rindex(seam) + 1,
                "rule_id": RULE, "severity": "Error", "seam": seam, "case": case,
            })

    def save(self, root):
        write(root / self.path, "\n".join(self.lines) + "\n")


def create_fixtures(root):
    calls = Fixture("Shared/Calls.swift")
    bodies = Fixture("Shared/Audio/Kernel/Memory/FaultLatch.swift")
    positives = Fixture("Shared/Positives.swift")
    bodies.add("struct FaultLatch {")
    positives.add("struct Definitions {")
    for index, name in enumerate(SEAMS):
        calls.add(f"func productionCaller{index}() {{")
        forms = {
            "qualified_call": f"    latch.{name}()",
            "unqualified_call": f"    {name}()",
            "qualified_reference": f"    _ = latch.{name}",
            "unqualified_reference": f"    _ = {name}",
            "optional_call": f"    _ = optional?.{name}()",
            "optional_reference": f"    _ = optional?.{name}",
            "backtick_qualified_call": f"    latch.`{name}`()",
            "backtick_unqualified_call": f"    `{name}`()",
            "backtick_qualified_reference": f"    _ = latch.`{name}`",
            "backtick_unqualified_reference": f"    _ = `{name}`",
            "multiline_call": f"    latch\n        .{name}()",
            "multiline_reference": f"    _ = latch\n        .{name}",
            "multiline_backtick_call": f"    latch\n        .`{name}`()",
            "labeled_qualified_reference": f"    _ = latch.{name}(_:state:)",
            "labeled_unqualified_reference": f"    _ = {name}(_:state:)",
            "optional_labeled_reference": f"    _ = optional?.{name}(_:state:)",
            "interpolation_call": '    _ = "value \\(latch.' + name + '())"',
            "interpolation_reference": '    _ = "value \\(latch.' + name + ')"',
            "raw_interpolation_call": '    _ = #"value \\#(latch.' + name + '())"#',
            # A whitespace-spanning declaration exception must not swallow this.
            "comment_func_previous_line": "    // func\n    " + name + "()",
        }
        for case, text in forms.items():
            calls.add(text, name, case)
        calls.add("}\n" if index == len(SEAMS) - 1 else "}\n\n")
        bodies.add(f"    func {name}() {{ self.{name}() }}",
                   name, "same_line_declaration_body")
        bodies.add(f"    func {name}(value: Int = latch.{name}()) {{}}",
                   name, "same_name_default_argument")
        bodies.add(f"    func otherMethod{index}() {{ {name}() }}",
                   name, "another_method_inside_FaultLatch")
        positives.add(f"    func {name}() {{}}")
    bodies.add("}")
    positives.add("}\n\nstruct BacktickDefinitions {")
    for name in SEAMS:
        positives.add(f"    func `{name}`() {{}}")
    positives.add("}\n\nfunc harmlessText() {")
    for name in SEAMS:
        positives.add(f"    // {name}()\n    /* {name} */")
        positives.add(f'    _ = "{name}()"\n    _ = #"{name}()"#')
        positives.add(f"    _ = latch.{name}Extra\n    _ = latch.prefix{name}")
    positives.add("    TriggerScheduler.completeForTesting()\n}")
    fixtures = [calls, bodies, positives]
    for path in ("Shared/FluxKlangTests/NotAuthorized.swift",
                 "FluxKlangTestsExtra/NotAuthorized.swift"):
        fixture = Fixture(path)
        fixture.add("func notAuthorized() {")
        for name in SEAMS:
            fixture.add(f"    latch.{name}()", name, "path_lookalike")
        fixture.add("}")
        fixtures.append(fixture)
    for fixture in fixtures:
        fixture.save(root)
    # Identical forbidden expressions are permitted only under root tests,
    # including descendants of that directory.
    for fixture, destination in (
        (calls, "FluxKlangTests/Authorized.swift"),
        (bodies, "FluxKlangTests/Nested/Authorized.swift"),
    ):
        write(root / destination, "\n".join(fixture.lines) + "\n")
    return [entry for fixture in fixtures for entry in fixture.expected]


class Check:
    def __init__(self, evidence, swiftlint):
        self.evidence = evidence
        self.root = evidence / "root"
        self.swiftlint = swiftlint
        self.manifest = {
            "repository": str(REPOSITORY), "outcome": "FAIL",
            "executable": swiftlint, "inputs": [], "commands": [],
        }

    def copy_input(self, source, destination):
        data = (REPOSITORY / source).read_bytes()
        target = self.root / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.manifest["inputs"].append({
            "source": str(REPOSITORY / source), "destination": destination,
            "sha256": hashlib.sha256(data).hexdigest(),
        })

    def run(self, label, arguments):
        command = [self.swiftlint] + arguments
        record = {"label": label, "argv": command, "cwd": str(self.root),
                  "exit_status": None}
        self.manifest["commands"].append(record)
        try:
            result = subprocess.run(command, cwd=self.root, capture_output=True,
                                    text=True, timeout=60, check=False)
        except subprocess.TimeoutExpired as error:
            record["error"] = str(error)
            for stream in ("stdout", "stderr"):
                output = getattr(error, stream) or b""
                if isinstance(output, bytes):
                    output = output.decode("utf-8", errors="replace")
                write(self.evidence / "logs" / f"{label}.{stream}", output)
            raise RuntimeError(f"{label}: SwiftLint timed out after 60 seconds") from error
        record["exit_status"] = result.returncode
        for stream in ("stdout", "stderr"):
            relative = f"logs/{label}.{stream}"
            write(self.evidence / relative, getattr(result, stream))
            record[stream] = relative
        return result

    def lint(self, label, expected, paths=()):
        # cwd is the actual temporary root. Explicit --config ignores nested
        # configuration in SwiftLint; --working-directory is not a chdir.
        result = self.run(label, ["--strict", "--no-cache", "--reporter", "json", *paths])
        diagnostics = json.loads(result.stdout)
        actual = []
        for diagnostic in diagnostics:
            diagnostic["file"] = str(Path(diagnostic["file"]).relative_to(self.root))
            actual.append(tuple(diagnostic[field] for field in DIAGNOSTIC_FIELDS))
        wanted = Counter(tuple(entry[field] for field in DIAGNOSTIC_FIELDS)
                         for entry in expected)
        observed = Counter(actual)
        missing, unexpected = wanted - observed, observed - wanted
        exit_status = 2 if expected else 0
        if missing or unexpected or result.returncode != exit_status:
            raise RuntimeError(
                f"{label}: expected={sum(wanted.values())} actual={len(actual)} "
                f"missing={sum(missing.values())} unexpected={sum(unexpected.values())} "
                f"lint_exit={result.returncode} (expected {exit_status}); "
                f"missing_sample={list(missing)[:3]} unexpected_sample={list(unexpected)[:3]}"
            )
        print(f"PASS {label}: diagnostics={len(actual)} lint_exit={result.returncode}")

    def execute(self):
        # These are the ACTUAL repository configurations, copied byte-for-byte.
        # Do not synthesize only_rules or substitute a test-only policy.
        for path in (".swiftlint.yml", "FluxKlangTests/.swiftlint.yml"):
            self.copy_input(path, path)
        for source, destination in ACTUAL_SOURCES.items():
            self.copy_input(source, destination)
        expected = create_fixtures(self.root)
        if len(expected) != 200:
            raise RuntimeError(f"incomplete negative matrix: {len(expected)} cases, expected 200")
        self.manifest["expected_negatives"] = expected
        actual_paths = set(ACTUAL_SOURCES.values())
        self.manifest["generated_swift_files"] = [
            str(path.relative_to(self.root)) for path in sorted(self.root.rglob("*.swift"))
            if str(path.relative_to(self.root)) not in actual_paths
        ]
        version = self.run("version", ["version"])
        if version.returncode != 0:
            raise RuntimeError(f"swiftlint version exited {version.returncode}")
        print(f"SwiftLint {version.stdout.strip()}: {self.swiftlint}")
        self.lint("negative-matrix", expected)
        self.lint("positive-controls", [], (
            "Shared/Positives.swift", "Shared/ActualFaultLatch.swift", "FluxKlangTests",
        ))
        sentinel = "FluxKlangTests/OtherRuleSentinel.swift"
        write(self.root / sentinel,
              "func allowedTest() {\n    latch.seedForTesting() \n}\n")
        self.lint("other-rule-sentinel", [{
            "file": sentinel, "line": 2, "character": 27,
            "rule_id": "trailing_whitespace", "severity": "Error",
        }], (sentinel,))
        self.manifest["outcome"] = "PASS"
        print("PASS fault-seam-policy self-check: 200 negatives, positives, other-rule sentinel")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-evidence", type=Path, metavar="NEW_DIRECTORY",
                        help="preserve fixtures/logs outside the repository instead of cleaning them")
    args = parser.parse_args()
    swiftlint = shutil.which("swiftlint")
    if swiftlint is None:
        parser.error("swiftlint is missing from PATH; run with the caller's pinned toolchain")
    temporary = None
    try:
        if args.keep_evidence:
            evidence = args.keep_evidence.resolve()
            if evidence == REPOSITORY or REPOSITORY in evidence.parents:
                parser.error("--keep-evidence must be outside the repository")
            evidence.mkdir(parents=True, exist_ok=False)
            print(f"Evidence: {evidence}")
        else:
            temporary = tempfile.TemporaryDirectory(prefix="fluxklang-test-seam-policy-")
            evidence = Path(temporary.name).resolve()
        check = Check(evidence, str(Path(swiftlint).resolve()))
        try:
            check.execute()
        finally:
            write(evidence / "manifest.json", json.dumps(check.manifest, indent=2) + "\n")
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"FAIL fault-seam-policy self-check: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    sys.exit(main())
