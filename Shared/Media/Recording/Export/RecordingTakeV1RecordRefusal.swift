//
//  RecordingTakeV1RecordRefusal.swift
//  FluxKlang
//
//  Why a cleared take cannot become a contract v1 `takeRecord` (#110 TKX1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `RecordingTakeV1Record.make` finds, in this order: `seq`, `takeId`, `stream`, the segment
/// count, then per segment (lowest index first) its placement, `sampleClock` and `gapFrames`, then `note`. The
/// stop never refuses: every stop has a contract v1 value.
enum RecordingTakeV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The take ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidTakeID(TakeID)
    /// The stream ID does not match the media contract ID pattern.
    case invalidStream(StreamID)
    /// The take has more segments than `TakeLedger.maximumSegmentsPerTake` (`limit`). The ledger never builds
    /// such a take and the gate sets no count limit, so a hand-built one is refused here; this bounds the output.
    case tooManySegments(count: Int, limit: Int)
    /// The segment at this index names a sample clock that does not match the media contract ID pattern.
    case invalidSampleClock(segment: Int)
    /// The gap before the segment at this index does not fit an `Int64`: its `startFrame` and the end of the
    /// previous same-generation segment are further apart than any `gapFrames` the schema can hold. The ledger
    /// reads frames from a device counter, so only an extreme stamp reaches this; nothing is clamped.
    case gapFramesOutOfRange(segment: Int)
    /// The note is empty, all whitespace, or longer than `RecordingTakeV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
    /// The take fails a gate rule after all. Unreachable through a clearance the gate built; kept so a
    /// broken invariant refuses instead of crashing or remapping.
    case uncleared(RecordingTakeV1Refusal)
}
