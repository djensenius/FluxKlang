# FluxKlang

A native SwiftUI app to control a **Behringer WING Rack** over the network — for
**iPhone, iPad, and Mac** (deployment target **iOS/macOS 26+**).

FluxKlang gives you:

- **Configurable volume faders** bound to WING channels/buses/mains with live,
  two-way sync, mute and a level meter. On Mac they feel native — scroll-wheel to
  adjust, double-click to reset to 0 dB and ⌥-drag for fine control.
- **Routing** — input patching (sources → channels), output/main assignment and a
  bus send matrix.
- A **drag-and-drop signal-chain builder** to wire your gear into WING inputs →
  channels → buses → outputs; the WING-touching wires apply as real routing.
- **Presets / scene recall** — save a snapshot of fader levels, mutes and routing,
  then recall it with one tap (or ⌘1–9 on Mac).
- **Network discovery** with manual-IP entry and a remembered last-known console.
- A **full offline Demo Mode** that simulates a complete WING — explore, screenshot
  or demo with no console on the network.
- **WING Co-Pilot hand-off** — jump to Behringer's app (toolbar button / ⌘⇧P) for
  the deep 1% (full EQ/dynamics/FX); FluxKlang covers the everyday 99% and
  coexists with Co-Pilot, treating the console as the source of truth.
- **Shortcuts & Siri** via App Intents — connect, enter demo mode, set a channel
  volume, and recall a preset.

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
  Store/     local persistence (Application Support)
  Views/     App / Connection / Mixer / Routing / Chain / Presets / Mac
  Intents/   App Intents for Shortcuts & Siri
FluxKlang/      iOS @main
FluxKlangMac/   macOS @main (WindowGroup + Settings + Commands + MenuBarExtra)
FluxKlangTests/ unit tests
```

A demo simulator (`DemoWingTransport`) sits behind the same `WingTransporting`
protocol as the live OSC transport, so every feature works offline and in Xcode
previews.

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
make lint        # swiftlint --strict
make build       # iOS simulator build
make build-mac   # native macOS build
make test        # unit tests
```
