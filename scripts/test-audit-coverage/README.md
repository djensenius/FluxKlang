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

Always inspect `analysisComplete` and `enforcementSatisfied`. The registration
manifest is complete. `MacPureModelSmokeTests`, `MIDIClipOwnershipTests`,
`CloudKitHistoryIsolationTests`, `PerformanceProjectSessionTests`,
`PerformanceDraftReviewTests` and, under `#if os(macOS)`, `RoutingDSPTests`,
`GraphCompilerTests`, `RoutingBoundaryTests`, `GraphCompilerPlanTests` and
`GraphReferenceEvaluatorTests` use the canonical suite trait; this is partial
source adoption only. The iOS owners of those five macOS-guarded suites remain
unadopted. Other owners'
annotation obligations remain unsatisfied: inventory intentionally exits 0 with
`enforcementSatisfied: false`, while default enforcement exits 1. Inventory
success is not coverage or isolation.

The trait observes cumulative suite-exit state with nonrecursive scope, not
per-test evidence or exclusive attribution. Missing/invalid
`FLUXKLANG_AUDIT_RUN_ID` records an issue after the body, not at earliest
bootstrap. This adoption provides no new safe ordinary/unprepared Mac execution
workflow and does not authorize hosted execution.

The macOS guard also applies to the isolated pure SwiftPM consumer; it does not
exclude that consumer from the canonical audit. Its successor fixture retains
the original 149 repository source paths and adds the unchanged
`Shared/Store/ProductionAccessAudit.swift` to `FluxKlang` and
`FluxKlangTests/ProductionAccessScope.swift` to `FluxKlangTests` (151 repository
sources). The successor fixture also adds one private instrumentation source, for
152 staged Swift inputs: 151 exact repository sources plus one private witness.
Generated SwiftPM runner sources are separate. The manifest and original
`(GraphCompilerTests|RoutingDSPTests|RoutingBoundaryTests)` filter are unchanged.

Separately authorized, bounded Debug and Release runs of this fixture each
passed all original 39 declarations and 50 case invocations plus the witness
(40 declarations, 51 cases, three suites) using SwiftPM's `--build-system native`.
Each run retained genuine canonical suite-exit attachments through
`--attachments-path` (an existing writable directory) under its own fresh
authorized `FLUXKLANG_AUDIT_RUN_ID`. The observed `Test.ID` was
`FluxKlangTests/RoutingDSPTests`, all 14 operation IDs reported zero
`apiEntered` and `factoryEvaluated` counters, and no audit issue was recorded.
The Release run is optimized with `-enable-testing`, which `@testable` imports
require; it does not establish shipping-build equivalence. Best-effort
`Attachment.record` alone does not establish persistence. These RoutingDSP
receipts do not qualify the separate MIDI/history adoption described below;
the broader storage selection remains deferred.

The private witness records ordered `CommandLine.arguments`, self executable
paths and POSIX process IDs in a separately named genuine attachment. The
witness uses a bounded request/acknowledgment protocol: the supervisor publishes
complete control only after launching the command and obtaining its actual
PID/group. The witness waits for validated control, then for matching
independent observations. Other tests may already be running; this is not
pre-test or bootstrap control. A 50 ms condition wait is only waiting, never
proof. Missing/mismatched acknowledgment, ancestry, image or owned-group
membership fails closed without adopting or signalling an unowned group.

One separately compiled private Security-framework metadata observer is tooling,
not another fixture source, test or suite: fixture counts remain 151+1 inputs
and 40 declarations/51 cases/three suites. Its public APIs report OS code-origin
metadata, not signature validity, authenticity or secure loaded-byte identity.
Required executable URL/status/type checks do not detect all invalid metadata;
optional unsigned-code fields are not mandatory. The observer was separately
compiled and narrowly qualified as a tool (one directly owned live subject)
before fixture execution was authorized; that qualification does not cover the
fixture, SwiftPM groups or bootstrap.

The recorded `CommandLine.arguments` remain Swift process arguments **during the
witness**, not initial kernel argv or an unmodified launch snapshot.
Self/external PID, group, current ancestry, paths and run UUID must correlate
with the genuine canonical suite-exit payload.
A hosting `swiftpm-testing-helper` or `xctest` is not the test-bundle executable;
actual host/bundle headers and loading relationships remain separate gates, and
an Apple host's deployment target need not equal the fixture's macOS 27 target.
The witness reads only its authorized run UUID and allowlisted control-path
environment entry, never serializes the environment, and does not invent a
canonical `Test.ID`.

Earlier attempts were not accepted. Debug02's collector rejected
valid parameterized summaries and lacked independent live host/group correlation.
A later Release attempt without `-enable-testing` failed to build. The
observation protocol is not proof of birth identity, historical ancestry or
descendant closure. Source-checker qualification covers registrations, not this
README or the private witness/tool.

Remaining gates include other source-owner adoption and independent review,
coordinator-only native compile-only qualification, and separately authorized
native/hosted runtime qualification: exact runner argv, earliest bootstrap,
fresh-host isolation, actual UUID delivery and runtime `Test.ID`/result
identity, attachment persistence, descendant closure and artifact sealing.
Source registration rows are not runtime receipt expectations; #60 remains open.

