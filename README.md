# FluxKlang

A native SwiftUI app to control a **Behringer WING Rack** over the network — for
**iPhone, iPad, and Mac** (deployment target **iOS/macOS 26+**).

FluxKlang gives you:

- **Configurable volume faders** bound to WING channels/buses with live feedback.
- **Routing** — input patching (sources → channels) and output routing, plus
  one-tap preset/scene buttons.
- A **drag-and-drop signal-chain builder** to wire your gear into WING inputs →
  channels → buses → outputs.

The Mac build is a **first-class native Mac app** (menu-bar commands, a Settings
window, source-list sidebar + inspector, and a menu-bar quick-mixer) — not an
iPad port.

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
FluxKlang/      iOS @main
FluxKlangMac/   macOS @main (WindowGroup + Settings + Commands + MenuBarExtra)
FluxKlangTests/ unit tests
```

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
