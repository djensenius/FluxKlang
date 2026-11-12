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
`PerformanceDraftReviewTests`, `PerformanceWiringEditorTests` and, under
`#if os(macOS)`, `RoutingDSPTests`,
`GraphCompilerTests`, `RoutingBoundaryTests`, `GraphCompilerPlanTests`,
`GraphReferenceEvaluatorTests`, `AudioGainContractTests`,
`AudioMuteContractTests`, `ProjectPackageManifestCodecTests`,
`ProjectPackageManifestValidationTests`, `ProjectPackageManifestReferenceTests`,
`ProjectPackagePathTests`, `MIDIClockFollowerTests`, `MIDIClockMathTests`,
`MIDIClockPulseScheduleTests`, `MIDIClockTempoTests`,
`MIDIClockTempoEstimatorTests`, `ControlPickupTests`, `ControlPickupBookTests`,
`ProjectPackageAdmissionTests`, `PerformBindingListTests`,
`WiringConnectionListTests`, `MIDIClockArbitrationTests`,
`MIDIClockArbitrationSteadyRunTests`, `MIDIInternalClockTests`,
`MTCFollowerTests`, `MetronomeGridTests`, `MIDIClipTimingTests`,
`MIDIClipLoopTests`, `MIDIClipContinuityTests`, `MIDIClipContinuityTempoTests`,
`SMFTempoImportTests`, `MIDIProtocolTests`, `MIDIControlChangeDecodeTests`,
`MIDI1ChannelStateTests`, `MIDI1ParameterStateTests`,
`MIDI1PerformanceSnapshotTests`, `UMPPacketFramingTests`,
`UMPChannelVoiceTests`, `UMPScalingTests`, `UMPTranslationTests`,
`UMPTranslationStateTests`, `UMPTranslationDataEntryTests`,
`ShowNavigationTests`, `ShowNavigationCursorTests`, `ShowNavigationLinkTests`,
`ShowTransitionTests`, `ShowTransitionWalkTests`, `ShowFootInputTests`,
`ShowFootInputRefusalTests`, `ShowFootSessionTests`, `MPEZoneTests`,
`TunerPitchTests`, `TunerSmootherTests`, `OpenSoundControlCodecTests`,
`OpenSoundControlFramingTests`, `OSCNamespaceTests`, `WiringNodeEditTests`,
`WiringPreviewTests`, `WiringReviewDiffTests`, `WiringEditPathTests`,
`WiringEditPathEquivalenceTests`, `WiringComposeTests`,
`WiringDestinationListTests`, `WiringMatrixTests`, `UMPStreamMessageTests`,
`UMPTranslationStreamTests`, `UMPTranslationStreamPropertyTests`,
`MIDIMachineControlTests`, `MIDITimecodeTests`,
`MIDIClockArbitrationDropoutTests`, `ControlBindingTests`,
`ControlBindingGroupTests`, `ControlHostTruthTests`, `ControlTriggerTests`,
`ControlTriggerClearTests`, `ControlTriggerDetectorTests`,
`ControlLearnTests`, `ControlLearnConflictTests`, `ControlInputGateTests`,
`ControlInputBankTests`, `ControlSourceAvailabilityTests`,
`ControlLocalTriggerDispatchTests`, `ControlFeedbackTests`,
`MIDIControlIntakeTests`, `ActiveSensingTests`, `MIDISourceRegistryTests`,
`StandardMIDIFileTests`, `StandardMIDIFileReaderTests`,
`CaptureSMFExportTests`, `MIDICaptureExportTests`, `MIDICaptureClockTests`,
`MIDICaptureProtocolTests`, `MIDICaptureRestartTests`,
`TimecodeMachineTests`, `AutomationBankTests`, `AutomationRenderTests`,
`AutomationRenderHandbackTests`, `AutomationRenderLoopTests`,
`AutomationRenderTempoTests`, `ActionSetSubmissionTests`,
`ActionSetSubmissionAdmissionTests`, `ActionSetSubmissionCancelTests`,
`RecordingTakeTests`, `RecordingTakeBackwardJumpTests`,
`RecordingTakeDiscontinuityTests`, `RecordingTakeRecoveryTests`,
`RecordingTakeV1GateTests`, `PatchVariationTests`,
`PatchVariationEditingTests`, `PatchVariationRepairTests`,
`PatchTransitionTests`, `PatchTransitionBoundsTests`,
`PatchTransitionLifecycleTests`, `PatchTransitionRepeatedTests`,
`PatchTransitionSustainTests`, `PeerStatusProjectionTests`,
`PeerBackpressureTests`, `PeerEndpointPolicyTests` and
`PeerControlMessageTests`
use the canonical suite trait; this is partial source adoption only. The iOS
owners of those one hundred and nineteen macOS-guarded suites remain
unadopted.
Other owners' annotation obligations remain unsatisfied: inventory
intentionally exits 0 with `enforcementSatisfied: false`, while default
enforcement exits 1. Inventory success is not coverage or isolation.

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

## Gain and mute graph contract source adoption

`AudioGainContractTests` and `AudioMuteContractTests` now use the canonical
trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, target-membership or registration
changes. Against the unmodified base, the complete source inventory retains
all 4,856 registrations and moves 16 `FluxKlangMacTests` owner rows (eight per
suite) to satisfied: 136 satisfied rows instead of 120. The iOS
`FluxKlangTests` rows for both suites stay unsatisfied and no other row
changes. Diagnostics fall from 7,176 to 7,144 (16 removed per suite, none
added). Inventory still exits 0 and default enforcement still exits 1.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 189 repository sources from this change: the 180 paths of the
routing schedule fixture above, both suite files, the shared
`ManifestTestSupport` helper's file `ProjectPackageManifestCodecTests.swift`
and six in-memory `Shared/Persistence/Projects` manifest, limit and path
sources. Debug and Release (`-c release -Xswiftc -enable-testing`) runs
filtered to the two suites each passed 32 tests (82 case invocations) in two
suites. Each run, under its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one
`suiteExit` attachment to `--attachments-path` for each of
`FluxKlangTests/AudioGainContractTests` and
`FluxKlangTests/AudioMuteContractTests`, carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no audit
issue recorded. These runs add no process-identity, argv or bootstrap evidence
and do not cover the iOS owners; the remaining #60 gates above still apply and
#60 remains open.

## Project package manifest and path source adoption

`ProjectPackageManifestCodecTests`, `ProjectPackageManifestValidationTests`,
`ProjectPackageManifestReferenceTests` and `ProjectPackagePathTests` now use
the canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. The `ManifestTestSupport` helper enum in the codec suite's
file is not a suite and stays unannotated. Against the unmodified base, the
complete source inventory retains all 4,856 registrations and moves 32
`FluxKlangMacTests` owner rows (eight per suite) to satisfied: 168 satisfied
rows instead of 136. The iOS `FluxKlangTests` rows for all four suites stay
unsatisfied and no other row changes. Diagnostics fall from 7,144 to 7,080 (16
removed per suite, none added). Inventory still exits 0 and default enforcement
still exits 1.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 194 repository sources from this change: the 189 paths of the gain
and mute fixture above, which already include the codec suite's file and six
`Shared/Persistence/Projects` sources, plus the other three suite files, the
shared `ProjectPackageTestSupport` helper's file
`ProjectPackageAdmissionTests.swift` and the in-memory
`ProjectPackageAdmission.swift` source. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the four suites each
passed 39 tests (no parameterized cases) in four suites. Each run, under its
own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of
`FluxKlangTests/ProjectPackageManifestCodecTests`,
`FluxKlangTests/ProjectPackageManifestValidationTests`,
`FluxKlangTests/ProjectPackageManifestReferenceTests` and
`FluxKlangTests/ProjectPackagePathTests`, carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no audit
issue recorded. These runs add no process-identity, argv or bootstrap evidence
and do not cover the iOS owners; the remaining #60 gates above still apply and
#60 remains open.

## MIDI clock follower, math, pulse schedule and tempo source adoption

`MIDIClockFollowerTests`, `MIDIClockMathTests`, `MIDIClockPulseScheduleTests`
and `MIDIClockTempoTests` now use the canonical trait under `#if os(macOS)` on
their root declarations, matching `GraphCompilerTests`, without test-body,
helper, target-membership or registration changes. Against the unmodified
base, the complete source inventory retains all 4,856 registrations and moves
32 `FluxKlangMacTests` owner rows (eight per suite) to satisfied: 200
satisfied rows instead of 168. The iOS `FluxKlangTests` rows for all four
suites stay unsatisfied and no other row changes. Diagnostics fall from 7,080
to 7,016 (16 removed per suite, none added). Inventory still exits 0 and
default enforcement still exits 1.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 208 repository sources from this change: the 194 paths of the
project package fixture above, which already include the
`Shared/Contracts/Transport` clock stamp, clock map and generation ledger
sources, plus the four suite files, the seven value-only
`Shared/MIDI/Clock` sources and the three `Shared/MIDI/Protocol/MIDI1` event,
parser and semantic sources. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the four suites each
passed 28 tests (no parameterized cases) in four suites. Each run, under its
own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of `FluxKlangTests/MIDIClockFollowerTests`,
`FluxKlangTests/MIDIClockMathTests`,
`FluxKlangTests/MIDIClockPulseScheduleTests` and
`FluxKlangTests/MIDIClockTempoTests`, carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no audit
issue recorded. These runs add no process-identity, argv or bootstrap evidence
and do not cover the iOS owners; the remaining #60 gates above still apply and
#60 remains open.

