# Passive hardware inventory (Phase A)

Roadmap #48, work package `passive-hardware-inventory` (#67). This is the redacted public summary of a
**passive, read-only** descriptor inventory of the hardware-connected Mac. Raw output stays on that machine
under `~/.local/state/FluxKlang/transform-passive-hardware-inventory/<UTC timestamp>/` and is never
committed.

> **No compatibility, latency or stability claim.** Nothing here says that any device works with FluxKlang,
> meets a latency budget, or runs without dropouts at any buffer size. Buffer and rate ranges are what the
> driver reports. Missing evidence is recorded as unknown, not as pass or fail.

## Capture context

| Item | Value |
| --- | --- |
| Captured | 2026-10-31, two runs at 18:41Z and 18:42Z; the HAL listings matched except for object IDs |
| Host | `MAC-A`: Apple silicon MacBook Pro, macOS 27.2 (26B123), arm64 |
| Toolchain used by the lister | Apple Swift 6.4 (Command Line Tools), run as a standalone script |
| Rig reservation | Not needed: Phase A only, nothing emitted or changed (see [Safety](#what-was-and-was-not-done)) |
| Operator | The human owner approved this passive, read-only listing; no console screens have been read yet |

Placeholders are stable within this document only: `DEV-*` = CoreAudio devices, `MIDI-*` = CoreMIDI devices,
`HUB-*` = USB hubs. Serial numbers, device UIDs, USB location/registry IDs, the USB device signature (it
embeds the WING serial), BSD disk names, hostnames and user names are omitted.

## What was and was not done

Commands run on `MAC-A`, all read-only:

- `scripts/hardware-inventory/passive-inventory.sh --self-check` (static grep, see below), then
  `scripts/hardware-inventory/passive-inventory.sh`, which runs:
  - `sw_vers`, `uname -m`, `swift --version`
  - `system_profiler -listDataTypes`, then
    `system_profiler -json SPUSBHostDataType SPAudioDataType SPThunderboltDataType SPPowerDataType`
    (macOS 27 has no `SPUSBDataType`; the runner picks whichever name the OS lists)
  - `ioreg -p IOUSB -l -w0` and, from the second run on, `ioreg -r -c IOUSBHostInterface -l -w0`
  - `swift scripts/hardware-inventory/passive-inventory.swift` (CoreAudio HAL has/size/get queries and
    CoreMIDI enumeration getters only)
- Local `jq`/`grep`/`awk` filtering of the raw files to write this summary.

Not done, by design: no audio, MIDI or OSC emitted; no audio session, engine, IOProc or Audio Unit started;
no plug-in instantiated; no HAL property set (rate, buffer, clock, routing, gain, default device); no hog mode
taken; no MIDI client, port or send; no network contact with the WING (no OSC query, discovery or Bonjour
browse); no disk mounted, unmounted, ejected or written; the app was not launched.

## Audio devices (CoreAudio HAL, cross-checked with `SPAudioDataType`)

| ID | Device (reported name) | Transport | In / Out ch | Nominal rate | Available nominal rates | Buffer frames (current; range) | Default role |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DEV-A | Studio Display Microphone | USB | 1 / 0 | 48 kHz | 44.1, 48, 88.2, 96 kHz | 512; 15–4096 | default input |
| DEV-B | Studio Display Speakers | USB | 0 / 8 | 96 kHz | 44.1, 48, 88.2, 96 kHz | 512; 29–4096 | default output and system output |
| DEV-C | **WING** (BEHRINGER) | USB | **48 / 48** | **48 kHz** | **48 kHz only** | 512; 15–4096 | none |
| DEV-D | USB webcam microphone | USB | 1 / 0 | 48 kHz | 48 kHz | 512; 15–4096 | none |
| DEV-E | MacBook Pro Microphone | built-in | 1 / 0 | 48 kHz | 44.1, 48, 88.2, 96 kHz | 512; 15–4096 | none |
| DEV-F | MacBook Pro Speakers | built-in | 0 / 2 | 48 kHz | 44.1, 48, 88.2, 96 kHz | 512; 15–4096 | none |
| DEV-G | Third-party virtual loopback device | virtual | 1 / 1 | 48 kHz | 48 kHz | 512; 15–4096 | none |

At capture time every device reported `isAlive = true`, `isRunningSomewhere = false` (no process had I/O
running on it) and no hog-mode owner. "Current buffer frames" is the HAL value read by an idle process, not a
chosen or validated operating point.

### WING USB audio detail (DEV-C)

- HAL model UID `WING:1397:050B` (vendor `0x1397` BEHRINGER, product `0x050B`). The device UID has the form
  `AppleUSBAudioEngine:BEHRINGER:WING:<serial>:<interfaces>`, so the UID is unit-specific and must be
  redacted. The prefix shows that Apple's built-in USB audio driver is bound now. This is **not** a
  class-compliance or compatibility qualification.
- One stream per direction, both starting at channel 1: input = 48 ch, 24-bit linear PCM, 48 kHz, terminal
  type `micr`; output = 48 ch, 24-bit linear PCM, 48 kHz, terminal type `spkr`.
- HAL channel element names are generic: `In 1` … `In 48` and `Out 1` … `Out 48`, in order. HAL input scope is
  console → computer and output scope is computer → console.
- No clock-source property, clock-source list, model name or firmware version is exposed through HAL, and
  the clock domain is `0` (not reported). The console clock source and lock state are therefore **unknown**
  from the OS and go into the [operator checklist](#operator-checklist-operator-to-read).
- `SPAudioDataType` agrees: 48 in, 48 out, 48 kHz, USB transport, not a default device.

## USB descriptors (`SPUSBHostDataType`, `ioreg`)

| Device | VID:PID | Link speed | bcdDevice | USB bus power allocation |
| --- | --- | --- | --- | --- |
| WING | `1397:050B` | 480 Mb/s (High Speed) | `0x0200` | none reported |
| Launch Control XL 3 (`LCXL3 1`) | `1235:0148` | 12 Mb/s (Full Speed) | `0x0100` | 2.5 W (500 mA) |
| Studio Display (audio/control) | `05AC:1114` | 480 Mb/s | `0x0201` | 2.5 W (500 mA) |
| USB webcam (DEV-D) | `3673:0002` | 480 Mb/s | `0x0720` | 2.5 W (500 mA) |

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

USB path (from descriptor names; the operator should confirm the physical cabling):
`MAC-A` → Thunderbolt (USB4 bus 0, Thunderbolt 3 mode) → Studio Display → `HUB-A` (Apple USB 2 hub inside the
display) → `HUB-B` (USB 2.0 hub with a Microsoft vendor ID; a "Surface Thunderbolt 4 Dock" device hangs off the
same hub, so it is probably that dock's hub) → WING. The
WING is two USB hub tiers below a bus that appears to be tunnelled through the display, not on a direct Mac
port. The Launch Control XL 3 sits two further USB 2 hub tiers below `HUB-B`. This is recorded for later
qualification; no effect on timing is claimed or ruled out.

## MIDI (CoreMIDI, no client)

| ID | Device | Driver | State | Entities → endpoints (protocol) |
| --- | --- | --- | --- | --- |
| MIDI-A | WING (BEHRINGER) | Apple USB MIDI driver | online | `Port 1` src+dst, `Port 2` src+dst (MIDI 1.0) |
| MIDI-B | LCXL3 1 (Focusrite - Novation) | Apple USB MIDI driver | online | `MIDI Out`/`MIDI In`, `DAW Out`/`DAW In` (MIDI 1.0) |
| — | IAC Driver | Apple IAC | offline | 1 bus |
| — | Network, UMP Network, Bluetooth drivers | Apple | online, no entities | none |
| — | 15 cached devices from earlier connections | Apple USB MIDI driver | offline | not present now |

System totals: 4 sources and 4 destinations, all from MIDI-A and MIDI-B. The purpose of WING `Port 1` versus
`Port 2` (for example, remote control versus DIN pass-through) is **unknown** and was not probed. MIDI
enumeration does not show what a port does, so no class-compliance or MIDI function is inferred from it.

## Physical console channels versus USB stream channels

- **Verified (OS):** the computer sees one 48-channel input stream and one 48-channel output stream named
  `In 1–48` / `Out 1–48`. These are USB stream positions, not console channel names.
- **Not verified, so unknown:** which console sources feed USB sends 1–48, which console channels or outputs take
  USB returns 1–48, console channel names and any 1:1 mapping. WING Local input numbers (for example LCL 1–24
  in `Shared/Models/WingSource.swift`) are **not** USB channel numbers. The app's `USB` source group with
  48 inputs models the console's routing space; it does not identify these HAL channels.
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

- The inventory reads the IORegistry only. It never mounts, unmounts, ejects, formats or writes a volume.
- **Observed:** the Launch Control XL 3 exposes a mass-storage interface ("Easy Start Drive",
  class 8 / SCSI / bulk-only) with a 192 KiB FAT16 medium flagged `Writable = No`. Leave it alone. Do not
  eject it as part of rig work, write to it or use it as scratch space. Its mount state was not checked.
- **Observed:** the WING's active configuration has no mass-storage interface; it presents audio and MIDI only.
- **Rule:** if a run shows the WING (or any audio interface) with a mass-storage interface, without its
  audio interfaces, or under a different product ID, it is not in normal audio mode. It may be in an update
  or disk mode; which mode is unverified. Stop. Do not write to it, and ask the operator before any further
  step. Never start a firmware or disk procedure from an inventory or experiment session.

## Power, charging and one-USB-host constraints

- **Observed:** `MAC-A` was on AC power. A 94 W charger was reported connected, the battery was not charging
  at 80 % and system sleep on AC was disabled (`0`). The reason it was not charging (for example a charge
  limit) was not determined.
- **Observed:** the WING has no USB bus-power allocation, which is consistent with a mains-powered device
  (operator to confirm). The Launch Control XL 3 and other small devices are bus-powered (500 mA allocations)
  through the display/dock hub chain.
- **Constraint:** a USB device port serves exactly one USB host at a time. While the WING USB port is cabled
  to `MAC-A`, no other computer, iPad or iPhone can use the WING as a USB audio/MIDI device. Moving the cable
  is a physical rig change: it needs a rig-ledger reservation, and the operator must record which host owns
  the WING. Moving it also removes MIDI-A and DEV-C from `MAC-A`.
- **Constraint (mobile, not verified here):** on a single-port iPhone/iPad, the WING occupies the only USB-C
  port. Charging at the same time needs a powered hub or dock with power pass-through. Whether a particular
  hub preserves the audio/MIDI interfaces must be qualified in an approved mobile step.
- **Constraint:** passive inventory needs no rig reservation and can run on any machine at any time. During
  someone else's reserved active window, run it only with the reservation owner's agreement, because
  `system_profiler` adds a short CPU burst. That load is not audio activity.

## Operator checklist (operator to read)

Read these from the console screens and record them in the local evidence folder. Read only; change nothing.

- [ ] WING model/variant as shown on the console, and **firmware version** (system information screen).
- [ ] **Console system sample rate** and **clock source** (internal or external), plus **sync/lock status**.
- [ ] **USB audio settings** shown on the console: USB channel count or mode and any USB configuration choice.
      Compare with the OS view (48×48, 48 kHz, configuration 1 of 2).
- [ ] **USB send routing:** which console sources feed USB outputs 1–48 (console → computer, HAL `In N`).
- [ ] **USB return routing:** which channels/outputs use USB inputs 1–48 (computer → console, HAL `Out N`).
- [ ] Purpose of WING USB MIDI `Port 1` and `Port 2`, as documented by the console or vendor manual.
- [ ] Physical path: whether the WING USB cable goes through the Studio Display and dock hubs (descriptors
      suggest this), cable type and length, and whether a direct Mac port is available for active phases.
- [ ] Power: the WING is mains-powered; note `MAC-A` power source and any charge limit.
- [ ] No other host is cabled to, or controlling, the WING right now. Ask people; do not browse or scan the
      network.
- [ ] The WING is in normal operation, not an update or disk mode (see [Disk-mode safety](#disk-mode-safety)).
- [ ] Current monitoring/safe-level state, recorded only, as the restoration baseline for a future active step.

## Re-running on another machine

1. Check out the repository on the target Mac. A Swift toolchain (Xcode or Command Line Tools) is optional.
   Without it, the CoreAudio/CoreMIDI listing is skipped and the OS descriptors are still collected.
2. Confirm the static safety check passes:

   ```sh
   scripts/hardware-inventory/passive-inventory.sh --self-check
   # self-check: OK (.../passive-inventory.swift uses only allowlisted read-only calls and imports)
   ```

   The check fails if `passive-inventory.swift` contains any forbidden token. These include
   `AudioObjectSetPropertyData`, `AudioDeviceStart`, `AudioOutputUnitStart`, `AudioUnitInitialize`,
   `AVAudioEngine`, `AVAudioSession`, `MIDIClientCreate`, `MIDISend`, `MIDIReceived`, `socket`, `Network`,
   `OSC`, `Process(`, `dlopen`/`dlsym` and others listed in the runner. It also fails if the file calls any
   `Audio*(`/`MIDI*(` symbol outside the read-only allowlist or imports anything except `CoreAudio`,
   `CoreMIDI` and `Foundation`. A manual equivalent of the deny-list part:

   ```sh
   grep -nE 'AudioObjectSetPropertyData|AudioDeviceStart|AudioOutputUnitStart|AudioUnitInitialize|AVAudioEngine|AVAudioSession|MIDIClientCreate|MIDISend|MIDIReceived|socket|Network|OSC' \
     scripts/hardware-inventory/passive-inventory.swift   # expect no output
   ```

3. Run the collector. Output goes to a new private (`umask 077`) timestamped folder:

   ```sh
   scripts/hardware-inventory/passive-inventory.sh
   # optional: FLUXKLANG_INVENTORY_DIR=/some/private/dir scripts/hardware-inventory/passive-inventory.sh
   ```

4. Complete the operator checklist from the console screens.
5. Publish only a hand-redacted summary in the format of this document. Replace serials, device UIDs, USB
   location/registry IDs, the USB device signature, BSD disk names, MAC/IP addresses, hostnames, user names and
   personal device names with stable placeholders. Keep model names, VID:PID, channel counts, rates and ranges.
   Never commit the raw folder.

iPhone/iPad inventories are out of scope here, because route and channel queries need an audio session. They
belong to a separately approved active step.

## Helper notes

- `scripts/hardware-inventory/passive-inventory.swift` is a standalone script. It is not part of any app or
  test target and is not built by XcodeGen. `swiftlint --strict` lints it because the repository lints all
  Swift files.
- The issue asks for fake mutator spies "where helpers are added". No app-side helper or production code was
  added, so the protection for this standalone script is the static allowlist/deny-list self-check plus the
  read-only call list recorded in its JSON output (`readOnlyCalls`).
