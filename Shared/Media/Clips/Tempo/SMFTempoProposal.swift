//
//  SMFTempoProposal.swift
//  FluxKlang
//
//  The tempo and meter a Standard MIDI File proposes (#112 CL6). A proposal is
//  advice: values a later slice may adopt. Nothing here applies a map, edits a
//  clip or touches a transport.
//

/// What the merge of a file's tempo events dropped, and whether the first tempo was invented.
struct SMFTempoCounts: Equatable, Hashable, Sendable {
    /// Tempo events replaced by a later event at the same clip tick (merged order: tick, track, position).
    let supersededTempos: Int
    /// Tempo events that equal the tempo in force, so they start no segment.
    let coalescedTempos: Int
    /// No tempo event was at tick 0, so 500,000 micros per quarter (120 BPM, the SMF default) was proposed there.
    let defaultedInitialTempo: Bool
}

/// A time signature change after the initial meter, at `atTicks` clip ticks.
struct SMFMeterChange: Equatable, Hashable, Sendable {
    let atTicks: Int64
    let meter: MusicalMeter
}

/// Tempo and meter proposed by one Standard MIDI File, in clip ticks (15,360 per quarter).
///
/// Built only by `make`, which re-validates every invariant whoever built the arguments (the scan builds its own
/// result through it): `segments` are non-empty, start at tick 0, strictly increase, hold at most
/// `maximumSegments`, never repeat a tempo in two adjacent segments and stay within `MIDIClip.maximumLengthTicks`;
/// `laterMeterChanges` hold at most `maximumMeterChanges`, are in non-decreasing tick order and within the same bound.
/// The initial meter, if any, is the first time signature at tick 0; a time signature that is not first at tick 0 is
/// in `laterMeterChanges`, and none is coalesced or dropped.
struct SMFTempoProposal: Equatable, Hashable, Sendable {
    /// The most segments a proposal holds: the `MusicalMap` bound.
    static let maximumSegments = 4_096
    /// The most meter changes after the initial meter.
    static let maximumMeterChanges = 256
    /// The tempo proposed when a file has none at tick 0: 120 BPM.
    static let defaultMicrosPerQuarter: Int64 = 500_000

    let segments: [TempoSegment]
    let initialMeter: MusicalMeter?
    let laterMeterChanges: [SMFMeterChange]
    let counts: SMFTempoCounts

    var supersededTempos: Int { counts.supersededTempos }
    var coalescedTempos: Int { counts.coalescedTempos }
    var defaultedInitialTempo: Bool { counts.defaultedInitialTempo }

    private init(segments: [TempoSegment], initialMeter: MusicalMeter?, laterMeterChanges: [SMFMeterChange],
                 counts: SMFTempoCounts) {
        self.segments = segments
        self.initialMeter = initialMeter
        self.laterMeterChanges = laterMeterChanges
        self.counts = counts
    }

    /// The proposal for these values, or the first invariant they break (see the type's contract): too many
    /// segments, too many meter changes, the segment rules in order (none, first not at 0, per adjacent pair
    /// ticks then tempo, last beyond the clip limit), the meter change rules (range, then order), then the counts.
    static func make(segments: [TempoSegment], initialMeter: MusicalMeter?, laterMeterChanges: [SMFMeterChange],
                     counts: SMFTempoCounts) throws(SMFTempoRefusal) -> SMFTempoProposal {
        guard segments.count <= maximumSegments else { throw .tooManySegments(limit: maximumSegments) }
        guard laterMeterChanges.count <= maximumMeterChanges else {
            throw .tooManyMeterChanges(limit: maximumMeterChanges)
        }
        try validate(segments: segments)
        try validate(meterChanges: laterMeterChanges)
        guard counts.supersededTempos >= 0, counts.coalescedTempos >= 0 else {
            throw .invalidProposal(.negativeCount)
        }
        guard !counts.defaultedInitialTempo || segments[0].microsPerQuarter == defaultMicrosPerQuarter else {
            throw .invalidProposal(.defaultedTempoMismatch)
        }
        return SMFTempoProposal(segments: segments, initialMeter: initialMeter,
                                laterMeterChanges: laterMeterChanges, counts: counts)
    }

    private static func validate(segments: [TempoSegment]) throws(SMFTempoRefusal) {
        guard let first = segments.first, let last = segments.last else { throw .invalidProposal(.noSegments) }
        guard first.atTicks == 0 else { throw .invalidProposal(.firstSegmentNotAtZero) }
        for (earlier, later) in zip(segments, segments.dropFirst()) {
            guard earlier.atTicks < later.atTicks else { throw .invalidProposal(.segmentsNotStrictlyIncreasing) }
            guard earlier.microsPerQuarter != later.microsPerQuarter else {
                throw .invalidProposal(.adjacentSegmentsHaveEqualTempo)
            }
        }
        guard last.atTicks <= MIDIClip.maximumLengthTicks else { throw .invalidProposal(.segmentBeyondClipLimit) }
    }

    private static func validate(meterChanges: [SMFMeterChange]) throws(SMFTempoRefusal) {
        guard meterChanges.allSatisfy({ (0...MIDIClip.maximumLengthTicks).contains($0.atTicks) }) else {
            throw .invalidProposal(.meterChangeOutOfRange)
        }
        guard zip(meterChanges, meterChanges.dropFirst()).allSatisfy({ $0.atTicks <= $1.atTicks }) else {
            throw .invalidProposal(.meterChangesNotOrdered)
        }
    }

    /// The `MusicalMap` of `segments` for `clock` at `revision`. Only calls `MusicalMap.init`; a proposal's segments
    /// satisfy its rules, so a `.map` refusal is not expected. It applies nothing: adopting the map is the caller's.
    func makeMap(clock: ClockID, revision: Generation) throws(SMFTempoRefusal) -> MusicalMap {
        do {
            return try MusicalMap(clock: clock, revision: revision, segments: segments)
        } catch {
            throw .map(error)
        }
    }
}
