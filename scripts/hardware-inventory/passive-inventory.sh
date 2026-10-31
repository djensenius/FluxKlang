#!/usr/bin/env bash
# Passive, read-only hardware inventory runner for FluxKlang (roadmap #48, issue #67).
#
# Collects OS descriptors (system_profiler, ioreg) first, then, only with a working
# Swift toolchain and a passing self-check, a read-only CoreAudio HAL / CoreMIDI
# listing. Nothing here plays, sends or sets anything; OS-side effects of reading
# are listed in docs/transformation/hardware-inventory.md. Raw output can contain
# serials, device UIDs, USB location IDs and personal names: never commit it.
#
# Usage:
#   scripts/hardware-inventory/passive-inventory.sh [--require-symbols]               # collect
#   scripts/hardware-inventory/passive-inventory.sh --self-check [--require-symbols]  # tripwire only
#
# --require-symbols (or FLUXKLANG_INVENTORY_REQUIRE_SYMBOLS=1) makes the self-check FAIL when its
# symbol layer does not run fully (no working Swift toolchain, the lister does not compile, or
# swift-demangle is missing or fails). Without it the self-check warns and falls back to the source layer.
# CI and the Makefile target use it. When collecting, it only makes the pre-listing self-check
# strict; with no toolchain at all the listing is still skipped with a warning.
#
# Output (root overridable with FLUXKLANG_INVENTORY_DIR; refused inside the repo):
#   ~/.local/state/FluxKlang/transform-passive-hardware-inventory/<UTC stamp>.XXXXXX/
set -Eeuo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
swift_source="$script_dir/passive-inventory.swift"
out_dir=""
require_symbols="${FLUXKLANG_INVENTORY_REQUIRE_SYMBOLS:-0}"

on_error() {
  local status=$? line="$1"
  printf 'passive-inventory: failed with status %s near line %s\n' "$status" "$line" >&2
  if [[ -n "$out_dir" ]]; then
    printf 'passive-inventory: INCOMPLETE raw output left in %s (private; never commit)\n' "$out_dir" >&2
  fi
}
trap 'on_error "$LINENO"' ERR

die() {
  printf 'passive-inventory: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'passive-inventory: WARNING: %s\n' "$*" >&2
  if [[ -n "$out_dir" ]]; then printf '%s\n' "$*" >>"$out_dir/warnings.txt"; fi
}

# ---------------------------------------------------------------------------
# Self-check: a defence-in-depth TRIPWIRE, not a proof of read-only behaviour.
# It catches accidental or careless edits to the Swift lister; a determined
# author can always evade static checks, so review the Swift source as well.
#
# Layer 1 (source, needs only bash/grep/tr/sed/awk; works without Xcode):
#   - newlines are folded first, so a call split across lines still matches;
#   - every Audio*/MIDI*/kAudio*/kMIDI* identifier, comments included, must be on
#     allowed_identifiers (types, read-only getters and property constants);
#   - denied_source fragments (setters, starts, sends, listeners, clients, ports,
#     network, process, file-write and dynamic-lookup escape hatches, backticks)
#     must not appear anywhere;
#   - every import, whatever its attributes or `;` joins, must be allowlisted.
# Layer 2 (symbols, only with a working Swift toolchain; if it cannot run, a
# warning, or a failure with --require-symbols / FLUXKLANG_INVENTORY_REQUIRE_SYMBOLS=1):
#   the file is compiled with `swiftc -c` into a temp dir and every undefined
#   symbol from `nm -u` is checked: Audio*/MIDI* functions must be on
#   allowed_symbols, kAudio*/kMIDI* data on allowed_identifiers, and C, ObjC and
#   demangled Swift symbols must not match the denied_symbol_* patterns.
# ---------------------------------------------------------------------------

allowed_imports=(CoreAudio CoreMIDI Foundation)

# Read-only CoreAudio/CoreMIDI functions the lister may link against.
allowed_symbols=(
  AudioObjectHasProperty AudioObjectGetPropertyDataSize AudioObjectGetPropertyData
  MIDIGetNumberOfDevices MIDIGetDevice MIDIDeviceGetNumberOfEntities MIDIDeviceGetEntity
  MIDIEntityGetNumberOfSources MIDIEntityGetSource MIDIEntityGetNumberOfDestinations
  MIDIEntityGetDestination MIDIGetNumberOfSources MIDIGetNumberOfDestinations
  MIDIObjectGetStringProperty MIDIObjectGetIntegerProperty
)

