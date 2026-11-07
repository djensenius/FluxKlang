//
//  CaptureClipExportRefusal.swift
//  FluxKlang
//
//  Typed refusals of the SMF export of a MIDI capture log (#112 CL5). A refused export returns nothing and
//  leaves the log, a value, unchanged.
//

/// Why a capture log cannot be exported as a clip or Standard MIDI File. Checks run in this order and the first
/// defect found is the one reported: streams empty, too many streams, duplicate stream, undeclared stream, tainted
/// stream (those four in list order, wrapped in `.capture`), missing musical ticks, no captures, length out of range,
/// an undecodable MIDI 1 packet, nothing exportable, ticks out of range, a Note On while sounding, too many items,
/// then the clip's own refusal. A selection whose captures are all untimed holds both a missing-ticks and a
/// no-captures defect, and the missing ticks are reported. The length check covers a requested length and, when none
/// is requested, the default length taken from the selected MIDI 1 channel-voice captures (decodable or not): both
/// are checked before any capture is decoded, so an out-of-range default length wins over an undecodable packet.
enum CaptureClipExportRefusal: Error, Equatable, Sendable {
    /// The log's own export refusal (`exportStreamsEmpty`, `exportStreamsDuplicate`, `undeclaredStream`,
    /// `containsUnsupportedCapture`, `captureRefusedAtCapacity`, `exportHasNoCaptures`), with its payload.
    case capture(MIDICaptureRefusal)
    /// More than `limit` streams are selected. Checked right after the empty list, so 65 names (64 declared plus a
    /// repeat) report this and not the repeat.
    case tooManyStreams(count: Int, limit: Int)
    /// A selected capture carries no musical ticks (no transport was anchored): SMF needs ticks and wall-clock time
    /// is never guessed. `stream` and `index` (into `MIDICaptureLog.records`) name the first such capture.
    case noMusicalTime(stream: StreamID, index: Int)
    /// The requested clip length, or the default length of the selected MIDI 1 channel-voice captures (taken from
    /// the last of them before any is decoded), is outside
    /// `1...MIDIClip.maximumLengthTicks`. The payload is the offending length; a default length whose quarter-note
    /// product would overflow `Int64` is reported as `Int64.max`.
    case lengthOutOfRange(Int64)
    /// The capture at `index` of `MIDICaptureLog.records` is MT 0x2 but not a MIDI 1 channel-voice message.
    case invalidChannelVoice(stream: StreamID, index: Int, UMPRefusal)
    /// No selected capture is MIDI 1 channel voice, so nothing would be written; all `dropped` were counted.
    case nothingExportable(dropped: Int)
    /// A message lies outside `0...lengthTicks`.
    case ticksOutOfRange(ticks: Int64, lengthTicks: Int64)
    /// A Note On arrived for a channel and note that was sounding since `sinceTicks`.
    case noteOnWhileSounding(channel: UInt8, note: UInt8, ticks: Int64, sinceTicks: Int64)
    /// The export would hold `count` items, more than `limit`.
    case tooManyItems(count: Int, limit: Int)
    /// The clip refused the converted items.
    case clip(MIDIClipRefusal)
}
