# Passive hardware inventory (Phase A)

Roadmap #48, work package `passive-hardware-inventory` (#67). This is the redacted public summary of a
**passive, read-only** descriptor inventory of the hardware-connected Mac. Raw output stays on that machine
under `~/.local/state/FluxKlang/transform-passive-hardware-inventory/` and is never committed.

> **No compatibility, latency or stability claim.** Nothing here says that any device works with FluxKlang,
> meets a latency budget, or runs without dropouts at any buffer size. Buffer and rate ranges are what the
> driver reports. Missing evidence is recorded as unknown, not as pass or fail.

## Capture context

| Item | Value |
| --- | --- |
| Captured | 2026-10-31, two runs at 18:41Z and 18:42Z; the HAL listings matched except for object IDs |
| Host | `MAC-A`: Apple silicon Mac laptop, arm64, `sw_vers` ProductVersion `27.2`, BuildVersion `26B123` (both verbatim) |
| Toolchain used by the lister | Apple Swift 6.4 (Command Line Tools), run as a standalone script |
| Rig reservation | Not needed: Phase A only, nothing emitted or changed (see [Safety](#what-was-and-was-not-done)) |
| Operator | The human owner approved this passive, read-only listing; no console screens have been read yet |

**Script versions.** Runs 1 and 2 used the first version of the runner and lister: JSON schema `/1`, which
also carried a hard-coded `readOnlyCalls` list (a label, not evidence), and a grep-only self-check. Run 2
added `ioreg -r -c IOUSBHostInterface`; run 1 did not list USB interfaces, so the interface facts below come
from run 2 only. The HAL listings of both runs matched except for object IDs. Afterwards the scripts were
hardened: a layered self-check, OS descriptors collected before any Swift step, `mktemp` run folders, and
schema `/2` without `readOnlyCalls`. The lister's CoreAudio HAL and CoreMIDI read calls did not change. The
hardened version has **not** been re-run on this hardware.

Placeholders are stable within this document only: `DEV-*` = CoreAudio devices, `MIDI-*` = CoreMIDI devices,
`HUB-*` = USB hubs. Serial numbers, device UIDs, USB location/registry IDs, the USB device signature (it
embeds the WING serial), BSD disk names, hostnames and user names are omitted. To limit the rig fingerprint,
this summary covers only the WING, the MIDI controller and the hub depth between them and the Mac. Other
peripherals and host power details are in the raw files only.

## What was and was not done

Commands run on `MAC-A` during runs 1 and 2, all read-only:

- `scripts/hardware-inventory/passive-inventory.sh --self-check` (first grep-only version), then
  `scripts/hardware-inventory/passive-inventory.sh`, which at that time ran:
  - `sw_vers`, `uname -m`, `swift --version`
  - `system_profiler -listDataTypes`, then
    `system_profiler -json SPUSBHostDataType SPAudioDataType SPThunderboltDataType SPPowerDataType`
    (macOS 27 has no `SPUSBDataType`; the runner picks whichever name the OS lists)
  - `ioreg -p IOUSB -l -w0` and, in run 2 only, `ioreg -r -c IOUSBHostInterface -l -w0`
  - `swift scripts/hardware-inventory/passive-inventory.swift` (CoreAudio HAL has/size/get queries and
    CoreMIDI enumeration and property getters only)
- Local `jq`/`grep`/`awk` filtering of the raw files to write this summary.

Not done by the scripts, by design:

- Nothing was emitted: no audio, MIDI or OSC.
- Nothing was started or instantiated: no audio session, engine, IOProc or Audio Unit. The script loaded
  no plug-in itself, but the OS may load HAL driver plug-ins (see below).
- Nothing was changed: no HAL property was set (rate, buffer, clock, routing, gain or default device) and
  no hog mode was taken.
- No MIDI client, port or send.
- No contact with the WING over the network: no OSC query, discovery or Bonjour browse. The script opened
  no socket. OS-driven activity is described below.
- No disk was mounted, unmounted, ejected or written, and the app was not launched.

### Side effects of passive reads

Here "passive" means that the scripts set, start and send nothing themselves. Reading still has OS-side
effects that the scripts cannot control:

- **CoreAudio:** the first HAL query connects the process to `coreaudiod`. If they are not loaded yet, the HAL
  may load HAL driver plug-ins, in `coreaudiod` or, for legacy drivers, in the lister's own process.
- **USB:** HAL, IORegistry and `system_profiler` reads can make a driver send USB control *GET* requests to a
  device, for example for names, the current rate or descriptors. The scripts send no USB request
  themselves. Whether a driver answered from its cache or from the device was not observed.
- **CoreMIDI:** the first CoreMIDI call can launch the CoreMIDI server. The server loads its MIDI drivers,
  including the network-session and Bluetooth MIDI drivers, and they act according to the Mac's own MIDI
  settings. The lister creates no MIDI client or port and sends no MIDI.
- **Network:** the scripts open no network connection. They cannot rule out network activity that the OS or
  the CoreMIDI network driver starts on its own.
- **`system_profiler`** starts helper processes and causes a short CPU burst.

## Audio device: WING (CoreAudio HAL, cross-checked with `SPAudioDataType`)

| ID | Device (reported name) | Transport | In / Out ch | Nominal rate | Available nominal rates | Buffer frames (current; range) | Default role |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DEV-A | **WING** (BEHRINGER) | USB | **48 / 48** | **48 kHz** | **48 kHz only** | 512; 15–4096 | none |

Other built-in, peripheral and virtual CoreAudio devices were listed but are omitted from this summary.
At capture time the WING reported:

- `isAlive = true` and `isRunningSomewhere = false` (no process had I/O running on it);
- no hog-mode owner;
- not the default input, output or system-output device.

"Current buffer frames" is the HAL value read by an idle process. It is not a chosen or validated operating
point.

### WING USB audio detail (DEV-A)

- HAL model UID `WING:1397:050B` (vendor `0x1397` BEHRINGER, product `0x050B`). The device UID has the form
  `AppleUSBAudioEngine:BEHRINGER:WING:<serial>:<interfaces>`, so the UID is unit-specific and must be
  redacted. The prefix shows that Apple's built-in USB audio driver is bound now. This is **not** a
  class-compliance or compatibility qualification.
- One stream per direction, both starting at channel 1:
  - input: 48 ch, 24-bit linear PCM, 48 kHz, terminal type `micr`;
  - output: 48 ch, 24-bit linear PCM, 48 kHz, terminal type `spkr`.
- HAL channel element names are generic: `In 1` … `In 48` and `Out 1` … `Out 48`, in order. HAL input scope is
  console → computer and output scope is computer → console.
- HAL exposes no clock-source property, clock-source list, model name or firmware version, and the clock
  domain is `0` (not reported). The console clock source and lock state are therefore **unknown** from the
  OS. They go into the [operator checklist](#operator-checklist-operator-to-read).
- `SPAudioDataType` agrees: 48 in, 48 out, 48 kHz, USB transport, not a default device.

## USB descriptors (`SPUSBHostDataType`, `ioreg`)

| Device | VID:PID | Link speed | bcdDevice | USB bus power allocation |
| --- | --- | --- | --- | --- |
| WING | `1397:050B` | 480 Mb/s (High Speed) | `0x0200` | none reported |
| Launch Control XL 3 (`LCXL3 1`) | `1235:0148` | 12 Mb/s (Full Speed) | `0x0100` | 2.5 W (500 mA) |

WING device and interfaces, from the descriptor registry:

- Device class `0xEF/0x02/0x01`, a composite device using interface association descriptors; `bcdUSB 0x0200`.
  `bNumConfigurations = 2`, active configuration `1`. The contents of configuration 2 are **unknown**.
- Configuration 1 interfaces:

  | # | Class / subclass / protocol | Meaning |
  | --- | --- | --- |
  | 0 | Audio / AudioControl / `0x20` | USB Audio Class 2.0 control |
  | 1 | Audio / AudioStreaming / `0x20` | UAC2 streaming, registry name "WING Output Terminal" |
  | 2 | Audio / AudioStreaming / `0x20` | UAC2 streaming, registry name "WING Input Terminal" |
  | 3 | Audio / AudioControl / `0x00` | control interface of the MIDI function |
  | 4 | Audio / MIDIStreaming / `0x00` | USB MIDI, 2 endpoints |

- `bcdDevice 0x0200` is the USB device release number. Whether it corresponds to console firmware is
  **unverified**, so the firmware version comes from the console screen.
- No mass-storage interface is present in the active configuration.

USB path, from the descriptor tree (the operator should confirm the physical cabling): the WING is **not** on
a direct Mac port. It is two USB 2 hub tiers deep (`HUB-A` → `HUB-B` → WING) on a bus that appears to be
tunnelled through a Thunderbolt-attached peripheral. The Launch Control XL 3 is two further USB 2 hub tiers
below `HUB-B`. This is recorded for later qualification; no effect on timing is claimed or ruled out.

## MIDI (CoreMIDI, no client)

| ID | Device | Driver | State | Entities → endpoints (protocol) |
| --- | --- | --- | --- | --- |
| MIDI-A | WING (BEHRINGER) | Apple USB MIDI driver | online | `Port 1` src+dst, `Port 2` src+dst (MIDI 1.0) |
| MIDI-B | LCXL3 1 (Focusrite - Novation) | Apple USB MIDI driver | online | `MIDI Out`/`MIDI In`, `DAW Out`/`DAW In` (MIDI 1.0) |

Apple's built-in IAC, network and Bluetooth MIDI driver devices, and offline devices cached from earlier
connections, were also listed. None of them had online endpoints, and they are omitted. System totals: 4
sources and 4 destinations, all from MIDI-A and MIDI-B.

The purpose of WING `Port 1` versus `Port 2` (for example, remote control versus DIN pass-through) is
**unknown** and was not probed. MIDI enumeration does not show what a port does, so no class compliance or
MIDI function is inferred from it.

## Physical console channels versus USB stream channels

- **Verified (OS):** the computer sees one 48-channel input stream and one 48-channel output stream named
  `In 1–48` / `Out 1–48`. These are USB stream positions, not console channel names.
- **Not verified, so unknown:** which console sources feed USB sends 1–48, which console channels or outputs
  take USB returns 1–48, the console channel names and whether any mapping is 1:1.
- WING Local input numbers (for example LCL 1–24 in `Shared/Models/WingSource.swift`) are **not** USB
  channel numbers. The app's `USB` source group with 48 inputs models the console's routing space; it does
  not identify these HAL channels.
- The mapping becomes known only from the console's routing screens (operator to read). Confirming it with
  signal requires an approved active step.

## Verified facts and unknowns

| Topic | Verified from passive OS descriptors | Unknown / requires another step |
| --- | --- | --- |
| Model | WING (BEHRINGER, `1397:050B`), USB 2.0 High Speed, UAC2 audio + USB MIDI | Console hardware variant (operator to read) |
| Firmware | — | Console firmware version (operator to read); meaning of `bcdDevice 0x0200` |
| USB mode | Configuration 1 of 2 active; 48×48 at 24-bit; 2 MIDI ports | Contents of configuration 2; console-side USB mode/channel setting (operator to read) |
| Clock / rate | HAL nominal 48 kHz; only 48 kHz offered; no HAL clock source | Console clock source, lock state and system rate (operator to read). Whether HAL follows a console rate change **requires an approved active step** |
| Buffers | Driver range 15–4096 frames; idle value 512 | Lowest stable buffer, deadline behaviour, round-trip latency: **requires approved active steps** (Phase B/C) |
| Driver-reported latency | Not collected on purpose, to avoid latency claims | Can be added later as a passive read labelled "driver-reported only" |
| Mapping | Generic USB stream channel names | Console channel ↔ USB stream mapping (operator to read; signal check is active) |
| Mobile | — | iPhone/iPad route and channel queries need `AVAudioSession` activation: **separate approved active step** |
| Network | — | Anything over the WING's network interface: **requires an approved network step** |

## Disk-mode safety

- The inventory only reads: `system_profiler` data types (USB, audio, Thunderbolt and power), the IORegistry
  through `ioreg` (the IOUSB plane and `IOUSBHostInterface` entries), and CoreAudio HAL and CoreMIDI
  property getters. It never mounts, unmounts, ejects, formats or writes a volume.
- **Observed:** the Launch Control XL 3 exposes a mass-storage interface ("Easy Start Drive",
  class 8 / SCSI / bulk-only) with a 192 KiB FAT16 medium flagged `Writable = No`. Leave it alone. Do not
  eject it as part of rig work, write to it or use it as scratch space. Its mount state was not checked.
- **Observed:** the WING's active configuration has no mass-storage interface; it presents audio and MIDI only.
- **Rule:** in any later run, the WING (or any audio interface) may not be in normal audio mode. Signs:
  - it shows a mass-storage interface;
  - its audio interfaces are missing;
  - it appears under a different product ID.

  It may then be in an update or disk mode; which mode is unverified. Stop, do not write to it, and ask the
  operator before any further step. Never start a firmware or disk procedure from an inventory or experiment
  session.

## Power, charging and one-USB-host constraints

- **Observed:** `MAC-A` was on external (AC) power during capture. Battery, charger and sleep details are in
  the raw files only.
- **Observed:** the WING has no USB bus-power allocation, which is consistent with a self-powered device.
  That it runs from its own mains supply is **operator to confirm**. The Launch Control XL 3 is bus-powered
  (500 mA allocation) through the external hub chain.
- **Constraint:** a USB device port serves exactly one USB host at a time. While the WING USB port is cabled
  to `MAC-A`, no other computer, iPad or iPhone can use the WING as a USB audio/MIDI device.
  - Moving the cable is a physical rig change. It needs a rig-ledger reservation, and the operator must
    record which host owns the WING.
  - Moving it also removes MIDI-A and DEV-A from `MAC-A`.
- **Constraint (mobile, not verified here):** on a single-port iPhone/iPad, the WING occupies the only USB-C
  port. Charging at the same time needs a powered hub or dock with power pass-through. Whether a particular
  hub preserves the audio/MIDI interfaces must be qualified in an approved mobile step.
- **Constraint:** passive inventory needs no rig reservation and can run on any machine at any time. During
  someone else's reserved active window, run it only with the reservation owner's agreement. It adds a short
  `system_profiler` CPU burst and the OS-side effects listed above, although it starts no audio activity.

## Operator checklist (operator to read)

Read these from the console screens and record them in the local evidence folder. Read only; change nothing.

- [ ] WING model/variant as shown on the console, and **firmware version** (system information screen).
- [ ] **Console system sample rate** and **clock source** (internal or external), plus **sync/lock status**.
- [ ] **USB audio settings** shown on the console: USB channel count or mode and any USB configuration choice.
      Compare with the OS view (48×48, 48 kHz, configuration 1 of 2).
- [ ] **USB send routing:** which console sources feed USB outputs 1–48 (console → computer, HAL `In N`).
- [ ] **USB return routing:** which channels/outputs use USB inputs 1–48 (computer → console, HAL `Out N`).
- [ ] Purpose of WING USB MIDI `Port 1` and `Port 2`, as documented by the console or vendor manual.
- [ ] Physical path: whether the WING USB cable runs through external hubs (the descriptors show two hub tiers
      on a Thunderbolt-attached chain), cable type and length, and whether a direct Mac port is available for
      active phases.
- [ ] Power (operator to confirm): whether the WING runs from its own mains supply, and the `MAC-A` power
      source and any charge limit.
- [ ] No other host is cabled to, or controlling, the WING right now. Ask people; do not browse or scan the
      network.
- [ ] The WING is in normal operation, not an update or disk mode (see [Disk-mode safety](#disk-mode-safety)).
- [ ] Current monitoring/safe-level state, recorded only, as the restoration baseline for a future active step.

## Re-running on another machine

1. Check out the repository on the target Mac. A Swift toolchain (Xcode or Command Line Tools) is optional.
   The runner looks for a working one with `xcode-select -p` and `xcrun --find`, because the `/usr/bin/swift`
   stub exists even without developer tools. Without one, the CoreAudio/CoreMIDI listing is skipped and the
   OS descriptors are still collected.
2. Run the self-check, either directly or with `make hardware-inventory-self-check`. CI runs the same command
   in the Lint workflow.

   ```sh
   scripts/hardware-inventory/passive-inventory.sh --self-check
   # self-check: source layer OK (.../passive-inventory.swift)
   # self-check: symbol layer OK (N undefined symbols checked)
   # self-check: PASSED source and symbol layers; a defence-in-depth tripwire, not a proof
   ```

   The self-check is a **defence-in-depth tripwire** against careless edits. It is **not a proof** that the
   code is read-only: a determined author can evade any static check, so `passive-inventory.swift` still needs
   human review. It has two layers:

   - **Source layer** (bash, grep, sed and awk only; Xcode is not needed). Newlines are folded first, so a call
     split across lines still matches. Then:
     - every `Audio*`, `MIDI*`, `kAudio*` or `kMIDI*` identifier, comments included, must be on the runner's
       `allowed_identifiers` list of read-only getters, plain types and property constants;
     - no denylisted fragment may appear. The denylist covers:
       - setters (any `*SetProperty`, `MIDIObjectSet*`), `AudioHardwareUnload`, listener add/remove;
       - device, unit and queue start or stop, and aggregate or tap devices;
       - MIDI clients, ports, send, receive, flush, thru, setup, device creation and property removal;
       - AVFoundation/AVFAudio and network APIs;
       - `system(`, `popen`, `fork`, `exec[lvp]*`, `posix_spawn`, `ioctl`, `open(`, `fopen`, `connect(`,
         `sendto` and `/dev/`;
       - file writes, `Process`, `NSTask`, `NSAppleScript`, `URLSession`, `NSURLConnection` and
         `Data(contentsOf:`;
       - `dlopen`, `dlsym`, dynamic selectors, `@_silgen_name`, `@_cdecl` and backticks;
     - every `import` (including attributed and `;`-joined ones) must be `CoreAudio`, `CoreMIDI` or
       `Foundation`.
   - **Symbol layer** (only with a working Swift toolchain). The runner compiles the lister with `swiftc -c`
     into a temporary folder and checks the undefined symbols from `nm -u`:
     - linked `Audio*`/`MIDI*` functions must be on the read-only getter allowlist;
     - C symbols, Objective-C classes and selectors, and demangled Swift symbols must not match the
       denylists.

     If there is no toolchain or the compile fails, the layer prints a warning and the source layer's result
     stands.

   A manual cross-check of the identifier allowlist:

   ```sh
   tr '\n' ' ' <scripts/hardware-inventory/passive-inventory.swift \
     | grep -oE '(^|[^A-Za-z0-9_])(Audio|MIDI|kAudio|kMIDI)[A-Za-z0-9_]*' | sed -E 's/^[^A-Za-z]//' | sort -u
   # each name printed must be a getter, type or constant listed in allowed_identifiers
   ```

3. Run the collector:

   ```sh
   scripts/hardware-inventory/passive-inventory.sh
   # optional: FLUXKLANG_INVENTORY_DIR=/private/dir/outside/the/repo scripts/hardware-inventory/passive-inventory.sh
   ```

   What the collector does:
   - It writes `os.txt`, `system_profiler.json` and both `ioreg` listings first.
   - Only if a working toolchain is present and the self-check passes (saved as `self-check.txt`) does it run
     the lister with `xcrun swift`.
   - Warnings go to `warnings.txt`, for example a missing USB data type, an empty IOUSB plane or a skipped
     listing.
   - Each run gets a new private folder, `<UTC stamp>.XXXXXX`, created with `mktemp` and `umask 077`.
   - It refuses a root inside the git repository or one containing `..`.
   - On a failure it prints the path of the incomplete folder.
4. Complete the operator checklist from the console screens.
5. Publish only a hand-redacted summary in the format of this document.
   - Replace these with stable placeholders: serials, device UIDs, USB location/registry IDs, the USB device
     signature, BSD disk names, MAC/IP addresses, hostnames, user names and personal device names.
   - Keep model names, VID:PID, channel counts, rates and ranges.
   - Leave out peripherals that the WING or interface handoff does not need.
   - Never commit the raw folder.

iPhone/iPad inventories are out of scope here, because route and channel queries need an audio session. They
belong to a separately approved active step.

## Helper notes

- `scripts/hardware-inventory/passive-inventory.swift` is a standalone script. It is not part of any app or
  test target and is not built by XcodeGen. `swiftlint --strict` lints it because the repository lints all
  Swift files.
- The issue asks for fake mutator spies "where helpers are added". No app-side helper or production code was
  added. This standalone script is protected by the self-check tripwire above and by code review, not by a
  runtime spy.