## MIDI clock tempo estimator, control pickup and package admission source adoption

`MIDIClockTempoEstimatorTests`, `ControlPickupTests`, `ControlPickupBookTests`
and `ProjectPackageAdmissionTests` now use the canonical trait under
`#if os(macOS)` on their root declarations, matching `GraphCompilerTests`,
without test-body, helper, target-membership or registration changes.
`ControlPickupBookTests` keeps its `"Control pickup book"` display name: the
trait is added to its existing `@Suite` in the macOS branch, the `#else`
branch keeps that `@Suite` unchanged, and its `+Limits` extension stays
unannotated. The `BookFx` and `ProjectPackageTestSupport` helper enums are not
suites and stay unannotated. Against the unmodified base (main `2d23cd7f`),
the complete source inventory retains all 4,872 registrations and moves 32
`FluxKlangMacTests` owner rows (eight per suite) to satisfied: 240 satisfied
rows instead of 208. The iOS `FluxKlangTests` rows for all four suites stay
unsatisfied and no other row changes. Diagnostics fall from 7,032 to 6,976
(16 removed for each
of the three suites that had no `@Suite`, and 8 for `ControlPickupBookTests`,
whose existing `@Suite` already met the single-macro requirement; none added).
Inventory still exits 0 and default enforcement still exits 1.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 113 repository sources from this change instead of extending the
MIDI clock fixture above. Seven are test sources: the four suites' five files,
`ControlBindingTests.swift` for the `ControlBindingTests` helpers that
`ControlPickupTests` uses, and `ProductionAccessScope.swift`. The other 106
are `Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: 43 `Shared/Contracts` sources (all but the two
`Transport/Snapshot` sources, `ClockGenerationSnapshot.swift` and
`ClockGenerationStaleness.swift`), 41 `Shared/Control` binding, pickup,
intake, availability, dispatch, Learn, trigger and feedback message and
encoding sources, the seven `Shared/MIDI/Clock` sources, the ten
`Shared/MIDI/Protocol/MIDI1` event, parser, semantic and state sources,
`Shared/WING/FaderMath.swift` and the `ProjectPackageAdmission`, limits and
path sources. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the four suites each
passed 59 tests (63 case invocations) in four suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of
`FluxKlangTests/MIDIClockTempoEstimatorTests`,
`FluxKlangTests/ControlPickupTests`, `FluxKlangTests/ControlPickupBookTests`
and `FluxKlangTests/ProjectPackageAdmissionTests`, carrying that run ID, with
all 14 operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no
audit issue recorded. These runs add no process-identity, argv or bootstrap
evidence and do not cover the iOS owners; the remaining #60 gates above still
apply and #60 remains open.

## MIDI clock arbitration, internal clock, MTC follower and metronome grid source adoption

`MIDIClockArbitrationTests`, `MIDIClockArbitrationSteadyRunTests`,
`MIDIInternalClockTests`, `MTCFollowerTests` and `MetronomeGridTests` now use
the canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. The two arbitration suites and `MTCFollowerTests` keep
their display names: the trait is added to each existing `@Suite` in the macOS
branch and the `#else` branch keeps that `@Suite` unchanged. Their `+`
extension files, `MIDIClockArbitrationTests+Jitter.swift`, the five
`MIDIInternalClockTests+` files, the seven `MTCFollowerTests+` files and the
two `MetronomeGridTests+` files, stay unannotated. The suites drive value types
with in-memory inputs and synthetic `HostStamp`, `HostTimebase` and clock map
fixtures: no file system, wall clock, sleep, dispatch, defaults, global state,
MIDI hardware or audio. `MetronomeGridTests` imports Foundation but uses only
standard library and repository value types. `MIDIClockArbitrationDropoutTests`
is equally pure but stays unadopted: its file is at SwiftLint's 500-line
`file_length` limit, so the guard would need a file split first.
`MIDIClockJitterTests`, `MTCEmitTests` and `ClockGenerationUnificationTests`
read repository sources from disk and stay unadopted. Against the unmodified
base (main `5702231c`), the complete source inventory retains all 4,888
registrations and moves 40 `FluxKlangMacTests` owner rows (eight per suite) to
satisfied: 288 satisfied rows instead of 248. The iOS `FluxKlangTests` rows for
all five suites stay unsatisfied and no other row changes. Diagnostics fall
from 6,992 to 6,936 (16 removed for each of `MIDIInternalClockTests` and
`MetronomeGridTests`, which had no `@Suite`, and 8 for each of the three suites
whose existing named `@Suite` already met the single-macro requirement; none
added). Inventory still exits 0 and default enforcement still exits 1. The
full base-versus-change checker diff ran on an earlier six-suite draft that
also annotated `MIDIClockArbitrationDropoutTests`; the final five-suite tree
was compared with the base by totals and per-suite counts only.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 132 repository sources from this change. Twenty-one are test
sources: the five suites' 20 root and extension files and
`ProductionAccessScope.swift`. The other 111 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: all 45 `Shared/Contracts` sources (including the two
`Transport/Snapshot` sources for `ClockGenerationSnapshot`), the 26
`Shared/MIDI/Clock` sources including `Arbitration`, `Internal` and `Jitter`,
the ten `Shared/MIDI/Protocol/MIDI1` sources, the 22 `Shared/MIDI/Timecode`
sources, the five `Shared/Media/Metronome` sources,
`Shared/MIDI/Performance/MIDIPerformanceIDs.swift` for `MIDIInputID` and
`Shared/WING/FaderMath.swift`. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the five suites each
passed 258 tests (263 case invocations) in five suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of `FluxKlangTests/MIDIClockArbitrationTests`,
`FluxKlangTests/MIDIClockArbitrationSteadyRunTests`,
`FluxKlangTests/MIDIInternalClockTests`, `FluxKlangTests/MTCFollowerTests` and
`FluxKlangTests/MetronomeGridTests`, carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no audit
issue recorded. These runs add no process-identity, argv or bootstrap evidence
and do not cover the iOS owners; the remaining #60 gates above still apply and
#60 remains open.

## MIDI clip timing, loop, continuity and SMF tempo import source adoption

`MIDIClipTimingTests`, `MIDIClipLoopTests`, `MIDIClipContinuityTests`,
`MIDIClipContinuityTempoTests` and `SMFTempoImportTests` now use the canonical
trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. All five keep their display names: the trait is added to
each existing `@Suite` in the macOS branch and the `#else` branch keeps that
`@Suite` unchanged. `MIDIClipLoopTests` and `MIDIClipContinuityTempoTests` are
separate root suites declared in `MIDIClipTimingTests+Loop.swift` and
`MIDIClipContinuityTests+Tempo.swift`; the nine `SMFTempoImportTests+`
extension files stay unannotated. The clip suites build `MIDIClip`,
`MIDIClipPlacement` and `MIDIClipScheduler` values over synthetic
`MusicalClockMap`, `ClockAnchor` and `HostStamp` fixtures, with the seeded
`MIDIClipSplitMix64` value generator for randomized cases. `SMFTempoImportTests`
feeds hand-built Standard MIDI File bytes to `SMFTempoScan` and
`StandardMIDIFile`. None of the five touches the file system, bundles, wall
clock, sleep, dispatch, defaults, global state, MIDI hardware or audio.
`MediaTapPlanTests`, `MediaBlockLedgerTests`, `MediaBlockPoolTests` and
`MediaIOWorkerTests` stay unadopted: they drive reference types rather than
value types (the `FanOutHandoff` fan-out, or a real `MediaBlockPool`, a class
over an unsafe sample buffer, and its leases). `MIDITimecodeTests` stays
unadopted because its 498-line root file would exceed SwiftLint's 500-line
`file_length` limit with the guard. Only this change was run through the
checker; the UARG7 tree was not re-run, and the comparison below uses its
recorded totals (4,888 registrations, 288 satisfied rows, 6,936 diagnostics).
The complete source inventory of this change retains all 4,888 registrations
and has 328 satisfied rows, 40 more than the UARG7 tree. The five suites' 40
`FluxKlangMacTests` root rows (eight per suite) are now satisfied, which
accounts for the whole increase. The iOS `FluxKlangTests` root rows for all
five suites stay unsatisfied, each with one annotation diagnostic. Diagnostics
fall by 40, from 6,936 to 6,896, which is consistent with one diagnostic
removed for each newly satisfied row. No `FluxKlangMacTests` diagnostic remains
for the five suites. Inventory still exits 0 and default enforcement still
exits 1. The two trees were compared by totals only; the per-suite counts come
from this change's output, not from a row-level diff.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 86 repository sources from this change. Fifteen are test sources:
the four MIDI clip suite files, the root and nine extension files of
`SMFTempoImportTests`, and `ProductionAccessScope.swift`. The other 71 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: all 45 `Shared/Contracts` sources, the ten
`Shared/MIDI/Protocol/MIDI1` sources, 14 `Shared/Media/Clips` sources (the
five root files, `SMF` and `Tempo`), and `Shared/WING/FaderMath.swift`. Debug
and Release (`-c release -Xswiftc -enable-testing`) runs filtered to the five
suites each passed 135 tests (145 case invocations) in five suites. Each run,
under its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment
to `--attachments-path` for each of `FluxKlangTests/MIDIClipTimingTests`,
`FluxKlangTests/MIDIClipLoopTests`, `FluxKlangTests/MIDIClipContinuityTests`,
`FluxKlangTests/MIDIClipContinuityTempoTests` and
`FluxKlangTests/SMFTempoImportTests`, carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no audit
issue recorded. These runs add no process-identity, argv or bootstrap evidence
and do not cover the iOS owners; the remaining #60 gates above still apply and
#60 remains open.

