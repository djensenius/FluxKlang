#!/usr/bin/env bash
# Passive, read-only hardware inventory runner for FluxKlang (roadmap #48, issue #67).
#
# Collects OS descriptors (system_profiler, ioreg) and a read-only CoreAudio HAL /
# CoreMIDI listing into a private local directory. It plays and sends nothing,
# opens no audio session or engine, creates no MIDI client, changes no device
# setting and contacts no network device. Raw output can contain serial numbers,
# device UIDs, USB location IDs and personal device names: never commit it;
# publish only a hand-redacted summary (see docs/transformation/hardware-inventory.md).
#
# Usage:
#   scripts/hardware-inventory/passive-inventory.sh               # self-check, then collect
#   scripts/hardware-inventory/passive-inventory.sh --self-check  # static self-check only
#
# Output root (override with FLUXKLANG_INVENTORY_DIR):
#   ~/.local/state/FluxKlang/transform-passive-hardware-inventory/<UTC timestamp>/
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
swift_source="$script_dir/passive-inventory.swift"

# Calls or frameworks that would activate, change, listen or emit. None may appear in the Swift source.
forbidden_pattern='AudioObjectSetPropertyData|AudioDeviceStart|AudioDeviceStop|AudioDeviceCreateIOProcID'
forbidden_pattern+='|AudioDeviceAddIOProc|AudioOutputUnitStart|AudioUnitInitialize|AudioComponentInstanceNew'
forbidden_pattern+='|AudioHardwareCreateAggregateDevice|AudioObjectAddPropertyListener|AUGraph|AUAudioUnit'
forbidden_pattern+='|AVAudioEngine|AVAudioSession|AVAudio|MIDIClientCreate|MIDIOutputPortCreate|MIDIInputPortCreate'
forbidden_pattern+='|MIDISend|MIDIReceived|MIDISourceCreate|MIDIDestinationCreate|MIDIObjectSet|MIDIRestart'
forbidden_pattern+='|socket|Network|NWConnection|NWBrowser|NetService|URLSession|OSC|Process\(|posix_spawn'
forbidden_pattern+='|dlopen|dlsym|NSClassFromString|@_silgen_name|@_cdecl'

# The only CoreAudio/CoreMIDI calls (and plain C struct initialisers) the Swift source may use.
allowed_calls=(
  AudioObjectHasProperty AudioObjectGetPropertyDataSize AudioObjectGetPropertyData
  AudioObjectPropertyAddress AudioValueRange AudioValueTranslation AudioStreamBasicDescription
  AudioObjectID AudioStreamID
  MIDIGetNumberOfDevices MIDIGetDevice MIDIDeviceGetNumberOfEntities MIDIDeviceGetEntity
  MIDIEntityGetNumberOfSources MIDIEntityGetSource MIDIEntityGetNumberOfDestinations MIDIEntityGetDestination
  MIDIObjectGetStringProperty MIDIObjectGetIntegerProperty MIDIGetNumberOfSources MIDIGetNumberOfDestinations
)
allowed_imports=(CoreAudio CoreMIDI Foundation)

self_check() {
  local status=0 hits name
  if [[ ! -f "$swift_source" ]]; then
    printf 'self-check: missing %s\n' "$swift_source" >&2
    return 1
  fi
  if hits="$(grep -nE "$forbidden_pattern" "$swift_source")"; then
    printf 'self-check: forbidden token in %s:\n%s\n' "$swift_source" "$hits" >&2
    status=1
  fi
  while IFS= read -r name; do
    [[ -z "$name" || " ${allowed_calls[*]} " == *" $name "* ]] && continue
    printf 'self-check: CoreAudio/CoreMIDI call not on the read-only allowlist: %s\n' "$name" >&2
    status=1
  done < <(grep -oE '(^|[^A-Za-z0-9_])(Audio|MIDI)[A-Za-z0-9_]*\(' "$swift_source" \
    | grep -oE '(Audio|MIDI)[A-Za-z0-9_]*' | sort -u)
  while IFS= read -r name; do
    [[ -z "$name" || " ${allowed_imports[*]} " == *" $name "* ]] && continue
    printf 'self-check: import not on the allowlist: %s\n' "$name" >&2
    status=1
  done < <(sed -nE 's/^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)?import[[:space:]]+([A-Za-z0-9_.]+).*/\2/p' \
    "$swift_source" | sort -u)
  if (( status == 0 )); then
    printf 'self-check: OK (%s uses only allowlisted read-only calls and imports)\n' "$swift_source"
  fi
  return "$status"
}

collect() {
  self_check
  local root stamp out listing type types=()
  root="${FLUXKLANG_INVENTORY_DIR:-$HOME/.local/state/FluxKlang/transform-passive-hardware-inventory}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$root/$stamp"
  umask 077
  mkdir -p "$out"

  {
    sw_vers
    printf 'arch: %s\n' "$(uname -m)"
    if command -v swift >/dev/null 2>&1; then swift --version 2>&1; fi
  } >"$out/os.txt"

  # macOS 15+ renamed SPUSBDataType to SPUSBHostDataType; use whichever this OS lists.
  listing="$(system_profiler -listDataTypes)"
  for type in SPUSBDataType SPUSBHostDataType SPAudioDataType SPThunderboltDataType SPPowerDataType; do
    if grep -qx "$type" <<<"$listing"; then types+=("$type"); fi
  done
  system_profiler -json "${types[@]}" >"$out/system_profiler.json"
  ioreg -p IOUSB -l -w0 >"$out/ioreg-iousb.txt"
  # Interface descriptors: audio/MIDI class versions and any mass-storage (disk-mode) interface.
  ioreg -r -c IOUSBHostInterface -l -w0 >"$out/ioreg-usb-interfaces.txt"

  if command -v swift >/dev/null 2>&1; then
    swift "$swift_source" >"$out/coreaudio-coremidi.json"
  else
    printf 'swift not found; CoreAudio/CoreMIDI listing skipped\n' >"$out/coreaudio-coremidi.skipped.txt"
  fi

  printf 'Raw passive inventory written to: %s\n' "$out"
  printf 'Raw files can contain serials, UIDs, location IDs and personal names. Never commit them.\n'
}

case "${1:-}" in
  --self-check) self_check ;;
  "") collect ;;
  -h | --help) sed -n '2,17p' "$0" ;;
  *)
    printf 'usage: %s [--self-check]\n' "$0" >&2
    exit 2
    ;;
esac
