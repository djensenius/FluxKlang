//
//  TakeLedgerState.swift
//  FluxKlang
//
//  The append-only bookkeeping of one take while it records: its segments,
//  their overflow intervals, the boundaries that split it and the stop it owns
//  (media-contract.md §8.3). The audit types it hands out can only be built here.
//

/// Why a take's segment ended and the next one began.
enum SegmentBoundaryReason: Hashable, Sendable {
    /// A new sample clock generation; the closed segment ended at `previousFrame`.
    case clockRestart(previousFrame: Int64)
    /// A frame jump within the same generation; the closed segment ended at the last captured frame.
    case sampleJump
}

/// One audit entry of a take's history: every restart or jump that split it, including
/// those whose closed segment held no frames and was therefore dropped, never stored.
struct TakeBoundary: Hashable, Sendable {
    let reason: SegmentBoundaryReason
    /// The generation and frame where the next segment starts.
    let generation: Generation
    let frame: Int64
    /// Where the closed segment ended: its last captured frame (exclusive).
    let closedAt: Int64
    let droppedEmptySegment: Bool

    fileprivate init(reason: SegmentBoundaryReason, generation: Generation, frame: Int64, closedAt: Int64,
                     droppedEmptySegment: Bool) {
        self.reason = reason
        self.generation = generation
        self.frame = frame
        self.closedAt = closedAt
        self.droppedEmptySegment = droppedEmptySegment
    }
}

/// One segment as the ledger records it, before placement.
struct CapturedSegment: Hashable, Sendable {
    let generation: UInt64
    let startFrame: Int64
    /// The capture frontier while this segment is current; its end once closed.
    fileprivate(set) var endFrame: Int64
    fileprivate(set) var overflows: [OverflowInterval] = []
    /// Nil for the segment the take opened with.
    let openedBy: SegmentBoundaryReason?

    fileprivate init(generation: UInt64, startFrame: Int64, openedBy: SegmentBoundaryReason?) {
        self.generation = generation
        self.startFrame = startFrame
        endFrame = startFrame
        self.openedBy = openedBy
    }

    var isEmpty: Bool { endFrame == startFrame }

    /// Bounded: overflows are disjoint inside the segment, so the sum never exceeds its frames.
    var paddedFrames: Int64 { overflows.reduce(0) { $0 + $1.frames } }
}

/// Where capture ended for a non-`user` stop. `generation`/`frame` sit at the end of the
/// take's last stored segment; `reported*` is where the record arrived (they differ when a
/// stop lands right after a restart or jump, on a segment that holds no frames).
struct TakeStopMark: Hashable, Sendable {
    let generation: Generation
    let frame: Int64
    let reason: TakeStopReason
    let reportedGeneration: Generation
    let reportedFrame: Int64

    fileprivate init(_ stop: TakeLedgerState.Stop) throws(TakeLedgerError) {
        generation = try TakeLedger.contractGeneration(stop.generation)
        frame = stop.frame
        reason = stop.reason
        reportedGeneration = try TakeLedger.contractGeneration(stop.reportedGeneration)
        reportedFrame = stop.reportedFrame
    }
}

/// An unfinished take given up with a typed reason. Its frames and evidence stay readable.
struct DiscardedTake: Hashable, Sendable {
    let take: TakeID
    let stream: StreamID
    let inputLatency: InputLatency
    let reason: TakeDiscardReason
    /// The segments that held frames; an empty current segment is not kept.
    let segments: [CapturedSegment]
    let boundaries: [TakeBoundary]
    /// The stop the take owned, if any, including one that arrived before any frame.
    let stop: TakeLedgerState.Stop?

    fileprivate init(_ state: TakeLedgerState, reason: TakeDiscardReason) {
        take = state.opening.take
        stream = state.opening.stream
        inputLatency = state.opening.inputLatency
        self.reason = reason
        segments = state.storedSegments
        boundaries = state.boundaries
        stop = state.stop
    }
}

enum TakeOutcome: Hashable, Sendable {
    case finished(RecordingTake)
    case discarded(DiscardedTake)
}

struct TakeLedgerState: Sendable {
    struct Stop: Hashable, Sendable {
        let generation: UInt64
        let frame: Int64
        let reason: TakeStopReason
        let reportedGeneration: UInt64
        let reportedFrame: Int64

        fileprivate init(at end: CapturedSegment, reason: TakeStopReason, reported: RuntimeSampleStamp) {
            generation = end.generation
            frame = end.endFrame
            self.reason = reason
            reportedGeneration = reported.generation
            reportedFrame = reported.frame
        }
    }

    let opening: TakeOpening
    private(set) var segments: [CapturedSegment]
    private(set) var stop: Stop?
    private(set) var boundaries: [TakeBoundary] = []
    private(set) var outcome: TakeOutcome?

