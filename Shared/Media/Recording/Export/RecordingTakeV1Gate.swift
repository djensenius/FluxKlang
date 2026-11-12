//
//  RecordingTakeV1Gate.swift
//  FluxKlang
//
//  A fail-closed precondition for the contract v1 take exporter (#109): the shapes the #352
//  ruling still says must be refused with a typed error, never remapped: a pair of consecutive
//  segments that is neither a restart split nor a forward `sampleJump` split, and an unplaced
//  segment. A ledger stop is not one: it exports as the contract's `discontinuity` stop reason
//  (#336). Its clearance is the input of `RecordingTakeV1Record.make` (#110 TKX1), which builds
//  the `takeRecord`.
//

/// Proof that `RecordingTakeV1Gate.clear` accepted `take`. Only the gate builds it.
struct RecordingTakeV1Clearance: Sendable {
    let take: RecordingTake

    fileprivate init(take: RecordingTake) {
        self.take = take
    }
}

enum RecordingTakeV1Gate {
    /// Returns the first refusal in a fixed order: the lowest consecutive segment pair that is neither a
    /// restart split (same clock, `gen` then `gen + 1`) nor a forward `sampleJump` split (same clock and
    /// generation, the later segment starting after the earlier one's last frame), then the lowest unplaced
    /// segment. A same-clock, same-generation pair that is not forward (backward or no gap) is refused as
    /// `.sampleJumpNotForward`; every other bad pair, such as a clock change or a generation skip, as
    /// `.notRestartSplit`. The stop never refuses: every `TakeStopReason` has a contract v1 value.
    /// It adds no limit on the segment count. Ledger takes do not change clock, so the clock half
    /// of the pair rule is reachable only by a hand-built take.
    /// A cleared take is a necessary, not a sufficient, condition for the contract checker to
    /// accept a document: its other take rules (frames, offsets, overflow, stop placement) are
    /// not re-checked here.
    static func clear(_ take: RecordingTake) throws(RecordingTakeV1Refusal) -> RecordingTakeV1Clearance {
        let segments = take.segments
        for index in segments.indices.dropLast() {
            switch pair(segments[index], segments[index + 1]) {
            case .restartSplit, .forwardJump: continue
            case .notForward: throw .sampleJumpNotForward(after: index)
            case .refused: throw .notRestartSplit(after: index)
            }
        }
        for index in segments.indices where segments[index].startOffsetNs == nil {
            throw .unplacedSegment(index)
        }
        return RecordingTakeV1Clearance(take: take)
    }

    private enum Pair {
        case restartSplit, forwardJump, notForward, refused
    }

    /// Classified by geometry, not by how the later segment was opened.
    private static func pair(_ earlier: RecordingSegment, _ later: RecordingSegment) -> Pair {
        guard earlier.clock == later.clock else { return .refused }
        if earlier.generation == later.generation {
            // `RecordingSegment` guarantees that the end does not overflow.
            return later.startFrame > earlier.startFrame + earlier.frames ? .forwardJump : .notForward
        }
        guard let next = try? earlier.generation.next(), next == later.generation else { return .refused }
        return .restartSplit
    }
}
