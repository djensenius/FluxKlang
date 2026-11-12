//
//  RecordingTakeV1Refusal.swift
//  FluxKlang
//
//  Why a finished take cannot become a contract v1 document: the standing refusals of the
//  #352 ruling. In memory only; nothing serializes or remaps them.
//

/// The first offence found by `RecordingTakeV1Gate.clear`: a pair of consecutive segments that is neither
/// a restart split nor a forward `sampleJump` split (#352), or an unplaced segment.
enum RecordingTakeV1Refusal: Error, Hashable, Sendable {
    /// Segments `after` and `after + 1` are not a restart split (`(clock, gen)` then `(clock, gen + 1)`) and
    /// not a same-generation pair: a clock change, a generation skip or a wrapped generation.
    case notRestartSplit(after: Int)
    /// Segments `after` and `after + 1` share a clock and generation but the later does not start after the
    /// earlier's last frame: a backward jump (overlapping frames) or no gap. Only a forward jump has a contract
    /// shape (`gapFrames`).
    case sampleJumpNotForward(after: Int)
    /// The segment at this index has no `startOffsetNs`.
    case unplacedSegment(Int)
}