    init(opening: TakeOpening) {
        self.opening = opening
        segments = [CapturedSegment(generation: opening.startGeneration, startFrame: opening.startFrame,
                                    openedBy: nil)]
    }

    var isOpen: Bool { outcome == nil }

    /// Open and not stopped: restarts and jumps split only capturing takes.
    var isCapturing: Bool { isOpen && stop == nil }

    /// An open take holds its stream until it finishes or is discarded, unless the ledger
    /// itself ended it at a discontinuity.
    var holdsStream: Bool {
        guard isOpen else { return false }
        if case .discontinuity? = stop?.reason { return false }
        return true
    }

    var current: CapturedSegment { segments[segments.count - 1] }

    /// Segments that hold frames; only the last can be empty, and it is never stored.
    var storedSegments: [CapturedSegment] { segments.filter { !$0.isEmpty } }

    /// Where a stop belongs: the current segment's end, or, when the current segment is
    /// still empty, the end of the last segment that holds frames.
    private var stopSegment: CapturedSegment {
        current.isEmpty ? storedSegments.last ?? current : current
    }

    // MARK: Progress

    mutating func advance(to stamp: RuntimeSampleStamp) throws(TakeLedgerError) {
        guard stamp.clock == opening.startClockSlot else { throw .clockMismatch }
        guard stop == nil else { throw .captureAlreadyStopped }
        guard stamp.generation == current.generation else {
            throw .generationMismatch(expected: current.generation, actual: stamp.generation)
        }
        guard stamp.frame >= current.endFrame else {
            throw .progressRegressed(frontier: current.endFrame, frame: stamp.frame)
        }
        segments[segments.count - 1].endFrame = stamp.frame
    }

    // MARK: Records

    /// Touching intervals (one starting where the previous ends) are accepted as separate
    /// records, never merged; overlapping ones are refused.
    mutating func appendOverflow(_ sample: RuntimeSampleStamp, frames: UInt32?) throws(TakeLedgerError) {
        guard let frames else { throw .missingOverflowFrames }
        let interval = try OverflowInterval(startFrame: sample.frame, frames: Int64(frames))
        guard segments.contains(where: { $0.generation == sample.generation }) else {
            throw .generationMismatch(expected: current.generation, actual: sample.generation)
        }
        // After a backward jump two segments of one generation may share frames; the latest wins.
        guard let index = segments.lastIndex(where: {
            $0.generation == sample.generation && interval.startFrame >= $0.startFrame
                && interval.endFrame <= $0.endFrame
        }) else {
            throw .overflowOutsideSegment(startFrame: interval.startFrame, endFrame: interval.endFrame)
        }
        let segment = segments[index]
        if let previous = segment.overflows.last, interval.startFrame < previous.endFrame {
            throw .overflowOverlapsPrevious(startFrame: interval.startFrame)
        }
        guard segment.overflows.count < TakeLedger.maximumOverflowsPerSegment else { throw .tooManyOverflows }
        segments[index].overflows.append(interval)
    }

    /// A `captureStopped` at the frontier. Right after a restart or jump the current segment
    /// is empty and will be dropped, so the stop moves to the last stored segment's end.
    mutating func appendStop(_ sample: RuntimeSampleStamp,
                             reason: RuntimeCaptureStopReason) throws(TakeLedgerError) {
        guard stop == nil else { throw .duplicateCaptureStopped }
        guard sample.generation == current.generation else {
            throw .generationMismatch(expected: current.generation, actual: sample.generation)
        }
        guard sample.frame == current.endFrame else {
            throw .stopNotAtEnd(frame: sample.frame, frontier: current.endFrame)
        }
        stop = Stop(at: stopSegment, reason: TakeStopReason(reason), reported: sample)
    }

    /// Whether this take owns the record (§8.3): same stream and clock, a segment of the
    /// same generation, and overlapping frames. While capturing, the current segment extends
    /// past the frontier, so a record beyond capture progress is owned, then refused, never
    /// ignored, and an empty current segment also owns a `captureStopped` at its start. An
    /// overflow without a length (nil or 0 frames) is owned like a 1-frame one: ownership is
    /// decided first, then `appendOverflow` refuses the length (`.missingOverflowFrames`).
    func owns(stream: UInt32, sample: RuntimeSampleStamp, kind: RuntimeDiscontinuityKind, frames: UInt32?) -> Bool {
        guard stream == opening.streamSlot, sample.clock == opening.startClockSlot else { return false }
        // Ended by the ledger at a discontinuity: later records describe audio after the jump.
        if stop?.reason.isLedgerStop == true { return false }
        let last = segments.count - 1
        return segments.indices.contains { index in
            let segment = segments[index]
            guard segment.generation == sample.generation else { return false }
            let isCapturingCurrent = isCapturing && index == last
            let upper = isCapturingCurrent ? Int64.max : segment.endFrame
            if case .captureStopped = kind {
                let atEmptyStart = isCapturingCurrent && segment.isEmpty && sample.frame == segment.startFrame
                return (segment.startFrame < sample.frame || atEmptyStart) && sample.frame <= upper
            }
            let length = max(Int64(frames ?? 0), 1)
            let (end, overflow) = sample.frame.addingReportingOverflow(length)
            return sample.frame < upper && (overflow || end > segment.startFrame)
        }
    }