# Every Audio*/MIDI*/kAudio*/kMIDI* identifier the source may contain: the getters
# above, plain C types and property selector/scope/element constants.
allowed_identifiers=(
  "${allowed_symbols[@]}"
  MIDI
  AudioBufferList AudioObjectID AudioObjectPropertyAddress AudioObjectPropertyElement
  AudioObjectPropertyScope AudioObjectPropertySelector AudioStreamBasicDescription AudioStreamID
  AudioValueRange AudioValueTranslation MIDIObjectRef MIDIEndpointRef MIDIEntityRef
  kAudioObjectSystemObject kAudioObjectPropertyScopeGlobal kAudioObjectPropertyScopeInput
  kAudioObjectPropertyScopeOutput kAudioObjectPropertyElementMain kAudioObjectPropertyElementName
  kAudioObjectPropertyName kAudioObjectPropertyManufacturer kAudioObjectPropertyModelName
  kAudioObjectPropertyFirmwareVersion
  kAudioHardwarePropertyDevices kAudioHardwarePropertyDefaultInputDevice
  kAudioHardwarePropertyDefaultOutputDevice kAudioHardwarePropertyDefaultSystemOutputDevice
  kAudioDevicePropertyDeviceUID kAudioDevicePropertyModelUID kAudioDevicePropertyTransportType
  kAudioDevicePropertyClockDomain kAudioDevicePropertyDeviceIsAlive
  kAudioDevicePropertyDeviceIsRunningSomewhere kAudioDevicePropertyHogMode
  kAudioDevicePropertyNominalSampleRate kAudioDevicePropertyAvailableNominalSampleRates
  kAudioDevicePropertyBufferFrameSize kAudioDevicePropertyBufferFrameSizeRange
  kAudioDevicePropertyStreamConfiguration kAudioDevicePropertyStreams
  kAudioDevicePropertyClockSource kAudioDevicePropertyClockSources
  kAudioDevicePropertyClockSourceNameForIDCFString
  kAudioStreamPropertyStartingChannel kAudioStreamPropertyTerminalType
  kAudioStreamPropertyIsActive kAudioStreamPropertyPhysicalFormat
  kMIDIPropertyName kMIDIPropertyManufacturer kMIDIPropertyModel kMIDIPropertyDriverOwner
  kMIDIPropertyOffline kMIDIPropertyProtocolID
)

ident_start='(^|[^A-Za-z0-9_])' # nothing or a non-identifier character before the token
call_open='[[:space:]]*\('      # opening parenthesis, whitespace and folded newlines tolerated
backtick=$'\x60'

denied_source=(
  # CoreAudio / AudioToolbox / AVFoundation: setters, unload, listeners, I/O, units, taps, aggregates.
  SetProperty AudioHardwareUnload AddPropertyListener RemovePropertyListener
  AudioDeviceStart AudioDeviceStop IOProc AudioOutputUnit AudioUnit AudioComponent
  AudioQueue AudioServices AudioFile ExtAudioFile AggregateDevice ProcessTap CATap
  AUGraph AUAudioUnit AVAudio AVFoundation AVFAudio
  # CoreMIDI: clients, ports, emission, thru, setup and object mutation.
  MIDIClient MIDIInputPort MIDIOutputPort MIDIPort MIDISend MIDIReceived MIDIFlushOutput
  MIDISourceCreate MIDIDestinationCreate MIDIDeviceCreate MIDIExternalDeviceCreate
  MIDIThruConnection MIDISetup MIDIObjectSet MIDIObjectRemoveProperty MIDIRestart MIDINetwork
  # Network and IPC.
  Network NWConnection NWBrowser NWListener NetService URLSession NSURLConnection URLRequest
  socket Socket sendto sendmsg getaddrinfo NSXPCConnection
  "${ident_start}OSC" "${ident_start}connect${call_open}" "${ident_start}send${call_open}"
  # Processes, scripts, devices, file writes, dynamic lookup and linkage escape hatches.
  "${ident_start}system${call_open}" popen "${ident_start}v?fork${call_open}" "${ident_start}f?exec[lvp]"
  posix_spawn ioctl "${ident_start}(f|fre)?open(at)?${call_open}" "${ident_start}creat${call_open}"
  /dev/ forWriting forUpdating FileManager fileDescriptor
  "${ident_start}write${call_open}[[:space:]]*to(File)?[[:space:]]*:"
  "${ident_start}(Data|NSData|String|NSString)${call_open}[[:space:]]*contentsOf"
  "${ident_start}Process([^A-Za-z0-9_]|\$)" NSTask NSAppleScript NSUserScriptTask NSWorkspace
  dlsym dlopen NSClassFromString NSSelectorFromString "${ident_start}Selector${call_open}" '#selector'
  "${ident_start}perform${call_open}" objc_ Bundle IOServiceOpen IOConnect IORegistryEntrySet IOHID
  @_silgen_name @_cdecl @_extern "$backtick"
)

