//
//  RecordingTakeV1Gate.swift
//  FluxKlang
//
//  A fail-closed precondition for the contract v1 take exporter (#109): the two shapes the
//  #352 ruling still says must be refused with a typed error, never remapped: a pair of
//  consecutive segments that is not a restart split, and an unplaced segment. A ledger stop
//  is not one: it exports as the contract's `discontinuity` stop reason (#336). Its clearance
//  is the input of `RecordingTakeV1Record.make` (#110 TKX1), which builds the `takeRecord`.
//

/// Proof that `RecordingTakeV1Gate.clear` accepted `take`. Only the gate builds it.
struct RecordingTakeV1Clearance: Sendable {
    let take: RecordingTake

    fileprivate init(take: RecordingTake) {
        self.take = take
    }
}

enum RecordingTakeV1Gate {
    /// Returns the first refusal in a fixed order: the lowest consecutive segment pair that is not
    /// `(clock, gen)` then `(clock, gen + 1)`, then the lowest unplaced segment. The stop never
    /// refuses: every `TakeStopReason` has a contract v1 value.
    /// It adds no limit on the segment count. Ledger takes do not change clock, so the clock half
    /// of the pair rule is reachable only by a hand-built take.
    /// A cleared take is a necessary, not a sufficient, condition for the contract checker to
    /// accept a document: its other take rules (frames, offsets, overflow, stop placement) are
    /// not re-checked here.
    static func clear(_ take: RecordingTake) throws(RecordingTakeV1Refusal) -> RecordingTakeV1Clearance {
        let segments = take.segments
        for index in segments.indices.dropLast() where !isRestartSplit(segments[index], segments[index + 1]) {
            throw .notRestartSplit(after: index)
        }
        for index in segments.indices where segments[index].startOffsetNs == nil {
            throw .unplacedSegment(index)
        }
        return RecordingTakeV1Clearance(take: take)
    }

    private static func isRestartSplit(_ earlier: RecordingSegment, _ later: RecordingSegment) -> Bool {
        guard earlier.clock == later.clock, let next = try? earlier.generation.next() else { return false }
        return next == later.generation
    }
}