## MIDI 1 parser, control change decode and channel state source adoption

`MIDIProtocolTests`, `MIDIControlChangeDecodeTests`, `MIDI1ChannelStateTests`,
`MIDI1ParameterStateTests` and `MIDI1PerformanceSnapshotTests` now use the
canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. None of the five had a `@Suite`, so each gains
`@Suite(.productionAccessAudit)` in a macOS-only branch with no `#else`. The
three `MIDIControlChangeDecodeTests+` extension files stay unannotated, as do
the `MIDI1StateFixture` and `MIDI1SnapshotCorruption` helper enums, which are
not suites. The suites feed hand-built byte arrays and `MIDI1Event` and
`MIDI1Semantic` values to `MIDI1Parser`, `MIDIControlChange.decode` and
`MIDI1PerformanceState`; their fixtures are immutable file-scope or static
`let` values. The production closure is the ten `Shared/MIDI/Protocol/MIDI1`
value sources plus `MIDIControlChange`, whose `decode` only drives
`MIDI1Parser`. `MIDIControlChange` shares
`Shared/Models/LaunchControlXLConfiguration.swift` with a bundle-loading
`LaunchControlXLConfiguration.bundled()`, which these suites never call. None
of the five touches the file system, bundles, wall clock, sleep, dispatch,
defaults, global mutable state, MIDI hardware or audio.
`MIDIInputSessionTests`, `MIDICapabilityNegotiationTests` and
`ControlFeedbackMIDI1Tests` stay unadopted because they or their extension
files read repository sources from disk through `#filePath` and
`FileManager`. The UMP codec and translation suites were not reviewed for this
batch and stay unadopted. `MIDITimecodeTests` and
`MIDIClockArbitrationDropoutTests` still stay unadopted for the
`file_length` reasons above. Only this change was run through the checker; the
UARG8 tree was not re-run, and the comparison below uses its recorded totals
(4,888 registrations, 328 satisfied rows, 6,896 diagnostics). The complete
source inventory of this change retains all 4,888 registrations and has 368
satisfied rows, 40 more than the UARG8 tree. The five suites' 40
`FluxKlangMacTests` root rows (eight per suite) are now satisfied, which
accounts for the whole increase. The iOS `FluxKlangTests` root rows for all
five suites stay unsatisfied. Diagnostics fall by 80, from 6,896 to 6,816
(16 removed per suite, as none had a `@Suite`; none added). Inventory
still exits 0 and default enforcement still exits 1. The two trees were
compared by totals only; the per-suite counts come from this change's output,
not from a row-level diff.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 21 repository sources from this change. Nine are test sources: the
five suites' root files, the three `MIDIControlChangeDecodeTests+` extension
files and `ProductionAccessScope.swift`. The other 12 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: the ten `Shared/MIDI/Protocol/MIDI1` sources and
`Shared/Models/LaunchControlXLConfiguration.swift`. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the five suites each
passed 71 tests (437 case invocations) in five suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of `FluxKlangTests/MIDIProtocolTests`,
`FluxKlangTests/MIDIControlChangeDecodeTests`,
`FluxKlangTests/MIDI1ChannelStateTests`,
`FluxKlangTests/MIDI1ParameterStateTests` and
`FluxKlangTests/MIDI1PerformanceSnapshotTests`, carrying that run ID, with all
14 operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no
audit issue recorded. These runs add no process-identity, argv or bootstrap
evidence and do not cover the iOS owners; the remaining #60 gates above still
apply and #60 remains open.

## UMP codec and MIDI 1 translation source adoption

`UMPPacketFramingTests`, `UMPChannelVoiceTests`, `UMPScalingTests`,
`UMPTranslationTests`, `UMPTranslationStateTests` and
`UMPTranslationDataEntryTests` now use the canonical trait under
`#if os(macOS)` on their root declarations, matching `GraphCompilerTests`,
without test-body, helper, target-membership or registration changes. All six
keep their display names: the trait is added to each existing `@Suite` in the
macOS branch and the `#else` branch keeps that `@Suite` unchanged. The six are
separate root suites declared in `UMPCodecTests.swift`,
`UMPCodecTests+ChannelVoice.swift`, `UMPCodecTests+Scaling.swift`,
`UMPTranslationTests.swift`, `UMPTranslationTests+State.swift` and
`UMPTranslationTests+DataEntry.swift`; none has extension files. The
file-private `UMPFixture` and `UMPMT4Vector` helpers are not suites and stay
unannotated. The suites feed hand-built words, bytes, `MIDI1Event` and
`MIDI1Semantic` values to `UMPPacket`, `UMPStreamSplitter`, the
`UMPMIDI1ChannelVoice` and `UMPMIDI2ChannelVoice` codecs, `UMPScaling` and
the `UMPMIDI1ToMIDI2Translator` and `UMPMIDI2ToMIDI1Translator` value types;
their fixtures are static `let` values or static helper functions. The
production closure is the six top-level `Shared/MIDI/Protocol/UMP` sources,
the four `UMP/Translation` sources outside `Stream` and the ten
`Shared/MIDI/Protocol/MIDI1` sources, none of which imports a module. None of
the six touches the file system, bundles, wall clock, sleep, dispatch,
defaults, global mutable state, MIDI hardware or audio. `UMPStreamMessageTests`
(with its four extension files), `UMPTranslationStreamTests` and
`UMPTranslationStreamPropertyTests` stay unadopted only to keep this batch to
six suites. A grep of their files and of the `UMP/StreamMessages` and
`UMP/Translation/Stream` sources they reach found none of those APIs, but they
were not otherwise reviewed or run through the fixture.
`MIDIInputSessionTests`, `MIDICapabilityNegotiationTests` and
`ControlFeedbackMIDI1Tests` still stay unadopted for the `#filePath` reasons
above, and `MIDITimecodeTests` and `MIDIClockArbitrationDropoutTests` for the
`file_length` reasons above. Only this change was run through the checker; the
UARG9 tree was not re-run, and the comparison below uses its recorded totals
(4,888 registrations, 368 satisfied rows, 6,816 diagnostics). The complete
source inventory of this change retains all 4,888 registrations and has 416
satisfied rows, 48 more than the UARG9 tree. The six suites' 48
`FluxKlangMacTests` root rows (eight per suite) are now satisfied, which
accounts for the whole increase. The iOS `FluxKlangTests` root rows for all
six suites stay unsatisfied, each with one annotation diagnostic. Diagnostics
fall by 48, from 6,816 to 6,768 (eight removed per suite, as each had a named
`@Suite`; none added). Inventory still exits 0 and default enforcement still
exits 1. The two trees were compared by totals only; the per-suite counts come
from this change's output, not from a row-level diff.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 28 repository sources from this change. Seven are test sources:
the six suites' files and `ProductionAccessScope.swift`. The other 21 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: the six top-level `Shared/MIDI/Protocol/UMP` sources, the four
`UMP/Translation` sources outside `Stream` and the ten
`Shared/MIDI/Protocol/MIDI1` sources. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the six suites each
passed 81 tests (none parameterized) in six suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of `FluxKlangTests/UMPPacketFramingTests`,
`FluxKlangTests/UMPChannelVoiceTests`, `FluxKlangTests/UMPScalingTests`,
`FluxKlangTests/UMPTranslationTests`,
`FluxKlangTests/UMPTranslationStateTests` and
`FluxKlangTests/UMPTranslationDataEntryTests`, carrying that run ID, with all
14 operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no
audit issue recorded. These runs add no process-identity, argv or bootstrap
evidence and do not cover the iOS owners; the remaining #60 gates above still
apply and #60 remains open.

## Show, MPE, tuner and OSC source adoption

