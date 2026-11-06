//
//  RecordingSegment.swift
//  FluxKlang
//
//  One segment of a take: the frames captured in one sample clock generation, at
//  that generation's own nominal rate (media-contract.md §8.3). Also the exact
//  frame-to-nanosecond arithmetic behind `startOffsetNs`.
//

/// Frames `[startFrame, endFrame)` that capture dropped and padded with silence.
struct OverflowInterval: Hashable, Sendable {
    let startFrame: Int64
    let frames: Int64
    let endFrame: Int64

    init(startFrame: Int64, frames: Int64) throws(TakeLedgerError) {
        guard frames > 0 else { throw .missingOverflowFrames }
        let (endFrame, overflow) = startFrame.addingReportingOverflow(frames)
        guard !overflow else { throw .arithmeticOverflow }
        self.startFrame = startFrame
        self.frames = frames
        self.endFrame = endFrame
    }
}

/// Why a segment carries no `startOffsetNs`. Finishing never fails for these; the take
/// reports them instead (`RecordingTake.unplacedSegments`).
enum UnplacedReason: Hashable, Sendable {
    /// No anchor of the segment's generation was observed.
    case anchorNotObserved
    /// An anchor of the segment's generation arrived after a newer one and was refused stale.
    case anchorRefusedStale
    /// The take's first segment has no anchor, so no offset can be measured from it.
    case takeAnchorMissing
    /// The anchors place the segment before the take's anchor.
    case beforeTakeStart
}

enum SegmentPlacement: Hashable, Sendable {
    /// Nanoseconds from the take's anchor (its first segment's start), never absolute host ticks (M13).
    case placed(startOffsetNs: Int64)
    case unplaced(UnplacedReason)
}

struct RecordingSegment: Hashable, Sendable {
    let clock: ClockID
    let generation: Generation
    /// The generation's nominal rate; nil only when no anchor of the generation was observed.
    let nominalRate: Int?
    let startFrame: Int64
    let placement: SegmentPlacement
    let fileFrameStart: Int64
    /// Frames in the file for this segment, padded overflow included.
    let frames: Int64
    /// Ascending, disjoint and wholly inside the segment.
    let overflows: [OverflowInterval]
    /// The sum of `overflows`' frames.
    let paddedFrames: Int64
    /// Nil for the segment the take opened with.
    let openedBy: SegmentBoundaryReason?

    init(clock: ClockID, generation: Generation, nominalRate: Int?, startFrame: Int64, placement: SegmentPlacement,
         fileFrameStart: Int64, frames: Int64, overflows: [OverflowInterval],
         openedBy: SegmentBoundaryReason?) throws(TakeLedgerError) {
        guard frames > 0 else { throw .inconsistentRecord(.frames) }
        let (endFrame, overflow) = startFrame.addingReportingOverflow(frames)
        guard !overflow, fileFrameStart >= 0 else { throw .inconsistentRecord(.frames) }
        guard nominalRate.map(MediaNominalRate.isValid) ?? true else { throw .inconsistentRecord(.nominalRate) }
        if case .placed(let offset) = placement, offset < 0 { throw .inconsistentRecord(.placement) }
        var cursor = startFrame
        var padded: Int64 = 0
        for interval in overflows {
            guard interval.startFrame >= cursor, interval.endFrame <= endFrame else {
                throw .inconsistentRecord(.overflows)
            }
            cursor = interval.endFrame
            // Bounded: the intervals are disjoint inside the segment, so the sum is at most `frames`.
            padded += interval.frames
        }
        self.clock = clock
        self.generation = generation
        self.nominalRate = nominalRate
        self.startFrame = startFrame
        self.placement = placement
        self.fileFrameStart = fileFrameStart
        self.frames = frames
        self.overflows = overflows
        paddedFrames = padded
        self.openedBy = openedBy
    }

    var startOffsetNs: Int64? {
        if case .placed(let offset) = placement { offset } else { nil }
    }

    /// Exclusive; the initializer checked that it fits.
    var endFrame: Int64 { startFrame + frames }
}

/// A generation's first observed anchor and its nominal rate.
struct GenerationAnchor: Hashable, Sendable {
    let frame: Int64
    let hostTicks: UInt64
    let nominalRate: Int
}

/// A frame on the generation that `anchor` describes.
struct AnchoredFrame: Hashable, Sendable {
    let frame: Int64
    let anchor: GenerationAnchor
}

enum TakeOffsetMath {
    /// Nanoseconds from `base` to `position`, each converted to host time through its own
    /// generation's anchor and rate. Exact rational arithmetic, rounded half-up
    /// (`floor(x + ½)`) once, at the end. Throws on Int128 or Int64 overflow.
    static func offsetNs(of position: AnchoredFrame, from base: AnchoredFrame,
                         timebase: HostTimebase) throws(TakeLedgerError) -> Int64 {
        let rate = Int128(position.anchor.nominalRate)
        let baseRate = Int128(base.anchor.nominalRate)
        let nanos: Int128 = 1_000_000_000
        let hostDelta = Int128(position.anchor.hostTicks) - Int128(base.anchor.hostTicks)
        let hostTerm = try product([hostDelta, Int128(timebase.numer), rate, baseRate])
        let frameTerm = try product([Int128(position.frame) - Int128(position.anchor.frame), nanos,
                                     Int128(timebase.denom), baseRate])
        let baseTerm = try product([Int128(base.frame) - Int128(base.anchor.frame), nanos,
                                    Int128(timebase.denom), rate])
        let (numerator, borrow) = try sum(hostTerm, frameTerm).subtractingReportingOverflow(baseTerm)
        guard !borrow else { throw .arithmeticOverflow }
        let denominator = try product([Int128(timebase.denom), rate, baseRate])
        let rounded = ExactMath.floorDiv(try sum(try product([2, numerator]), denominator),
                                         try product([2, denominator]))
        guard let result = Int64(exactly: rounded) else { throw .arithmeticOverflow }
        return result
    }

    private static func product(_ factors: [Int128]) throws(TakeLedgerError) -> Int128 {
        var result: Int128 = 1
        for factor in factors {
            let (value, overflow) = result.multipliedReportingOverflow(by: factor)
            guard !overflow else { throw .arithmeticOverflow }
            result = value
        }
        return result
    }

    private static func sum(_ lhs: Int128, _ rhs: Int128) throws(TakeLedgerError) -> Int128 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw .arithmeticOverflow }
        return value
    }
}
