# Unit audit source inventory

This standalone SwiftParser checker compares reviewed unit-target membership with
the generated PBX source phases, inventories supported Swift Testing owners, and
requires the canonical `.productionAccessAudit` trait on each owner. It does not
execute application code or tests, discover runtime tests, or validate receipts.
Unsupported discovery contexts (including XCTest ancestry) fail closed.

## Build and run

Run from the repository root using Bash or Zsh. The qualified configuration is
Apple Silicon, Swift 6 language mode, Swift 6.4.2 and macOS SDK 27.2, targeting
macOS 27. Use one Xcode toolchain consistently for the compiler, SDK and matching
`SwiftParser`/`SwiftSyntax` host libraries. No package download is needed.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ulimit -c 0
root="$PWD"
work="$(mktemp -d "${TMPDIR:-/tmp}/fluxklang-test-audit.XXXXXX")"
work="$(cd "$work" && pwd -P)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
host="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host"
sources=(scripts/test-audit-coverage/*.swift)
common=(-swift-version 6 -target arm64-apple-macosx27.0 -sdk "$sdk"
        -I "$host" -L "$host" -Xlinker -rpath -Xlinker "$host"
        -module-cache-path "$work/module-cache")

xcrun swiftc "${common[@]}" "${sources[@]}" -o "$work/Check"
"$work/Check" --root "$root" --mode inventory > "$work/inventory.json"
"$work/Check" --root "$root" > "$work/enforcement.json"
```

`--root` is absolute. The optional `--manifest` is root-relative and defaults to
`scripts/test-audit-coverage/registrations.json`. `--format text` selects a
human-readable report; JSON is the default. Modes and exit codes are:

| Exit | Meaning |
| --- | --- |
| 0 | Enforcement satisfied, **or explicitly non-enforcing inventory completed** |
| 1 | Structurally complete but registration/annotation obligations are unsatisfied |
| 2 | Invalid inputs or unsupported/incomplete structural analysis |

Always inspect `analysisComplete` and `enforcementSatisfied`. The initial
registration manifest is complete, but the roots are not yet annotated:
inventory intentionally exits 0 with `enforcementSatisfied: false`, while
default enforcement exits 1. Inventory success is not coverage or isolation.

## Headless fixtures

Using the same shell variables, compile fixture mode and copy the four required
reference inputs from the reviewed checkout. The fixtures parse these files;
they do not compile or execute their test bodies.

```bash
xcrun swiftc "${common[@]}" -D AUDIT_CHECK_TESTS \
    "${sources[@]}" -o "$work/CheckTests"
mkdir "$work/reference-sources"
cp FluxKlangTests/ProductionAccessScope.swift \
   FluxKlangTests/ProductionAccessScopeTests.swift \
   FluxKlangTests/AssistantMixerExecutionTests.swift \
   FluxKlangTests/AssistantActionPlanningTests.swift \
   "$work/reference-sources/"
"$work/CheckTests" --scratch "$work/fixtures" \
    --u1-root "$work/reference-sources"
```

Despite its historical name, `--u1-root` must contain all four files directly.
Use a fresh scratch directory for each fixture run: fixtures deliberately create
malformed projects, alternate sources and symlinks, and will not overwrite an
existing fixture world. The suite has 311 checks: all 292 historical checks plus
19 focused v2 role/qualification mutation groups. Historical regressions include
for unsupported XCTest discovery, nested PBX roots, standard macro handling,
opaque return types, specialized ancestry, erased generic-alias initializers,
current-module-qualified and inherited aliases, source-defined XCTest names,
cross-file extension ownership, local alias/namespace provenance and
actual-owner member rejection, implicit getter boundaries, unsupported consumed
alias initializers, cycle handling, and bounded input reads/rechecks.
The actual-source expectations currently reflect unadopted audit traits; review
those expectations when adopting or otherwise changing the reference sources.

Retain command output, source/input hashes and the reviewed manifest for evidence.
After the commands finish, remove only the generated scratch directory you
created, if its outputs are no longer needed; do not remove shared Xcode caches.

## Input limits

Each source read is limited to 8,000,000 bytes; manifest, PBX and reviewed project
metadata reads are limited to 32,000,000 bytes. These are decimal byte limits.
Reads remain bounded if a file grows while being read, and oversized content is
rejected before caching or parsing. Rereads and input rechecks retain the smallest
limit requested for that path, including after an unsuccessful first read.

## Reviewed manifest maintenance

`specification.review: "REVIEWED"` records a review assertion, not authorization
or an automatic trust operation. The checker verifies the exact `project.yml`
SHA256, but does not parse YAML itself. After a project change:

1. Review the YAML unit-target directory/file memberships and target/configuration
   matrix, and regenerate/review the PBX project using the repository's process.
2. Update the membership transcription and specification digest only after that
   review. The supported PBX location is one repository-root
   `NAME.xcodeproj/project.pbxproj`, not a nested project.
3. Run explicit inventory and require `analysisComplete: true`. Review its
   `derivedRegistrations` against the intended owners before updating
   `registrations`; do not create an exemption baseline or hide missing traits.
4. Run default enforcement and preserve its actual result. Source adoption and
   later CI enforcement are separate work, not implied by manifest completion.

Rows identify source owners per target/module, Debug/Release configuration and
consistent symbolic `canImport(FluxKlangMac)`/`canImport(FoundationModels)`
assignments. They are not public `Test.ID`, parameterized case IDs, SDK
availability claims or expected runtime receipts. Input rechecks detect observed
changes, not an atomic filesystem transaction or adversarial change-and-restore.

Generic ancestry is handled conservatively: unsupported initializer chains fail
closed, without generic argument substitution or inferring ordinary ancestry
from rejection-only traversal. This inventory is not a Swift type checker.
Unshadowed current-module-qualified bases are refused structurally; a source
namespace shadowing the module name still uses source lookup. Enclosing inherited
bindings are checked conservatively for rejection, not to prove ordinary lineage.
Supported source bindings take precedence over SDK terminal spellings.

Extension-declared members are matched to resolved source owners and lexical
access, not qualified-name text alone. Consumed ambiguous, inaccessible or
indeterminate source bindings are refused. Extension-owned ancestry, including
nested owners, uses rejection-only scoped validation rather than establishing
ordinary lineage.

Local source-bound ancestry remains unsupported even where a compiler accepts it.
The lexical index retains declaration provenance when ordinary local lookup is
declined. Nearer formals and physical declarations precede rejection-only lookup
of actual-owner members, using identity, access and the consumer's source path.
Ambiguity, cycles and missing required owner modeling remain indeterminate,
not absence.
Associated extension lookup uses the actual target, not its enclosing owners.
Presence does not prove a binding or SDK ancestry; a dotted-index miss does not
prove absence. Unconsumed declarations and unrelated external helpers do not
themselves require refusal.

Implicit property and subscript getter bodies are local executable scopes; their
declarations do not become enclosing-type members. Consumed aliases require a
supported initializer path, without interpreting unsupported composition elements.
Completed transitive member results are cached by owner, exact name, consumer
path and root/inherited lookup context. Cycles and indeterminate lookups are
never cached as completed absence.

## Opt-in qualification role (schema v2)

Production registration uses v2 to separate audited targets from the dedicated
Apple qualification target. V1 retains its two-unit-target schema, canonical
obligations, report fields and
exit semantics. Merely downgrading a manifest cannot hide a third actual PBX unit
target.

V2 is a single fixed contract, not a configurable exemption facility:

- `FluxKlangTests` and `FluxKlangMacTests` remain audited, with all canonical
  registration/annotation requirements.
- `FluxKlangAppleQualificationTests` is the additional iOS unit target. All six
  Debug/Release matrix rows retain exact target/module/platform identities.
- Required `targetRoles` entries contain only `target` and `role`. Required
  `qualification` contains only `target` and `tests`; each test contains only
  `path`, `owner` and normalized `signature`. These must transcribe
  `TargetRoleContract` exactly. All v1 nested schemas remain strict.
- Its explicit three-file closure is the two owner files under
  `FluxKlangAppleQualificationTests/` and
  `FluxKlangTests/AssistantRoutingFixture.swift`. No directories are allowed.
  Owner files belong to neither audited target; the shared fixture remains in
  the iOS audited target, not the Mac subset.

Every source is parsed and every target/configuration/symbolic variant completes
role-neutral discovery before role obligations are selected. Qualification
requires the two directly declared, top-level struct/method identities, exact
actor annotations and existing single `@Test(.enabled(if: ... == "1"))`
expressions. Nested, extension, alias, free, static, generic, overload and helper
test substitutions fail closed. Real conditional compilation anywhere in the
three files is rejected (comments and string contents are not directives).

V2 adds deterministic `targetRoles` and a separate `qualification` report:
`contractSatisfied` plus sixteen inventory rows for the two methods across
Debug/Release and all four symbolic assignments. Audited `ownership` and
`derivedRegistrations` never include qualification rows. Qualification diagnostics
have no canonical registration and include a declaration site when available.
Structural/input failures force exit 2 in both modes and a false contract status;
otherwise audited failures still mean inventory 0 / enforcement 1.
Text output also reports qualification status and inventory separately.

This checker does **not** bind or parse schemes, validate effective host settings,
prove environment provenance, execute tests, or prove fresh-host isolation.
Host/scheme review is a coordinator-only static integration gate. Live method
bodies and helpers must be preserved through reviewed source moves; there is no
body-hash or canonical-adoption mechanism here. Native/runtime/source integration
and independent review remain separate gates.