# Undefined C / ObjC symbols that must not appear (Darwin may add a $SUFFIX variant).
denied_symbol_c='^_(system|popen|pclose|v?fork|f?exec[A-Za-z]*|posix_spawn[A-Za-z_]*|ioctl|open|openat'
denied_symbol_c+='|fopen|freopen|creat|connectx?|send|sendto|sendmsg|socket|socketpair|bind|listen|accept'
denied_symbol_c+='|getaddrinfo|dlopen|dlsym|xpc_[A-Za-z_]*|IOServiceOpen|IOConnect[A-Za-z]*'
denied_symbol_c+='|IORegistryEntrySet[A-Za-z]*|CFBundle[A-Za-z]*|CFSocket[A-Za-z]*|CF(Read|Write)?Stream[A-Za-z]*'
denied_symbol_c+='|CFMessagePort[A-Za-z]*|NSClassFromString|NSSelectorFromString'
denied_symbol_c+='|objc_(getClass|lookUpClass|getRequiredClass|getMetaClass|getProtocol)|sel_(registerName|getUid)'
denied_symbol_c+='|class_getMethodImplementation|method_getImplementation)(\$[A-Za-z0-9_$]*)?$'
denied_symbol_c+='|^_OBJC_(METACLASS|CLASS)_[$]_(AV|AU|NW|CA|MIDI|Audio|NSTask|NSAppleScript|NSUserScriptTask'
denied_symbol_c+='|NSURLSession|NSURLConnection|NSNetService|NSBundle|NSFileManager|NSWorkspace|NSXPCConnection'
denied_symbol_c+='|NSPipe|NSStream|NSInputStream|NSOutputStream|NSSocketPort|NSHost)'
denied_symbol_c+='|^__swift_FORCE_LOAD_[$]_swift(Network|AV[A-Za-z]*|AudioToolbox|AudioUnit|CoreAudioKit'
denied_symbol_c+='|MultipeerConnectivity)$'
# ObjC selector stubs (objc_msgSend$<selector>), matched case-insensitively.
denied_symbol_selector='^_objc_msgSend\$.*(forwriting|forupdating|contentsof|launch|executable|writeto'
denied_symbol_selector+='|createfile|removeitem|executeandreturnerror|datatask|principalclass'
denied_symbol_selector+='|loadandreturnerror|performselector|valueforkey|setvalue)'
# Demangled Swift symbols.
denied_symbol_swift='(^|[^A-Za-z0-9_])((Network|NetworkExtension|AVFoundation|AVFAudio|AudioToolbox|AudioUnit'
denied_symbol_swift+='|CoreAudioKit|CoreMIDI|Glibc)\.|Foundation\.(Process|URLSession|URLRequest|Bundle|FileManager'
denied_symbol_swift+='|Pipe|OutputStream|InputStream|Host|NetService)([^A-Za-z0-9_]|$)|Darwin\.(system|popen|v?fork'
denied_symbol_swift+='|f?exec[a-z]*|posix_spawn[a-z_]*|ioctl|fcntl|open|openat|fopen|creat|connect|send|sendto|socket'
denied_symbol_swift+='|dlopen|dlsym)([^A-Za-z0-9_]|$)|__C\.(NSTask|NSAppleScript|NSUserScriptTask|NSURLSession'
denied_symbol_swift+='|NSURLConnection|NSNetService|NSBundle|NSFileManager|NSWorkspace|NSXPCConnection|NSPipe'
denied_symbol_swift+='|NSStream|NSInputStream|NSOutputStream|NSHost|AV|AU|NW))|forWriting|forUpdating|contentsOf'
denied_symbol_swift+='|\.write(<[^>]*>)?\(to(File)?:'

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then return 0; fi
  done
  return 1
}

join_patterns() {
  local IFS='|'
  printf '%s' "$*"
}

have_swift_toolchain() {
  # /usr/bin/swift and /usr/bin/xcrun exist even without developer tools, so ask
  # xcode-select first (no install prompt) and then resolve the real binaries.
  if ! command -v xcode-select >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then return 1; fi
  if ! xcode-select -p >/dev/null 2>&1; then return 1; fi
  xcrun --find swiftc >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1
}

