//
//  InterruptedTakeSalvage.swift
//  FluxKlang
//
//  Plans what to keep of a take that a crash cut short. Pure: it reads nothing, writes nothing and
//  has no notion of time.
//

/// Why the planner refused its input. Checked in this order. The contiguity check does not judge a segment whose
/// predecessor's file end does not fit in `Int64`; a contiguity violation elsewhere is reported before the overflow.
enum TakeSalvageRefusal: Error, Equatable, Sendable {
    /// More journaled segments than `InterruptedTakeSalvage.maximumSegments`; the payload is the count given.
    case tooManySegments(Int)
    case negativeDurableFrames
    /// The first segment (by position) whose predecessor's file end is representable and that does not start there,
    /// or, for the first segment, that does not start at file frame 0.
    case fileNotContiguous(index: Int)
    /// A segment's file end does not fit in `Int64`.
    case arithmeticOverflow
}

enum InterruptedTakeSalvage {
    static let maximumSegments = TakeLedger.maximumSegmentsPerTake

    /// The plan for `facts`. Refusals are checked in the order of `TakeSalvageRefusal`'s cases. A finalized
    /// container with at least one durable frame whose file is shorter than the journal is still `trimmed`;
    /// frames past the journal's end are reported as untracked and never kept.
    static func plan(_ facts: InterruptedTakeFacts) throws(TakeSalvageRefusal) -> TakeSalvagePlan {
        let segments = facts.segments
        guard segments.count <= maximumSegments else { throw .tooManySegments(segments.count) }
        guard facts.durableFileFrames >= 0 else { throw .negativeDurableFrames }
        try requireContiguousFile(segments)
        let journaledEnd = try journaledFileEnd(segments)
        let durable = facts.durableFileFrames
        if segments.isEmpty {
            return TakeSalvagePlan(verdict: .nothingDurable, keptSegments: [], lostJournaledFrames: 0,
                                   untrackedTailFrames: durable, needsHeaderRepair: false, interrupted: true)
        }
        if durable >= journaledEnd {
            let finalized = facts.containerFinalized
            return TakeSalvagePlan(verdict: finalized ? .intact : .headerRepairOnly, keptSegments: segments,
                                   lostJournaledFrames: 0, untrackedTailFrames: durable - journaledEnd,
                                   needsHeaderRepair: !finalized, interrupted: !finalized)
        }
        if durable == 0 {
            return TakeSalvagePlan(verdict: .nothingDurable, keptSegments: [], lostJournaledFrames: journaledEnd,
                                   untrackedTailFrames: 0, needsHeaderRepair: false, interrupted: true)
        }
        return TakeSalvagePlan(verdict: .trimmed, keptSegments: try durablePart(of: segments, frames: durable),
                               lostJournaledFrames: journaledEnd - durable, untrackedTailFrames: 0,
                               needsHeaderRepair: true, interrupted: true)
    }

    /// Segment 0 starts at file frame 0 and each next one where the previous ended. When a previous end does not
    /// fit in `Int64` no start can match it, so the check is left to `journaledFileEnd`, which refuses.
    private static func requireContiguousFile(_ segments: [RecordingSegment]) throws(TakeSalvageRefusal) {
        var expectedStart: Int64? = 0
        for (index, segment) in segments.enumerated() {
            if let expected = expectedStart, segment.fileFrameStart != expected {
                throw .fileNotContiguous(index: index)
            }
            let (end, overflow) = segment.fileFrameStart.addingReportingOverflow(segment.frames)
            expectedStart = overflow ? nil : end
        }
    }

    /// The file end the journal promises. With contiguity established it equals the sum of the frames.
    private static func journaledFileEnd(_ segments: [RecordingSegment]) throws(TakeSalvageRefusal) -> Int64 {
        var journaledEnd: Int64 = 0
        for segment in segments {
            let (end, overflow) = segment.fileFrameStart.addingReportingOverflow(segment.frames)
            guard !overflow else { throw .arithmeticOverflow }
            journaledEnd = end
        }
        return journaledEnd
    }

    /// The segments wholly inside the first `frames` file frames, then the one the cut passes through, clipped.
    /// Every file end was checked by `journaledFileEnd`.
    private static func durablePart(of segments: [RecordingSegment],
                                    frames: Int64) throws(TakeSalvageRefusal) -> [RecordingSegment] {
        var kept: [RecordingSegment] = []
        for segment in segments where segment.fileFrameStart < frames {
            if segment.fileFrameStart + segment.frames <= frames {
                kept.append(segment)
            } else {
                kept.append(try clipped(segment, toFrames: frames - segment.fileFrameStart))
            }
        }
        return kept
    }

    /// `segment` cut after `newFrames` frames (`0 < newFrames < segment.frames`). Everything but `frames`, the
    /// overflows and the padding the initializer sums from them is carried over unchanged, `placement` included.
    /// The rebuild cannot fail for a validated segment: the new length is positive and shorter, and every retained
    /// overflow lies inside it. The one `catch` exists because typed throws requires it and is not exercised.
    private static func clipped(_ segment: RecordingSegment,
                                toFrames newFrames: Int64) throws(TakeSalvageRefusal) -> RecordingSegment {
        let cut = segment.startFrame + newFrames
        do {
            var overflows: [OverflowInterval] = []
            for interval in segment.overflows where interval.startFrame < cut {
                if interval.endFrame <= cut {
                    overflows.append(interval)
                } else {
                    overflows.append(try OverflowInterval(startFrame: interval.startFrame,
                                                          frames: cut - interval.startFrame))
                }
            }
            return try RecordingSegment(clock: segment.clock, generation: segment.generation,
                                        nominalRate: segment.nominalRate, startFrame: segment.startFrame,
                                        placement: segment.placement, fileFrameStart: segment.fileFrameStart,
                                        frames: newFrames, overflows: overflows, openedBy: segment.openedBy)
        } catch {
            throw .arithmeticOverflow
        }
    }
}
