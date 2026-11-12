//
//  AnchorV1RecordRefusal.swift
//  FluxKlang
//
//  Why a clock anchor cannot become a contract v1 `anchorRecord` (#84 AXR1). In memory only; nothing is
//  clamped, remapped or serialized in its place.
//

/// The first offence `AnchorV1Record.make` finds, in this order: `seq`, `sampleClock`, the musical ticks, then
/// `note`.
enum AnchorV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The sample clock ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidSampleClock(ClockID)
    /// The musical stamp's ticks are below 0.
    case negativeMusicalTicks(Int64)
    /// The note is empty, all whitespace, or longer than `AnchorV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
