# OS-27 toolchain, SDK and realtime API inventory

Package `toolchain-api-inventory` for #59 (roadmap #48, gate G-SDK). It feeds #60 (hosted
native tests), #61 (OS-27 CI) and #74 (native I/O backends and native vs Rust kernels).

- Captured: 2026-10-31 at `main` 9cfa1ec on one Apple-silicon development Mac. Usernames,
  hostnames, device identifiers and serials are redacted, and home paths are shown as `~`.
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
| **Web** | Public source, retrieved 2026-10-31. This can change without notice. |
| **Assumption** / **Unknown** | Not verified. It must not be cited as a fact downstream. |

## 1. Gate summary

1. The selected toolchain, Xcode 27.1 (27A9275) with Swift 6.4 and Apple clang 21, ships the
   iOS 27.1, iOS Simulator 27.1 and macOS 27.0 SDKs. Both apps build unsigned for the
   iOS Simulator, a generic iOS device and macOS at deployment 27.0, with zero errors (**Verified**).
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

Xcode 27 requires macOS Tahoe 26.6 or later and runs only on Apple silicon (**Web**: Xcode 27
and 27.1 release notes).

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
  simulator is ineligible.

Build settings (`xcodebuild -showBuildSettings -scheme … -sdk … -configuration …`, **Verified**):

| Scheme / SDK / config | `ARCHS` | `ARCHS_STANDARD` | `VALID_ARCHS` | `ONLY_ACTIVE_ARCH` | Deployment / SDK |
| --- | --- | --- | --- | --- | --- |
| FluxKlang / iphonesimulator / Debug | arm64 x86_64 | arm64 x86_64 | arm64 x86_64 | NO (no destination given) | iOS 27.0 / 27.1 |
| FluxKlang / iphoneos / Release | arm64 | arm64 | arm64 arm64e arm64e.x1 armv7 armv7s | NO | iOS 27.0 / 27.1 |
| FluxKlangMac / macosx / Debug | arm64 | arm64 | arm64 arm64e arm64e.x1 i386 x86_64 | YES | macOS 27.0 / 27.0 |
| FluxKlangMac / macosx / Release | arm64 | arm64 | same as Debug | NO | macOS 27.0 / 27.0 |

Other settings verified: `SWIFT_VERSION = 6`, `ENABLE_USER_SCRIPT_SANDBOXING = YES`, and the
macOS app has `ENABLE_APP_SANDBOX` and `ENABLE_HARDENED_RUNTIME` set to `YES`.

Products (`lipo -archs`, `vtool -show-build`, **Verified**):

| Product | Arch | Platform | minos | sdk |
| --- | --- | --- | --- | --- |
| iOS Simulator app | arm64 | IOSSIMULATOR | 27.0 | 27.1 |
| iOS device app | arm64 | IOS | 27.0 | 27.1 |
| Mac app | arm64 | MACOS | 27.0 | 27.0 |

Supported native architectures:

- **macOS** is arm64 only at deployment 27.0. Xcode 27 removed x86_64 from `ARCHS_STANDARD`
  when `MACOSX_DEPLOYMENT_TARGET >= 27.0`; you can add it back explicitly in `ARCHS` (**Web**:
  Xcode 27 release notes, "Intel Deprecation", 161837535). The SDK still carries x86_64 slices
  for back-deployment.
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
nothing was installed or trusted.

## 5. Existing commands verified

| Command | How it was run | Result |
| --- | --- | --- |
| `make lint` (`swiftlint --strict`) | `mise exec swiftlint@0.65.1 -- swiftlint --strict`, and the Homebrew 0.65.1 binary | exit 0, no violations |
| `make generate` (`xcodegen generate`) | `mise exec xcodegen@2.46.0 -- xcodegen generate` and Homebrew 2.46.0. The output was reverted afterwards. | Succeeds. **Drift:** `project.pbxproj` changes by 4+/4−. |
| `make build` (iOS Simulator) | `xcodebuild … -scheme FluxKlang -destination "id=<slot simulator>" build-for-testing CODE_SIGNING_ALLOWED=NO` in the fleet slot, with private DerivedData | `TEST BUILD SUCCEEDED` (34.98 s real, 1 warning: AppIntents metadata extraction skipped) |
| `make build-mac` | `xcodebuild … -scheme FluxKlangMac build CODE_SIGNING_ALLOWED=NO` (slot) | `BUILD SUCCEEDED` (33.95 s real, 0 warnings) |
| Generic iOS device build | `-destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` (slot) | `BUILD SUCCEEDED` (24.65 s real, 0 warnings) |
| `make test` | Not run, because hosted tests are gated by #60 and this package does not launch apps. | — |

Notes on the drift:

- The only change is the object IDs for `StudioPhysicalOverlapTests.swift`. The committed IDs
  were hand-incremented in commit ba6ab03.
