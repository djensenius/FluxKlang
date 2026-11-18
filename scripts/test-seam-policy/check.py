#!/usr/bin/env python3
"""Regression tripwire for #192's source policy, not compiler access control.

The same self-check also covers `fault_latch_raw_raise` (#190): production code must
not call the plain `FaultLatch.raise(scope, kind, frame:)`; authority raises
(`raise(&token, ...)`) and `raiseContended()` stay allowed. A third rule,
`fault_latch_authority_raise`, allows authority raises only in the four
lane-owner files listed in its `excluded:` entries. A fourth, `fault_latch_construction`,
allows `FaultLatch(` only in `FaultLatch+Chains.swift` (K-190c).

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
import re
import shutil
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[2]
RULE = "fault_latch_test_seams"
RAW_RAISE_RULE = "fault_latch_raw_raise"
AUTHORITY_RAISE_RULE = "fault_latch_authority_raise"
CONSTRUCTION_RULE = "fault_latch_construction"
# The lane owners, in .swiftlint.yml order; again not read from the rule.
AUTHORITY_ALLOWLIST = (
    "Shared/Audio/Kernel/Memory/DeferredRelease.swift",
    "Shared/Audio/Kernel/Memory/ReservedCapacityRing+Chains.swift",
    "Shared/Audio/Kernel/Memory/FanInHandoff+Chains.swift",
    "Shared/Audio/Kernel/Events/SysExAssembler.swift",
)
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


def resolve_swiftlint(selected):
    selected = Path(selected).absolute()
    target = selected.resolve()
    if target.name != "mise":
        # Preserve argv[0] for ordinary executable symlinks, too.
        return str(selected)
    # A mise shim is a symlink to mise, not a SwiftLint executable. Ask mise
    # for the repository's selected binary BEFORE entering the fixture cwd;
    # invoking the shim there would instead use that directory's tool selection.
    try:
        result = subprocess.run(
            [str(target), "which", "swiftlint"], cwd=REPOSITORY,
            capture_output=True, text=True, timeout=30, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("repository SwiftLint resolution timed out") from error
    executable = Path(result.stdout.strip())
    if (result.returncode != 0 or not executable.is_absolute()
            or executable.resolve().name == "mise"
            or shutil.which(str(executable)) is None):
        raise RuntimeError(
            "cannot resolve repository SwiftLint through mise: "
            + (result.stderr.strip() or result.stdout.strip() or "no executable returned")
        )
    return str(executable)


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
        self.check_raw_raise()
        self.check_authority_raise()
        self.check_construction()
        self.manifest["outcome"] = "PASS"
        print("PASS fault-seam-policy self-check: 200 negatives, positives, other-rule sentinel")

    def check_raw_raise(self):
        # Second rule (fault_latch_raw_raise), linted over explicit paths so the
        # 200-case matrix above stays exactly as it was.
        positives = (
            "    latch.raise(scope, kind, frame: 1)",
            "    _ = faultsRef._withUnsafeGuaranteedRef { $0.raise(scope, kind, frame: 1) }",
            "    _ = optional?.raise(scope, kind, frame: 1)",
            "    latch\n        .raise(\n            scope, kind, frame: 1)",
            "    latch.raise(\n        scope, kind, frame: 1)",
            "    latch.raise (scope, kind, frame: 1)",
        )
        negatives = (
            "    raise(1)",
            "    authority.raise(&token, scope, kind, frame: 1)",
            "    authority.raise(\n        &token, scope, kind, frame: 1)",
            "    authority.raise(  &token, scope, kind, frame: 1)",
            "    _ = authorityRef._withUnsafeGuaranteedRef { $0.raise(&token, scope, kind, frame: 1) }",
            "    latch.raiseContended()",
            "    raiseContended()",
        )
        plain = ["func rawRaisePositives() {"]
        expected = []
        for text in positives:
            plain.extend(text.splitlines())
            # The identifier is the last `raise` before the argument list.
            line = max(i for i, row in enumerate(plain) if "raise" in row)
            expected.append({
                "file": "Shared/RawRaisePositives.swift", "line": line + 1,
                "character": plain[line].index("raise") + 1,
                "rule_id": RAW_RAISE_RULE, "severity": "Error",
            })
        plain.append("}")
        # Space before the paren also trips the unrelated no_space_in_method_call rule.
        spaced = next(i for i, row in enumerate(plain) if "raise (" in row)
        expected.append({
            "file": "Shared/RawRaisePositives.swift", "line": spaced + 1,
            "character": plain[spaced].index("raise (") + len("raise") + 1,
            "rule_id": "no_space_in_method_call", "severity": "Error",
        })
        declared = ["struct Assembler {", "    private func raise(_ index: Int) {}",
                    "    func caller() {"]
        for text in negatives:
            declared.extend(text.splitlines())
        declared.extend(["    }", "}"])
        write(self.root / "Shared/RawRaisePositives.swift", "\n".join(plain) + "\n")
        write(self.root / "Shared/RawRaiseNegatives.swift", "\n".join(declared) + "\n")
        write(self.root / "FluxKlangTests/RawRaisePositives.swift", "\n".join(plain) + "\n")
        self.lint("raw-raise-positives", expected, ("Shared/RawRaisePositives.swift",))
        # Authority forms are the other rule's; outside the allowlist they fire it, not this one.
        authority = [{
            "file": "Shared/RawRaiseNegatives.swift", "line": i + 1,
            "character": row.index(".raise(") + 2,
            "rule_id": AUTHORITY_RAISE_RULE, "severity": "Error",
        } for i, row in enumerate(declared) if ".raise(" in row]
        self.lint("raw-raise-negatives", authority, ("Shared/RawRaiseNegatives.swift",))
        exempt = [dict(expected[-1], file="FluxKlangTests/RawRaisePositives.swift")]
        self.lint("raw-raise-root-tests-exempt", exempt, ("FluxKlangTests/RawRaisePositives.swift",))
        # The one legitimate plain call carries a narrow, reviewable disable comment.
        source = "Shared/Audio/Kernel/Memory/FaultLatch+Chains.swift"
        lines = (REPOSITORY / source).read_text(encoding="utf-8").splitlines()
        # Fourth rule (fault_latch_construction): the file's one `FaultLatch(` passes only at its own path.
        built = [i for i, row in enumerate(lines) if "FaultLatch(" in row]
        if len(built) != 1:
            raise RuntimeError("FaultLatch+Chains.swift must keep exactly one FaultLatch( construction")
        construction = {"line": built[0] + 1, "character": lines[built[0]].index("FaultLatch(") + 1,
                        "rule_id": CONSTRUCTION_RULE, "severity": "Error"}
        self.copy_input(source, source)
        self.lint("construction-real-chains", [], (source,))
        self.copy_input(source, "Shared/RealFaultLatchChains.swift")
        self.lint("raw-raise-real-chains", [dict(construction, file="Shared/RealFaultLatchChains.swift")],
                  ("Shared/RealFaultLatchChains.swift",))
        disables = [i for i, row in enumerate(lines)
                    if f"swiftlint:disable:next {RAW_RAISE_RULE}" in row]
        if len(disables) != 1 or "latch.raise(" not in lines[disables[0] + 1]:
            raise RuntimeError("FaultLatch+Chains.swift must keep exactly one disable on its plain raise")
        del lines[disables[0]]
        write(self.root / "Shared/MutatedFaultLatchChains.swift", "\n".join(lines) + "\n")
        self.lint("raw-raise-real-chains-without-disable", [{
            "file": "Shared/MutatedFaultLatchChains.swift", "line": disables[0] + 1,
            "character": lines[disables[0]].index("raise(") + 1,
            "rule_id": RAW_RAISE_RULE, "severity": "Error",
        }, dict(construction, file="Shared/MutatedFaultLatchChains.swift",
                line=construction["line"] - (disables[0] < built[0]))],
            ("Shared/MutatedFaultLatchChains.swift",))
        print("PASS fault-seam-policy self-check: raw-raise positives, negatives, exemptions")

    def check_authority_raise(self):
        # Third rule (fault_latch_authority_raise): `raise(&token, ...)` only in the lane owners.
        lines = (REPOSITORY / ".swiftlint.yml").read_text(encoding="utf-8").splitlines()
        entries, section = [], None
        for row in lines[lines.index(f"  {AUTHORITY_RAISE_RULE}:") + 1:]:
            if not row.startswith("    "):
                break
            if not row.startswith("     "):
                section = row.strip()
            elif section == "excluded:" and row.startswith("      - "):
                entries.append(row[len("      - "):])
        if entries != ["/" + re.escape(path) + "$" for path in AUTHORITY_ALLOWLIST]:
            raise RuntimeError(f"authority allowlist drifted from the self-check: {entries}")
        # Broader than the rule (also `. raise (` and comments), so every allowlist
        # entry names a real file that still raises and no other production file does.
        call = re.compile(r"\.\s*raise\s*\(\s*&")
        found = sorted(
            str(path.relative_to(REPOSITORY))
            for top in ("Shared", "FluxKlang", "FluxKlangMac")
            for path in (REPOSITORY / top).rglob("*.swift")
            if call.search(path.read_text(encoding="utf-8"))
        )
        if found != sorted(AUTHORITY_ALLOWLIST):
            raise RuntimeError(f"production authority raises outside the allowlist or stale entries: {found}")
        for source in AUTHORITY_ALLOWLIST:
            moved = "Shared/NotAllowlisted/" + Path(source).name
            self.copy_input(source, source)
            self.copy_input(source, moved)
            rows = (REPOSITORY / source).read_text(encoding="utf-8").splitlines()
            sites = [i for i, row in enumerate(rows) if ".raise(&" in row]
            if len(sites) != 1:
                raise RuntimeError(f"{source}: expected one authority raise, found {len(sites)}")
            self.lint(f"authority-raise-real-{Path(source).stem}", [], (source,))
            self.lint(f"authority-raise-moved-{Path(source).stem}", [{
                "file": moved, "line": sites[0] + 1,
                "character": rows[sites[0]].index("raise(&") + 1,
                "rule_id": AUTHORITY_RAISE_RULE, "severity": "Error",
            }], (moved,))
        positives = (
            "    x.raise(&token, scope, kind, frame: 0)",
            "    _ = authorityRef._withUnsafeGuaranteedRef { $0.raise(&token, scope, kind, frame: 0) }",
            "    _ = optional?.raise(&token, scope, kind, frame: 0)",
            "    authority.raise(\n        &token, scope, kind, frame: 0)",
            "    authority\n        .raise(&token, scope, kind, frame: 0)",
        )
        body = ["func authorityRaisePositives() {"]
        calls = []
        for text in positives:
            body.extend(text.splitlines())
            calls.append(max(i for i, row in enumerate(body) if "raise" in row))
        body.append("}")
        source = "\n".join(body) + "\n"
        # Lookalikes of allowlisted paths are not allowlisted.
        for path in ("Shared/AuthorityRaisePositives.swift",
                     "Shared/Audio/Kernel/Memory/XDeferredRelease.swift",
                     "Shared/Audio/Kernel/Memory/DeferredRelease+Extra.swift",
                     "Shared/Other/SysExAssembler.swift"):
            write(self.root / path, source)
            self.lint(f"authority-raise-positives-{Path(path).stem}", [{
                "file": path, "line": i + 1, "character": body[i].index("raise") + 1,
                "rule_id": AUTHORITY_RAISE_RULE, "severity": "Error",
            } for i in calls], (path,))
        write(self.root / "FluxKlangTests/AuthorityRaisePositives.swift", source)
        self.lint("authority-raise-root-tests-exempt", [], ("FluxKlangTests/AuthorityRaisePositives.swift",))
        negatives = ["func authorityRaiseNegatives() {", "    latch.raiseContended()",
                     "    raiseContended()", "    latch.raise(scope, kind, frame: 0)", "}"]
        write(self.root / "Shared/AuthorityRaiseNegatives.swift", "\n".join(negatives) + "\n")
        self.lint("authority-raise-negatives", [{
            "file": "Shared/AuthorityRaiseNegatives.swift", "line": 4,
            "character": negatives[3].index("raise") + 1,
            "rule_id": RAW_RAISE_RULE, "severity": "Error",
        }], ("Shared/AuthorityRaiseNegatives.swift",))
        print("PASS fault-seam-policy self-check: authority-raise allowlist, positives, negatives")

    def check_construction(self):
        # Fourth rule (fault_latch_construction): spelled-out `FaultLatch(` and `FaultLatch.init(`, also split
        # over lines; the real FaultLatch+Chains.swift is checked in check_raw_raise.
        positives = (
            "    _ = try? FaultLatch(scopes: [])",
            "    _ = try? FaultLatch.init(scopes: [])",
            "    _ = try? FaultLatch\n        .init(scopes: [])",
        )
        body = ["func constructionPositives() {"]
        sites = []
        for text in positives:
            # The diagnostic is on the `FaultLatch` token, the first line of each form.
            sites.append(len(body))
            body.extend(text.splitlines())
        body.append("}")
        source = "\n".join(body) + "\n"
        # A lookalike of the excluded path is not excluded.
        for path in ("Shared/ConstructionPositives.swift",
                     "Shared/Audio/Kernel/Memory/XFaultLatch+Chains.swift"):
            write(self.root / path, source)
            self.lint(f"construction-positives-{Path(path).stem}", [{
                "file": path, "line": i + 1, "character": body[i].index("FaultLatch") + 1,
                "rule_id": CONSTRUCTION_RULE, "severity": "Error",
            } for i in sites], (path,))
        write(self.root / "FluxKlangTests/ConstructionPositives.swift", source)
        self.lint("construction-root-tests-exempt", [], ("FluxKlangTests/ConstructionPositives.swift",))
        negatives = ["func constructionNegatives() {", "    // FaultLatch(scopes: [])",
                     '    _ = "FaultLatch(scopes: [])"', "    _ = MyFaultLatch()", "    _ = FaultLatchNote()",
                     "    _ = FaultLatch.PreparationError.self", "}"]
        write(self.root / "Shared/ConstructionNegatives.swift", "\n".join(negatives) + "\n")
        self.lint("construction-negatives", [], ("Shared/ConstructionNegatives.swift",))
        print("PASS fault-seam-policy self-check: construction positives, negatives, exemption, lookalike path")


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
        swiftlint = resolve_swiftlint(swiftlint)
        if args.keep_evidence:
            evidence = args.keep_evidence.resolve()
            if evidence == REPOSITORY or REPOSITORY in evidence.parents:
                parser.error("--keep-evidence must be outside the repository")
            evidence.mkdir(parents=True, exist_ok=False)
            print(f"Evidence: {evidence}")
        else:
            temporary = tempfile.TemporaryDirectory(prefix="fluxklang-test-seam-policy-")
            evidence = Path(temporary.name).resolve()
        check = Check(evidence, swiftlint)
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
