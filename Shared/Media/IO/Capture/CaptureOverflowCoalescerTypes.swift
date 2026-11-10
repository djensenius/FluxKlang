//
//  CaptureOverflowCoalescerTypes.swift
//  FluxKlang
//
//  The plain values of the capture overflow coalescer (#109 CDB1,
//  media-contract.md section 8.3): limits, typed refusals and the step an offered
//  interval produces. Scalars only; no sample payload, no collection.
//

/// The bounds of the capture overflow coalescer, each pinned by a test at both ends (accepted at the end, refused
/// one outside): a record limit in `1...maximumRecords` and an interval's frames in `1...maximumRecordFrames`.
enum CaptureOverflowLimits {
    /// The ledger's own per-segment overflow cap, referenced so a ledger cap change is followed.
    static let maximumRecords = TakeLedger.maximumOverflowsPerSegment
    /// The width of a discontinuity's frame count (`UInt32`), shared with the pump's padding bound.
    static let maximumRecordFrames = CaptureDrainLimits.maximumPaddingFrames
}

/// Why the coalescer refused. A refusal leaves the coalescer `==` its copy.
enum CaptureOverflowRefusal: Error, Equatable, Sendable {
    /// `make`: the record limit is not in `1...maximum`.
    case recordLimitOutOfRange(limit: Int, maximum: Int)
    /// `offer`: the interval starts before frame 0.
    case negativeStartFrame(Int64)
    /// `offer`: the frame count is not in `1...maximum`.
    case framesOutOfRange(frames: Int, maximum: Int)
    /// `offer`: the end of the interval does not fit `Int64`.
    case frameOverflow(startFrame: Int64, frames: Int)
    /// `offer`: the interval starts before the end of the last interval offered.
    case overlapsPrevious(startFrame: Int64, frontier: Int64)
    /// The discontinuity could not be built; not exercised, because the range checks of `offer` keep the frame
    /// count inside the mapping's width.
    case mapping(MediaIOMappingRefusal)
}

/// What one offered interval did.
enum CaptureOverflowStep: Sendable {
    /// Absorbed into, or started, the held run; nothing to append yet.
    case held
    /// The previous held run closed: append it to the ledger. The offered interval is now the held run.
    case record(RuntimeDiscontinuity)
    /// The interval needed a new record and the record limit was used up: it is NOT recorded and its frames are
    /// counted in `unrecordedFrames`. The caller must act.
    case saturated(CaptureDrainOverflow)
}
