# Permissions: audio input, local network, Bluetooth, multicast, background

Work package `audio-network-permissions` (#57, roadmap #48, gate G-SDK). This
file records which privacy keys and entitlements FluxKlang declares, which it
leaves out on purpose, and how a denial is reported. Anything not yet checked on
signed hardware is marked **Unknown**.

## Rules

- Nothing queries or requests a permission at init or launch. Reading
  `PermissionProbe.status` never shows a prompt. `PermissionProbe.request` runs
  only after an explicit user action. Test hosts (`AppPersistence.isTesting`)
  get `InertPermissionProbe` through `HardwareServiceFactories`.
- Launch sends no network traffic that could raise the Local Network alert, and
  starts no audio (no tones).
- A denial leaves the app usable. Demo Mode, editing, presets and stores need no
  permission.
- Manual IP entry goes through the same checked path as every other WING
  connect, so it cannot get around a Local Network denial.

## Local-network inventory (before this change)

| Path | Code | Local Network operation (TN3179) | Trigger |
| --- | --- | --- | --- |
| Broadcast discovery | `WingDiscovery.scan` → `WingTransport.start(broadcast: true)` + `send` to each IPv4 broadcast address | UDP broadcast send and receive. iOS also requires the multicast entitlement | User taps **Scan for WING** |
| Unicast connect (including manual IP and `.local` names) | `AppModel.connect(host:)` → `WingController.connect` → `WingTransport.start` + subscribe/GET sends | UDP unicast send; resolving a `.local` name | User picks a console, enters an IP, presses ⌘R, or runs the Connect intent |
| Startup reconnect | `AppModel.loadStores` → `shouldReconnectOnStartup` → `connect(host: lastHost)` | UDP unicast send at launch | Automatic at launch |

Before this change, `WingTransport.start` only bound a local UDP socket, and
binding is not a checked operation. `WingController` therefore showed
**Connected** before anything had been sent, and later sends failed silently
(`try?`). A denied manual-IP connect looked like a success.

### Can the startup reconnect prompt at launch? Yes. It is now gated.

`lastHost` lives in `UserDefaults.standard` (`AppPersistence.defaults`). It is
not mirrored to iCloud KVS, but backups and device migration restore it. The
Local Network privilege starts out **undetermined** for each install, signing
identity and user account. TN3179: "Your program starts in the undetermined
state", and macOS "maintains separate local network privacy state for each user
account". So an unconditional reconnect to `lastHost` at launch can raise the
alert in these cases:

- An iOS restore from backup, or a move to a new device. Whether moving to a
  new device carries the privacy state over is **Unknown**.
- An iOS **Reset Location & Privacy**.
- The first launch on macOS 15 or later on a Mac that saved `lastHost` earlier.
- A Mac build with a different signing identity that shares the same sandbox
  container. TN3179 says the privilege follows the code signature.

The gate is `StartupReconnectPolicy.shouldReconnect`, called from
`Shared/Views/App/AppModel+Permissions.swift`. Launch reconnects only when
`LocalNetworkGrantEvidence` shows that **this build** already connected to
**this host** on **this device** after a user action. The evidence is a file in
`AppPersistence.directory` marked `isExcludedFromBackup`, so a restore cannot
carry it to another device. It is keyed to
`CFBundleShortVersionString-CFBundleVersion`, so after each update the first
connect waits for the user. That UX cost is deliberate. **Retry**,
**Reconnect to …** and ⌘R still work. Two cases remain **Unknown**:

- macOS Migration Assistant or Time Machine may copy the container, including
  the evidence. Whether the privilege comes with it is not known.
- A build with the same version but a different signature that shares the
  container.

### Truthful denial on connect, including manual IP

`WingTransport.start(broadcast: false)` now runs `LocalNetworkProbe` first. The
probe calls `connect()` on a UDP socket, which is a checked operation that sends
no packets (TN3179, "Local network operations" table and "Trigger the local
network alert"). If it fails, `start` throws
`WingTransportError.localNetworkBlocked(errno:)` before any OSC socket opens.
`WingController` then shows **Connection failed — Local Network access is off
for FluxKlang, or the access prompt hasn't been answered. Allow FluxKlang under
Privacy & Security › Local Network in Settings, then try again.** It never shows
Connected and never hangs.

TN3179 notes that while the alert is on screen, the system "may deny the
operation immediately, before the user has responded". The message covers that
case, and the user retries after answering.

TN3179 does not say which errno a denied `connect` returns. FluxKlang treats
`EHOSTUNREACH`, `ENETUNREACH`, `EPERM` and `EACCES` as a denial and reports any
other errno as a generic path failure. This is **Unknown** until operator checks
M2 and I2 run. If a signed build shows that `connect` succeeds even when access
is denied, the fallback is to classify the first subscribe send instead.
`WingController.swift` is at the 500-line lint limit, so that change needs its
own package.

### Discovery

- **iOS:** without `com.apple.developer.networking.multicast`, iOS blocks UDP
  broadcast (TN3179, "Multicast operations"). `WingDiscovery` therefore sends
  nothing and shows **Automatic WING discovery isn't available in this build.
  Enter the WING's IP address instead.** The simulator behaves the same way, to
  match devices.
- **macOS:** the entitlement isn't required, so the scan runs. If no broadcast
  interface is up, or every send fails, it shows the reason instead of "No
  consoles found".

## Keys and entitlements

| Key / entitlement | Target | Decision | Source |
| --- | --- | --- | --- |
| `NSLocalNetworkUsageDescription` | iOS, macOS | **Added.** Required for direct unicast to local hosts. macOS 15 and later enforce the Local Network privilege | https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription, https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy |
| `NSMicrophoneUsageDescription` | iOS, macOS | **Added.** "Required if your app uses APIs that access the device's microphone". The future audio-input packages (#64/#110) need it. It is shown only when input is requested, and nothing requests input yet | https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription |
| `com.apple.security.device.audio-input` | macOS | **Added.** Hardened Runtime resource access for the microphone and Core Audio input; the Mac target uses the hardened runtime | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input |
| `com.apple.security.device.microphone` | macOS | **Added.** App Sandbox › Hardware › Audio Input; the Mac target is sandboxed. Whether macOS 27 needs both keys is **Unknown**; each is documented for one of the target's two configurations | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone |
| `NSBonjourServices` | — | **Not added.** No Bonjour API is used: WING discovery is UDP broadcast and OSC is unicast. Peer control (#93) must declare its own type (for example `_fluxklang._tcp`; #93 owns the name) when it registers or browses | https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices |
| `com.apple.developer.networking.multicast` | iOS | **Not added: needs Apple approval.** "Requires permission from Apple". The owner must request it at https://developer.apple.com/contact/request/networking-multicast. Until it is approved, iOS discovery shows as unavailable and manual IP is the way to connect. When approved, change `LocalNetworkAccess.hasMulticastEntitlement` and project.yml together. macOS doesn't need it | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast |
| `NSBluetoothAlwaysUsageDescription` / `com.apple.security.device.bluetooth` | — | **Not added: deferred.** No Bluetooth or BLE-MIDI feature exists yet. Add both when a package pairs with or scans for BLE MIDI devices. Whether CoreMIDI sources for already-paired BLE devices need the key is **Unknown** | https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth |
| `UIBackgroundModes` | iOS | **Not added.** See below | https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes, https://developer.apple.com/documentation/xcode/configuring-background-execution-modes |
| `com.apple.security.network.client` / `.server` | macOS | Unchanged (already present) | — |

## Background mode decision (mobile lifecycle)

On iOS, FluxKlang is a foreground remote control: it plays no audio and has no
audio engine yet. It therefore declares **no** `UIBackgroundModes`. App Review
Guideline 2.5.4 says background services may be used only "for their intended
purposes" (https://developer.apple.com/app-store/review/guidelines/#2.5.4).

- The OSC link may lapse while the app is suspended. When the app returns to the
  foreground, the current reconnect UX applies.
- TN3179: if an iOS app in the background uses the local network while its
  privilege is undetermined, the system denies the operation *without* showing
  the alert. A Connect intent or Siri action run in the background therefore
  fails with a truthful message instead of prompting.
- When the mobile audio engine lands (G-LAT/G-HW), that package must add the
  `audio` background mode together with real background audio use.
- macOS has no Background Modes capability ("isn't available for macOS apps").

## Validation

- `FluxKlangTests/PermissionStateTests` covers:
  - user-facing reasons and the errno mapping
  - the iOS discovery gate and the startup reconnect policy
  - grant evidence: scoped to host and build, and excluded from backup
  - a denied manual-IP connect, which opens no socket and makes no writes
  - inert probes in test hosts
- The Mac entitlements were checked by ad-hoc signing a throwaway copy of the
  build and reading them back with `codesign -d --entitlements -`. The app was
  never launched.
- The signed denial smoke checks need a human operator and have **not** been
  run. That acceptance item is **partial**.

## Operator smoke checklist (signed builds, human operator)

Before you start:

- Use builds from this branch signed with an Apple-issued development identity,
  not ad hoc (TN3179 "Build-time considerations").
- Put a WING on the same LAN. Only the read-only subscribe and GET messages that
  connect already sends are allowed; make no mixer changes.
- Record results under `~/.local/state/FluxKlang/transform-audio-network-permissions/`
  with IP addresses redacted.
- Stop if anything unexpected happens: a prompt, a sound or a mixer change.

### macOS 15 or later

Use a fresh user account, or remove FluxKlang under System Settings › Privacy &
Security › Local Network. The remove button exists on macOS 27.2 and later.

1. **M1, silent launch with a previously saved host:**
   1. Run a `main` build and connect once, so `lastHost` is saved.
   2. Quit, then reset the Local Network entry.
   3. Install this branch and launch it.
   4. Expect no Local Network or Microphone alert, no sound, no automatic
      reconnect, and the status **Not connected**.
2. **M2, deny through manual IP:**
   1. Open Connection, enter the WING's IP address and click Connect.
   2. When the alert appears, click **Don't Allow**.
   3. Expect **Connection failed — Local Network access is off…**. It must never
      show **Connected**, and it must not hang for more than about 1 s.
   4. Record the errno, for example with a debugger breakpoint on
      `localNetworkBlocked`.
3. **M3, app stays usable:** Demo Mode, editing a preset and Settings all work.
4. **M4, scan while denied:** run Scan for WING. Expect the "scan couldn't
   send…" reason or an empty list, never a console that isn't there.
5. **M5, allow:**
   1. Turn on FluxKlang under System Settings › Privacy & Security › Local
      Network, then connect.
   2. Expect **Connected** and live values.
   3. Quit and relaunch. It reconnects without a prompt, because the evidence
      file now exists.
6. **M6, entitlements:** `codesign -d --entitlements - FluxKlangMac.app` lists
   `device.audio-input`, `device.microphone`, `network.client` and
   `network.server`, and no multicast or Bluetooth entitlement.

### iOS/iPadOS device

Delete the app first to reset the privilege. The simulator doesn't enforce Local
Network privacy, so use a real device.

1. **I1, silent launch:** do a fresh install and launch. Expect no alert and no
   sound.
2. **I2, deny through manual IP:**
   1. Enter the WING's IP address, tap Connect, then tap **Don't Allow**.
   2. Expect the Local Network failure message, never **Connected**.
   3. Tap Retry. It is still denied, with no second alert.
   4. Record the errno.
3. **I3, app stays usable:** Demo Mode, presets and the assistant review UI work.
4. **I4, discovery:** run Scan for WING. Expect **Automatic WING discovery isn't
   available in this build…**, and no alert from the scan.
5. **I5, allow:**
   1. Turn on Settings › Privacy & Security › Local Network › FluxKlang.
   2. Connect. It succeeds.
   3. Relaunch. It reconnects without a prompt.
6. **I6, restore:**
   1. Restore a backup made after I5 onto a second device, or erase and restore.
   2. Launch. `lastHost` is shown, but nothing reconnects and no alert appears
      until the user taps Connect.
7. **I7, background:**
   1. Start from a fresh install, so the privilege is undetermined.
   2. Run the Connect to WING shortcut while the app is in the background.
   3. Expect a truthful failure and no alert.

## Sources

- TN3179 Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- NSLocalNetworkUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription
- NSBonjourServices: https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
- NSMicrophoneUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription
- NSBluetoothAlwaysUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription
- UIBackgroundModes: https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes
- Configuring background execution modes: https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- Audio Input entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
- com.apple.security.device.microphone: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone
- com.apple.security.device.bluetooth: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth
- com.apple.developer.networking.multicast: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- App Review Guidelines 2.5.4: https://developer.apple.com/app-store/review/guidelines/#2.5.4

## Unknowns

- Which errno a denied UDP `connect` returns on iOS 27 and macOS 27 (operator
  checks M2 and I2).
- Whether `AVAudioApplication.recordPermission` reports the macOS microphone
  (TCC) state the same way it does on iOS. Launch never calls
  `SystemPermissionProbe`, so this cannot affect startup.
- Whether sandboxed audio input on macOS 27 needs both `device.audio-input` and
  `device.microphone`.
- Whether device migration or Migration Assistant carries the Local Network
  privilege.
- Whether the WING advertises any Bonjour service. FluxKlang doesn't use or need
  Bonjour today.