## MIDI and history source adoption

The existing MIDI clip ownership and CloudKit history isolation roots now use
the canonical `.productionAccessAudit` trait without changing their test bodies,
guards or target memberships. The complete source-inventory comparison retains
all 4,808 registrations (at that time) and adds 24 satisfied owner rows (16 MIDI, eight history):
40 satisfied rows instead of 16. All other owner obligations remain unchanged.
The unchanged checker fixture suite passes all 311 checks; inventory remains
non-enforcing and default enforcement still reports unsatisfied obligations.

Those source results are separate from the newly qualified pure fixture:
126 exact repository Swift inputs plus one private witness, retaining all nine
committed dependency pins. The baseline and separately authorized Debug and
Release candidates each passed 71 MIDI cases, eight history cases and the
witness. The unchanged baseline retained no selected canonical receipts; that
was the expected missing-adoption RED, not a test failure.

Each candidate persisted exactly two genuine schema-1 `suiteExit` receipts,
with observed `Test.ID` values `FluxKlangTests/MIDIClipOwnershipTests` and
`FluxKlangTests/CloudKitHistoryIsolationTests`, plus the private witness.
All 14 operation IDs had integer-zero `factoryEvaluated` and `apiEntered`
counters, without audit issues. The three run UUIDs differ; the candidates'
process-instance and invocation UUIDs also differ. Baseline receipt-internal
identities were not observed.

The private witness and independent process observations correlate receipts by
run UUID and host PID, subject to the argument, origin and nonrecursive-scope
limitations above. All 127 owned inputs explicitly select Swift 6; the
generated SwiftPM runner has no explicit language selection, so its Swift 6
language mode is not established. Release uses `-O` and `-enable-testing`, not
shipping-build equivalence. Driver jobs were limited to two, but Release
whole-module compiler invocations requested ten threads; actual concurrent
thread usage was not observed.

This is not a new supported execution workflow, earliest-bootstrap proof,
exclusive per-test attribution, native host isolation or permission to access
CloudKit. The remaining #60 gates still apply.

## Graph compiler and routing boundary source adoption

`GraphCompilerTests` and `RoutingBoundaryTests` now use the canonical trait
under `#if os(macOS)`, matching `RoutingDSPTests`, without semantic test-body,
target-membership or registration changes. To stay within `file_length`, five
wrapped closures in `collectionAndMapPreflightPrecedesValidation` were reflowed
(whitespace only). Against the unmodified base, the complete
source inventory retains all 4,840 registrations and moves 16 `FluxKlangMacTests`
owner rows (eight per suite) to satisfied: 88 satisfied rows instead of 72. The
iOS `FluxKlangTests` rows for both suites stay unsatisfied and no other row
changes. Diagnostics fall from 7,240 to 7,208 (16 removed per suite, none
added). Inventory still exits 0 and default enforcement still exits 1.

The RoutingDSP pure fixture's 151 repository source paths were byte-copied from
this change into a fresh SwiftPM package (default build system), without the
private witness or observer. The checker and fixture runs used the trait change
before the whitespace-only reflow above. Debug and
Release (`-c release -Xswiftc -enable-testing`) runs with the original filter each
passed 39 tests (50 case invocations) in three suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of `FluxKlangTests/GraphCompilerTests`,
`FluxKlangTests/RoutingBoundaryTests` and `FluxKlangTests/RoutingDSPTests`,
carrying that run ID, with all 14 operation IDs reporting zero `apiEntered` and
`factoryEvaluated` and no audit issue recorded. Without the witness, these runs
add no process-identity, argv or bootstrap evidence; the limitations and
remaining #60 gates above still apply.

## Routing schedule and reference evaluator source adoption

`GraphCompilerPlanTests` and `GraphReferenceEvaluatorTests` now use the
canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, extension-file, target-membership or
registration changes. Against the unmodified base, the complete source
inventory retains all 4,840 registrations and moves 16 `FluxKlangMacTests`
owner rows (eight per suite) to satisfied: 104 satisfied rows instead of 88.
The iOS `FluxKlangTests` rows for both suites stay unsatisfied and no other row
changes. Diagnostics fall from 7,208 to 7,176 (16 removed per suite, none
added). Inventory still exits 0 and default enforcement still exits 1.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 180 repository sources from this change: the 151 RoutingDSP fixture
paths plus the 16 root and extension files of both suites and the 13
`Shared/Audio/GraphCompiler/Plan` and `DSP` sources. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the two suites each
passed 95 tests (no parameterized cases) in two suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of `FluxKlangTests/GraphCompilerPlanTests` and
`FluxKlangTests/GraphReferenceEvaluatorTests`, carrying that run ID, with all
14 operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no
audit issue recorded. These runs add no process-identity, argv or bootstrap
evidence and do not cover the iOS owners; the remaining #60 gates above still
apply and #60 remains open.

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
19 focused v2 role/qualification mutation groups. Historical regressions include checks
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
