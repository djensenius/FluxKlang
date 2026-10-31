# OS-27 toolchain, SDK and realtime API inventory

Package `toolchain-api-inventory` for #59 (roadmap #48, gate G-SDK). It feeds #60 (hosted
native tests), #61 (OS-27 CI) and #74 (native I/O backends and native vs Rust kernels).

- Captured: 2026-10-31 at `main` 9cfa1ec on one Apple-silicon development Mac. Re-checked the
  same day after merging `main` 0c97cc6, which adds the FluxKlangMacTests target, the
  `build-for-testing-mac` and `test-mac` Make targets (#127), and a regenerated project (17a813a).
  Rows that were not re-run say "pre-merge". Usernames, hostnames, device identifiers and
  serials are redacted, and home paths are shown as `~`.
- Deployment policy: iOS and macOS stay at **27.0** (`project.yml:4-6`). This document
  never proposes lowering them. If a host or runner lacks the OS-27 SDKs, that is a **blocker**
  and must not be worked around with a fallback.
- Raw evidence, including command output, compile probes, runner READMEs and build logs, stays
  local and uncommitted under `~/.local/state/FluxKlang/transform-toolchain-api-inventory/`.

Evidence labels used throughout:

| Label | Meaning |
| --- | --- |
| **Verified** | Command output or a compile probe run on this machine with the selected Xcode. |
| **SDK** | Read from an SDK header or `.swiftinterface` at the cited `file:line`, but not compiled. |
| **Web** | Public source, retrieved 2026-10-31 (URLs in §14). This can change without notice. |
| **Assumption** / **Unknown** | Not verified. It must not be cited as a fact downstream. |

## 1. Gate summary

1. The selected toolchain, Xcode 27.1 (27A9275) with Swift 6.4 and Apple clang 21, ships the
   iOS 27.1, iOS Simulator 27.1 and macOS 27.0 SDKs. Both apps build unsigned for the
   iOS Simulator, a generic iOS device and macOS at deployment 27.0, with zero errors. Both
   schemes also compile their test bundles with `build-for-testing` (**Verified**).
2. `xcode-select` on this Mac points at Command Line Tools. Every command must set
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Without it, `xcodebuild` fails
   (**Verified**, §2).
3. OS-27 adds realtime-safe AVFAudio entry points, available from 27.0. They sit alongside the
   AU and HAL callbacks that were already annotated `CA_REALTIME_API` (Clang `nonblocking`) in
   the macOS 26.5 SDK. The new AVFAudio entry points, `AUAudioUnit.osWorkgroup` and
   `AudioWorkIntervalCreate` are **unavailable in Swift** (**Verified** by P5). A realtime core
   that uses them needs a C, Objective-C or C++ target, or a Rust C-ABI target.
4. Clang function-effect analysis (`nonblocking` and `nonallocating`) works, but only with
   `-Wfunction-effects`, which is off by default (**Verified** by P1 and P2). Swift does not
   enforce the annotation on closures it passes to C (**Verified** by P6). Swift's
   `@_noLocks`/`@_noAllocation` work but are underscored and unstable (**Verified** by P4).
5. **RTSan is unavailable** with the selected toolchain: `-fsanitize=realtime` and
   `-sanitize=realtime` are rejected, and there is no `rtsan` runtime (**Verified** by P3). This
   is a blocker for any claim backed by RTSan (§7.3).
6. CI: `actions/runner-images` lists only the **preview** `xcode-27` image with OS-27 SDKs.
   `macos-15` and `macos-26` cannot build at 27.0 (**Web**). The public Xcode Cloud release notes
   do not mention Xcode 27, so Xcode Cloud support is **Unknown** (§9).

## 2. Selected toolchain (Verified)

| Item | Value | Command |
| --- | --- | --- |
| Active developer dir (default) | `/Library/Developer/CommandLineTools` | `xcode-select -p` |
| Without `DEVELOPER_DIR` | `xcodebuild`: "requires Xcode, but active developer directory … is a command line tools instance"; `xcrun --show-sdk-path` gives the CLT `MacOSX.sdk` (to `MacOSX27.0.sdk`) | `env -u DEVELOPER_DIR …` |
| Selected Xcode | `/Applications/Xcode.app`, Xcode 27.1, build 27A9275. It is the only Xcode installed. | `xcodebuild -version` |
| Xcode build settings | `XCODE_VERSION_ACTUAL = 2710`, `XCODE_PRODUCT_BUILD_VERSION = 27A9275` | `-showBuildSettings` (slot) |
| Swift | Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1), swift-driver 1.168.6 | `swift --version` |
| Clang | Apple clang 21.0.0 (clang-2100.3.34.2) | `clang --version` |
| Linker | ld-27037.1 | `ld -v` |
| Command Line Tools | 27.0.0.0.1788430756, with SDKs MacOSX26.5 and MacOSX27.0. Same Swift and Clang builds, no RTSan. | `pkgutil`, `ls` |
| Instruments | xctrace 27.1 (27A9275). Templates include Audio System Trace, Time Profiler, CPU Profiler, CPU Counters, Allocations, Leaks, System Trace, Processor Trace, Swift Concurrency, Logging. | `xcrun xctrace version`, `xcrun xctrace list templates` |
| Host OS | macOS 27.2 (26B123), Darwin 27.2.0 | `sw_vers`, `uname -r` |
| Host CPU | Apple M1 Max, `arm64`, 10 cores (8 performance + 2 efficiency) | `uname -m`, `sysctl` |
| Rosetta 2 | **Not installed**: `arch -x86_64 /usr/bin/true` fails with "Bad CPU type in executable" | `arch` |

SDKs (`xcodebuild -showsdks`, `xcrun --sdk <sdk> --show-sdk-version/--show-sdk-build-version`):

| SDK | Version (build) | Default / max deployment (SDKSettings) | Arches (SDKSettings) |
| --- | --- | --- | --- |
| `iphoneos` | 27.1 (24A94232) | 27.0 / 27.1.99 | arm64, arm64e, arm64e.x1 |
| `iphonesimulator` | 27.1 | 27.0 / 27.1.99 | arm64, x86_64 |
| `macosx` | 27.0 (26A425). `-showsdks` lists `macosx27.0` twice because `MacOSX27.0.sdk` and `MacOSX27.sdk` are symlinks. | 27.0 / 27.0.99 | x86_64, x86_64h, arm64, arm64e, arm64e.x1 |
| others | DriverKit, tvOS, visionOS and watchOS 27.0 (not used by FluxKlang) | | |

Xcode 27 requires macOS Tahoe 26.6 or later and runs only on Apple silicon (**Web**:
[Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes),
162138432, and
[Xcode 27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)).

## 3. Destinations, runtimes and architectures

Simulator runtimes (`xcrun simctl list runtimes`, **Verified**):

- iOS 26.5 (23F77)
- iOS 27.0 (24A5423a and 24A434)
- iOS 27.1 (24A94425)
- tvOS, watchOS and visionOS 26.5 and 27.0

Destinations (`xcodebuild -showdestinations`, run in the slot, **Verified**):

- **FluxKlang (iOS):**
  - Eligible destinations are iOS 27.0 simulators and placeholders for any iOS device and any
    iOS Simulator. The 27.0 simulators are iPhone 17, 17 Pro, 17 Pro Max, 17e, 18 Pro,
    18 Pro Max and Air, plus several iPads. iPhone Duo is on the 27.1 runtime.
  - "My Mac (Designed for iPad/iPhone)" (arm64) and the visionOS 26.5 and 27.0 simulators in
    "Designed for iPad/iPhone" mode are also listed as eligible.
  - Every iOS 26.5 simulator is **ineligible**: "doesn't match FluxKlang.app's iOS Simulator
    27.0 deployment target". Native tvOS, watchOS and visionOS destinations and native macOS
    (arm64e) are ineligible.
  - The Makefile's `name=iPhone 17 Pro` resolves to one iOS 27.0 device locally.
- **FluxKlangMac:** The eligible destinations are the host Mac (`arm64`) and Any Mac. Every
  simulator is ineligible. This is unchanged on the merged tree, where the scheme also has a
  test action for FluxKlangMacTests.

