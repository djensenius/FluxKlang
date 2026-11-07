//
//  SMFTempoRefusal.swift
//  FluxKlang
//
//  Typed refusals of the Standard MIDI File tempo and meter scan (#112 CL6).
//  A refused scan returns no proposal: nothing is clamped, dropped or kept
//  partially. `track` is a zero-based index among the file's MTrk chunks and
//  `offset` a byte offset into the file.
//

/// Why Standard MIDI File bytes yield no tempo and meter proposal.
enum SMFTempoRefusal: Error, Equatable, Sendable {
    /// A structural defect the CL2 reader refuses in the same way (same case, same values): size, header, chunks,
    /// variable-length quantities, running status, End of Track and the `SMFReadLimits` bounds.
    case file(SMFRefusal)
    /// The tempo meta event (FF 51) that starts at `offset` has a length other than 3.
    case malformedTempo(track: Int, offset: Int)
    /// The time signature meta event (FF 58) that starts at `offset` has a length other than 4.
    case malformedTimeSignature(track: Int, offset: Int)
    /// A tempo event, at `atTicks` clip ticks, is outside `60,000...3,000,000` micros per quarter. Even a tempo that
    /// a later event at the same tick would supersede refuses: it is never clamped or dropped.
    case tempoOutOfRange(atTicks: Int64, microsPerQuarter: Int64)
    /// A time signature is not a valid `MusicalMeter`: `numerator` must be 1...64 and the denominator,
    /// `2^denominatorPower`, one of 1, 2, 4, 8, 16 and 32 (power 0...5). The power is reported, not the denominator,
    /// as the file byte may be 255.
    case invalidMeter(numerator: Int, denominatorPower: Int)
    /// The merged tempos need more than `limit` segments (the `MusicalMap` bound).
    case tooManySegments(limit: Int)
    /// The meter changes after the initial one number more than `limit`.
    case tooManyMeterChanges(limit: Int)
    /// `SMFTempoProposal.make` was given values that break an invariant of a proposal.
    case invalidProposal(SMFProposalDefect)
    /// `MusicalMap` refused the segments of a proposal.
    case map(ClockMapError)
}

/// Which invariant of `SMFTempoProposal` a caller-built value breaks.
enum SMFProposalDefect: Equatable, Sendable {
    case noSegments
    case firstSegmentNotAtZero
    case segmentsNotStrictlyIncreasing
    case adjacentSegmentsHaveEqualTempo
    case segmentBeyondClipLimit
    case meterChangesNotOrdered
    case meterChangeOutOfRange
    case negativeCount
    case defaultedTempoMismatch
}
