//
//  DiscontinuityV1RecordRefusal.swift
//  FluxKlang
//
//  Why a clock, transport or stream event cannot become a contract v1 `discontinuityRecord` (#109 DXR1).
//  In memory only; nothing is clamped, remapped or serialized in its place.
//

/// The first offence `DiscontinuityV1Record.make` finds, in this order: `seq`, `sampleClock`, the event's
/// `stream`, the event's `frames`, then `note`.
enum DiscontinuityV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The sample clock ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidSampleClock(ClockID)
    /// The event's stream ID does not match the media contract ID pattern.
    case invalidStream(StreamID)
    /// An `underrun`'s frame count is outside the schema's `frames` range, 1...`DiscontinuityV1Record.maximumFrames`.
    case framesOutOfRange(Int64)
    /// The note is empty, all whitespace, or longer than `DiscontinuityV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