`ShowNavigationTests`, `ShowNavigationCursorTests`, `ShowNavigationLinkTests`,
`ShowTransitionTests`, `ShowTransitionWalkTests`, `ShowFootInputTests`,
`ShowFootInputRefusalTests`, `ShowFootSessionTests`, `MPEZoneTests`,
`TunerPitchTests`, `TunerSmootherTests`, `OpenSoundControlCodecTests`,
`OpenSoundControlFramingTests` and `OSCNamespaceTests` now use the canonical
trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. `ShowNavigationTests`, `ShowNavigationCursorTests`,
`ShowNavigationLinkTests`, `ShowTransitionTests`, `ShowTransitionWalkTests` and
`MPEZoneTests` had no `@Suite` and gain a bare `@Suite(.productionAccessAudit)`
inside `#if os(macOS)`. The other eight keep their display names: the trait is
added to each existing `@Suite` in the macOS branch and the `#else` branch keeps
that `@Suite` unchanged. None of the fourteen has other suite traits. Each is a
separate root `struct` in its own file (`ShowNavigationTests.swift`,
`ShowNavigationTests+Cursor.swift`, `ShowNavigationTests+Links.swift`,
`ShowTransitionTests.swift`, `ShowTransitionWalkTests.swift`,
`ShowFootInputTests.swift`, `ShowFootInputTests+Refusals.swift`,
`ShowFootSessionTests.swift`, `MPEZoneTests.swift`, `TunerPitchTests.swift`,
`TunerPitchTests+Smoother.swift`, `OpenSoundControlCodecTests.swift`,
`OpenSoundControlCodecTests+Framing.swift` and `OSCNamespaceTests.swift`). Their
extensions stay unannotated: `MPEZoneTests+Allocator.swift`, `+Expression.swift`
and `+Config.swift`; `TunerPitchTests+Fixtures.swift`; the five
`OSCNamespaceTests+*.swift` files (`Arguments`, `Grammar`, `Liveness`,
`Precedence`, `Routes`); and the in-file extensions of
`ShowNavigationCursorTests` and `OpenSoundControlCodecTests`. The fixture enums,
rigs and seeded SplitMix generators (`ShowNavigationTestFixture`,
`ShowTransitionTestFixture`, `ShowFootInputFixture`, `ShowFootInputRig`,
`OpenSoundControlFixture`, `OSCNamespaceFixture` and the like) are not suites
and stay unannotated. The suites build show libraries, setlists, cursors,
footswitch maps, MPE zones, synthetic sample buffers and OSC packets from
literals and seeded generators, and drive the `Shared/Performance/Shows`
planners, cursor, walk and foot-input session, the `Shared/Control/Triggers`
detector, the `Shared/MIDI/Performance/MPE` model, the
`Shared/Media/Utilities/Tuner` estimator and smoother, and the `Shared/OSC`
codec, framer and namespace mapper. The production closure the fixture needed
also takes in value types from `Shared/Contracts`, `Shared/Control/Bindings`,
`Shared/Host/Authority`, `Shared/Performance/Actions`,
`Shared/Performance/Patches`, two `Shared/MIDI/Protocol/MIDI1` sources and
`Shared/WING/FaderMath.swift`. No source in it imports anything but Foundation;
its only `static var` members are computed, and its only classes are three
stateless `fileprivate final class Identity` tokens in `Shared/Host/Authority`.
`OpenSoundControl+WallClock.swift` maps injected instants and reads no clock.
None of the fourteen suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio. Only
this change was run through the checker; the UARG10 tree was not re-run, and the
comparison below uses its recorded totals (4,888 registrations, 416 satisfied
rows, 6,768 diagnostics). The complete source inventory of this change retains
all 4,888 registrations and has 528 satisfied rows, 112 more than the UARG10
tree. The fourteen suites' 112 `FluxKlangMacTests` root rows (eight per suite)
are now satisfied, which accounts for the whole increase. The iOS
`FluxKlangTests` root rows for all fourteen suites stay unsatisfied. Diagnostics
fall by 160, from 6,768 to 6,608: sixteen removed for each of the six suites
that had no `@Suite` and eight for each of the eight named suites; none added.
Inventory still exits 0 and default enforcement still exits 1. The two trees
were compared by totals only; the per-suite counts come from this change's
output, not from a row-level diff.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 145 repository sources from this change. 24 are test sources: the
fourteen suites' files, their nine extension files and
`ProductionAccessScope.swift`. The other 121 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production closure:
all of `Shared/Performance/Shows` (28 sources), `Shared/OSC` (26),
`Shared/Control/Triggers` (3), `Shared/MIDI/Performance/MPE` (5) and
`Shared/Media/Utilities/Tuner` (5), plus the 53 further sources from the other
directories named above that the build required. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the fourteen suites
each passed 309 tests (five parameterized, 56 cases) in fourteen suites. Each
run, under its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit`
attachment to `--attachments-path` for each of the fourteen suites
(`FluxKlangTests/` plus the suite name), carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no audit
issue recorded. These runs add no process-identity, argv or bootstrap evidence
and do not cover the iOS owners; the remaining #60 gates above still apply and
#60 remains open.

## Wiring editor source adoption

`WiringNodeEditTests`, `WiringPreviewTests`, `WiringReviewDiffTests`,
`WiringEditPathTests`, `WiringEditPathEquivalenceTests`, `WiringComposeTests`,
`WiringDestinationListTests` and `WiringMatrixTests` now use the canonical
trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. All eight keep their display names: the trait is added
to each existing `@Suite` in the macOS branch and the `#else` branch keeps that
`@Suite` unchanged. None of the eight has other suite traits. Each is a
separate root `struct` (`WiringNodeEditTests.swift`,
`WiringPreviewTests.swift`, `WiringPreviewTests+Diff.swift`,
`WiringEditPathTests.swift`, `WiringEditPathTests+Equivalence.swift`,
`WiringComposeTests.swift`, `WiringComposeTests+Destinations.swift` and
`WiringMatrixTests.swift`); the longest root file,
`WiringEditPathTests.swift`, grows from 487 to 491 lines, under the 500-line
`file_length` limit. Their extensions stay unannotated:
`WiringNodeEditTests+Add.swift`, `+Remove.swift` and `+Order.swift`;
`WiringEditPathTests+Quantization.swift`; `WiringMatrixTests+EdgeBound.swift`;
and the `WiringDestinationListTests` extensions in
`WiringComposeTests+Bulk.swift` and at the end of
`WiringComposeTests+Destinations.swift`. The fixture enums
(`WiringPreviewFixture`, `WiringEditFixture`, `WiringComposeFixture` and the
file-private bound, seed and graph fixtures) and the seeded SplitMix
generators are not suites and stay unannotated. The suites build graph
documents, drafts and edits from literals and seeded generators and drive the
`Shared/Wiring` composers, candidate classifier, review diff, destination
list and matrix. Their only `static var` members are computed (such as
`WiringPreviewFixture.graph` and `WiringComposeFixture.monoLoop`); their only
class is a local `ValidationCount: @unchecked Sendable` counter guarded by an
`NSLock`, created per test in `WiringMatrixTests+EdgeBound.swift`. The
production closure the fixture needed is all of `Shared/Wiring` plus value
types from `Shared/Contracts/Graph`, `Shared/Contracts/Core`,
`Shared/Contracts/Devices`, `Shared/Contracts/Project` and
`Shared/Drafts/History`. No source in it imports anything but Foundation, and
it declares no classes. Its only stored `static var` is
`@TaskLocal static var observer` on `WiringCandidateValidationObserver` in
`Shared/Wiring/Preview/WiringCandidateClassifier.swift`: a task-local,
test-only validation-count hook that is `nil` unless a test binds it with
`withValue`, so it is not shared mutable state. None of the eight suites
touches the file system, bundles, wall clock, sleep, dispatch, defaults,
global mutable state, MIDI hardware, network or audio. `WiringInspectorTests`,
`WiringSelectionTests`, `WiringProblemListTests` and `WiringImpactTests` stay
unadopted because they read repository sources through `#filePath` or
`FileManager`; `WiringConnectionListTests` already had the trait.

Only this change was run through the checker; the UARG11 tree was not re-run,
and the comparison below uses its recorded totals (4,888 registrations, 528
satisfied rows, 6,608 diagnostics). The complete source inventory of this
change retains all 4,888 registrations and has 592 satisfied rows (552
`FluxKlangMacTests`, 40 `FluxKlangTests`), 64 more than the UARG11 tree. The
eight suites' 64 `FluxKlangMacTests` root rows (eight per suite) are now
satisfied, which accounts for the whole increase. The iOS `FluxKlangTests`
root rows for all eight suites stay unsatisfied, each with one annotation
diagnostic. Diagnostics fall by 64, from 6,608 to 6,544 (eight removed per
suite, as each had a named `@Suite`; none added). Inventory still exits 0 and
default enforcement still exits 1. The two trees were compared by totals
only; the per-suite counts come from this change's output, not from a
row-level diff.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 73 repository sources from this change. 15 are test sources: the
eight suites' files, their six extension-only files and
`ProductionAccessScope.swift`. The other 58 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: all of `Shared/Wiring` (39 sources) plus the 18 further sources from
the other directories named above that the build required. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the eight suites each
passed 167 tests (none parameterized) in eight suites. Each run, under its own
fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of the eight suites (`FluxKlangTests/` plus the
suite name), carrying that run ID, with all 14 operation IDs reporting zero
`apiEntered` and `factoryEvaluated` and no audit issue recorded. These runs
add no process-identity, argv or bootstrap evidence and do not cover the iOS
owners; the remaining #60 gates above still apply and #60 remains open.