Build settings (`xcodebuild -showBuildSettings -scheme … -sdk … -configuration …`, **Verified**):

| Scheme / SDK / config | `ARCHS` | `ARCHS_STANDARD` | `VALID_ARCHS` | `ONLY_ACTIVE_ARCH` | Deployment / SDK |
| --- | --- | --- | --- | --- | --- |
| FluxKlang / iphonesimulator / Debug | arm64 x86_64 | arm64 x86_64 | arm64 x86_64 | NO (no destination given) | iOS 27.0 / 27.1 |
| FluxKlang / iphoneos / Release | arm64 | arm64 | arm64 arm64e arm64e.x1 armv7 armv7s | NO | iOS 27.0 / 27.1 |
| FluxKlangMac / macosx / Debug | arm64 | arm64 | arm64 arm64e arm64e.x1 i386 x86_64 | YES | macOS 27.0 / 27.0 |
| FluxKlangMac / macosx / Release | arm64 | arm64 | same as Debug | NO | macOS 27.0 / 27.0 |

Other settings verified: `SWIFT_VERSION = 6`, `ENABLE_USER_SCRIPT_SANDBOXING = YES`, and the
macOS app has `ENABLE_APP_SANDBOX` and `ENABLE_HARDENED_RUNTIME` set to `YES`.

On the merged tree, all five targets (FluxKlang, FluxKlangTests, FluxKlangUITests,
FluxKlangMac and FluxKlangMacTests) have an effective deployment target of 27.0 in Debug and
Release. This was read from `xcodebuild -alltargets -showBuildSettings -json` through
`DEPLOYMENT_TARGET_SETTING_NAME`, which is the check proposed in §11-C.

Products (`lipo -archs`, `vtool -show-build`, **Verified**; the simulator and Mac rows were
re-checked on the merged tree):