# Layer 1. Returns 0 (pass) or 1 (fail).
source_check() {
  local status=0 folded hits name keyword_count import_count denied_pattern
  local import_re="${ident_start}import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?"
  import_re+='[A-Za-z_][A-Za-z0-9_]*'
  folded="$(tr '\n\r\t' '   ' <"$swift_source")"
  denied_pattern="$(join_patterns "${denied_source[@]}")"

  hits="$(grep -oE "$denied_pattern" <<<"$folded" | sed -E 's/^[[:space:]]+//' | sort -u || true)"
  if [[ -n "$hits" ]]; then
    printf 'self-check: denied token(s) in %s (newlines folded):\n' "$swift_source" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    status=1
  fi

  while IFS= read -r name; do
    if [[ -z "$name" ]] || in_list "$name" "${allowed_identifiers[@]}"; then continue; fi
    printf 'self-check: identifier not on the read-only allowlist: %s\n' "$name" >&2
    status=1
  done < <(grep -oE "${ident_start}(Audio|MIDI|kAudio|kMIDI)[A-Za-z0-9_]*" <<<"$folded" \
    | sed -E 's/^[^A-Za-z]//' | sort -u || true)

  keyword_count="$(grep -oE "${ident_start}import([^A-Za-z0-9_]|\$)" <<<"$folded" | grep -c . || true)"
  import_count="$(grep -oE "$import_re" <<<"$folded" | grep -c . || true)"
  if [[ "$keyword_count" != "$import_count" ]]; then
    printf 'self-check: %s import keyword(s) but only %s parseable import(s); rewrite imports plainly\n' \
      "$keyword_count" "$import_count" >&2
    status=1
  fi
  while IFS= read -r name; do
    if [[ -z "$name" ]] || in_list "$name" "${allowed_imports[@]}"; then continue; fi
    printf 'self-check: import not on the allowlist: %s\n' "$name" >&2
    status=1
  done < <(grep -oE "$import_re" <<<"$folded" | awk '{ print $NF }' | sort -u || true)

  return "$status"
}

# Layer 2. Returns 0 (pass), 1 (fail) or 2 (could not run or incomplete; self_check decides).
symbol_check() {
  local status=0 work hits name total demangled=1
  if ! have_swift_toolchain || ! xcrun --find nm >/dev/null 2>&1; then
    printf 'self-check: symbol layer unavailable: no working Swift toolchain (xcode-select -p, xcrun --find)\n' >&2
    return 2
  fi
  if ! work="$(mktemp -d "${TMPDIR:-/tmp}/fluxklang-passive-inventory.XXXXXX")"; then
    printf 'self-check: symbol layer unavailable: could not create a temp dir\n' >&2
    return 2
  fi
  if ! xcrun swiftc -c "$swift_source" -module-name PassiveInventory -o "$work/inventory.o" \
    >"$work/swiftc.log" 2>&1; then
    printf 'self-check: symbol layer unavailable: swiftc could not compile the lister:\n' >&2
    sed -n '1,20s/^/  /p' "$work/swiftc.log" >&2
    rm -rf -- "$work"
    return 2
  fi
  if ! xcrun nm -u "$work/inventory.o" >"$work/undefined.txt" 2>"$work/nm.log"; then
    printf 'self-check: symbol layer unavailable: nm -u failed\n' >&2
    rm -rf -- "$work"
    return 2
  fi
  total="$(grep -c . "$work/undefined.txt" || true)"

  while IFS= read -r name; do
    if [[ -z "$name" ]] || in_list "$name" "${allowed_symbols[@]}"; then continue; fi
    printf 'self-check: linked CoreAudio/CoreMIDI function not on the getter allowlist: %s\n' "$name" >&2
    status=1
  done < <(grep -E '^_(Audio|MIDI)' "$work/undefined.txt" | sed 's/^_//' | sort -u || true)
  while IFS= read -r name; do
    if [[ -z "$name" ]] || in_list "$name" "${allowed_identifiers[@]}"; then continue; fi
    printf 'self-check: linked CoreAudio/CoreMIDI constant not on the allowlist: %s\n' "$name" >&2
    status=1
  done < <(grep -E '^_(kAudio|kMIDI)' "$work/undefined.txt" | sed 's/^_//' | sort -u || true)

  hits="$( (grep -E "$denied_symbol_c" "$work/undefined.txt" || true; \
    grep -iE "$denied_symbol_selector" "$work/undefined.txt" || true) | sort -u)"
  if [[ -n "$hits" ]]; then
    printf 'self-check: denied undefined symbol(s):\n' >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    status=1
  fi

  grep -E '^_?[$]s' "$work/undefined.txt" >"$work/swift-symbols.txt" || true
  if ! xcrun --find swift-demangle >/dev/null 2>&1; then
    printf 'self-check: symbol layer incomplete: swift-demangle not found; Swift-level checks skipped\n' >&2
    demangled=0
  elif ! xcrun swift-demangle <"$work/swift-symbols.txt" >"$work/demangled.txt" 2>/dev/null \
    || (($(wc -l <"$work/swift-symbols.txt") != $(wc -l <"$work/demangled.txt"))); then
    # swift-demangle emits one line per input line; anything else is partial output.
    printf 'self-check: symbol layer incomplete: swift-demangle failed or returned partial output; Swift-level checks skipped\n' >&2
    demangled=0
  else
    hits="$( (grep -E "$denied_symbol_swift" "$work/demangled.txt" || true; \
      sed -E 's/CoreAudio\.UnsafeMutableAudioBufferListPointer//g' "$work/demangled.txt" \
        | grep -E 'CoreAudio\.' || true) | sort -u)"
    if [[ -n "$hits" ]]; then
      printf 'self-check: denied Swift symbol(s):\n' >&2
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
      status=1
    fi
    while IFS= read -r name; do
      if [[ -z "$name" ]] || in_list "$name" "${allowed_identifiers[@]}"; then continue; fi
      printf 'self-check: Swift symbol uses a CoreAudio/CoreMIDI type not on the allowlist: %s\n' "$name" >&2
      status=1
    done < <(grep -oE '__C\.(Audio|MIDI|kAudio|kMIDI)[A-Za-z0-9_]*' "$work/demangled.txt" \
      | sed 's/^__C\.//' | sort -u || true)
  fi

  rm -rf -- "$work"
  if ((status == 0 && demangled == 0)); then return 2; fi
  if ((status == 0)); then printf 'self-check: symbol layer OK (%s undefined symbols checked)\n' "$total"; fi
  return "$status"
}