## UMP stream, MIDI machine control, timecode and clock dropout source adoption

`UMPStreamMessageTests`, `UMPTranslationStreamTests`,
`UMPTranslationStreamPropertyTests`, `MIDIMachineControlTests`,
`MIDITimecodeTests` and `MIDIClockArbitrationDropoutTests` now use the
canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. All six keep their display names: the trait is added
to each existing `@Suite` in the macOS branch and the `#else` branch keeps
that `@Suite` unchanged. None of the six has other suite traits. Each is a
separate root `struct` (`UMPStreamMessageTests.swift`,
`UMPTranslationStreamTests.swift`, `UMPTranslationStreamTests+Property.swift`,
`MIDITimecodeTests+MMC.swift`, `MIDITimecodeTests.swift` and
`MIDIClockArbitrationTests+Dropout.swift`). This supersedes the earlier
sections' notes that these suites stay unadopted. UPREP1 (#556) has since
split the two files the UARG7 and UARG8 sections held back for
`file_length`: `MIDITimecodeTests.swift` grows from 415 to 419 lines and
`MIDIClockArbitrationTests+Dropout.swift` from 424 to 428, both under the
500-line limit. Their extensions stay unannotated:
`UMPStreamMessageTests+Decode.swift`, `+Hostile.swift`, `+ProductID.swift`
and `+Text.swift`; `MIDITimecodeTests+NibbleJoin.swift`; and
`MIDIClockArbitrationTests+DropoutEdgeCases.swift`. The file-private seeded
SplitMix generators (`UMPStreamHostileGenerator` and
`StreamPropertyGenerator`), the `GroupProbe` decode helper, the stream
property script and the timecode `Label`, `ByteFault` and `ExpectedPosition`
helpers are not suites and stay unannotated. The suites feed hand-built
words, bytes, `MIDI1Event` values and synthetic nanosecond or `HostStamp`
times to the `UMP/StreamMessages` codec and text assembler,
`UMPTranslationStream`, the `MMCMessage` codec, `MTCAssembler`,
`MTCQuarterFrame` and `SMPTETime`, and
`MIDIClockLeaderArbiter`. Their only `static var` member is the computed
`UMPStreamMessageTests.samples`; their file-scope values are `private let`.
The production closure the fixture needed is all of `Shared/Contracts`,
`Shared/MIDI/Clock`, `Shared/MIDI/Timecode` and `Shared/MIDI/Protocol` (the
`MIDI1` and `UMP` sources), plus
`Shared/MIDI/Performance/MIDIPerformanceIDs.swift` and
`Shared/WING/FaderMath.swift`. No source in it imports anything but
Foundation; its only `static var` members are computed or protocol
requirements, and its only class is the stateless
`fileprivate final class Identity` token in `TriggerSession.swift`. None of
the six suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio.

Only this change was run through the checker; the UARG12 tree was not re-run,
and the comparison below uses its recorded totals (4,888 registrations, 592
satisfied rows, 6,544 diagnostics). The complete source inventory of this
change retains all 4,888 registrations and has 640 satisfied rows (600
`FluxKlangMacTests`, 40 `FluxKlangTests`), 48 more than the UARG12 tree. The
six suites' 48 `FluxKlangMacTests` root rows (eight per suite) are now
satisfied, which accounts for the whole increase. The iOS `FluxKlangTests`
root rows for all six suites stay unsatisfied, each with one annotation
diagnostic. Diagnostics fall by 48, from 6,544 to 6,496 (eight removed per
suite, as each had a named `@Suite`; none added). Inventory still exits 0
and default enforcement still exits 1. The two trees were compared by totals
only; the per-suite counts come from this change's output, not from a
row-level diff.

A fresh SwiftPM package (default build system, no private witness or observer)
byte-copied 151 repository sources from this change. 13 are test sources: the
six suites' files, their six extension-only files and
`ProductionAccessScope.swift`. The other 138 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: the 58 `Shared/Contracts`, 26 `Shared/MIDI/Clock`, 22
`Shared/MIDI/Timecode`, 19 `Shared/MIDI/Protocol/UMP` and ten
`Shared/MIDI/Protocol/MIDI1` sources, `MIDIPerformanceIDs.swift` and
`FaderMath.swift`. Debug and Release (`-c release -Xswiftc -enable-testing`)
runs filtered to the six suites each passed 147 tests (seven parameterized,
23 cases) in six suites. Each run, under its own fresh
`FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of the six suites (`FluxKlangTests/` plus the
suite name), carrying that run ID, with all 14 operation IDs reporting zero
`apiEntered` and `factoryEvaluated` and no audit issue recorded. These runs
add no process-identity, argv or bootstrap evidence and do not cover the iOS
owners; the remaining #60 gates above still apply and #60 remains open.

## Control binding, trigger, learn and input gate source adoption

`ControlBindingTests`, `ControlBindingGroupTests`, `ControlHostTruthTests`,
`ControlTriggerTests`, `ControlTriggerClearTests`,
`ControlTriggerDetectorTests`, `ControlLearnTests`,
`ControlLearnConflictTests` and `ControlInputGateTests` now use the
canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. None of the nine had a `@Suite`, so each gains a bare
`@Suite(.productionAccessAudit)` in a macOS-only branch with no `#else`,
after any doc comment. Each is a separate root `struct`
(`ControlBindingTests.swift`, `ControlBindingGroupTests.swift`,
`ControlHostTruthTests.swift`, `ControlTriggerTests.swift`,
`ControlTriggerTests+Clear.swift`, `ControlTriggerTests+Detector.swift`,
`ControlLearnTests.swift`, `ControlLearnTests+Conflicts.swift` and
`ControlInputGateTests.swift`). Their extensions stay unannotated:
`ControlBindingTests+Coverage.swift`, the four `ControlInputGateTests+`
files (`Counters`, `Listening`, `Phases` and `Refusals`) and the in-file
extensions of `ControlBindingTests`, `ControlBindingGroupTests` and
`ControlHostTruthTests`. The file-private `ClearSeededGenerator` and the
nested `ControlInputGateTests.Phased` fixture are not suites and stay
unannotated. Several suites borrow fixtures from another of the nine through
a `Fixture` or `Truth` type alias; `ControlPickupTests`, adopted earlier,
also uses `ControlBindingTests` helpers. The suites build bindings, groups,
host truth, trigger detectors, Learn sessions and input gates from literals,
static `let` identifiers, injected integer ticks and the seeded generator,
and drive the `Shared/Control/Bindings`, `Triggers`, `Learn` and
`Learn/Gate` value types. Their only `static var` member is the computed
`ControlBindingTests.encoder2Fields`. The production closure the fixture
copied is all of `Shared/Contracts`, the ten `Shared/MIDI/Protocol/MIDI1`
sources, the `Shared/Control` `Bindings` (with `Intake` and `Pickup` but
not `Availability`), `Triggers` and `Learn` (with `Gate`) sources, and
`Shared/WING/FaderMath.swift`. No source in it imports anything
but Foundation; its only `static var` members are computed or protocol
requirements, and its only class is the stateless
`fileprivate final class Identity` token in `TriggerSession.swift`. None of
the nine suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio.

Against the unmodified UARG13 tree, both checker modes report 4,888
registrations. Satisfied rows rise from 640 (600 `FluxKlangMacTests`, 40
`FluxKlangTests`) to 712 (672 `FluxKlangMacTests`, 40 `FluxKlangTests`).
The nine suites' 72 `FluxKlangMacTests` root rows (eight per suite) are now
satisfied, which accounts for the whole increase; no row is removed.
Diagnostics fall by 144, from 6,496 to 6,352: sixteen removed per suite,
as none had a `@Suite`, and none added. The iOS `FluxKlangTests` root rows
for all nine suites stay unsatisfied, with two diagnostics per row
(sixteen per suite). Inventory still exits 0 and default enforcement still
exits 1. Unlike the previous sections, this comparison is a row-level diff
of both trees' output.

A fresh SwiftPM package (default build system, no private witness or
observer) byte-copied 114 repository sources from this change. 15 are test
sources: the nine suites' files, their five extension-only files and
`ProductionAccessScope.swift`. The other 99 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: the 58 `Shared/Contracts`, 29 `Shared/Control` and ten
`Shared/MIDI/Protocol/MIDI1` sources and `FaderMath.swift`. Debug and
Release (`-c release -Xswiftc -enable-testing`) runs filtered to the nine
suites each passed 136 tests (four parameterized, eight cases) in nine
suites. Each run, under its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one
`suiteExit` attachment to `--attachments-path` for each of the nine suites
(`FluxKlangTests/` plus the suite name), carrying that run ID, with all 14
operation IDs reporting zero `apiEntered` and `factoryEvaluated` and no
audit issue recorded. The Debug console log lists all 136 tests as passed.
A first Release run's console log dropped most per-test lines, so Release
was re-run with `--xunit-output` and `--event-stream-output-path`: its
xUnit report lists 136 test cases with no failures or skips, and its event
stream ends all 136 test functions and nine suites with no issue events.
These runs add no process-identity, argv or bootstrap evidence and do not
cover the iOS owners; the remaining #60 gates above still apply and #60
remains open.

