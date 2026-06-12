# Changelog

## [0.0.4](https://github.com/djensenius/FluxKlang/compare/v0.0.3...v0.0.4) (2026-06-12)


### Features

* switchable Environments — effects routing, spatial placement, WING I/O reading ([#13](https://github.com/djensenius/FluxKlang/issues/13)) ([bf2c167](https://github.com/djensenius/FluxKlang/commit/bf2c167fd0ec3879d8bc62e0f8f8eb4a663c3e72))

## [0.0.3](https://github.com/djensenius/FluxKlang/compare/v0.0.2...v0.0.3) (2026-06-11)


### Features

* pre-populate WingController cache with bulk-refresh on connect ([#10](https://github.com/djensenius/FluxKlang/issues/10)) ([dc033e7](https://github.com/djensenius/FluxKlang/commit/dc033e72aa18435a65b4b1378603e850aba1b625))
* sync all persisted state via iCloud ([#11](https://github.com/djensenius/FluxKlang/issues/11)) ([3ec275b](https://github.com/djensenius/FluxKlang/commit/3ec275bc3cdac9b973d413d91c4bca73a8012d63))
* write WING scribble-strip names and colours back to the console ([#8](https://github.com/djensenius/FluxKlang/issues/8)) ([58e845f](https://github.com/djensenius/FluxKlang/commit/58e845f081626ac542073d07c5dbebc1660fb13f))


### Bug Fixes

* correct WING /io/out output-patch OSC paths and source-group tokens ([#7](https://github.com/djensenius/FluxKlang/issues/7)) ([20a9091](https://github.com/djensenius/FluxKlang/commit/20a90919a80e74360013f8f1f809a24e5d5d4a98))

## [0.0.2](https://github.com/djensenius/FluxKlang/compare/v0.0.1...v0.0.2) (2026-06-11)


### Features

* add App Intents for Shortcuts and Siri ([2dcec2a](https://github.com/djensenius/FluxKlang/commit/2dcec2a999e93874317e36cf4cf56c7b3b0c31c2))
* add Codable domain models and Application Support stores ([6c70cb4](https://github.com/djensenius/FluxKlang/commit/6c70cb4c51a368ce70b897815476642c59977d64))
* add drag-and-drop signal-chain builder ([3b6684b](https://github.com/djensenius/FluxKlang/commit/3b6684bc38c1e7c1b74130f791d01edbc8ff3e33))
* add first-class stereo device support to faders and routing ([c582e79](https://github.com/djensenius/FluxKlang/commit/c582e794ab3e817a45c7b2e92fc91f26bfcedfbe))
* add routing tools (input patch, output routing, send matrix) ([16a5124](https://github.com/djensenius/FluxKlang/commit/16a51248f2fd66a97b9c8468d13ee4325f83990c))
* add savable presets and one-tap scene recall ([679c07d](https://github.com/djensenius/FluxKlang/commit/679c07d5788b95081e595ad2dfd40bd0a3035e21))
* add spatial mixing — speaker volume and instrument placement ([67a4dd5](https://github.com/djensenius/FluxKlang/commit/67a4dd588031fc250dd43482afb8b214b66abad5))
* add three selectable, layered app icons with an in-app picker ([#5](https://github.com/djensenius/FluxKlang/issues/5)) ([71d7d4d](https://github.com/djensenius/FluxKlang/commit/71d7d4d7a471a28449f415fb6deea7d2cb4c1378))
* add usable Demo Mode UI (faders, connection, menu-bar mixer) ([542a3ac](https://github.com/djensenius/FluxKlang/commit/542a3ac6700a2ce14ebd4668ac37a592027eddf7))
* add WING Co-Pilot hand-off ([7de09bb](https://github.com/djensenius/FluxKlang/commit/7de09bb6b065e7adfef46ec072590cd8907cdf6b))
* add WING network discovery ([e3c8b9f](https://github.com/djensenius/FluxKlang/commit/e3c8b9ff74bd66afd0f631e0c844315fc38c84c7))
* add WING OSC core with offline demo mode ([2526e7e](https://github.com/djensenius/FluxKlang/commit/2526e7ea37a60247a98c6425960e79fffe9ca4e9))
* finish app shell with discovery UI, theme and settings ([8a08404](https://github.com/djensenius/FluxKlang/commit/8a084041e6a6c07ef36d6f7b9eb60fe0e3b11514))
* make the fader bank configurable and persisted ([775f1ac](https://github.com/djensenius/FluxKlang/commit/775f1acd964c034cb946aeb0839f0793dba72afd))
* make the Mac build first-class native ([db93f01](https://github.com/djensenius/FluxKlang/commit/db93f010d45cd43963e824999b8e7dacfce752e2))
* stereo inputs, fan-in routing, output patching, and easier wire editing ([#4](https://github.com/djensenius/FluxKlang/issues/4)) ([53074eb](https://github.com/djensenius/FluxKlang/commit/53074eb12119914eb37381916784cfa4a37a9791))
