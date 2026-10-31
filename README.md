# FluxKlang

A native SwiftUI app to control a **Behringer WING Rack** over the network — for
**iPhone, iPad, and Mac** (deployment target **iOS/macOS 27+**).

FluxKlang gives you:

- A **Studio-first patch workflow** — start with an instrument, branch it to dry,
  effect and space controls, and let FluxKlang turn that into WING routing.
- **Configurable volume faders** bound to WING channels/buses/mains with live,
  two-way sync, mute and a visual fader-position indicator (not an audio meter).
  On Mac they feel native — scroll-wheel to
  adjust, double-click to reset to 0 dB and ⌥-drag for fine control.
- **Advanced WING tools** — raw input patching, output/main assignment, bus-send
  matrix, the legacy chain canvas and legacy environment/spatial editors live
  under Advanced instead of crowding the main workflow.
- **Presets / scene recall** — save a snapshot of fader levels, mutes and routing,
  then recall it with one tap (or ⌘1–9 on Mac).
- **Network discovery** with manual-IP entry and a remembered last-known console.
- A **full offline Demo Mode** that simulates a complete WING — explore, screenshot
  or demo with no console on the network.
- **WING Co-Pilot hand-off** — jump to Behringer's app (toolbar button / ⌘⇧P) for
  the deep 1% (full EQ/dynamics/FX); FluxKlang covers the everyday 99% and
  coexists with Co-Pilot, treating the console as the source of truth.
- **Shortcuts & Siri** via App Intents — connect, enter demo mode, set a channel
  volume, recall a preset, and say requests like “Tell FluxKlang to wire synth
  through delay to speakers” to create Studio drafts for explicit in-app review.
- **iCloud syncing** — your fader bank, equipment library, signal chain, presets
  and spatial layout sync across iPhone, iPad and Mac via iCloud key-value
  storage; a local copy keeps everything working offline.

The Mac build is a **first-class native Mac app** (menu-bar commands, a Settings
window, source-list sidebar + inspector, native canvas interactions and a
menu-bar quick-mixer) — not an iPad port. Written in **Swift 6** with full
async/await.

## Architecture

- **SwiftUI**, **XcodeGen** (`project.yml` is the source of truth; the
  `.xcodeproj` is generated), **SwiftLint** (strict).
- WING control via **OSC over UDP** using the **SwiftOSC** package.
- Shared cross-platform code in `Shared/`; thin `@main` targets in `FluxKlang/`
  (iOS) and `FluxKlangMac/` (macOS).

```
Shared/
  WING/      OSC transport + WingController, discovery, address book, fader math
  Models/    WING domain + equipment/chain/fader/preset models (Codable)
  Store/     local persistence (Application Support) + iCloud key-value sync
  Views/     App / Studio / Connection / Mixer / Routing / Chain / Presets / Mac
  Intents/   App Intents for Shortcuts & Siri
FluxKlang/      iOS @main
FluxKlangMac/   macOS @main (WindowGroup + Settings + Commands + MenuBarExtra)
FluxKlangTests/ unit tests
FluxKlangMacTests/ native macOS unit tests (hosted by FluxKlangMac)
```

A demo simulator (`DemoWingTransport`) sits behind the same `WingTransporting`
protocol as the live OSC transport, so every feature works offline and in Xcode
previews.

## Studio wiring, metadata, and review safety

- **Live WING metadata** is console state read over OSC, such as connection
  status, scribble-strip names, fader values, mutes, and routing replies.
- **FluxKlang physical wiring** is the user-configured map of which equipment
  ports are actually cabled to WING Local inputs/outputs and AES50 stagebox
  outputs. A console scribble name may be offered as a friendly-label
  suggestion, but it never proves or changes a physical cable connection.
- Studio Connections are stored as readable, sorted JSON in
  `Application Support/FluxKlang/studio-connections.json` and remain editable
  through Settings. The one-time starting output map is the editable bundled
  file `Shared/Configuration/studio-connections.defaults.json`; later user
  edits and cleared assignments are never re-seeded by that version.
- **Home** is the saved normal physical wiring map. A **Temporary Move** overlays
  selected connectors without mutating Home. Returning Home requires a cable
  checklist, an explicit routing preview/apply action, and verification before
  the override is removed.
- For routing, the in-app assistant and Siri create only a **pending Studio draft**.
  Equipment names and prompts are treated as untrusted text. The user must open
  the review, resolve validation errors, and explicitly accept before semantic
  Studio nodes are added. Accepting still does not write to a WING; **Listen** is
  the separate hardware-write action.
- Assistant generation uses Apple Intelligence by default when Foundation
  Models are available. Settings can instead opt into GitHub Copilot using its
  OpenAI-compatible API, matching FluxHaus Server, with a configurable model
  (default `gpt-4o`). The GitHub token is stored only in this device's Keychain;
  prompts and required FluxKlang tool results are sent to GitHub when selected.
  Both providers expose only authoritative help, read-only state inspection,
  and review-only Studio draft tools—never WING writes.