## Control bank, dispatch, feedback and MIDI intake source adoption

`ControlInputBankTests`, `ControlSourceAvailabilityTests`,
`ControlLocalTriggerDispatchTests`, `ControlFeedbackTests`,
`MIDIControlIntakeTests`, `ActiveSensingTests` and `MIDISourceRegistryTests`
now use the canonical trait under `#if os(macOS)` on their root
declarations, matching `GraphCompilerTests`, without test-body, helper,
target-membership or registration changes. All seven keep their display
names: the trait is added to each existing `@Suite` in the macOS branch and
the `#else` branch keeps that `@Suite` unchanged. None of the seven has
other suite traits. Each is a separate root `struct` in its own file
(`ControlInputBankTests.swift`, `ControlSourceAvailabilityTests.swift`,
`ControlLocalTriggerDispatchTests.swift`, `ControlFeedbackTests.swift`,
`MIDIControlIntakeTests.swift`, `ActiveSensingTests.swift` and
`MIDISourceRegistryTests.swift`); the longest root file,
`ControlLocalTriggerDispatchTests.swift`, grows from 487 to 491 lines,
under the 500-line `file_length` limit. Their extensions stay unannotated:
`ControlInputBankTests+Lifecycle.swift`; the three `ControlFeedbackTests+`
files (`Corrections`, `Echo` and `TouchHold`) and the in-file extensions of
`ControlFeedbackTests`; the six `MIDIControlIntakeTests+` files (`Bounds`,
`Determinism`, `Goldens`, `Keys`, `Precedence` and `Widths`); the three
`ActiveSensingTests+` files (`Arming`, `Refusal` and `Timeout`); and the
four `MIDISourceRegistryTests+` files (`Bounds`, `Endpoint`, `Isolation`
and `Reset`). The nested `ControlInputBankTests.Fx` and
`MIDIControlIntakeTests.LaunchControl` fixtures and the file-private `Fx`
and `Seen` helpers of `ControlLocalTriggerDispatchTests` are not suites and
stay unannotated. Each suite uses only its own fixtures; none borrows a
helper from another test file. The suites build bindings, links, host
truth, MIDI 1 state updates and byte streams from literals, static `let`
identifiers, injected integer ticks or `HostStamp` values and a seeded
integer stream, and drive the `Shared/Control` `Bank`, `Availability`,
`Dispatch`, `Feedback` and `Intake` value types,
`ActiveSensingObserver` and `MIDISourceRegistry`. They declare no
`static var` members. `ControlFeedbackTests` and `MIDIControlIntakeTests`
import Foundation; the only Foundation API either uses is
`String(format:)` in one feedback fixture. The production closure the
fixture copied is all of `Shared/Contracts`, the ten
`Shared/MIDI/Protocol/MIDI1` sources, the `Shared/Control` sources except
`ProgramRecall`, the six `Shared/MIDI/IO/Registry` sources, the three
`Shared/MIDI/Performance/Sensing` and three `Curves` sources,
`MIDIPerformanceIDs.swift`, `MIDIRouting.swift`,
`MIDI1Semantic+Routing.swift`,
`Shared/Performance/Automation/AutomationArbitration.swift` and
`Shared/WING/FaderMath.swift`. No source in it imports anything but
Foundation; its only `static var` members are computed or protocol
requirements, and its only class is the stateless
`fileprivate final class Identity` token in `TriggerSession.swift`. None
of the seven suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio.
`ControlFeedbackMIDI1Tests` and `ControlLocalDispatchTests` stay unadopted
because their `+RoundTrip` and `+Composition` extension files read
repository sources through `#filePath`.

Against the unmodified UARG14 tree, both checker modes report 4,888
registrations. Satisfied rows rise from 712 (672 `FluxKlangMacTests`, 40
`FluxKlangTests`) to 768 (728 `FluxKlangMacTests`, 40 `FluxKlangTests`).
The seven suites' 56 `FluxKlangMacTests` root rows (eight per suite) are
now satisfied, which accounts for the whole increase; no row is removed.
Diagnostics fall by 56, from 6,352 to 6,296: eight removed per suite, as
each had a named `@Suite`, and none added. The iOS `FluxKlangTests` root
rows for all seven suites stay unsatisfied, with one diagnostic per row
(eight per suite). Apart from the Mac rows' status, the only row change,
in both modules, is that test line numbers in the six root files that
declare tests shift by four; `MIDISourceRegistryTests.swift` declares
none. Inventory still exits 0 and default enforcement still exits 1. This
comparison is a row-level diff of both trees' output.

A fresh SwiftPM package (default build system, no private witness or
observer) byte-copied 156 repository sources from this change. 25 are test
sources: the seven suites' files, their 17 extension-only files and
`ProductionAccessScope.swift`. The other 131 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: the 58 `Shared/Contracts`, 45 `Shared/Control`, ten
`Shared/MIDI/Protocol/MIDI1`, six `Shared/MIDI/IO/Registry` and nine
`Shared/MIDI/Performance` sources, `AutomationArbitration.swift` and
`FaderMath.swift`. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the seven suites
each passed 317 tests (none parameterized) in seven suites, with
`--xunit-output` and `--event-stream-output-path`. Each xUnit report lists
317 test cases with no failures or skips, and each event stream ends all
317 test functions and seven suites with no issue events. Each run, under
its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of the seven suites (`FluxKlangTests/` plus
the suite name), carrying that run ID, with all 14 operation IDs reporting
zero `apiEntered` and `factoryEvaluated` and no audit issue recorded.
These runs add no process-identity, argv or bootstrap evidence and do not
cover the iOS owners; the remaining #60 gates above still apply and #60
remains open.

## Standard MIDI File, MIDI capture and timecode machine source adoption

`StandardMIDIFileTests`, `StandardMIDIFileReaderTests`,
`CaptureSMFExportTests`, `MIDICaptureExportTests`, `MIDICaptureClockTests`,
`MIDICaptureProtocolTests`, `MIDICaptureRestartTests` and
`TimecodeMachineTests` now use the canonical trait under `#if os(macOS)` on
their root declarations, matching `GraphCompilerTests`, without test-body,
helper, target-membership or registration changes. All eight keep their
display names: the trait is added to each existing `@Suite` in the macOS
branch and the `#else` branch keeps that `@Suite` unchanged. None of the
eight has other suite traits. Each is a separate root `struct`
(`StandardMIDIFileTests.swift`, `StandardMIDIFileTests+Reader.swift`,
`CaptureSMFExportTests.swift`, `MIDICaptureExportTests.swift`,
`MIDICaptureExportTests+Clock.swift`, `MIDICaptureExportTests+Protocol.swift`,
`MIDICaptureExportTests+Restart.swift` and `TimecodeMachineTests.swift`);
the longest root file, `MIDICaptureExportTests+Clock.swift`, grows from 457
to 461 lines, under the 500-line `file_length` limit. Their extensions stay
unannotated: the in-file extension of `StandardMIDIFileTests`; the six
`CaptureSMFExportTests+` files (`Bounds`, `Fixture`, `Groups`, `Losses`,
`Order` and `Pairing`); `MIDICaptureExportTests+V1Capture.swift`; and the
four `TimecodeMachineTests+` files (`Authorization`, `Gate`, `SendGrant`
and `TempoSharing`). The nested `CaptureSMFExportTests.Fixture`, the shared
`MIDICaptureFixture` enum, the file-private `MIDICaptureProtocolRow` and
`protocolTable`, and the file-private `TempoRecorder` are not suites and
stay unannotated. The three `MIDICapture` suites split from
`MIDICaptureExportTests` share its `MIDICaptureFixture`, and
`MIDICaptureRestartTests` calls the `MIDICaptureExportTests.json` helper.
`StandardMIDIFileTests` and `StandardMIDIFileReaderTests` alias
`MIDIClipTimingTests`, adopted earlier, for clip fixtures;
`StandardMIDIFileTests` also uses its seeded `MIDIClipSplitMix64` and
`MIDICaptureFixture`. The suites build bytes, `UMPPacket` words, MMC
messages and grants from literals and drive `StandardMIDIFile`, the
`Shared/Media/Clips` `Capture`, `Export`, `SMF` and `Tempo` value types and
the `Shared/MIDI/Timecode/Machine` gate, authorization, send builder and
tempo-sharing seam, over synthetic `HostStamp`, `SampleStamp`,
`ClockAnchor` and `MusicalClockMap` values. They declare no `static var`
members. Only `TimecodeMachineTests+TempoSharing.swift` imports anything
beyond Testing: Synchronization, for the `Mutex` call log owned by each
`TempoRecorder` instance, which a test creates locally; no recorder is
shared. The production closure the fixture copied is all of
`Shared/Contracts`, `Shared/MIDI/Protocol/MIDI1`, `Shared/MIDI/Protocol/UMP`
and `Shared/MIDI/Timecode`, `Shared/Media/Clips` except `Ownership`, and
`Shared/WING/FaderMath.swift`. No source in it imports anything but
Foundation; the two `V1Record` capture sources use it for `Data` and
`String(format:)`. Its only `static var` members are computed or protocol
requirements, and its only class is the stateless
`fileprivate final class Identity` token in
`TriggerSession.swift`. None of the eight suites touches the file system,
bundles, wall clock, sleep, dispatch, defaults, global mutable state, MIDI
hardware, network or audio.

