# Transformation baseline and source ownership ledger

Work package `baseline-reuse-map` (#50) for roadmap #48. This ledger records what the
baseline revision actually contains, which parts are reused and by whom, which commands
already exist, and what is still unqualified. It is a source review only: nothing here
was built, run, launched or measured.

## Disclaimers

- **#47 is not rendering proof.** PR #47 ("prepare complete Apple multi-route requests
  for Studio review", merge `6c4885c`) adds assistant interpretation and Studio graph
  preparation for review. It produces drafts that a person accepts into the local graph.
  It does not render audio, open an audio engine, enumerate USB audio or qualify latency.
  No ticket may cite #47 as USB, rendering or audio qualification.
- **No stale-checkout claims.** Every fact below was checked against `main` at the
  revision below, not the older dirty checkout. Claims from earlier handoffs or
  conversations are included only when verified in this revision. If a ticket cites a
  path, line or behavior, check it against this ledger or re-verify it first.
- **Historical qualification is not current qualification.**
  `docs/validation/apple-actions-2026-10-28.md` records results for source revision
  `3b2b418` (an ancestor of the baseline), including "367 tests in 48 suites". Those
  results are not a test run of this baseline.

## Baseline identity

| Item | Value (verified in source) |
|---|---|
| Commit | `9cfa1eccb914cbdecfe3c00c49e0e5f58ec288b7` (`chore(main): release 0.0.7`) |
| Commit date | 2026-10-29 12:56:57 -0400 |
| Release manifest | `.release-please-manifest.json` = `0.0.7`; `VERSION` and `MARKETING_VERSION` = `0.0.1` |
| Deployment targets | iOS `27.0`, macOS `27.0` (`project.yml:4-6`). Keep these unless a compatibility ADR changes them. |
| Swift | `SWIFT_VERSION: "6"` (`project.yml`) |
| Project generation | XcodeGen from `project.yml`; `FluxKlang.xcodeproj` is generated and checked in |
| Targets | `FluxKlang` (iOS app), `FluxKlangMac` (macOS app, sandboxed, network client and server entitlements), `FluxKlangTests` (iOS unit tests hosted by the app), `FluxKlangUITests` (iOS UI tests). Both apps compile `Shared/`. |
| Schemes | `FluxKlang`: build, run, test (`FluxKlangTests`, `FluxKlangUITests`). `FluxKlangMac`: build, run, profile, analyze. **No Mac test action.** |
| Package dependencies | `swift-osc` from `3.1.0` (product `SwiftOSC`), resolved at 3.1.0. Transitive dependencies: swift-osc-core 1.4.0, swift-osc-io-nio 1.2.0, swift-nio 2.101.0, swift-atomics, swift-collections, swift-system, swift-ascii, swift-data-parsing. |
| iCloud | Both entitlements files declare the KV store and a CloudKit container. |
| Tool pins | No `mise` configuration file is tracked in this revision. The README says to install `xcodegen` and `swiftlint` with Homebrew. |

### Test inventory (static source count, not a run)

| Bundle | Framework | Files | Types | Tests |
|---|---|---|---|---|
| `FluxKlangTests` (iOS, app-hosted) | Swift Testing (`import Testing`) | 54 test files plus `TestSupport.swift` and `AssistantBackendTestSupport.swift` | 56 distinct `*Tests` types. 8 have an explicit `@Suite`; the rest are implicit suites. | 536 `@Test` declarations (including 7 written as `@MainActor @Test` on one line), including 55 parameterized (`arguments:`) declarations that expand to more cases at runtime |
| `FluxKlangUITests` (iOS) | XCTest | 5 | 5 `XCTestCase` classes | 22 `test…` methods |
| Mac | none | — | — | No Mac test target or testable exists. |

### CI and release

- `.github/workflows/apple-lint.yml` runs on `macos-15` for every push to `main` and every
  PR. It runs `brew install swiftlint` and then `swiftlint --strict` (line 16). **This is
  the only CI check. CI does not build or test anything.**
- `.github/workflows/release.yml` runs release-please (`googleapis/release-please-action`)
  on `ubuntu-latest`. It only manages versions and the changelog.
- Native Apple release builds use Xcode Cloud (per #48), not GitHub Actions.

### Existing commands (`Makefile`)

| Target | Line | Command |
|---|---|---|
| `generate` | 4 | `xcodegen generate` |
| `build` | 7 | `xcodebuild -scheme FluxKlang` for the iOS Simulator (`iPhone 17 Pro`), `CODE_SIGNING_ALLOWED=NO` |
| `build-mac` | 12 | `xcodebuild -scheme FluxKlangMac build`, `CODE_SIGNING_ALLOWED=NO` |
| `test` | 16 | `xcodebuild -scheme FluxKlang test` on the iOS Simulator. Runs **both** unit and UI tests. |
| `lint` | 21 | `swiftlint --strict` |
| `clean` | — | `rm -rf build DerivedData` |

There is no `test-mac` target. #56 adds it deliberately.

## Verified source map

All entries from the #48 "Source map" were checked at `9cfa1ec`. That covers 58 path:line
references and 3 path-only references. **All were verified. None had moved or were
missing.** As #48 states, a path without a directory prefix uses the directory of the
first path in its concern. For example, the Assistant files without a prefix are in
`Shared/Assistant/`, not `Shared/Views/App/`.

Reuse decisions: **reuse** = keep as-is behind a new seam; **adapt** = keep the logic but
retarget it to neutral contracts; **replace** = a new subsystem supersedes it;
**retire** = remove after migration. Owners are packages from the #48 work-package index.

### Shared owner and navigation (coordinator-only)

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Views/App/AppModel.swift:23` | `final class AppModel`, the root `@Observable` owner | adapt (only through narrow seams) | coordinator; #51 seam |
| `Shared/Views/App/AppModel.swift:131` | `loadStores()` startup. It calls `launchControlXL.load()`, which starts CoreMIDI, and auto-reconnects the WING. | adapt | #51 |
| `Shared/Views/App/AppModel.swift:390` | `connect(host:port:)` WING connection | adapt (lazy lease) | #76 |
| `Shared/Views/App/AppRootView.swift:80` | `enum AppSection` primary navigation | adapt | coordinator; #99 / #26 |
| `Shared/Views/Advanced/AdvancedView.swift:10` | `AdvancedView`, home of the WING compatibility UI | adapt | #76 / #99 |
| `Shared/Views/Mac/MacCommands.swift:35` | `CommandMenu("WING")` | adapt | #99 / #76 |

### Graph and lowering

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Models/StudioGraph.swift:30` | `StudioEndpoint` | adapt to neutral graph endpoints | #54 |
| `Shared/Models/StudioGraph.swift:129` | `StudioGraph` (Codable) | adapt / migrate | #54, #122 |
| `Shared/Models/StudioGraph.swift:217` | `plan(for:endpoints:)` → `StudioRoutingPlan` | adapt | #66 |
| `Shared/Models/StudioSignalCompiler.swift:59` | `compile(_:)` → `StudioCompiledRouting` (lowers the graph to WING settings) | adapt; keep as the WING lowering | #66 / #76 |
| `Shared/Models/StudioResourceAllocator.swift:54` | `allocateEndpoints(` | adapt | #66 |

### Dispatch gap

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Views/App/AppModel+StudioApply.swift:4` | `applyStudio()` → `WingApplyVerification`. The full-patch Listen entry point (verified apply at line 17). | replace with host-authority activation | #62 |
| `Shared/Views/Studio/StudioView.swift:300` | `.disabled(!appModel.isConnected …)`, a guard that exists only in the UI | replace before exposing activation to peers or automation | #62 |

`applyStudio()` is **not** the only path from the graph or the models to hardware. The
authority migration (#62) must audit every direct WING write path, all of which bypass
`applyStudio()`:

| Location | Path | Owner |
|---|---|---|
| `Shared/Views/App/TemporaryMoveAppModel.swift:52` | `applyTemporaryMove(_:)` compiles the active Studio graph (lines 15-16) and calls `wing.apply` | #62 / #76 |
| `Shared/Views/App/TemporaryMoveAppModel.swift:70` | `returnTemporaryMoveHome(_:)` → `wing.apply` | #62 / #76 |
| `Shared/Views/App/AppModel.swift:208` | `applyChainRouting()` → `wing.apply` | #62 |
| `Shared/Views/App/AppModel.swift:252` | `applyEnvironment()` → `wing.apply` | #62 |
| `Shared/Views/App/AppModel.swift:316`, `:321` | `recall(_:)` / `recallRoutingSnapshot(_:)` → `wing.apply` | #62 / #104 |
| `Shared/Views/App/AppModel.swift:421`, `:427` | `applyVoicePlacement(_:)` / `applyAllPlacements()` → `wing.apply` (spatial) | #62 / #114 |
| `Shared/Views/App/AppModel.swift:435`, `:442`; `Shared/Views/App/LaunchControlXLAppModel.swift:19-41` | live fader/mute/pan setters (UI and Launch Control XL) | #87 / #62 (live-parameter policy) |
| `Shared/Views/App/AppModel+AssistantMixer.swift:126` | reviewed assistant mixer write (`setConfirmedMixerValue`) | #62 / #117 (assistant parent) |

### Assistant (reuse review, cancellation and stale fences)

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Assistant/AssistantCore.swift:37` | `AssistantToolContext` snapshot | adapt to an immutable neutral snapshot | #118 |
| `Shared/Assistant/AssistantCore.swift:416` | `commitPreparedRouting(` | reuse | #37 |
| `Shared/Views/App/AppModel+Assistant.swift:7` | `assistantToolContext()` builder | adapt | #118 |
| `Shared/Views/App/AppModel+Assistant.swift:63` | `acceptPendingAssistantDraft()`. Accepting a draft is not activation. | reuse | #37 / #119 |
| `Shared/Assistant/FoundationModelActionInterpreter.swift:76` | `SystemLanguageModel.default, tools: []` (tool-free session) | reuse | #37 / #120 |
| `Shared/Assistant/FoundationModelActionInterpreter.swift:151` | `prompt(_:)` (current text only) | reuse | #37 |
| `Shared/Assistant/AssistantRoutingPreparation.swift:12` | `prepare(` all-or-clarify resolution | adapt | #37 |
| `Shared/Assistant/AssistantRoutingPreparation.swift:47` | `sources.insert(source.id).inserted` guard against duplicate sources inside `prepare` | reuse | #37 |
| `Shared/Assistant/AssistantChatController.swift:259` | `AssistantRoutingOwnership.owns(question)` routing branch | reuse | #37 / #119 |
| `Shared/Assistant/StudioPatchDraft.swift:25` | `StudioWiringRequest` | adapt to neutral proposals | #37 |
| `Shared/Assistant/StudioWiringAdvisor.swift:147` | `revalidate(` exact revalidation | reuse | #37 |
| `Shared/Assistant/StudioPatchDraftMerger.swift:4` | `merge(` draft into graph | adapt | #37 |
| `Shared/Assistant/AssistantActionController+Execution.swift:7` | `confirm(reviewID:)` single-use reviewed execution | reuse | #62 / #119 |

### WING (lazy, leased compatibility)

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/WING/WingMixerWriteAuthorization.swift:35` | `WingMixerWriteAuthorization`, single-use mixer write authority | reuse | #76 / #62 |
| `Shared/WING/WingController.swift:32` | `confirmedValues` incoming-evidence cache | reuse | #76 |
| `Shared/WING/WingController.swift:443` | `ingest(_:)` incoming OSC | reuse | #76 |
| `Shared/WING/WingController+Confirmed.swift:28` | `readFreshConfirmed(` | reuse | #76 |
| `Shared/WING/WingController+VerifiedApply.swift:6` | `applyAndVerify(` bounded verified apply | reuse | #76 |

### Wiring and migration

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Models/GlobalStudioConnections.swift:103` | `StudioHomeConnections.inputRange = 1...24` (WING-local numbering, not USB channels) | adapt; keep separate from runtime bindings | #54 / #76 |
| `Shared/Models/GlobalStudioConnections.swift:420` | `instrumentChannels(_:)` physical routing | adapt | #54 |
| `Shared/Models/TemporaryDeviceMove.swift:435` | `effectiveHome` (physical Home plus Temporary Moves) | reuse | #54 / #122 |
| `Shared/Models/RoutingEnvironment.swift:99` | `duplicated(named:)` | adapt | #52 |
| `Shared/Models/RoutingEnvironment.swift:121` | `studioGraph: studioGraph` is copied verbatim and is **not remapped** when an environment is duplicated | fix | #52 |
| `Shared/Views/App/TemporaryMoveAppModel.swift:41` | `applyTemporaryMove(_:)` | adapt behind authority | #62 / #76 |

### MIDI (input only, filtered CC)

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/MIDI/CoreMIDIInput.swift:18` | `start(` creates the CoreMIDI client and input port (input only) | adapt; isolate from startup | #51, then #81 |
| `Shared/MIDI/LaunchControlXLController.swift:87` | `restart()`, which calls `midiInput.start` | adapt | #51, then #87 |
| `Shared/Models/LaunchControlXLConfiguration.swift:86` | `decode(_:)` → `[MIDIControlChange]` (CC only) | reuse as a controller profile; replace general parsing | #80 / #87 |
| `Shared/Views/App/LaunchControlXLAppModel.swift:9` | `handleLaunchControlXL(_:)` | adapt to bindings | #87 |

### Spatial (keep DBAP, default and stereo goldens)

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Models/SpatialPanner.swift:30` | `gains(` DBAP gains | reuse; golden-locked | #114 / #115 |
| `Shared/Models/SpeakerArray.swift:16` | `Speaker` | adapt (separate speaker identity from device route) | #114 |
| `Shared/Models/SpatialRouting.swift:19` | `settings(for:speakers:)` → `[WingSetting]` | adapt; WING lowering only | #114 / #76 |
| `Shared/Models/SpatialSource.swift` | `SpatialSource` model | adapt | #114 |
| `FluxKlangTests/SpatialTests.swift` | Spatial goldens (with `EnvironmentSpatialTests.swift`) | reuse; must keep passing | #113 lanes |

### Storage

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Store/JSONFileStore.swift:14` | `enum AppPersistence` | adapt | #122 |
| `Shared/Store/JSONFileStore.swift:86` | `load(_:from:)` | reuse for preferences; projects move to versioned packages | #122 / #124 |
| `Shared/Store/PendingStudioPatchStore.swift:8` | `actor PendingStudioPatchStore` pending drafts | reuse; keep the data | #122 / #124 |
| `Shared/Assistant/AssistantHistoryStore.swift:146` | `live()` CloudKit-backed history | reuse; separate privacy disclosure | #124 |
| `Shared/Assistant/AssistantHistoryStore.swift:195` | `merge(_:)` record merge | reuse | #124 |

### Travel meter

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `Shared/Views/Mixer/FaderStripView.swift:79` | `MeterView(level: isMuted ? 0 : position)`. It shows **fader travel, not signal.** | replace with measured telemetry or show Unavailable | #102 |

### Validation

| Location | What it is | Decision | Owner |
|---|---|---|---|
| `project.yml:4` | `deploymentTarget` (27.0) | reuse | coordinator |
| `project.yml:155` | `FluxKlang` scheme `test:` (unit and UI) | reuse; Mac testables are added separately | #56 |
| `Makefile:4,7,12,16,21` | `generate`, `build`, `build-mac`, `test`, `lint` | reuse; add `test-mac` | #56 |
| `.github/workflows/apple-lint.yml:16` | `swiftlint --strict` | reuse; add native build and test | #61 |
| `FluxKlangTests/TestSupport.swift` | Shared test helpers | reuse | #58 / all test lanes |

## What current main does not have

Each item was checked by searching `Shared/`, `FluxKlang/` and `FluxKlangMac/` at the
baseline revision.

| Capability | Evidence of absence | Owner |
|---|---|---|
| Audio renderer or engine | No `AVAudioEngine`, `AVAudioSession`, `AVAudioNode` or `installTap` | #63 (#64, #65, #66) |
| AU hosting | No `AUAudioUnit`, `AVAudioUnit`, `AudioComponent` or `AudioUnit` | #69 (#70–#73, #77, #78) |
| General MIDI output | No `MIDIOutputPortCreate`, `MIDISend`, `MIDISendEventList`, `MIDIReceived` or `MIDISourceCreate`. CoreMIDI use is input only (`MIDIClientCreateWithBlock`, `MIDIInputPortCreateWithBlock` in `CoreMIDIInput.swift`). | #81 |
| Musical clock, MTC or MMC | No clock status bytes (`0xF8`) and no `tempo`, `BPM`, `MTC` or `MMC` identifiers (whole-word search) | #84, #85 |
| Peer control | No `NWListener`, `NWBrowser`, `NWConnection`, `NetService`, Bonjour or MultipeerConnectivity | #92 (#93–#97) |
| TouchOSC | No references | #91 |
| General OSC | OSC/UDP is used only by the WING transport (`Shared/WING/WingTransport.swift`, SwiftOSC `OSCUDPSocket`) | #89, #90 |
| Measured meters | `MeterView` receives the fader position. There are no power, peak or RMS sources. | #102 |
| Mac tests | The `FluxKlangMac` scheme has no test action, and there is no Mac test bundle | #56 |

## Remaining qualification

None of the following was qualified by reading the source for this ledger.

| Unqualified item | Owner |
|---|---|
| Build and test of this baseline on the OS-27 SDK (unit, UI and Mac builds were not run here) | #60 (hosted, after #51, #56, #58, #59); #61 for CI |
| OS-27 SDK, API availability, and GitHub runner availability (CI uses `macos-15` and only runs lint) | #59, then #61 |
| Hosted unit tests that load fixtures without starting CoreMIDI or the WING | #51 |
| Native Mac testables and `make test-mac` | #56 |
| Audio interface and WING USB capability, channel counts and clock (read-only Phase A) | #67 |
| Hardware loopback, latency and backend comparison | #68, #74 |
| Generic, mobile and WING hardware matrix and soak | #125 |
| Media timing and fidelity contract (G-MEDIA) | #53 |
| Original UX and contract examples | #98 |

## Shared files and wave-1 ownership

**Coordinator-only shared files.** These are owned only by the coordinator. Package
workers propose diffs for coordinator integration; any shared-file change a package
needs is an explicit, per-change coordinator decision, never a standing package right.

- `project.yml`, generated `FluxKlang.xcodeproj/**`, `Makefile`
- `.github/**`, `release-please-config.json`, `.release-please-manifest.json`, `VERSION`,
  `CHANGELOG.md`, `.swiftlint.yml`
- `Shared/Views/App/AppModel*.swift` and `Shared/Views/App/AppRootView.swift` (exception:
  the narrow seam granted to #51 below)
- `FluxKlang/*App*.swift`, `FluxKlangMac/*App*.swift`
- Schema and migration registration, and shared contract types
- This ledger (`docs/transformation/baseline.md`, owned by #50)

**Wave-1 exclusive files.** Packages in the initial parallel frontier, per #48:

| Package | Exclusive files |
|---|---|
| #51 `startup-hardware-isolation` | `Shared/MIDI/CoreMIDIInput.swift`, `Shared/MIDI/LaunchControlXLController.swift`; its `AppModel` startup seam (`loadStores()` at `AppModel.swift:131`) is a coordinator-integrated change |
| #56 `native-mac-test-scaffolding` | `FluxKlangMacTests/**`; its `project.yml`/`Makefile`/generated-project changes are coordinator-integrated |
| #53 `media-clock-fidelity-contracts` | `docs/transformation/media-contract*` |
| #59 `toolchain-api-inventory` | `docs/transformation/toolchain-inventory.md` |
| #98 `contract-ux-draft` | `docs/transformation/workspace-ux/**` |
| #67 `passive-hardware-inventory` | `docs/transformation/hardware-inventory.md`, `scripts/hardware-inventory/**` |
| #50 `baseline-reuse-map` | `docs/transformation/baseline.md` |

Historical issues stay open and are not closed automatically: reuse #26 and #37 for
acceptance and history, keep #24, and #36 stays optional.
