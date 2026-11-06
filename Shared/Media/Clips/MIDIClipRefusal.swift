//
//  MIDIClipRefusal.swift
//  FluxKlang
//
//  Typed refusals of MIDI clip playback timing (#112 CL1). Clock-map errors,
//  including stale generations and overflow, pass through unchanged inside `.clock`.
//  A refused operation returns nothing and leaves its input and state unchanged.
//

/// Why a MIDI clip, placement, window query or render is refused.
enum MIDIClipRefusal: Error, Equatable, Sendable {
    /// The clock map refused, or the map is stale for the live sample or transport generation.
    case clock(ClockMapError)
    /// The clock map's tempo map revision is not the live `musicalMap` generation.
    case staleMusicalMap
    /// v1 clips play only with `tempoFollowing`.
    case unsupportedTimePolicy(MediaTimePolicy)
    /// The clip length must lie in `1...MIDIClip.maximumLengthTicks`.
    case lengthOutOfRange(Int64)
    /// The clip holds more than `limit` items.
    case tooManyItems(count: Int, limit: Int)
    /// Channels are 1...16.
    case invalidChannel(item: Int, channel: UInt8)
    /// A data value is outside its MIDI 1 range (note or controller 0...127, Note On velocity 1...127, …).
    case invalidData(item: Int)
    /// A note span needs `0 ≤ startTicks < endTicks ≤ lengthTicks`.
    case invalidNoteSpan(item: Int, startTicks: Int64, endTicks: Int64)
    /// A non-note event needs `0 ≤ ticks < lengthTicks`.
    case eventOutsideClip(item: Int, ticks: Int64)
    /// Note On and Note Off are authored only as note spans.
    case noteMessageOutsideSpan(item: Int)
    /// System common, real-time and SysEx messages are not clip content in v1 (found in the per-item checks).
    /// Nor are hold controllers (CC 64, 66, 69) or channel mode messages (CC 120...127) at any value. They are
    /// refused after the per-item checks and before the overlap check, and `item` is the first such item in
    /// authoring order.
    case unsupportedMessage(item: Int)
    /// Two spans of one channel and note overlap; `first` starts no later than `second`.
    case overlappingNotes(first: Int, second: Int)
    /// The placement start must be nonnegative and leave room for the clip in `Int64`.
    case startOutOfRange(Int64)
    /// The clip loop `[startTicks, endTicks)` must end at or before the clip length.
    case loopOutsideClip(startTicks: Int64, endTicks: Int64, lengthTicks: Int64)
    /// The frame window `[start, end)` has `end < start`.
    case invalidWindow(start: Int64, end: Int64)
    /// The window spans more than `limit` frames.
    case windowTooLong(start: Int64, end: Int64, limit: Int64)
    /// The window holds more than `limit` events; nothing is returned rather than a truncated list.
    case tooManyEvents(limit: Int)
    /// A render must start where the previous one ended.
    case nonContiguousWindow(expected: Int64, start: Int64)
    /// The render's generations differ from those the scheduler is bound to; `stop()` first, then render.
    case clockRevisionChanged(expected: MIDIClipGenerations, got: MIDIClipGenerations)
    /// `rebind` needs a cursor: the scheduler has not rendered since creation or `stop()`.
    case rebindWithoutRender
    /// `rebind` must happen at the cursor, where the last render ended.
    case rebindCursorMismatch(expected: Int64, frame: Int64)
    /// The transport generation changed (a locate), so playback is not continuous: `stop()` first.
    case transportChangedRequiresStop(expected: Generation, got: Generation)
    /// The clock's transport loop iteration differs from the bound one (a loop wrap, which bumps no generation),
    /// so playback is not continuous: `stop()` first.
    case loopWrapRequiresStop(expected: UInt32, got: UInt32)
}