Against the unmodified UARG15 tree, both checker modes report 4,888
registrations. Satisfied rows rise from 768 (728 `FluxKlangMacTests`, 40
`FluxKlangTests`) to 832 (792 `FluxKlangMacTests`, 40 `FluxKlangTests`).
The eight suites' 64 `FluxKlangMacTests` root rows (eight per suite) are
now satisfied, which accounts for the whole increase; no row is removed.
Diagnostics fall by 64, from 6,296 to 6,232: eight removed per suite, as
each had a named `@Suite`, and none added. The iOS `FluxKlangTests` root
rows for all eight suites stay unsatisfied, with one diagnostic per row
(eight per suite). Apart from the Mac rows' status, the only row change,
in both modules, is that test line numbers in the eight root files shift
by four. Inventory still exits 0 and default enforcement still exits 1.
This comparison is a row-level diff of both trees' output.

A fresh SwiftPM package (default build system, no private witness or
observer) byte-copied 161 repository sources from this change. 21 are test
sources: the eight suites' files, their 11 extension-only files,
`MIDIClipTimingTests.swift` and `ProductionAccessScope.swift`. The other
140 are `Shared/Store/ProductionAccessAudit.swift` and the in-memory
production closure: the 58 `Shared/Contracts`, ten
`Shared/MIDI/Protocol/MIDI1`, 21 `Shared/MIDI/Protocol/UMP`, 22
`Shared/MIDI/Timecode` and 27 `Shared/Media/Clips` sources and
`FaderMath.swift`. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs filtered to the eight suites
each passed 208 tests (two parameterized, 13 cases) in eight suites, with
`--xunit-output` and `--event-stream-output-path`. Each xUnit report lists
208 test cases with no failures or skips, and each event stream ends all
208 test functions and eight suites with no issue events. Each run, under
its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of the eight suites (`FluxKlangTests/` plus
the suite name), carrying that run ID, with all 14 operation IDs reporting
zero `apiEntered` and `factoryEvaluated` and no audit issue recorded.
`MIDIClipTimingTests` was compiled for its helpers but filtered out.
These runs add no process-identity, argv or bootstrap evidence and do not
cover the iOS owners; the remaining #60 gates above still apply and #60
remains open.

## Automation rendering and action-set submission source adoption

`AutomationBankTests`, `AutomationRenderTests`,
`AutomationRenderHandbackTests`, `AutomationRenderLoopTests`,
`AutomationRenderTempoTests`, `ActionSetSubmissionTests`,
`ActionSetSubmissionAdmissionTests` and `ActionSetSubmissionCancelTests` now
use the canonical trait under `#if os(macOS)` on their root declarations,
matching `GraphCompilerTests`, without test-body, helper, target-membership
or registration changes. All eight keep their display names: the trait is
added to each existing `@Suite` in the macOS branch and the `#else` branch
keeps that `@Suite` unchanged. None of the eight has other suite traits.
Each is a separate root `struct` (`AutomationBankTests.swift`,
`AutomationRenderTests.swift`, `AutomationRenderTests+Handback.swift`,
`AutomationRenderTests+Loop.swift`, `AutomationRenderTests+Tempo.swift`,
`ActionSetSubmissionTests.swift`, `ActionSetSubmissionTests+Admission.swift`
and `ActionSetSubmissionTests+Cancel.swift`); the longest root file,
`ActionSetSubmissionTests.swift`, grows from 446 to 450 lines, under the
500-line `file_length` limit. Their only extension,
`AutomationBankTests+Limits.swift`, stays unannotated. The nested
`AutomationBankTests.Tally`, `AutomationRenderTests.SplitMix`,
`AutomationRenderHandbackTests.Release`, `AutomationRenderLoopTests.Handback`
and `HandbackRun`, and `AutomationRenderTempoTests.PowerError`, and the
top-level `ActionSetSubmissionHarness` and `ActionSetSubmissionSchedulerCase`,
are not suites and stay unannotated. The four automation suites alias
`AutomationRenderTests` as their fixture, and the loop and tempo suites also
alias `AutomationRenderHandbackTests`. The three action-set suites share
`ActionSetSubmissionHarness`, which builds on the `ActionSetFixture` struct in
`DeclarativeActionTests.swift`; that suite has no `@Suite` and is not adopted
here. The suites build lanes, breakpoints, action sets and scheduler
snapshots from literals and seeded generators, and drive the
`Shared/Performance/Automation` lanes, arbiter, bank and block renderer and
the `Shared/Performance/Actions` action-set submitter, with the
`Shared/Contracts` trigger scheduler, over synthetic `HostStamp`,
`ClockAnchor`, `MusicalClockMap` and `ClockGenerationSnapshot` values. They
declare no `static var` members. The only class is `AutomationBankTests.Tally`,
a render-call counter that each test creates locally; no tally is shared.
The automation suites import only Testing and the action-set suites only
Foundation and Testing. The production closure the fixture copied is all of
`Shared/Contracts`, `Shared/Performance/Automation` and
`Shared/Performance/Actions`, the top-level `Shared/Control/Bindings` sources
and `Shared/WING/FaderMath.swift`. No source in it imports anything but
Foundation. Its only `static var` members are computed or protocol
requirements, and its only class is the stateless
`fileprivate final class Identity` token in `TriggerSession.swift`. None of
the eight suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio.

Against the unmodified UARG16 tree, both checker modes report 4,888
registrations. Satisfied rows rise from 832 (792 `FluxKlangMacTests`, 40
`FluxKlangTests`) to 896 (856 `FluxKlangMacTests`, 40 `FluxKlangTests`).
The eight suites' 64 `FluxKlangMacTests` root rows (eight per suite) are
now satisfied, which accounts for the whole increase; no row is removed.
Diagnostics fall by 64, from 6,232 to 6,168: eight removed per suite, as
each had a named `@Suite`, and none added. The iOS `FluxKlangTests` root
rows for all eight suites stay unsatisfied, with one diagnostic per row
(eight per suite). Apart from the Mac rows' status, the only row change,
in both modules, is that test line numbers in the eight root files shift
by four. Inventory still exits 0 and default enforcement still exits 1.
This comparison is a row-level diff of both trees' output.

A fresh SwiftPM package (default build system, no private witness or
observer) byte-copied 100 repository sources from this change. 11 are test
sources: the eight suites' files, `AutomationBankTests+Limits.swift`,
`DeclarativeActionTests.swift` and `ProductionAccessScope.swift`. The other
89 are `Shared/Store/ProductionAccessAudit.swift` and the in-memory
production closure: the 58 `Shared/Contracts`, 12
`Shared/Performance/Automation`, nine `Shared/Performance/Actions` and eight
top-level `Shared/Control/Bindings` sources and `FaderMath.swift`. Debug and
Release (`-c release -Xswiftc -enable-testing`) runs filtered to the eight
suites each passed 93 tests (nine parameterized, 39 cases) in eight suites,
with `--xunit-output` and `--event-stream-output-path`. Each xUnit report
lists 93 test cases with no failures or skips, and each event stream ends all
93 test functions and eight suites with no issue events. Each run, under its
own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of the eight suites (`FluxKlangTests/` plus
the suite name), carrying that run ID, with all 14 operation IDs reporting
zero `apiEntered` and `factoryEvaluated` and no audit issue recorded.
`DeclarativeActionTests` was compiled for its helpers but filtered out.
These runs add no process-identity, argv or bootstrap evidence and do not
cover the iOS owners; the remaining #60 gates above still apply and #60
remains open.

## Recording take and patch variation source adoption