| Product | Arch | Platform | minos | sdk |
| --- | --- | --- | --- | --- |
| iOS Simulator app, `FluxKlangTests.xctest`, `FluxKlangUITests.xctest` | arm64 | IOSSIMULATOR | 27.0 | 27.1 |
| iOS device app (pre-merge) | arm64 | IOS | 27.0 | 27.1 |
| Mac app, `FluxKlangMacTests.xctest` | arm64 | MACOS | 27.0 | 27.0 |
| `FluxKlangUITests-Runner` (Xcode's prebuilt UI-test runner stub, not built from repo sources) | arm64 | IOSSIMULATOR | 17.0 | 27.0 |

Supported native architectures:

- **macOS** is arm64 only at deployment 27.0. Xcode 27 removed x86_64 from `ARCHS_STANDARD`
  when `MACOSX_DEPLOYMENT_TARGET >= 27.0`; you can add it back explicitly in `ARCHS` (**Web**:
  [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes),
  "Intel Deprecation", 161837535). The SDK still carries x86_64 slices for back-deployment.
- **iOS device** is arm64.
- **iOS Simulator** defaults to arm64 plus x86_64. The x86_64 slice cannot run here because
  Rosetta is missing.
- **arm64e** is a valid architecture, but it is not built.
- **Universal or x86_64 builds:** The coordinator would have to opt in. The x86_64 slices would
  be untestable locally.

## 4. XcodeGen, SwiftLint and mise resolution (Verified)

| Tool | Version | Resolution on this Mac |
| --- | --- | --- |
| XcodeGen | 2.46.0 | Installed in Homebrew (`/opt/homebrew`, arm64) and in mise (`aqua:yonaskolb/XcodeGen`, universal). |
| SwiftLint | 0.65.1 | Installed in Homebrew and in mise (`aqua:realm/SwiftLint`). |
| mise | 2026.10.25 macos-arm64 | The global config does not activate xcodegen or swiftlint. |

Version pinning today:

- The repo has no `mise.toml`, `.tool-versions`, `.xcode-version` or `ci_scripts/`.
- The mise shims on `PATH` fall through to the Homebrew binaries, so versions follow whatever
  `brew` last installed.
- The README says `brew install xcodegen swiftlint`.

Pinning check: a throwaway `mise.toml` with `xcodegen = "2.46.0"` and `swiftlint = "0.65.1"`
(proposal A, §11) resolves both tools to the mise installs (`mise ls --current`, `mise which`).
The check used `MISE_AUTO_INSTALL=0` and `MISE_TRUSTED_CONFIG_PATHS` scoped to one run, so
nothing was installed or trusted. A re-check without `MISE_TRUSTED_CONFIG_PATHS` resolved the
same pins, while `mise trust --show` reported the directory as untrusted. With mise
2026.10.25, a file containing only `[tools]` therefore does not need trust locally. CI trust is
covered in §11-B.

## 5. Existing commands verified

| Command | How it was run | Result |
| --- | --- | --- |
| `make lint` (`swiftlint --strict`) | `mise exec swiftlint@0.65.1 -- swiftlint --strict`, and the Homebrew 0.65.1 binary. Re-run with Homebrew on the merged tree. | exit 0, no violations |
| `make generate` (`xcodegen generate`) | `mise exec xcodegen@2.46.0 -- xcodegen generate` and Homebrew 2.46.0 on the merged tree, then `git status --porcelain -- FluxKlang.xcodeproj` (rechecked on the whole tree, including the generated plists and entitlements) | Succeeds. **No drift**: the status is empty for both tools. |
| iOS Simulator `build-for-testing`, used in place of `make build` | `xcodebuild … -scheme FluxKlang -destination "id=<slot simulator>" build-for-testing CODE_SIGNING_ALLOWED=NO` in the fleet slot, with private DerivedData. `make build` itself runs `build` against `name=iPhone 17 Pro` and was not run. | `TEST BUILD SUCCEEDED` before and after the merge. Merged tree: 32.89 s real, 1 warning (AppIntents metadata extraction skipped). |
| `make build-mac` (pre-merge) | `xcodebuild … -scheme FluxKlangMac build CODE_SIGNING_ALLOWED=NO` (slot) | `BUILD SUCCEEDED` (33.95 s real, 0 warnings) |
| `make build-for-testing-mac` (merged tree) | The Make recipe plus a private DerivedData: `-scheme FluxKlangMac -destination 'platform=macOS' build-for-testing CODE_SIGNING_ALLOWED=NO` (slot) | `TEST BUILD SUCCEEDED` (38.30 s real, 0 warnings). FluxKlangMacTests compiles and nothing is launched. |
| Generic iOS device build (pre-merge) | `-destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` (slot) | `BUILD SUCCEEDED` (24.65 s real, 0 warnings) |
| `make test`, `make test-mac` | Not run. Both launch an app as the test host. Hosted execution is gated by #60, and by #51 for the Mac. | — |

Project sync history:

- Before 17a813a, regenerating changed 4 lines of object IDs for
  `StudioPhysicalOverlapTests.swift`. Those IDs had been hand-edited in ba6ab03. Group and
  target membership were identical.
- `main` 17a813a regenerated the project. On the merged tree, both XcodeGen builds reproduce
  `FluxKlang.xcodeproj` exactly.
- If an untracked file is added inside `FluxKlang.xcodeproj`, `git diff --exit-code` still
  passes but `git status --porcelain` reports it. That is why §11-C uses the porcelain check.
- XcodeGen also writes `FluxKlang/Info.plist`, `FluxKlangMac/Info.plist` and both
  `.entitlements` files from `project.yml`. If an `info.properties` value changes and the
  regenerated plist isn't committed, a project-only check passes: Actions builds the new
  plist while Xcode Cloud builds the stale one. §11-C therefore checks the whole working tree.
  Probe: adding an `info.properties` key, then regenerating, leaves the project-only status
  empty, while the whole-tree status reports ` M FluxKlang/Info.plist`.

The slot simulator's UDID is redacted. DerivedData was kept under the evidence directory, not
in `/tmp` or `/var/tmp`, and deleted afterwards.

## 6. Realtime and lifecycle API inventory

Paths are relative to `<SDK>/System/Library/Frameworks/<Framework>.framework/Headers/` unless
they start with `usr/`. "Mac" means `MacOSX27.0.sdk` and "iOS" means `iPhoneOS27.1.sdk`.
Unless noted, both SDKs have the line at the same number. A spot-check of 33 cited lines, plus
the `os` swiftinterface range, found them byte-identical in both SDKs.

**`CA_REALTIME_API`** (`CoreAudioTypes/CoreAudioBaseTypes.h:36-50`, **SDK** and **Verified**):

- Under C++11 and later it expands to `[[clang::nonblocking]]`. In C and Objective-C it expands
  to `__attribute__((nonblocking))`. If the compiler lacks the attribute, it expands to nothing.
- Matching lines in the macOS 27.0 SDK: 104 in total, made up of AudioToolbox 83, AVFAudio 4,
  CoreAudio 13 and CoreAudioTypes 4 (including the definition). The iOS 27.1 SDK has 88.
  CoreMIDI has none, so its callbacks are not annotated.
- The macOS 26.5 SDK from the Command Line Tools already defines the macro and has 85 matching
  lines: AudioToolbox 72, CoreAudio 9 and CoreAudioTypes 4. OS-27 adds the AVFAudio
  realtime-safe types and more AU and HAL annotations (**Verified**: `grep -R` over both SDKs).

### 6.1 AVFAudio realtime-safe blocks

| API | Availability | Evidence | Swift | Probe |
| --- | --- | --- | --- | --- |
| `AVAudioSourceNodeRenderBlockRealtimeSafe` (`CA_REALTIME_API`) | macOS/iOS/tvOS/watchOS/visionOS 27.0 | `AVFAudio/AVAudioSourceNode.h:48` | Unavailable | P2, P2b |
| `-[AVAudioSourceNode initWithRealtimeSafeRenderBlock:]`, `initWithFormat:realtimeSafeRenderBlock:` | 27.0 | `AVAudioSourceNode.h:88`, `:116` | Unavailable: "Swift is not supported for use with audio realtime threads" | P2 (ObjC OK), P5 (Swift error) |
| Legacy `AVAudioSourceNodeRenderBlock` | macOS 10.15 / iOS 13 | `AVAudioSourceNode.h:41` | Available, not annotated | P6 (an allocating closure compiles silently) |
| `AVAudioSinkNodeReceiverBlockRealtimeSafe`, `initWithRealtimeSafeReceiverBlock:` | 27.0 | `AVFAudio/AVAudioSinkNode.h:40`, `:87` | Unavailable | P2, P5 |
| `AVAudioIONodeInputBlockRealtimeSafe`, `-[AVAudioInputNode setRealtimeSafeManualRenderingInputPCMFormat:inputBlock:]` | 27.0 | `AVFAudio/AVAudioIONode.h:50`, `:218` | Unavailable | SDK |
| `AVMIDIEventListBlock` (`CA_REALTIME_API`), `connectMIDI:…eventListProvider:` | 27.0 | `AVFAudio/AVAudioEngine.h:150`, `:880`, `:988` | SDK | SDK |
| Manual rendering: `enableManualRenderingMode`, `AVAudioEngineManualRenderingModeRealtime`, `manualRenderingBlock` (block type **not** `CA_REALTIME_API`) | macOS 10.13 / iOS 11 | `AVAudioEngine.h:669`, `:92`/`:100`, `:738`, `:138` | Available | P6 (typecheck) |
| Throwing graph edits `connect…error:` (Swift `connectNode(_:to:format:)`), `installTapOnBus…error:block:`, `-[AVAudioPlayerNode playAndReturnError:]` | 27.0 | `AVAudioEngine.h:271`, `:295`, `:373`; `AVAudioNode.h:160`; `AVAudioPlayerNode.h:323`, `:383` | Available. At a 26.0 target: "only available in macOS 27.0". | P6 |
| `AVAudioEngineConfigurationChangeNotification` | macOS 10.10 / iOS 8 | `AVAudioEngine.h:1062` | Available | SDK |

### 6.2 AUAudioUnit (AudioToolbox) and workgroups

| API | Availability | Evidence | Swift | Probe |
| --- | --- | --- | --- | --- |
| `AURenderPullInputBlock`, `AURenderBlock`, `AURenderObserver`, `AUScheduleParameterBlock`, `AUScheduleMIDIEventBlock`, `AUMIDIOutputEventBlock`, `AUHostMusicalContextBlock`, `AUHostTransportStateBlock`, `AUInputHandler` (all `CA_REALTIME_API`) | macOS 10.11+ / iOS 9+. `AUAudioUnit.h` already had 9 `CA_REALTIME_API` lines in the macOS 26.5 SDK. | `AudioToolbox/AUAudioUnit.h:108-110`, `:143-145`, `:156-158`, `:181-183`, `:200-201`, `:215-216`, `:243-246`, `:302-304`, `:1225-1227` | Available, but **annotation not enforced** | P6 (an allocating closure in `AURenderPullInputBlock` compiles) |
| `allocateRenderResourcesAndReturnError`, `renderResourcesAllocated`, `renderBlock` | macOS 10.11 / iOS 9 | `AUAudioUnit.h:434`, `:449`, `:493` | Available | SDK |
| `scheduleMIDIEventListBlock`, `MIDIOutputEventListBlock`, `hostMIDIProtocol` (MIDI 2.0 UMP) | macOS 12 / iOS 15 | `AUAudioUnit.h:652`, `:719`, `:756` | Available | SDK |
| `AUAudioUnit.osWorkgroup` | macOS 11 / iOS 14 | `AUAudioUnit.h:1326-1328` | Unavailable | P5 |
| `AUInternalRenderBlock` (`CA_REALTIME_API`), `internalRenderBlock`, `renderContextObserver` | macOS 10.11+ / iOS 9+; observer macOS 11 / iOS 14 | `AudioToolbox/AUAudioUnitImplementation.h:196-203`, `:222`, `:232-234` | Observer unavailable | SDK |
| `AURenderContextObserver` (`CA_REALTIME_API`), `kAudioOutputUnitProperty_OSWorkgroup` | macOS 11 / iOS 14 | `AudioToolbox/AudioUnitProperties.h:1401`, `:2497`/`:2531`; Swift-unavailable marks at `:936`, `:1374`, `:1377`, `:1402`, `:2532` | Partly unavailable | SDK |
| `AudioWorkIntervalCreate` | macOS 11 / iOS 14 | `AudioToolbox/AudioWorkInterval.h:88-91` | Unavailable | P2 (ObjC OK), P5 |
| `os_workgroup_join`/`_leave`/`_max_parallel_threads`, `os_workgroup_interval_start`/`_update`/`_finish` | macOS 11 / iOS 14 (`OS_REFINED_FOR_SWIFT`) | `usr/include/os/workgroup_object.h:178`, `:203`, `:351`; `workgroup_interval.h:95`, `:124`, `:148` | Swift overlay `os.WorkGroup` (`join`/`leave`/`start`/`finish`/`maxParallelThreads`), `usr/lib/swift/os.swiftmodule/arm64e-apple-macos.swiftinterface:2335-2377` | P6 (join/leave typecheck) |
| `kAudioUnitType_HeadTrackingBinauralRenderer` | 27.0 | `AudioToolbox/AUComponent.h:226` | SDK | SDK |

### 6.3 CoreAudio HAL (macOS only)

The iOS SDK's CoreAudio framework contains only `AudioHardwareBase.h`, `AudioServerPlugIn.h` and
`CoreAudioTypes.h`. P9 confirms that the HAL symbols typecheck in Swift on macOS and are not
found on iOS.

| API | Availability | Evidence (Mac) | Swift (macOS) | Probe |
| --- | --- | --- | --- | --- |
| `AudioDeviceIOProc`, `AudioDeviceIOBlock` (`CA_REALTIME_API`) | Typedefs with no availability macro. Already annotated in the macOS 26.5 SDK. | `CoreAudio/AudioHardware.h:787-793`, `:832-836` | Available, not enforced | P2 (ObjC static IOProc), P9 |
| `AudioDeviceCreateIOProcID`, `AudioDeviceCreateIOProcIDWithBlock` | macOS 10.5 / 10.7 | `AudioHardware.h:1372`, `:1396-1399` | Available | P9 |
| `kAudioDevicePropertyIOThreadOSWorkgroup` (`'oswg'`) | Enum constant with no per-constant macro | `AudioHardware.h:1027` (doc `:987`) | Available | P2, P9 |
| `AudioObjectGetPropertyData`, `AudioObjectAddPropertyListener[Block]`, `kAudioHardwarePropertyDevices`, `AudioHardwareCreateAggregateDevice` | macOS 10.4–10.9 | `AudioHardware.h:291`, `:347`, `:397`, `:608`, `:667` | Available | P9 |
| `kAudioDevicePropertyIOStoppedAbnormally`, `BufferFrameSize`/`Range`/`UsesVariableBufferFrameSizes` | Enum constants with no per-constant macro | `AudioHardware.h:1017`, `:1019-1021` | Available | SDK |
| `kAudioDevicePropertyDeviceIsAlive`, `Latency`, `SafetyOffset` | Enum constants with no per-constant macro | `CoreAudio/AudioHardwareBase.h:746`, `:750`, `:753` | Available | SDK |
| `kAudioDevicePropertySuggestedReferenceDevice` | macOS 27.0 | `AudioHardware.h:1031` | SDK | SDK |
| `AudioGetCurrentHostTime` and other HostTime functions (`CA_REALTIME_API`) | macOS 10.0 | `CoreAudio/HostTime.h:53-91` | Available | SDK |

### 6.4 AVAudioSession (iOS only; `API_UNAVAILABLE(macos)` at `AVAudioSession.h:31`)

| API | Availability | Evidence (iOS SDK) | Swift | Probe |
| --- | --- | --- | --- | --- |
| `setPreferredSampleRate:`, `setPreferredIOBufferDuration:` | iOS 6 / iOS 3 | `AVFAudio/AVAudioSession.h:305`, `:310` | Available (iOS) | SDK |
| `activateWithOptions:completionHandler:`, `deactivateWithOptions:completionHandler:` | iOS 27.0 | `AVAudioSession.h:278`, `:289` | Available | SDK |
| `AVAudioSessionInterruptionContext`, `DeactivationContext`, `ResumptionContext` | iOS 27.0 | `AVAudioSession.h:571-606` | Available | SDK |
| `AVAudioSessionDidBecomeActiveNotification`, `DidBecomeInactiveNotification`, `ResumptionRecommendationNotification` and keys | iOS 27.0 | `AVFAudio/AVAudioSessionTypes.h:311`, `:316`, `:321`, `:377`, `:382` | Available (`didBecomeInactiveNotification`, `resumptionRecommendationNotification`) | P7 |
| `AVAudioSessionInterruptionNotification` | iOS 6.0, **deprecated in 27.0** in favor of the two notifications above | `AVAudioSessionTypes.h:229` | Available, **no deprecation diagnostic** (see note) | P7, P7b–P7e |
| `RouteChange`, `MediaServicesWereLost`, `MediaServicesWereReset` notifications | iOS 6 / 7 / 6 | `AVAudioSessionTypes.h:237`, `:245`, `:253` | Available | P7 |
| On macOS | Unavailable | — | "unavailable in macOS" | P7 |

Note on the missing deprecation diagnostic (**Verified**):

- The header declares `API_AVAILABLE(ios(6.0)) API_DEPRECATED(…, ios(6.0, 27.0))`. Clang keeps
  the first iOS availability attribute, so neither Swift nor Objective-C warns at an iOS 27.0
  target.
- A local reproduction with the attributes in that order is silent. With the order reversed,
  it warns.
- Consequence: migrating off this notification must be driven by code review. Compiler
  warnings will not catch it.

### 6.5 CoreMIDI (UMP, MIDI 2.0, MIDI-CI)

| API | Availability | Evidence | Swift | Probe |
| --- | --- | --- | --- | --- |
| `MIDIProtocolID` / `kMIDIProtocol_2_0`, `MIDIInputPortCreateWithProtocol`, `MIDIDestinationCreateWithProtocol`, `MIDISourceCreateWithProtocol`, `MIDISendEventList`, `MIDIReceivedEventList`, `MIDIEventListInit`/`Add` | macOS 11 / iOS 14 | `CoreMIDI/MIDIServices.h:305-307`, `:1512`, `:1931`, `:2052`, `:2401`, `:2521`, `:2619`, `:2655` | Available | P8 (`MIDIInputPortCreateWithProtocol(… ._2_0 …)`) |
| `MIDISendUMPSysex`, `MIDISendUMPSysex8` | macOS 14 / iOS 17 | `MIDIServices.h:2460`, `:2475` | Available | SDK |
| UMP 1.1 / MIDI-CI classes: `MIDICIDevice`, `MIDICIDeviceManager`, `MIDI2DeviceInfo`, `MIDIUMPEndpoint`, `MIDIUMPEndpointManager`, `MIDIUMPFunctionBlock`, `MIDIUMPMutableEndpoint`, `MIDIUMPCIProfile` (`MIDI_AVAILABLE_UMP1_1`) | macOS 15 / iOS 18 / visionOS 2 | `MIDIUMPCI.h:40`; `MIDICIDevice.h:75`; `MIDICIDeviceManager.h:118`; `MIDIUMPEndpoint.h:71`, `:140`; `MIDIUMPEndpointManager.h:124`; `MIDIUMPFunctionBlock.h:93`; `MIDIUMPMutableEndpoint.h:83`; `MIDIUMPCIProfile.h:97` | Available | P8 (`umpEndpoints`, `discoveredCIDevices`) |
| Legacy MIDI-CI: `MIDICISession`, `MIDICIDiscoveryManager`, `MIDICIResponder` | Deprecated macOS 15 / iOS 18 | `MIDIUMPCI.h:37-38`; `MIDICapabilityInquiry.h:203`, `:279`, `:312` | Deprecated | SDK |
| Inline UMP message builders (`CF_INLINE`) | No availability macro | `MIDIMessages.h:259` onwards | Available | SDK |

## 7. Compiler annotations and RT instrumentation

### 7.1 Clang function effects (Verified)

What works:

- `__has_attribute(nonblocking)` is true.
- `__attribute__((nonblocking))`, `nonallocating`, `[[clang::nonblocking]]` and
  `[[clang::nonallocating]]` compile in C, C++ and Objective-C for macOS 27.0, iOS 27.0 and the
  iOS 27.0 Simulator.

When diagnostics fire:

- Function-effect diagnostics are **off by default**. Without `-Wfunction-effects` a
  `nonblocking` function that calls `malloc` compiles silently.
- With the flag, Clang flags `malloc`/`free`, `std::mutex` with `lock_guard`, constructing a
  `std::vector`, `throw`, and Objective-C message sends.
- `-Werror=function-effects` turns these diagnostics into errors.
- Relaxed C11 atomics are accepted.

Block literals passed to Apple APIs:

- An unannotated block literal passed to an OS-27 realtime-safe API only warns that "attribute
  'nonblocking' should not be added via type conversion". It does **not** analyze the block
  body.
- Writing `^OSStatus(…) CA_REALTIME_API { … }` turns on body analysis (P2b and P2c).
- Xcode 27.1 has no build setting for function effects. A target needs
  `WARNING_CFLAGS`/`OTHER_CFLAGS` (verified by inspecting the Clang `xcspec` in
  `SWBUniversalPlatform.framework`).
- The realtime-safe initializers are 27.0-gated. At a macOS 26.0 target,
  `-Wunguarded-availability-new` fires for each of them.

### 7.2 Swift (Verified)

| Feature | Result |
| --- | --- |
| OS-27 realtime-safe AVFAudio blocks, `AUAudioUnit.osWorkgroup`, `AudioWorkIntervalCreate` | **Unavailable in Swift**: "Swift is not supported for use with audio realtime threads" (P5, macOS and iOS 27). |
| Swift closure passed to a `CA_REALTIME_API` C block type | Accepted with no diagnostic, even when it allocates (P6). Swift does **not** enforce Clang `nonblocking`. |
| `@_noLocks`, `@_noAllocation` | Accepted and enforced at the SIL level in `-Onone` and `-O`, but **not** in `-typecheck`. For example: "Using type 'Box' can cause metadata allocation or locks" and "this code performs reference counting operations which can cause locking". Clean pointer loops compile for macOS and iOS 27 in Swift 6 mode (P4). |
| `@_noRuntime`, `@_noExistentials`, `@_noObjCBridging` | Accepted (P4). |
| Public successor (`@noLocks`, `@noAllocation`, `@nonblocking`, `@nonallocating`, `@realtime`, `@_realtime`, `@_nonblocking`) | None. Each is an "unknown attribute" in Swift 6.4 (P4). |
| `swiftc -print-supported-features` | 21 upcoming, 56 experimental and 2 optional features. None is a realtime-effects feature. Related options include `Embedded`, `LifetimeDependence`/`Lifetimes`, `StrictMemorySafety`, `SafeInteropWrappers`, `TypedAllocation`. |

Interpretation:

- Underscored attributes are compiler-internal and unstable. They may serve as an *extra*
  guard on pure-Swift helpers, but never as certification.
- Swift may still own the non-realtime control plane and lifecycle (session, engine graph,
  HAL property listeners, workgroup join or leave from non-render threads).

### 7.3 RealtimeSanitizer (RTSan) — Blocker

What fails (**Verified**, P3):

- `xcrun clang -fsanitize=realtime` reports "unsupported option '-fsanitize=realtime' for
  target" for `arm64-apple-macos27.0`, `arm64-apple-ios27.0`, `arm64-apple-ios27.0-simulator`
  and `arm64-apple-darwin27.2.0`.
- `xcrun swiftc -sanitize=realtime` reports "invalid value 'realtime'".

What is missing:

- There is no `libclang_rt.rtsan*` in
  `XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin` or in the Command Line Tools.
- Xcode's sanitizer settings offer only Address, Thread, Undefined, Integer, Nullability,
  Scudo, MemTag-stack and fuzzer.
- No other toolchain is installed: there is no `/Library/Developer/Toolchains` and no Homebrew
  LLVM.

Possible future route (all **Unknown** until probed):

- Upstream Clang 20.1.0 introduced RTSan behind `-fsanitize=realtime`, and the same release
  turned on verification of `nonblocking`/`nonallocating` function effects (**Web**:
  [Clang 20.1.0 release notes](https://releases.llvm.org/20.1.0/tools/clang/docs/ReleaseNotes.html),
  "Sanitizers").
- The [Clang RealtimeSanitizer docs](https://clang.llvm.org/docs/RealtimeSanitizer.html)
  mention macOS only when describing the `abort_on_error` option (**Web**).
- The `xcode-27` and `macos-26` runner images provide Homebrew `llvm@20` 20.1.8 at
  `$(brew --prefix llvm@20)/bin/clang` (**Web**:
  [xcode-27](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
  and [macos-26](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
  image READMEs).
- Still unverified: whether upstream Clang 20 builds and links RTSan against the Apple OS-27
  SDKs on arm64, whether that works inside an Xcode target, and anything about iOS or the
  simulator.

Rules for downstream packages:

- No package may claim to be RTSan-verified until a tagged probe passes.
- Hot-path evidence must come from function-effect analysis (§7.1), measurement, and code review.

### 7.4 Verified vs assumed

| Claim | Status |
| --- | --- |
| OS-27 SDKs ship `CA_REALTIME_API` realtime-safe AVFAudio, AU and HAL entry points | Verified (SDK + P2) |
| Clang enforces `nonblocking` in an explicitly annotated function or block body when `-Wfunction-effects` is on | Verified (P1, P2b, P2c) |
| Apple's annotations make a callback realtime-safe | **False / assumption.** Unannotated literals are not analyzed, analysis is off by default, Swift is not enforced, and annotations say nothing about plugins, FFI or third-party code (#48). |
| RTSan is available | **False** for Xcode 27.1. Unknown for upstream LLVM 20 on OS-27. |
| Swift can author OS-27 realtime-safe render blocks | **False** (P5) |
| `@_noLocks`/`@_noAllocation` are stable public API | **False.** They are underscored. |
| Rust kernels can target iOS | **Unknown/gap.** Locally `rustc` 1.99.1 has only `aarch64-apple-darwin` installed, with no iOS or simulator targets. Matters only if #74 proceeds with Rust. |
| Processor Trace or CPU Counters work on this M1 Max | **Unknown.** The templates are listed, but nothing was recorded. |

## 8. Probe log

All probes are throwaway files under the evidence directory and are not committed. They used
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. None of them starts audio, MIDI,
hardware, an app or a simulator. P3 never produced a runnable binary.

| Probe | Command form | Result |
| --- | --- | --- |
| P1 C/C++ effects | `xcrun clang[++] -target arm64-apple-macos27.0 -fsyntax-only [-Wfunction-effects \| -Werror=function-effects] p1_effects.{c,cpp}`, `p1_has.c` | Attributes supported. Silent without the flag. Diagnostics or errors with it. |
| P2/P2b/P2c ObjC AVFAudio | `xcrun --sdk {macosx,iphoneos,iphonesimulator} clang -target arm64-apple-{macos27.0,ios27.0,ios27.0-simulator} -fobjc-arc -fmodules -Wfunction-effects -c p2*.m`; repeated at `macos26.0` with `-Wunguarded-availability-new` | Compiles on all 3 targets. Annotated block bodies are analyzed, unannotated ones are not. 26.0 gives availability errors. |
| P3 RTSan | `xcrun clang -fsanitize=realtime -target … p3_rtsan.c`, `xcrun swiftc -sanitize=realtime p3_san.swift`, `ls …/clang/21/lib/darwin` | Rejected, no runtime (§7.3). |
| P4 Swift perf attrs | `xcrun swiftc -swift-version 6 {-Onone,-O} -c -target arm64-apple-{macos27.0,ios27.0} p4_perf{,_clean}.swift` | Violations diagnosed at SIL level, clean code compiles, no public successor. |
| P5 Swift RT-safe APIs | `xcrun --sdk <sdk> swiftc -typecheck -swift-version 6 -target … p5_swift_unavail.swift` | "unavailable in Swift" on macOS and iOS 27. |
| P6 Swift lifecycle | same, `p6_swift_avail.swift` (macOS 27.0, iOS 27.0, macOS 26.0) | Typechecks on 27. `connectNode` is 27-gated. Allocating closures are not diagnosed. |
| P7 AVAudioSession | `p7_session.swift` (iOS/macOS); `p7b`–`p7e` Objective-C/C deprecation probes | iOS 27 names are available, the type is unavailable on macOS, and the deprecation is silent (§6.4). |
| P8 CoreMIDI | `p8_midi.swift` (macOS/iOS 27) | Typechecks. |
| P9 HAL | `p9_hal.swift` (macOS/iOS 27) | Typechecks on macOS. "cannot find" on iOS. |

## 9. CI and Xcode Cloud SDK gaps

Current repo CI (**Verified**, read only):

- `.github/workflows/apple-lint.yml` runs on `macos-15` with `actions/checkout@v6.0.3`,
  `brew install swiftlint` (unpinned) and `swiftlint --strict`.
- `release.yml` runs release-please on `ubuntu-latest`.
- There is no build or test CI.
- Releases go through Xcode Cloud, configured in App Store Connect, with no Fastlane and no
  `ci_scripts/`.
- The generated `FluxKlang.xcodeproj` is committed, so Xcode Cloud does not need XcodeGen.

GitHub-hosted macOS images (**Web**: the
[`actions/runner-images` README](https://github.com/actions/runner-images#available-images) and
the [macos-15](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md),
[macos-26](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
and [xcode-27](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
arm64 image READMEs, image versions 20261028.0489.1, 20261026.0455.2 and 20261026.0314.1):

| Label | Base OS | Xcode (default) | Newest iOS / macOS SDK | Builds at 27.0? |
| --- | --- | --- | --- | --- |
| `macos-15` (current lint job), `macos-15-xlarge` | macOS 15.8.2 | 16.4 (also 16.0–16.4, 26.0.1–26.3) | iOS 26.2 / macOS 26.2 | **No** |
| `macos-latest`, `macos-26`, `macos-26-xlarge` | macOS 26.6.2 | 26.6 (also 26.0.1–26.5) | iOS 26.5 / macOS 26.5 | **No** |
| `xcode-27`, `xcode-27-xlarge` (**preview**, [actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404)) | macOS 27.0.1 | **27.1 (27A9275)**, matching this Mac, at `/Applications/Xcode_27.1.app`; also 27.0 (27A266a) and 27.2 RC (27B48) | iOS 27.0–27.2 / macOS 27.0, 27.2 | **Yes** |

On the `xcode-27` image:

- The iOS 27.0 runtime ships iPhone 17, iPhone 17e, iPhone 18 Pro/Pro Max, iPhone Air and
  iPads.
- There is **no "iPhone 17 Pro"**, so `make build` and `make test` cannot resolve their
  destination there.
- XcodeGen, SwiftLint and mise are not listed. jq 1.8.2, SwiftFormat 0.64.3, xcbeautify 3.2.1
  and Homebrew 7.0.11 are listed.
- "Preview" means capacity and queueing can vary and software may be unstable
  ([actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404)).

Xcode Cloud:

- Apple's public [Xcode Cloud release notes](https://developer.apple.com/xcode-cloud/release-notes/)
  were last updated on 2026-02-10. The newest Xcode they mention is 26.2 (17C52) on macOS
  Tahoe 26.2 (**Web**). Whether Xcode 27.x is available is **Unknown** from public sources.
- The [Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
  says the Environment section lets you choose from available Xcode and macOS versions.
  [Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud)
  says the build environment includes Homebrew for `ci_post_clone.sh` (**Web**).

Gaps and blockers:

| # | Gap | Severity | Owner |
| --- | --- | --- | --- |
| G1 | No GA GitHub-hosted image has OS-27 SDKs. Only the preview `xcode-27` label does. | Blocker for #61 on GA runners. Preview risk otherwise. | #61 / coordinator |
| G2 | Xcode Cloud availability of Xcode 27.x is unverified. | **Release blocker** until it is confirmed in App Store Connect. | Maintainer |
| G3 | RTSan is not in Xcode 27.1. Upstream LLVM 20 on OS-27 is unprobed. | Blocker for RTSan claims (#60/#74) | #74 / runtime lanes |
| G4 | The Makefile simulator name is absent on the `xcode-27` image. | CI breakage | Coordinator (diff D) |
| G5 | Lint uses an unpinned `brew install swiftlint`. Local pins are inactive. | Drift risk | Coordinator (diffs A, B) |
| G6 | ~~The committed `project.pbxproj` is not reproducible byte for byte from `project.yml`.~~ | **Resolved** on `main` by 17a813a. The merged tree has no drift (§5). | Done |
| G7 | No Rust iOS targets are installed locally. | Gap only if Rust is pursued (#74) | #74 |
| G8 | `xcode-select` points at the Command Line Tools. | Local trap | Every agent: set `DEVELOPER_DIR` |

## 10. Provisioning plan (proposed; nothing installed)

1. **Local:** Keep Xcode 27.1 (27A9275) at `/Applications/Xcode.app` and always export
   `DEVELOPER_DIR`. Optionally run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`;
   that is the maintainer's choice and was not applied. Adopt the repo `mise.toml` (A) and run
   `mise install`. Both pinned versions are already present on this Mac. Run Make through the
   pins with `mise exec -- make …`, or with mise activated or its shims first on PATH (E);
   `mise install` alone does not change PATH.
2. **GitHub Actions (#61):**
   - Add a build job on `runs-on: xcode-27` with
     `DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer`.
   - The job first runs fail-fast checks: the SDKs are at least 27.0, the generated project is
     in sync, and every target's effective deployment target is 27.0. It installs the pinned
     tools with `jdx/mise-action`, pinned to a commit.
   - It runs `build-for-testing` for macOS and iOS with signing disabled, using a simulator
     present on the image, then checks that every built Mach-O has `minos` 27.0 (C).
   - Hosted test execution waits for #60.
   - When an OS-27 image goes GA, switch the label to it. Never fall back to `macos-26` or
     `macos-15` for build jobs.
3. **Xcode Cloud (release):** No repo change.
   - In App Store Connect, confirm that a workflow can select Xcode 27.1 or newer on a
     macOS 27 or Tahoe 26.6+ image.
   - If it cannot, releases are blocked. Do not lower the deployment target and do not add
     Fastlane.
   - Keep the committed `.xcodeproj` as the Xcode Cloud input. It is in sync since 17a813a, and
     CI check C keeps it that way.
4. **RTSan (optional, #74):**
   - In a separate non-blocking job or a maintainer-approved local install, compile and run
     the P3 malloc-in-`nonblocking` probe with Homebrew `llvm@20` against the macOS 27 SDK.
   - Record the result. Only a pass upgrades G3, and only for macOS.
5. **Rust (conditional, #74):** If the Rust lane proceeds, `rustup target add aarch64-apple-ios
   aarch64-apple-ios-sim` and pin the toolchain in the Rust package. This was not done here.

## 11. Proposed coordinator diffs (not applied)

**A. New `mise.toml`** at the repo root. It was validated in a throwaway directory (§4).

```toml
# Developer tool pins; select Xcode separately via DEVELOPER_DIR (Xcode 27.1+).
[tools]
xcodegen = "2.46.0"
swiftlint = "0.65.1"
```

**B. `.github/workflows/apple-lint.yml`:** Pin SwiftLint and keep the runner. Lint needs no
OS-27 SDK, and SwiftLint parses with its bundled SwiftSyntax.

- **Prerequisite: diff A.** `install_args: swiftlint` installs the pinned 0.65.1 only when
  the repo `mise.toml` exists. Without it, mise resolves the latest release. In an empty
  directory, `mise install --dry-run swiftlint` picks 0.65.1, which is what
  `mise latest swiftlint` returns today, so the two cases only look the same until SwiftLint's
  next release.
- **Pin the action to a commit.** The repo pins exact tags such as `actions/checkout@v6.0.3`,
  but `@v5` is a floating major tag. The latest release is v5.2.5, published 2026-10-31. Its
  tag points at commit `6612f0ef07ed2a736cd1e00a94a065522dd41195`, as reported by
  `gh api repos/jdx/mise-action/git/ref/tags/v5.2.5` and `…/commits/<sha>` ("chore: release
  v5.2.5"). Use the SHA with a version comment as below. If the repo prefers tags, use at
  least `@v5.2.5`.
- **Pin mise itself** with `version: 2026.10.25`, which matches this Mac. Without it, the
  action installs the newest mise release that is at least 24 hours old.
- **CI config trust is unverified.** The v5.2.5 source
  ([`src/index.ts:390-391`](https://github.com/jdx/mise-action/blob/6612f0ef07ed2a736cd1e00a94a065522dd41195/src/index.ts#L390-L391))
  exports `MISE_TRUSTED_CONFIG_PATHS` set to the working directory and `MISE_YES=1` to later
  steps, unless they are already set. Locally, a `[tools]`-only `mise.toml` resolves even when
  it is untrusted (§4). Neither behaviour has been observed on a GitHub runner, and the local
  `MISE_TRUSTED_CONFIG_PATHS` was scoped to one command.
- `permissions: contents: read` restricts the default `GITHUB_TOKEN` to reading.
- **PATH activation is asserted, not assumed.** By default the action prepends its shims
  directory (`add_shims_to_path`) and the paths `mise env --paths` manages
  ([`src/index.ts:275-300, 393-396`](https://github.com/jdx/mise-action/blob/6612f0ef07ed2a736cd1e00a94a065522dd41195/src/index.ts#L275-L300)).
  An image-provided or Homebrew SwiftLint/XcodeGen could still shadow the pin, or a missing
  shim could fail late. So B and C each add a step that compares the tool on `PATH` with
  `mise current <tool>` and fails on a mismatch. Locally, both comparisons hold in a directory
  with diff A's `mise.toml` (`0.65.1`; `Version: 2.46.0`).

```diff
 name: Lint

 on:
   push:
     branches: [main]
   pull_request:

+permissions:
+  contents: read
+
 jobs:
   swiftlint:
     runs-on: macos-15
     steps:
       - uses: actions/checkout@v6.0.3
-      - name: Install SwiftLint
-        run: brew install swiftlint
+      - name: Install pinned SwiftLint (mise.toml)
+        uses: jdx/mise-action@6612f0ef07ed2a736cd1e00a94a065522dd41195 # v5.2.5
+        with:
+          version: 2026.10.25
+          install_args: swiftlint
+      - name: Pinned SwiftLint is on PATH
+        run: |
+          want=$(mise current swiftlint); have=$(swiftlint version)
+          echo "swiftlint $have at $(command -v swiftlint); mise.toml pins $want"
+          if [ -z "$want" ] || [ "$have" != "$want" ]; then
+            echo "::error::swiftlint '$have' is not the mise.toml pin '$want'"; exit 1
+          fi
       - name: Lint
         run: swiftlint --strict
```

**C. New `.github/workflows/apple-build.yml` for #61.** It does build qualification only. Test
execution follows #60. It depends on diff A, because `xcodegen` comes from `mise.toml`.

- The deployment checks use **effective** values rather than grepping `project.yml`, so they
  catch per-target `deploymentTarget` overrides and `IPHONEOS_`/`MACOSX_DEPLOYMENT_TARGET`
  settings.
  - Before building, it reads each target's `DEPLOYMENT_TARGET_SETTING_NAME` from
    `-alltargets -showBuildSettings -json` for Debug and Release.
  - After building, it reads the `minos` of every built Mach-O with `vtool -show-build`.
- `defaults.run.shell: bash` makes GitHub run steps with `bash -eo pipefail`.
- **Unverified destination:** `name=iPhone 17,OS=27.0` comes from the `xcode-27` image README
  (§9). It has not been resolved on a runner, and iPhone 17 Pro is not listed there (§13).

```yaml
name: Apple build

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

defaults:
  run:
    shell: bash

jobs:
  build:
    # Preview image; the only GitHub-hosted label with OS-27 SDKs as of 2026-10-31.
    runs-on: xcode-27
    env:
      DEVELOPER_DIR: /Applications/Xcode_27.1.app/Contents/Developer
    steps:
      - uses: actions/checkout@v6.0.3
      - uses: jdx/mise-action@6612f0ef07ed2a736cd1e00a94a065522dd41195 # v5.2.5
        with:
          version: 2026.10.25
          install_args: xcodegen
      - name: Pinned XcodeGen is on PATH
        run: |
          want=$(mise current xcodegen); have=$(xcodegen --version)
          echo "$have at $(command -v xcodegen); mise.toml pins $want"
          if [ -z "$want" ] || [ "$have" != "Version: $want" ]; then
            echo "::error::xcodegen '$have' is not the mise.toml pin '$want'"; exit 1
          fi
      - name: Require OS-27 SDKs
        run: |
          xcodebuild -version
          for sdk in macosx iphoneos iphonesimulator; do
            v=$(xcrun --sdk "$sdk" --show-sdk-version)
            echo "$sdk SDK $v"
            [ "${v%%.*}" -ge 27 ] || { echo "::error::$sdk SDK $v < 27.0 (no deployment downgrade)"; exit 1; }
          done
      - name: Generated project is in sync
        # Whole tree: XcodeGen also rewrites both apps' Info.plist and .entitlements files.
        run: |
          xcodegen generate
          git status --porcelain --untracked-files=all
          test -z "$(git status --porcelain --untracked-files=all)"
      - name: Effective deployment targets are 27.0
        run: |
          status=0
          for cfg in Debug Release; do
            rows=$(xcodebuild -project FluxKlang.xcodeproj -alltargets -configuration "$cfg" \
                -showBuildSettings -json \
              | jq -r '.[] | .buildSettings as $s | $s.DEPLOYMENT_TARGET_SETTING_NAME as $k
                  | [.target, $k, ($s[$k] // "unset")] | @tsv')
            [ -n "$rows" ] || { echo "::error::no $cfg build settings"; exit 1; }
            while IFS=$'\t' read -r target key value; do
              echo "$cfg $target $key=$value"
              [ "$value" = "27.0" ] || { echo "::error::$cfg $target $key=$value; deployment must stay 27.0"; status=1; }
            done <<< "$rows"
          done
          exit "$status"
      - name: Build macOS for testing
        run: >
          xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMac
          -destination 'platform=macOS'
          -derivedDataPath DerivedData build-for-testing CODE_SIGNING_ALLOWED=NO
      - name: Build iOS for testing
        run: >
          xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlang
          -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
          -derivedDataPath DerivedData build-for-testing CODE_SIGNING_ALLOWED=NO
      - name: Built products target OS 27.0
        # Skips Xcode's prebuilt UI-test runner stub (minos 17.0); its PlugIns are still checked.
        run: |
          status=0; count=0
          while IFS= read -r -d '' bin; do
            # Check linked images by content, not mode: libraries can be 0644. Objects and dSYMs are skipped.
            case $(file -b "$bin") in
              Mach-O*executable* | Mach-O*shared\ library* | Mach-O*bundle*) ;;
              *) continue ;;
            esac
            rel=${bin#DerivedData/Build/Products/}
            count=$((count + 1))
            if ! info=$(xcrun vtool -show-build "$bin" 2>&1) || ! archs=$(xcrun lipo -archs "$bin" 2>&1); then
              echo "::error::$rel could not be inspected"; status=1; continue
            fi
            # Universal binaries report one minos per slice; every slice must report 27.0.
            slices=$(awk '$1 == "minos" { print $2 }' <<< "$info")
            set -- $slices; nminos=$#; set -- $archs
            [ "$nminos" -ge "$#" ] || { echo "::error::$rel has $# slice(s) but $nminos minos"; status=1; }
            for minos in $slices; do
              echo "minos $minos $rel"
              [ "$minos" = "27.0" ] || { echo "::error::$rel minos $minos; deployment must stay 27.0"; status=1; }
            done
          done < <(find DerivedData/Build/Products -type f ! -path '*-Runner.app/*-Runner' -print0)
          [ "$count" -gt 0 ] || { echo "::error::no Mach-O products found"; exit 1; }
          exit "$status"
```

Checks run on C locally. The step scripts were extracted from this block with `yq` and run
under `bash -eo pipefail`. Commands that call `xcodebuild` ran in the fleet slot.

| Step | Passes on | Fails (exit 1, `::error::`) on |
| --- | --- | --- |
| SDK check | Xcode 27.1 | An SDK that reports 26.5 |
| Project sync | The merged tree, with mise and Homebrew XcodeGen | An untracked file inside `FluxKlang.xcodeproj`. The earlier `git diff --exit-code` passed it. |
| Effective deployment | The merged tree: 5 targets × Debug and Release, all 27.0, in 7.3 s | Throwaway copies with `deploymentTarget: "26.0"` on FluxKlangTests, or `MACOSX_DEPLOYMENT_TARGET: "26.0"` in FluxKlangMacTests settings. The earlier `project.yml` grep passed both. |
| Product `minos` | Simulator and Mac Debug products: 8 linked images (executables, dylibs, bundles), all 27.0. 81 SwiftPM object files (`minos` 12.0 or 15.0) and dSYMs are skipped, because only linked images ship. | A binary built with `-target arm64-apple-macos26.0`; a mode-0644 dylib at 26.0; a universal binary with arm64 at 27.0 and x86_64 at 26.0; the same binary after `vtool -remove-build-version` on one slice ("2 slice(s) but 1 minos"); and a truncated Mach-O that `vtool` can't read ("could not be inspected"). Before the runner exclusion was added, it also flagged `FluxKlangUITests-Runner` (17.0). |

Static checks: `actionlint` 1.7.12 with shellcheck reports only the unknown preview label
`xcode-27`. If actionlint is adopted, declare that label in `.github/actionlint.yaml`.

**Not verified:** the workflow has not run on a GitHub runner. That includes the simulator
destination, mise config trust and the image's tool paths.

**D. `Makefile`:** Make the simulator destination overridable. The local default is unchanged,
and CI can pass `IOS_SIM_DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=27.0'`.
Recipe lines must start with a tab, so this is shown as the resulting text rather than as a
unified diff. Add this after the `.PHONY` line. On the merged tree that line also lists
`build-for-testing-mac` and `test-mac`, and it needs no change.

```make
IOS_SIM_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
```

Only `build` and `test` name an iOS simulator. In both, replace
`-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \` with:

```make
	  -destination '$(IOS_SIM_DESTINATION)' \
```

`build-mac` has no destination, and `build-for-testing-mac` and `test-mac` use
`platform=macOS`, so those three are unchanged. This was checked with `make -n` on a throwaway
copy of the merged Makefile. Without an override, `build` and `test` still use iPhone 17 Pro.
With the override, both use it, and the three Mac targets print the same commands as before.

**E. `README.md` (Develop section):**

```diff
-brew install xcodegen swiftlint   # if not already installed
-make generate                     # xcodegen generate
+mise install                      # pinned xcodegen + swiftlint (mise.toml)
+export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode 27.1+; needed if xcode-select points at CLT
+mise exec -- make generate        # pinned xcodegen, even when Homebrew has another on PATH
 open FluxKlang.xcodeproj
```

In the Validate block, add one line before the `make` commands:

```diff
+# Run these through the pins: prefix with `mise exec --`, or activate mise / put its shims first on PATH.
 make lint                   # swiftlint --strict
```

`mise install` only installs; it does not put the pins on PATH. A bare `make` in a shell without
mise activation or shims runs whatever `xcodegen`/`swiftlint` comes first. On this Mac that is
Homebrew's (`/opt/homebrew/bin/xcodegen`), so the pin would be bypassed silently. Checked in a
clean `env -i` shell with Homebrew on PATH and a throwaway `mise.toml`: `mise exec -- xcodegen`
resolved `~/.local/share/mise/installs/xcodegen/2.46.0`, and `mise exec -- make generate`
and `mise exec -- make lint` both exited 0 with no drift.

**F. Future native realtime target** (#60/#74/runtime lanes; for when a C, Objective-C or C++
RT target exists). This goes in `project.yml` target settings and applies only to that target:

```yaml
settings:
  base:
    WARNING_CFLAGS: ["-Wfunction-effects"]
    OTHER_CFLAGS: ["-Werror=function-effects"]
```

Pair this with an explicit `CA_REALTIME_API` (or `[[clang::nonblocking]]`) on every render or
IO block literal and callback (§7.1). Do not add `-fsanitize=realtime`, because Xcode 27.1
rejects it.

**G. Regenerate the Xcode project: obsolete.** `main` 17a813a regenerated the project, and the
merged tree has no XcodeGen drift (§5). There is nothing to apply. The letter is kept so the
references to A–F stay stable.

## 12. Follow-ups for other packages

- **#61:**
  - Land A first, because B and C depend on it. Then adopt B, C and D.
  - Track the `xcode-27` preview-to-GA status and switch the label when an OS-27 GA image
    exists.
  - Keep the fail-fast SDK check, the effective-deployment check and the product `minos` check.
  - Record the image version per run (`ImageVersion` in the job log).
- **#60:**
  - Hosted tests stay gated. That covers `make test` and `make test-mac`.
  - `build-for-testing` already succeeds for the slot simulator and for
    `make build-for-testing-mac`.
  - On `xcode-27`, use `iPhone 17` (iOS 27.0) or create a device explicitly.
- **#74 and runtime lanes:**
  - Put the realtime core in a C, Objective-C or C++ (or Rust C-ABI) target with F.
  - Use the OS-27 `…RealtimeSafe` APIs from that target only.
  - Use `os_workgroup` and `AudioWorkIntervalCreate` for auxiliary RT workers.
  - Use `kAudioDevicePropertyIOThreadOSWorkgroup` on the Mac HAL and
    `kAudioOutputUnitProperty_OSWorkgroup` or `AUAudioUnit.osWorkgroup` on AU paths.
  - Treat annotations as necessary but not sufficient.
  - Run the RTSan probe (plan step 4) before claiming RTSan coverage.
  - Profile with xctrace templates: Audio System Trace, Time Profiler, Allocations, System Trace.
- **Mobile lifecycle:** Migrate interruption handling to
  `didBecomeInactiveNotification`/`resumptionRecommendationNotification` and the iOS 27
  async activation API. The compiler will not flag the deprecated notification (§6.4).

## 13. Assumptions and unknowns

- Runner image contents and Xcode Cloud documentation are **Web** snapshots from 2026-10-31.
  Re-check them when implementing #61.
- Xcode Cloud availability of Xcode 27.x and macOS 27: **Unknown**.
- Upstream LLVM 20 RTSan on Darwin arm64 with OS-27 SDKs, and RTSan on iOS or the simulator:
  **Unknown**.
- The `xcode-27` image's simulator list is from its README. Devices not listed there, such as
  iPhone 17 Pro, might be creatable with `simctl create`, but that is unverified. The C
  destination `name=iPhone 17,OS=27.0` has not been resolved on a runner either.
- No proposed workflow (B or C) has run on GitHub Actions. Whether mise trusts the repo config
  there is unverified. The `MISE_TRUSTED_CONFIG_PATHS` export comes from reading the action's
  source, not from running it.
- Measured build times are single-run figures from a shared machine with a private
  DerivedData. They are not benchmarks.
- No hardware, audio, MIDI or latency results are claimed here.

## 14. Sources (Web)

Each URL below was fetched on 2026-10-31 with `web_fetch` or `curl`, and each one resolved.
Apple's documentation pages are rendered by JavaScript. For those, the quoted text was checked
against the matching JSON at `developer.apple.com/tutorials/data/documentation/….json`.

| Claim | Source |
| --- | --- |
| Xcode 27 requires Tahoe 26.6+ and Apple silicon (162138432); x86_64 left out of `ARCHS_STANDARD` at macOS 27.0 (161837535) | <https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes> |
| Xcode 27.1 requires Tahoe 26.6+ | <https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes> |
| Xcode Cloud: newest listed Xcode is 26.2 (17C52); last update 2026-02-10 | <https://developer.apple.com/xcode-cloud/release-notes/> |
| Xcode Cloud: the Environment section selects the Xcode and macOS versions | <https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference> |
| Xcode Cloud: Homebrew is available to `ci_post_clone.sh` | <https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud> |
| Runner labels and images | <https://github.com/actions/runner-images#available-images> |
| `macos-15` (arm64) contents | <https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md> |
| `macos-26` (arm64) contents, `llvm@20` | <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md> |
| `xcode-27` contents: Xcode, simulators, jq, `llvm@20` | <https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md> |
| `xcode-27` is a preview image | <https://github.com/actions/runner-images/issues/14404> |
| Clang 20.1.0 introduced RTSan and function-effect verification | <https://releases.llvm.org/20.1.0/tools/clang/docs/ReleaseNotes.html> |
| RTSan options (`abort_on_error` mentions macOS) | <https://clang.llvm.org/docs/RealtimeSanitizer.html> |
| `jdx/mise-action` v5.2.5 release, and the commit its tag points at | <https://github.com/jdx/mise-action/releases/tag/v5.2.5> |
| mise-action exports `MISE_TRUSTED_CONFIG_PATHS` and `MISE_YES` | <https://github.com/jdx/mise-action/blob/6612f0ef07ed2a736cd1e00a94a065522dd41195/src/index.ts#L390-L391> |