- Group and target membership are identical, so there is no functional difference.
- Both tool builds produce exactly the same drift.

The slot simulator's UDID is redacted. DerivedData was kept under the evidence directory, not
in `/tmp`.

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

- Upstream LLVM introduced RTSan in Clang 20 (**Web**: LLVM 20.1.0 release notes; the clang
  RealtimeSanitizer docs mention macOS behavior).
- The `xcode-27` and `macos-26` runner images provide Homebrew `llvm@20` 20.1.8 at
  `$(brew --prefix llvm@20)/bin/clang` (**Web**).
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

GitHub-hosted macOS images (**Web**, `actions/runner-images` README and image READMEs, image
versions from 2026-10-26 to 2026-10-28):

| Label | Base OS | Xcode (default) | Newest iOS / macOS SDK | Builds at 27.0? |
| --- | --- | --- | --- | --- |
| `macos-15` (current lint job), `macos-15-xlarge` | macOS 15.8.2 | 16.4 (also 16.0–16.4, 26.0.1–26.3) | iOS 26.2 / macOS 26.2 | **No** |
| `macos-latest`, `macos-26`, `macos-26-xlarge` | macOS 26.6.2 | 26.6 (also 26.0.1–26.5) | iOS 26.5 / macOS 26.5 | **No** |
| `xcode-27`, `xcode-27-xlarge` (**preview**, actions/runner-images#14404) | macOS 27.0.1 | **27.1 (27A9275)**, matching this Mac, at `/Applications/Xcode_27.1.app`; also 27.0 (27A266a) and 27.2 RC (27B48) | iOS 27.0–27.2 / macOS 27.0, 27.2 | **Yes** |

On the `xcode-27` image:

- The iOS 27.0 runtime ships iPhone 17, iPhone 17e, iPhone 18 Pro/Pro Max, iPhone Air and
  iPads.
- There is **no "iPhone 17 Pro"**, so `make build` and `make test` cannot resolve their
  destination there.
- XcodeGen, SwiftLint and mise are not listed. SwiftFormat 0.64.3, xcbeautify 3.2.1 and
  Homebrew 7.0.11 are listed.
- "Preview" means capacity and queueing can vary and software may be unstable (actions/runner-images#14404).

Xcode Cloud:

- Apple's public Xcode Cloud release notes were last updated on 2026-02-10. The newest Xcode
  they mention is 26.2 (17C52) on macOS Tahoe 26.2 (**Web**). Whether Xcode 27.x is available
  is **Unknown** from public sources.
- The Xcode Cloud workflow reference says the Environment section lets you choose from
  available Xcode and macOS versions. Xcode Cloud includes Homebrew for `ci_post_clone.sh`
  (**Web**).

Gaps and blockers:

| # | Gap | Severity | Owner |
| --- | --- | --- | --- |
| G1 | No GA GitHub-hosted image has OS-27 SDKs. Only the preview `xcode-27` label does. | Blocker for #61 on GA runners. Preview risk otherwise. | #61 / coordinator |
| G2 | Xcode Cloud availability of Xcode 27.x is unverified. | **Release blocker** until it is confirmed in App Store Connect. | Maintainer |
| G3 | RTSan is not in Xcode 27.1. Upstream LLVM 20 on OS-27 is unprobed. | Blocker for RTSan claims (#60/#74) | #74 / runtime lanes |
| G4 | The Makefile simulator name is absent on the `xcode-27` image. | CI breakage | Coordinator (diff D) |
| G5 | Lint uses an unpinned `brew install swiftlint`. Local pins are inactive. | Drift risk | Coordinator (diffs A, B) |
| G6 | The committed `project.pbxproj` is not reproducible byte for byte from `project.yml`. | Blocks a "generated project in sync" CI check | Coordinator (diff G) |
| G7 | No Rust iOS targets are installed locally. | Gap only if Rust is pursued (#74) | #74 |
| G8 | `xcode-select` points at the Command Line Tools. | Local trap | Every agent: set `DEVELOPER_DIR` |

## 10. Provisioning plan (proposed; nothing installed)

1. **Local:** Keep Xcode 27.1 (27A9275) at `/Applications/Xcode.app` and always export
   `DEVELOPER_DIR`. Optionally run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`;
   that is the maintainer's choice and was not applied. Adopt the repo `mise.toml` (A) and run
   `mise install`. Both pinned versions are already present on this Mac.
2. **GitHub Actions (#61):**
   - Add a build job on `runs-on: xcode-27` with
     `DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer`.
   - The job first runs a fail-fast check that the SDKs are at least 27.0 and the deployment
     target is unchanged. It installs the pinned tools with `jdx/mise-action`.
   - It builds macOS and iOS (`build-for-testing`) with signing disabled, using a simulator
     present on the image (C).
   - Hosted test execution waits for #60.
   - When an OS-27 image goes GA, switch the label to it. Never fall back to `macos-26` or
     `macos-15` for build jobs.
3. **Xcode Cloud (release):** No repo change.
   - In App Store Connect, confirm that a workflow can select Xcode 27.1 or newer on a
     macOS 27 or Tahoe 26.6+ image.
   - If it cannot, releases are blocked. Do not lower the deployment target and do not add
     Fastlane.
   - Keep the committed `.xcodeproj` as the Xcode Cloud input. Diff G and CI check C keep it in
     sync.
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
OS-27 SDK, and SwiftLint parses with its bundled SwiftSyntax. Pin `jdx/mise-action` to a
commit SHA if the repo adopts SHA pinning; v5.2.5 was the latest release on 2026-10-31.

```diff
       - uses: actions/checkout@v6.0.3
-      - name: Install SwiftLint
-        run: brew install swiftlint
+      - name: Install pinned SwiftLint
+        uses: jdx/mise-action@v5
+        with:
+          install_args: swiftlint
       - name: Lint
         run: swiftlint --strict
```

**C. New `.github/workflows/apple-build.yml` for #61.** It does build qualification only. Test
execution follows #60.

```yaml
name: Apple build

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    # Preview image; the only GitHub-hosted label with OS-27 SDKs as of 2026-10-31.
    runs-on: xcode-27
    env:
      DEVELOPER_DIR: /Applications/Xcode_27.1.app/Contents/Developer
    steps:
      - uses: actions/checkout@v6.0.3
      - uses: jdx/mise-action@v5
      - name: Require OS-27 SDKs and unchanged deployment targets
        run: |
          xcodebuild -version
          for sdk in macosx iphoneos iphonesimulator; do
            v=$(xcrun --sdk "$sdk" --show-sdk-version)
            echo "$sdk SDK $v"
            [ "${v%%.*}" -ge 27 ] || { echo "::error::$sdk SDK $v < 27.0 (no deployment downgrade)"; exit 1; }
          done
          [ "$(grep -cE '^ +(iOS|macOS): "27\.0"$' project.yml)" -eq 2 ] \
            || { echo "::error::project.yml deployment targets changed"; exit 1; }
      - name: Generated project is in sync
        run: xcodegen generate && git diff --exit-code FluxKlang.xcodeproj
      - name: Build macOS
        run: >
          xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMac
          -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
      - name: Build iOS for testing
        run: >
          xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlang
          -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
          -derivedDataPath DerivedData build-for-testing CODE_SIGNING_ALLOWED=NO
```

Checks run on C locally (**Verified**):

- The guard step passes with Xcode 27.1. It exits 1 with an `::error::` when an SDK reports
  26.5, or when `project.yml` is changed to iOS 26.0.
- `actionlint` 1.7.12 accepts the file except for one finding: it does not know the preview
  label `xcode-27`. If actionlint is adopted, declare that label in `.github/actionlint.yaml`.
- The "in sync" step fails until diff G lands.

**D. `Makefile`:** Make the simulator destination overridable. The local default is unchanged,
and CI can pass `IOS_SIM_DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=27.0'`.
Recipe lines must start with a tab, so this is shown as the resulting text rather than as a
unified diff. `make -n` was run against a throwaway copy, with and without the override. Add
this after `.PHONY`:

```make
IOS_SIM_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
```

In both `build` and `test`, replace
`-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \` with:

```make
	  -destination '$(IOS_SIM_DESTINATION)' \
```

**E. `README.md` (Develop section):**

```diff
-brew install xcodegen swiftlint   # if not already installed
+mise install                      # pinned xcodegen + swiftlint (mise.toml); or: brew install xcodegen swiftlint
+export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode 27.1+; needed if xcode-select points at CLT
 make generate                     # xcodegen generate
```

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

**G. `chore: regenerate Xcode project`:** Run
`DEVELOPER_DIR=… mise exec -- xcodegen generate` and commit the resulting 4+/4− `project.pbxproj`
ID change for `StudioPhysicalOverlapTests.swift`. This must land before the sync check in C is
enabled.

## 12. Follow-ups for other packages

- **#61:**
  - Adopt C and D; A and B come first.
  - Track the `xcode-27` preview-to-GA status and switch the label when an OS-27 GA image
    exists.
  - Keep the fail-fast SDK and deployment guard.
  - Record the image version per run (`ImageVersion` in the job log).
- **#60:**
  - Hosted tests stay gated.
  - `build-for-testing` already succeeds on the slot simulator.
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
  iPhone 17 Pro, might be creatable with `simctl create`, but that is unverified.
- Measured build times are single-run figures from a shared machine with a private
  DerivedData. They are not benchmarks.
- No hardware, audio, MIDI or latency results are claimed here.