`RecordingTakeTests`, `RecordingTakeBackwardJumpTests`,
`RecordingTakeDiscontinuityTests`, `RecordingTakeRecoveryTests`,
`RecordingTakeV1GateTests`, `PatchVariationTests`,
`PatchVariationEditingTests` and `PatchVariationRepairTests` now use the
canonical trait under `#if os(macOS)` on their root declarations, matching
`GraphCompilerTests`, without test-body, helper, target-membership or
registration changes. The five recording-take suites and
`PatchVariationTests` had no `@Suite` and gain a bare
`@Suite(.productionAccessAudit)` inside `#if os(macOS)`, as `MPEZoneTests`
did. `PatchVariationEditingTests` and `PatchVariationRepairTests` keep their
display names: the trait is added to each existing `@Suite` in the macOS
branch and the `#else` branch keeps that `@Suite` unchanged. None of the
eight has other suite traits. Each is a separate root `struct`
(`RecordingTakeTests.swift`, `RecordingTakeTests+BackwardJumps.swift`,
`RecordingTakeTests+Discontinuities.swift`,
`RecordingTakeTests+Recovery.swift`, `RecordingTakeV1GateTests.swift`,
`PatchVariationTests.swift`, `PatchVariationTests+Editing.swift` and
`PatchVariationTests+Repair.swift`); the longest root file,
`RecordingTakeTests.swift`, grows from 496 to 499 lines, under the 500-line
`file_length` limit. Their extensions,
`RecordingTakeV1GateTests+Discontinuities.swift` and
`PatchVariationTests+Recall.swift`, stay unannotated. The top-level
`TakeLedgerTestFixture` enum in `RecordingTakeTests.swift` and the
function-local `Closing` enums in `RecordingTakeBackwardJumpTests` are not
suites and stay unannotated. The five recording-take suites alias
`TakeLedgerTestFixture` as their fixture; the editing and repair suites alias
`PatchVariationTests`. The suites build take openings, synthetic
`RuntimeSampleStamp`, `RuntimeClockAnchor`, `RuntimeDiscontinuity` and
`HostStamp` values, recording segments, patches and variation sets from
literals and inline JSON, and drive the `Shared/Media/Recording` take ledger
and `RecordingTakeV1` export gate, and the
`Shared/Performance/Patches` variation records, recall plan, editor and
repair, with `Shared/Contracts` coding. They declare no `static var`
members and no classes, and import only Foundation and Testing. The
production closure the fixture copied is all of `Shared/Contracts`,
`Shared/Media/Recording` and `Shared/Performance/Patches`, and
`Shared/WING/FaderMath.swift`. No source in it imports anything but
Foundation. Its only `static var` members are computed or protocol
requirements, and its only class is the stateless
`fileprivate final class Identity` token in `TriggerSession.swift`. None of
the eight suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio.

Against the unmodified UARG17 tree, both checker modes report 4,888
registrations. Satisfied rows rise from 896 (856 `FluxKlangMacTests`, 40
`FluxKlangTests`) to 960 (920 `FluxKlangMacTests`, 40 `FluxKlangTests`).
The eight suites' 64 `FluxKlangMacTests` root rows (eight per suite) are
now satisfied, which accounts for the whole increase; no row is removed.
Diagnostics fall by 112, from 6,168 to 6,056, and none is added. The two
named suites lose eight each (the missing trait). The six suites that had
no `@Suite` lose sixteen each: per Mac row, both the missing-trait
diagnostic and the "requires a single @Suite" one. The iOS
`FluxKlangTests` root rows for all eight suites stay unsatisfied, with the
same diagnostics as before (eight per named suite, sixteen per bare one).
Apart from the Mac rows' status, the only row change, in both modules, is
that test line numbers in the root files shift by three (bare form) or four
(named form); tests in the two extension files keep their lines. Inventory
still exits 0 and default enforcement still exits 1. This comparison is a
row-level diff of both trees' output.

A fresh SwiftPM package (default build system, no private witness or
observer) byte-copied 94 repository sources from this change. 11 are test
sources: the eight suites' files, the two extension files and
`ProductionAccessScope.swift`. The other 83 are
`Shared/Store/ProductionAccessAudit.swift` and the in-memory production
closure: the 58 `Shared/Contracts`, 15 `Shared/Media/Recording` and eight
`Shared/Performance/Patches` sources and `FaderMath.swift`. Debug and
Release (`-c release -Xswiftc -enable-testing`) runs filtered to the eight
suites each passed 136 tests (none parameterized) in eight suites, with
`--xunit-output` and `--experimental-event-stream-output`. Each xUnit report
lists 136 test cases with no failures or skips, and each event stream ends
all 136 test functions and eight suites with no issue events. Each run, under
its own fresh `FLUXKLANG_AUDIT_RUN_ID`, wrote one `suiteExit` attachment to
`--attachments-path` for each of the eight suites (`FluxKlangTests/` plus
the suite name), carrying that run ID, with all 14 operation IDs reporting
zero `apiEntered` and `factoryEvaluated` and no audit issue recorded.
These runs add no process-identity, argv or bootstrap evidence and do not
cover the iOS owners; the remaining #60 gates above still apply and #60
remains open.

## Patch transition and peer model source adoption

`PatchTransitionTests`, `PatchTransitionBoundsTests`,
`PatchTransitionLifecycleTests`, `PatchTransitionRepeatedTests`,
`PatchTransitionSustainTests`, `PeerStatusProjectionTests`,
`PeerBackpressureTests`, `PeerEndpointPolicyTests` and
`PeerControlMessageTests` now use the canonical trait under `#if os(macOS)`
on their root declarations, matching `GraphCompilerTests`, without
test-body, helper, target-membership or registration changes. The seven
suites that already had a named `@Suite` keep their display names: the trait
is added to each existing `@Suite` in the macOS branch and the `#else` branch
keeps that `@Suite` unchanged. `PeerEndpointPolicyTests` and
`PeerControlMessageTests` had no `@Suite` and gain a bare
`@Suite(.productionAccessAudit)` inside `#if os(macOS)`, as `MPEZoneTests`
did; the doc comment above `PeerControlMessageTests` stays above the `#if`.
None of the nine has other suite traits. Each is a separate root `struct`
(`PatchTransitionTests.swift`, `PatchTransitionTests+Bounds.swift`,
`PatchTransitionTests+Lifecycle.swift`, `PatchTransitionTests+Repeated.swift`,
`PatchTransitionTests+Sustain.swift`, `PeerStatusProjectionTests.swift`,
`PeerBackpressureTests.swift`, `PeerEndpointPolicyTests.swift` and
`PeerControlMessageTests.swift`); the longest, `PatchTransitionTests+Repeated`,
grows from 412 to 416 lines, under the 500-line `file_length` limit. Their
extension files (`PeerStatusProjectionTests+*`, `PeerBackpressureTests+*`,
`PeerEndpointPolicyTests+*` and `PeerControlMessageTests+*`) stay
unannotated, as do the top-level `PatchTransitionFixture` and
`PeerBackpressureFixture` enums, which are not suites.

The suites drive the `Shared/Performance/Transitions` planner and tracker
with `Shared/Performance/Patches` and `Shared/MIDI/Performance` note ledger
and routing values, and the `Shared/Peer` status projection, backpressure
budgets, endpoint policy and control message codec, all from literals and
injected integer ticks. They declare no classes and no stored `static var`
(the only `static var` members are the computed golden fixtures in
`PeerControlMessageTests+Golden.swift`), and import only Foundation and
Testing. The production closure the fixture copied is 137 sources, plus
`ProductionAccessAudit.swift`, which also imports `Synchronization`. The 137
import only Foundation, apart from
`CryptoKit` in `Shared/Peer/Trust/PeerIdentity.swift`, which is a pure
one-shot SHA-256 over in-memory bytes (no key, keychain or transport) and is
only a compile dependency of the grant types. Its `static var` members are
computed or protocol requirements, and its only class is the stateless
`fileprivate final class Identity` token in `TriggerSession.swift`. None of
the nine suites touches the file system, bundles, wall clock, sleep,
dispatch, defaults, global mutable state, MIDI hardware, network or audio.

Against the unmodified tree at `28086dc9` (the `main` this change was built
on), both checker modes report 4,936 registrations. Satisfied rows rise from
984 (944 `FluxKlangMacTests`, 40 `FluxKlangTests`) to 1,056 (1,016
`FluxKlangMacTests`, 40 `FluxKlangTests`). The nine suites' 72
`FluxKlangMacTests` root rows (eight per suite) are now satisfied, which
accounts for the whole increase; no row is removed. Diagnostics fall by 88,
from 6,080 to 5,992, and none is added. The seven suites that already had a
named `@Suite` lose eight each (the missing trait). The two suites that had no
`@Suite` lose sixteen each: per Mac row, both the missing-trait diagnostic and
the "requires a single @Suite" one. The iOS `FluxKlangTests` root rows for all
nine suites stay unsatisfied, with the same diagnostics as before (eight per
named suite, sixteen per bare one). Apart from the Mac rows' status, the only
row change, in both modules, is that test line numbers in the root files
shift by three (`PeerEndpointPolicyTests`, the one bare suite with tests in
its root file) or four (the seven named suites); tests in extension files
keep their lines, and `PeerControlMessageTests`, whose tests are all in
extension files, has none to shift. Inventory still exits 0 and default
enforcement still exits 1. This comparison is a row-level diff of both trees'
output.

A fresh SwiftPM package (default build system, no private witness or
observer) byte-copied those sources and the nine suites' test files, their
extension files and `ProductionAccessScope.swift`. Debug and Release
(`-c release -Xswiftc -enable-testing`) runs each passed 307 tests in nine
suites with no warnings, and collected no `suiteExit`, xUnit or event-stream
receipts. The runs add no process-identity, argv or bootstrap
evidence and do not cover the iOS owners; the iOS `FluxKlangTests` rows for
these suites stay unsatisfied, the remaining #60 gates above still apply and
#60 remains open.

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