self_check() {
  local source_status=0 symbol_status=0
  if [[ ! -f "$swift_source" ]]; then
    printf 'self-check: missing %s\n' "$swift_source" >&2
    return 1
  fi
  source_check || source_status=$?
  if ((source_status == 0)); then printf 'self-check: source layer OK (%s)\n' "$swift_source"; fi
  symbol_check || symbol_status=$?
  if ((source_status != 0 || symbol_status == 1)); then
    printf 'self-check: FAILED\n' >&2
    return 1
  fi
  if ((symbol_status == 2)); then
    if [[ "$require_symbols" == 1 ]]; then
      printf 'self-check: FAILED: the symbol layer is required (--require-symbols or %s) but did not run fully;\n' \
        'FLUXKLANG_INVENTORY_REQUIRE_SYMBOLS=1' >&2
      printf 'self-check: select a working Swift toolchain and make sure the lister compiles\n' >&2
      return 1
    fi
    printf 'self-check: WARNING: symbol layer did not run fully; falling back to the source layer only\n' >&2
    printf 'self-check: PASSED source layer only; a tripwire, not a proof\n'
  else
    printf 'self-check: PASSED source and symbol layers; a defence-in-depth tripwire, not a proof\n'
  fi
}

lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# Physical path of a possibly not-yet-existing directory (deepest existing ancestor resolved).
physical_path() {
  local path="$1" rest="" resolved
  if [[ "$path" != /* ]]; then path="$PWD/$path"; fi
  while [[ "$path" == */ && "$path" != / ]]; do path="${path%/}"; done
  while [[ ! -d "$path" ]]; do
    rest="/${path##*/}$rest"
    path="${path%/*}"
    if [[ -z "$path" ]]; then path=/; fi
  done
  resolved="$(CDPATH='' cd -P -- "$path" && pwd -P)"
  printf '%s%s\n' "${resolved%/}" "$rest"
}

git_usable() {
  local git_path
  git_path="$(command -v git 2>/dev/null)" || return 1
  # /usr/bin/git is a stub that prompts for developer tools when they are missing.
  if [[ "$git_path" != /usr/bin/git ]]; then return 0; fi
  xcode-select -p >/dev/null 2>&1
}

