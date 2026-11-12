//
//  RecordingTakeV1Refusal.swift
//  FluxKlang
//
//  Why a finished take cannot become a contract v1 document: the standing refusals of the
//  #352 ruling. In memory only; nothing serializes or remaps them.
//

/// The first offence found by `RecordingTakeV1Gate.clear`: a pair of consecutive segments that is
/// not a restart split (#352), or an unplaced segment.
enum RecordingTakeV1Refusal: Error, Hashable, Sendable {
    /// Segments `after` and `after + 1` are not `(clock, gen)` then `(clock, gen + 1)`.
    case notRestartSplit(after: Int)
    /// The segment at this index has no `startOffsetNs`.
    case unplacedSegment(Int)
}