- **Apple instrument understanding** uses a separate, tool-free on-device model
  to interpret requests such as “turn down the volume of my Astrolab” or “add my
  Mother-32 and turn the volume to 50%.” The app resolves current WING targets and
  prepares a review; the model cannot change the mixer. Similar names require
  selection, missing relative amounts are visibly suggested, and percentages mean
  **fader travel**, not loudness. Only explicit confirmation can execute a reviewed
  action, with fresh identity/level checks and truthful per-channel outcomes.
  Adding a live shortcut creates no cables, routing or new buses. Routing still
  requires its separate draft review and **Listen** action.
- The new **Ask FluxKlang** Siri/Shortcuts action brings a request into the
  Assistant composer. Tap Send to interpret it, then review and confirm any
  proposed action. It never writes hardware or accepts a routing draft merely
  because Siri invoked it. Apple command understanding does not silently fall
  back to Copilot; unavailable Apple Intelligence offers local exact commands
  for review or manual controls. [Design and qualification notes](docs/APPLE_INTELLIGENCE_ACTIONS.md).
- The assistant distinguishes saved studio equipment from observed WING input and
  channel labels. A console label is not proof of an attached instrument or cable.
  Unknown live labels require linking to saved equipment and its ports before
  creating a physical wiring draft; they do not silently create gear entries.
- A deterministic grounded fallback remains available when the selected model
  is unavailable or fails. To dictate a message, use the system keyboard's
  dictation feature; FluxKlang does not capture microphone audio. Visible conversation
  text and card references may sync through the user's private iCloud database;
  other app configuration uses iCloud key-value storage plus an offline copy.
- **Launch Control XL 3:** FluxKlang listens to the main USB MIDI endpoint in
  the controller's fixed Default Mode 16. The eight faders control the current
  FluxKlang fader bank, the first encoder row controls mono pan or stereo
  balance, the two button rows select and mute strips, and Track Left/Right
  changes banks. Settings defaults to **Monitor (WING handles MIDI)** for rigs
  where the controller's DIN output is also connected directly to the WING.
  **Control through FluxKlang (USB only)** must be used only after disabling
  direct WING MIDI control to prevent duplicate actions.
- The Launch Control mapping is stored in readable, editable
  `Application Support/FluxKlang/launch-control-xl.json`, initially copied from
  `Shared/Configuration/launch-control-xl.json`.

> **Meter disclosure:** the slim colored bars beside faders are currently
> simulated from fader position, not WING audio-level telemetry. Demo Mode also
> adds simulated ambient fader movement. Do not use either as a signal-presence,
> clipping, or gain-staging meter.

> **WING Co-Pilot identifiers** (URL scheme, macOS bundle id, App Store URL) are
> best-effort defaults and overridable via the `CoPilotURLScheme`,
> `CoPilotBundleID` and `CoPilotAppStoreURL` Info.plist keys — verify them against
> the shipping Co-Pilot app.

## Develop

```sh
brew install xcodegen swiftlint   # if not already installed
make generate                     # xcodegen generate
open FluxKlang.xcodeproj
```

## Validate

```sh
make lint                   # swiftlint --strict
make build                  # iOS simulator build
make build-mac              # native macOS build
make build-for-testing-mac  # compile Mac app + FluxKlangMacTests (no launch)
make test                   # unit tests
make test-mac               # hosted Mac tests; gated by #60 (startup isolation #51)
```

## Final acceptance status — September 10, 2026

- [x] Strict SwiftLint and whitespace validation.
- [x] 185 unit/adversarial/migration tests on iPhone 17 Pro, iOS 26.5 simulator.
- [x] 3 focused UI tests in Demo Mode on iPhone 17 Pro, iOS 26.5 simulator:
  Studio/Assistant/Mix/More, synthetic failure-to-Demo recovery, draft review,
  Temporary Move/Return Home gating, and forced grounded fallback.
- [x] iOS simulator build, unsigned generic iOS archive, and native Mac build.
- [ ] Manual Mac interaction pass: keyboard navigation through the sidebar,
  Assistant, Studio menus, fader arrow-key adjustment, Settings/Studio
  Connections, and Temporary Move review with VoiceOver and large Dynamic Type.

iOS 27.0 simulator UI automation was not used as acceptance evidence because
the beta runtime crashed while loading duplicate WebKit/WebCore accessibility
bundles. The same app launch worked outside UI automation; the stable iOS 26.5
runtime completed all focused UI tests.

No live WING writes or routing changes were authorized for this acceptance
slice. The remaining hardware checklist is explicitly authorization-gated:

1. Obtain approval for a maintenance window and the exact disposable channels,
   buses, mains, Local inputs, and Local outputs that may be changed.
2. Capture/approve a rollback snapshot in WING Co-Pilot or on the console.
3. Verify real fader, mute, name, color, input-source, output-source, send, and
   subscription reply shapes against firmware on `192.168.11.221`.
4. Exercise Temporary Move apply, confirmed-reply verification, reconnect drift,
   and Return Home on approved test cables only.
5. Confirm multi-client reconciliation with WING Co-Pilot and restore the
   approved baseline. Reachability alone is not authorization.
