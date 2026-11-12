//
//  RecordingTake.swift
//  FluxKlang
//
//  A finished, sealed take (media-contract.md §8.3) and the request that opens one.
//  Capture speaks in runtime slots; the take document speaks in contract IDs.
//  `TakeOpening` binds the two once, at open time.
//

/// Opens a take on one capture stream at its first captured frame.
struct TakeOpening: Hashable, Sendable {
    let take: TakeID
    let stream: StreamID
    /// The runtime slot that `RuntimeDiscontinuity.stream` uses for `stream`.
    let streamSlot: UInt32
    let clock: ClockID
    /// The first captured frame; its `clock` is the runtime slot for `clock`.
    let startClockSlot: UInt32
    let startGeneration: UInt64
    let startFrame: Int64
    let inputLatency: InputLatency

    init(take: TakeID, stream: StreamID, streamSlot: UInt32, clock: ClockID,
         start: RuntimeSampleStamp, inputLatency: InputLatency) {
        self.take = take
        self.stream = stream
        self.streamSlot = streamSlot
        self.clock = clock
        startClockSlot = start.clock
        startGeneration = start.generation
        startFrame = start.frame
        self.inputLatency = inputLatency
    }
}

/// A finished take. It reaches contract v1 only through `RecordingTakeV1Gate` → `RecordingTakeV1Record.make`
/// (#109, #110). A ledger stop exports as the contract's `discontinuity` stop reason (#336). The gate refuses
/// with typed errors, never by remapping: any two consecutive stored segments that are not
/// `(clock, gen) → (clock, gen + 1)`, split at a restart, which covers same-generation `sampleJump`
/// splits and generation skips left by a dropped empty restart segment (#352); and any `.unplaced`
/// segment (v1 requires `startOffsetNs`).
struct RecordingTake: Hashable, Sendable {
    let take: TakeID
    let stream: StreamID
    let inputLatency: InputLatency
    /// In order, contiguous in the file; never empty.
    let segments: [RecordingSegment]
    /// Every restart and jump that split the take, in order, including dropped empty segments.
    let boundaries: [TakeBoundary]
    /// The sum of every segment's padded overflow frames.
    let droppedFrames: Int64
    let stopReason: TakeStopReason
    /// Where capture ended for a non-`user` stop; nil exactly when `stopReason` is `user`.
    let stopMark: TakeStopMark?

    init(take: TakeID, stream: StreamID, inputLatency: InputLatency, segments: [RecordingSegment],
         boundaries: [TakeBoundary], stopReason: TakeStopReason,
         stopMark: TakeStopMark?) throws(TakeLedgerError) {
        guard let last = segments.last else { throw .emptySegment }
        var fileFrame: Int64 = 0
        var dropped: Int64 = 0
        for segment in segments {
            guard segment.fileFrameStart == fileFrame else { throw .inconsistentRecord(.fileContinuity) }
            let (nextFile, fileOverflow) = fileFrame.addingReportingOverflow(segment.frames)
            let (nextDropped, droppedOverflow) = dropped.addingReportingOverflow(segment.paddedFrames)
            guard !fileOverflow, !droppedOverflow else { throw .arithmeticOverflow }
            fileFrame = nextFile
            dropped = nextDropped
        }
        if let first = segments.first?.startOffsetNs, first != 0 { throw .inconsistentRecord(.placement) }
        switch (stopReason, stopMark) {
        case (.user, nil):
            break
        case (.user, .some), (_, nil):
            throw .inconsistentRecord(.stopMark)
        case (_, let mark?):
            guard mark.reason == stopReason, mark.generation == last.generation, mark.frame == last.endFrame else {
                throw .inconsistentRecord(.stopMark)
            }
        }
        self.take = take
        self.stream = stream
        self.inputLatency = inputLatency
        self.segments = segments
        self.boundaries = boundaries
        droppedFrames = dropped
        self.stopReason = stopReason
        self.stopMark = stopMark
    }

    /// The device's `captureStopped` the take ended on, if any: nil for `user` and for a ledger stop, which
    /// capture never reports. The exported `captureStopped` (§8.3) comes from `stopMark`, which every non-`user`
    /// stop has.
    var captureStopped: TakeStopMark? {
        stopMark.flatMap { $0.reason.captureReason == nil ? nil : $0 }
    }

    /// Frames in the file, padded overflow included.
    var fileFrames: Int64 {
        segments.last.map { $0.fileFrameStart + $0.frames } ?? 0
    }

    /// Indices of segments without `startOffsetNs`, for the take's summary.
    var unplacedSegments: [Int] {
        segments.indices.filter { segments[$0].startOffsetNs == nil }
    }
}