    // MARK: Restart and jump

    /// A jump in the take's first generation to a frame before its first segment's start.
    func jumpsBeforeStart(_ sample: RuntimeSampleStamp) -> Bool {
        segments[0].generation == sample.generation && sample.frame < segments[0].startFrame
    }

    /// §8.3: no stored segment of `generation`, the last included, ends after the `previousFrame` a
    /// restart gives it. One closed before a backward jump can; the restart is then refused, never
    /// trimmed: the segment's frames already sit in the file ahead of later segments, and its
    /// overflows stay recorded. Ending exactly at `previousFrame` is accepted (both are exclusive).
    /// Shared by capturing takes (`validateBoundary`) and every other take on the clock
    /// (`TakeLedger.restart`): stopped, ended by the ledger, finished or discarded.
    func validateGenerationEnd(_ generation: UInt64, at previousFrame: Int64) throws(TakeLedgerError) {
        guard let late = storedSegments.first(where: { $0.generation == generation && $0.endFrame > previousFrame })
        else { return }
        throw .segmentAfterRestart(opening.take, segmentEnd: late.endFrame, previousFrame: previousFrame)
    }

    func validateBoundary(_ reason: SegmentBoundaryReason, into generation: UInt64) throws(TakeLedgerError) {
        switch reason {
        case .clockRestart(let previousFrame):
            guard current.generation < generation, generation - current.generation == 1 else {
                throw .missedRestart(opening.take)
            }
            guard current.endFrame == previousFrame else {
                throw .segmentEndMismatch(frontier: current.endFrame, previousFrame: previousFrame)
            }
            try validateGenerationEnd(current.generation, at: previousFrame)
        case .sampleJump:
            guard current.generation == generation else { throw .missedRestart(opening.take) }
        }
        guard boundaries.count < TakeLedger.maximumBoundariesPerTake else { throw .tooManyBoundaries }
        guard current.isEmpty || segments.count < TakeLedger.maximumSegmentsPerTake else { throw .tooManySegments }
    }

    /// Closes the current segment at its frontier and opens the next at `startFrame`, with no
    /// padding or stitching across the boundary. An empty closed segment is dropped; the
    /// boundary is still recorded.
    mutating func applyBoundary(_ reason: SegmentBoundaryReason, into generation: Generation, rawGeneration: UInt64,
                                startFrame: Int64) {
        let closed = current
        if closed.isEmpty { segments.removeLast() }
        boundaries.append(TakeBoundary(reason: reason, generation: generation, frame: startFrame,
                                       closedAt: closed.endFrame, droppedEmptySegment: closed.isEmpty))
        segments.append(CapturedSegment(generation: rawGeneration, startFrame: startFrame, openedBy: reason))
    }

    /// Ends capture at the last good frame; the take keeps the audio it has and finishes
    /// with `.discontinuity(reason)`.
    mutating func end(at sample: RuntimeSampleStamp, _ reason: TakeDiscontinuityStop) {
        stop = Stop(at: stopSegment, reason: .discontinuity(reason), reported: sample)
    }

    // MARK: Finish and discard

    func validateStop(_ reason: TakeStopReason) throws(TakeLedgerError) {
        guard !storedSegments.isEmpty else { throw .emptySegment }
        switch (reason, stop) {
        case (.user, nil):
            return
        case (_, nil):
            throw .missingCaptureStopped(reason)
        case (_, let stop?):
            guard stop.reason == reason else { throw .stopReasonMismatch(expected: reason, recorded: stop.reason) }
        }
    }

    func stopMark() throws(TakeLedgerError) -> TakeStopMark? {
        try stop.map { stop throws(TakeLedgerError) in try TakeStopMark(stop) }
    }

    mutating func seal(_ take: RecordingTake) {
        outcome = .finished(take)
    }

    mutating func discard(_ reason: TakeDiscardReason) throws(TakeLedgerError) -> DiscardedTake {
        guard reason != .noCapturedFrames || storedSegments.isEmpty else { throw .discardReasonMismatch(reason) }
        let record = DiscardedTake(self, reason: reason)
        outcome = .discarded(record)
        return record
    }
}