refuse_inside_repo() {
  local requested="$1" target top tops=()
  case "/$requested/" in
    */../*) die "FLUXKLANG_INVENTORY_DIR must not contain '..' components: $requested" ;;
  esac
  target="$(physical_path "$requested")"
  target="$(lower "$target")"
  tops+=("$(CDPATH='' cd -P -- "$script_dir/../.." && pwd -P)")
  if git_usable && top="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    tops+=("$(CDPATH='' cd -P -- "$top" && pwd -P)")
  fi
  for top in "${tops[@]}"; do
    top="$(lower "$top")"
    if [[ "$target" == "$top" || "$target" == "$top"/* ]]; then
      die "refusing to write raw inventory inside the git repository ($top); set FLUXKLANG_INVENTORY_DIR elsewhere"
    fi
  done
}

collect() {
  local root stamp listing type usb_type="" types=()
  root="${FLUXKLANG_INVENTORY_DIR:-$HOME/.local/state/FluxKlang/transform-passive-hardware-inventory}"
  refuse_inside_repo "$root"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  umask 077
  mkdir -p -- "$root"
  out_dir="$(mktemp -d "$root/$stamp.XXXXXX")"

  # 1. Passive OS descriptors, before any Swift step.
  {
    sw_vers
    printf 'arch: %s\n' "$(uname -m)"
  } >"$out_dir/os.txt"

  # macOS 15+ renamed SPUSBDataType to SPUSBHostDataType; use whichever this OS lists.
  listing="$(system_profiler -listDataTypes)"
  for type in SPUSBDataType SPUSBHostDataType; do
    if grep -qx "$type" <<<"$listing"; then
      types+=("$type")
      usb_type="$type"
    fi
  done
  if [[ -z "$usb_type" ]]; then warn 'system_profiler lists no USB data type; USB section will be missing'; fi
  for type in SPAudioDataType SPThunderboltDataType SPPowerDataType; do
    if grep -qx "$type" <<<"$listing"; then types+=("$type"); fi
  done
  if ((${#types[@]} > 0)); then
    system_profiler -json "${types[@]}" >"$out_dir/system_profiler.json"
  else
    warn 'system_profiler lists none of the requested data types; skipped'
  fi

  ioreg -p IOUSB -l -w0 >"$out_dir/ioreg-iousb.txt"
  if ! grep -qE '<class (IOUSBHostDevice|IOUSBDevice)[,>]' "$out_dir/ioreg-iousb.txt"; then
    warn 'the IOUSB plane lists no USB devices'
  fi
  # Interface descriptors: audio/MIDI class versions and any mass-storage (disk-mode) interface.
  ioreg -r -c IOUSBHostInterface -l -w0 >"$out_dir/ioreg-usb-interfaces.txt"

  # 2. CoreAudio HAL / CoreMIDI listing: real toolchain and passing self-check only.
  if have_swift_toolchain; then
    xcrun swift --version >>"$out_dir/os.txt" 2>&1
    if ! self_check >"$out_dir/self-check.txt" 2>&1; then
      cat "$out_dir/self-check.txt" >&2
      printf 'passive-inventory: self-check failed; Swift listing NOT run. Partial output: %s\n' "$out_dir" >&2
      exit 1
    fi
    xcrun swift "$swift_source" >"$out_dir/coreaudio-coremidi.json"
  else
    warn 'no working Swift toolchain (xcode-select -p / xcrun --find swift); CoreAudio/CoreMIDI listing skipped'
  fi

  printf 'Raw passive inventory written to: %s\n' "$out_dir"
  printf 'Raw files can contain serials, UIDs, location IDs and personal names. Never commit them.\n'
}

usage() {
  printf 'usage: %s [--self-check] [--require-symbols] | --help\n' "$0" >&2
}

mode=collect
for arg in "$@"; do
  case "$arg" in
    --self-check) mode=self-check ;;
    --require-symbols) require_symbols=1 ;;
    -h | --help) mode=help ;;
    *)
      usage
      exit 2
      ;;
  esac
done
case "$require_symbols" in
  0 | 1) ;;
  *)
    printf 'passive-inventory: FLUXKLANG_INVENTORY_REQUIRE_SYMBOLS must be 0 or 1, not %s\n' "$require_symbols" >&2
    exit 2
    ;;
esac

case "$mode" in
  self-check)
    if self_check; then exit 0; fi
    exit 1
    ;;
  collect) collect ;;
  help) sed -n '2,21p' "${BASH_SOURCE[0]}" ;;
esac
