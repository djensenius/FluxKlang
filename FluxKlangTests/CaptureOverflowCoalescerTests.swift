import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// Capture overflow coalescer (#109 CDB1, media-contract.md section 8.3). Pure values; the ledger and the pump appear
// only in the tests that prove the defect and the fix against the real types.

private struct Identity {
    let clock: UInt32
    let generation: UInt64
    let stream: UInt32

    static let standard = Identity(clock: 0, generation: 1, stream: 0)
}

private func makeCoalescer(limit: Int = CaptureOverflowLimits.maximumRecords,
                           identity: Identity = .standard) throws(CaptureOverflowRefusal) -> CaptureOverflowCoalescer {
    try CaptureOverflowCoalescer.make(clock: identity.clock, generation: identity.generation,
                                      stream: identity.stream, recordLimit: limit)
}

private func span(_ start: Int64, _ frames: Int) -> CaptureDrainOverflow {
    CaptureDrainOverflow(startFrame: start, frames: frames)
}

private extension CaptureOverflowStep {
    var isHeld: Bool {
        if case .held = self { return true }
        return false
    }

    var closedRecord: RuntimeDiscontinuity? {
        if case .record(let record) = self { return record }
        return nil
    }

    var saturatedInterval: CaptureDrainOverflow? {
        if case .saturated(let interval) = self { return interval }
        return nil
    }
}

private extension CaptureDrainEnqueue {
    var paddedInterval: CaptureDrainOverflow? {
        if case .padded(let interval, _) = self { return interval }
        return nil
    }
}

private extension CaptureDrainPadResult {
    var paddedInterval: CaptureDrainOverflow? {
        if case .padded(let interval) = self { return interval }
        return nil
    }
}

private func expectRecord(_ found: RuntimeDiscontinuity?, frame: Int64, frames: UInt32,
                          identity: Identity = .standard, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let record = try #require(found, sourceLocation: sourceLocation)
    var isOverflow = false
    if case .overflow = record.kind { isOverflow = true }
    #expect(isOverflow, sourceLocation: sourceLocation)
    #expect(record.sample.clock == identity.clock, sourceLocation: sourceLocation)
    #expect(record.sample.generation == identity.generation, sourceLocation: sourceLocation)
    #expect(record.sample.frame == frame, sourceLocation: sourceLocation)
    #expect(record.frames == frames, sourceLocation: sourceLocation)
    #expect(record.stream == identity.stream, sourceLocation: sourceLocation)
    #expect(record.host == nil, sourceLocation: sourceLocation)
}

private func expectBalanced(_ coalescer: CaptureOverflowCoalescer, sourceLocation: SourceLocation = #_sourceLocation) {
    let settled = coalescer.emittedFrames + coalescer.pendingFrames + coalescer.unrecordedFrames
    #expect(coalescer.offeredFrames == settled, sourceLocation: sourceLocation)
    #expect(coalescer.recordsUsed <= coalescer.recordLimit, sourceLocation: sourceLocation)
}

private func refusal(of interval: CaptureDrainOverflow, on coalescer: inout CaptureOverflowCoalescer,
                     sourceLocation: SourceLocation = #_sourceLocation) -> CaptureOverflowRefusal? {
    let before = coalescer
    do throws(CaptureOverflowRefusal) {
        _ = try coalescer.offer(interval)
        return nil
    } catch {
        #expect(coalescer == before, sourceLocation: sourceLocation)
        return error
    }
}

private func overflowLeases(_ count: Int) throws -> [MediaBlockLease] {
    let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: max(count, 2), headFrames: 64)
    let pool = try MediaBlockPool.make(plan: plan, channelCount: 1)
    var leases: [MediaBlockLease] = []
    for _ in 0..<count { leases.append(try pool.lease()) }
    return leases
}

/// Thin wrappers over the existing ledger fixture of `RecordingTakeTests` (generation 1, an open take at frame 0).
private enum LedgerFixture {
    static let take = TakeLedgerTestFixture.take1

    static func stamp(_ frame: Int64) -> RuntimeSampleStamp {
        TakeLedgerTestFixture.stamp(1, frame)
    }

    static func overflow(_ frame: Int64, frames: UInt32) -> RuntimeDiscontinuity {
        TakeLedgerTestFixture.overflow(1, frame, frames: frames)
    }

    static func ledger() throws -> TakeLedger {
        try TakeLedgerTestFixture.ledger()
    }
}

@Suite("Capture overflow coalescer", .productionAccessAudit)
struct CaptureOverflowCoalescerTests {
    @Test
    func captureOverflowCoalescerGoldenTouchingRunBecomesOneRecord() throws {
        let identity = Identity(clock: 7, generation: 9, stream: 5)
        var coalescer = try makeCoalescer(identity: identity)
        let first = try coalescer.offer(span(0, 512))
        let second = try coalescer.offer(span(512, 512))
        let third = try coalescer.offer(span(1_024, 256))
        #expect(first.isHeld)
        #expect(second.isHeld)
        #expect(third.isHeld)
        #expect(coalescer.hasPending)
        #expect(coalescer.pendingFrames == 1_280)
        #expect(coalescer.recordsUsed == 1)
        let record = try coalescer.flush()
        try expectRecord(record, frame: 0, frames: 1_280, identity: identity)
        #expect(coalescer.hasPending == false)
        #expect(coalescer.emittedFrames == 1_280)
        let again = try coalescer.flush()
        #expect(again == nil)
    }

    @Test
    func captureOverflowCoalescerGapIsNotBridged() throws {
        var coalescer = try makeCoalescer()
        let first = try coalescer.offer(span(0, 512))
        #expect(first.isHeld)
        let second = try coalescer.offer(span(1_024, 512))
        try expectRecord(second.closedRecord, frame: 0, frames: 512)
        #expect(coalescer.pendingFrames == 512)
        #expect(coalescer.recordsUsed == 2)
        let last = try coalescer.flush()
        try expectRecord(last, frame: 1_024, frames: 512)
        expectBalanced(coalescer)
    }

    @Test
    func captureOverflowCoalescerStalledDiskIsOneRecord() throws {
        var coalescer = try makeCoalescer()
        var heldSteps = 0
        for index in 0..<20_000 {
            let step = try coalescer.offer(span(Int64(index) * 512, 512))
            if step.isHeld { heldSteps += 1 }
        }
        #expect(heldSteps == 20_000)
        #expect(coalescer.recordsUsed == 1)
        let record = try coalescer.flush()
        try expectRecord(record, frame: 0, frames: 10_240_000)
        #expect(coalescer.emittedFrames == 10_240_000)
        expectBalanced(coalescer)
    }

    @Test
    func captureOverflowCoalescerSplitsARunAtTheThirtyTwoBitWidth() throws {
        let widest = CaptureOverflowLimits.maximumRecordFrames
        let widestFrames = UInt32.max
        var below = try makeCoalescer()
        _ = try below.offer(span(0, widest - 1))
        let reach = try below.offer(span(Int64(widest - 1), 1))
        #expect(reach.isHeld)
        #expect(below.pendingFrames == UInt64(widest))

        var seam = try makeCoalescer()
        _ = try seam.offer(span(0, widest))
        let split = try seam.offer(span(Int64(widest), 1))
        try expectRecord(split.closedRecord, frame: 0, frames: widestFrames)
        #expect(seam.pendingFrames == 1)
        #expect(seam.recordsUsed == 2)
        let tail = try seam.flush()
        try expectRecord(tail, frame: Int64(widest), frames: 1)
        #expect(seam.emittedFrames == UInt64(widest) + 1)
        expectBalanced(seam)

        var lone = try makeCoalescer()
        let accepted = try lone.offer(span(0, widest))
        #expect(accepted.isHeld)
        var wide = try makeCoalescer()
        let tooWide = refusal(of: span(0, widest + 1), on: &wide)
        #expect(tooWide == .framesOutOfRange(frames: widest + 1, maximum: widest))
    }

    @Test
    func captureOverflowCoalescerRefusesBadIntervalsAndKeepsItsState() throws {
        let widest = CaptureOverflowLimits.maximumRecordFrames
        var coalescer = try makeCoalescer()
        _ = try coalescer.offer(span(0, 20))
        let none = refusal(of: span(20, 0), on: &coalescer)
        #expect(none == .framesOutOfRange(frames: 0, maximum: widest))
        let below = refusal(of: span(20, -1), on: &coalescer)
        #expect(below == .framesOutOfRange(frames: -1, maximum: widest))
        let overlap = refusal(of: span(10, 5), on: &coalescer)
        #expect(overlap == .overlapsPrevious(startFrame: 10, frontier: 20))

        var fresh = try makeCoalescer()
        let negative = refusal(of: span(-1, 1), on: &fresh)
        #expect(negative == .negativeStartFrame(-1))
        let edge = Int64.max - 1
        let overflow = refusal(of: span(edge, 2), on: &fresh)
        #expect(overflow == .frameOverflow(startFrame: edge, frames: 2))

        let touch = try coalescer.offer(span(20, 5))
        #expect(touch.isHeld)
        #expect(coalescer.pendingFrames == 25)
        let behind = refusal(of: span(22, 1), on: &coalescer)
        #expect(behind == .overlapsPrevious(startFrame: 22, frontier: 25))
    }

    @Test
    func captureOverflowCoalescerRefusalOrderNamesTheFirstDefect() throws {
        let widest = CaptureOverflowLimits.maximumRecordFrames
        var overlapped = try makeCoalescer()
        _ = try overlapped.offer(span(0, 20))
        let framesFirst = refusal(of: span(10, 0), on: &overlapped)
        #expect(framesFirst == .framesOutOfRange(frames: 0, maximum: widest))
        let negativeFirst = refusal(of: span(-1, 5), on: &overlapped)
        #expect(negativeFirst == .negativeStartFrame(-1))

        var nearEnd = try makeCoalescer()
        let top = Int64.max
        _ = try nearEnd.offer(span(top - 5, 5))
        let overflowFirst = refusal(of: span(top - 1, 2), on: &nearEnd)
        #expect(overflowFirst == .frameOverflow(startFrame: top - 1, frames: 2))
        let overlapLast = refusal(of: span(top - 2, 1), on: &nearEnd)
        #expect(overlapLast == .overlapsPrevious(startFrame: top - 2, frontier: top))

        // One interval with all four defects: the frames refusal wins by the pinned order.
        var allFour = try makeCoalescer()
        _ = try allFour.offer(span(0, 20))
        let everything = refusal(of: span(Int64.min, -1), on: &allFour)
        #expect(everything == .framesOutOfRange(frames: -1, maximum: widest))
        var wideAtTop = try makeCoalescer()
        let wideFirst = refusal(of: span(Int64.max, widest + 1), on: &wideAtTop)
        #expect(wideFirst == .framesOutOfRange(frames: widest + 1, maximum: widest))
    }

    @Test
    func captureOverflowCoalescerMakeAcceptsLimitsOneToMaximum() throws {
        let maximum = CaptureOverflowLimits.maximumRecords
        let one = try makeCoalescer(limit: 1)
        #expect(one.recordLimit == 1)
        let top = try makeCoalescer(limit: maximum)
        #expect(top.recordLimit == maximum)
        let standard = Identity.standard
        let defaulted = try CaptureOverflowCoalescer.make(clock: standard.clock, generation: standard.generation,
                                                          stream: standard.stream)
        #expect(defaulted.recordLimit == maximum)
        var caught: [CaptureOverflowRefusal] = []
        for limit in [0, maximum + 1] {
            do throws(CaptureOverflowRefusal) {
                _ = try makeCoalescer(limit: limit)
            } catch {
                caught.append(error)
            }
        }
        #expect(caught == [.recordLimitOutOfRange(limit: 0, maximum: maximum),
                           .recordLimitOutOfRange(limit: maximum + 1, maximum: maximum)])
    }

    @Test
    func captureOverflowCoalescerReportsSaturationAndCountsTheFrames() throws {
        var coalescer = try makeCoalescer(limit: 3)
        let first = try coalescer.offer(span(0, 1))
        let second = try coalescer.offer(span(2, 1))
        let third = try coalescer.offer(span(4, 1))
        #expect(first.isHeld)
        try expectRecord(second.closedRecord, frame: 0, frames: 1)
        try expectRecord(third.closedRecord, frame: 2, frames: 1)
        #expect(coalescer.isSaturated == false)
        let fourth = try coalescer.offer(span(6, 1))
        let dropped = try #require(fourth.saturatedInterval)
        #expect(dropped == span(6, 1))
        #expect(coalescer.isSaturated)
        #expect(coalescer.unrecordedFrames == 1)
        #expect(coalescer.recordsUsed == 3)
        expectBalanced(coalescer)
        let repeated = refusal(of: span(6, 1), on: &coalescer)
        #expect(repeated == .overlapsPrevious(startFrame: 6, frontier: 7))
        let held = try coalescer.flush()
        try expectRecord(held, frame: 4, frames: 1)
        expectBalanced(coalescer)
    }

    @Test
    func captureOverflowCoalescerSaturatedCallsRefuseTouchingAndGappedAfterFlush() throws {
        var coalescer = try makeCoalescer(limit: 3)
        for start in [Int64(0), 2, 4, 6] { _ = try coalescer.offer(span(start, 1)) }
        // Touches the end of the skipped (6, 1), not the end of the held (4, 1).
        let skippedTouch = try coalescer.offer(span(7, 1))
        #expect(skippedTouch.saturatedInterval == span(7, 1))
        _ = try coalescer.flush()
        let touching = try coalescer.offer(span(8, 1))
        let gapped = try coalescer.offer(span(10, 1))
        #expect(touching.saturatedInterval == span(8, 1))
        #expect(gapped.saturatedInterval == span(10, 1))
        #expect(coalescer.unrecordedFrames == 4)
        #expect(coalescer.hasPending == false)
        expectBalanced(coalescer)

        var absorbing = try makeCoalescer(limit: 3)
        for start in [Int64(0), 2, 4] { _ = try absorbing.offer(span(start, 1)) }
        let joined = try absorbing.offer(span(5, 1))
        #expect(joined.isHeld)
        #expect(absorbing.pendingFrames == 2)
        #expect(absorbing.isSaturated == false)
        expectBalanced(absorbing)
    }

    @Test
    func captureOverflowCoalescerSaturatesAWidthSplitAtTheRecordLimit() throws {
        let widest = CaptureOverflowLimits.maximumRecordFrames
        var coalescer = try makeCoalescer(limit: 1)
        _ = try coalescer.offer(span(0, widest))
        let split = try coalescer.offer(span(Int64(widest), 1))
        #expect(split.saturatedInterval == span(Int64(widest), 1))
        #expect(coalescer.isSaturated)
        #expect(coalescer.pendingFrames == UInt64(UInt32.max))
        #expect(coalescer.unrecordedFrames == 1)
        #expect(coalescer.recordsUsed == 1)
        let record = try coalescer.flush()
        try expectRecord(record, frame: 0, frames: UInt32.max)
        expectBalanced(coalescer)
    }

    @Test
    func captureOverflowCoalescerLedgerRefusesTouchingRecordsAtTheCap() throws {
        var ledger = try LedgerFixture.ledger()
        let limit = Int64(CaptureOverflowLimits.maximumRecords)
        try ledger.advance(LedgerFixture.take, to: LedgerFixture.stamp(limit + 1))
        for index in 0..<limit { _ = try ledger.ingest(LedgerFixture.overflow(index, frames: 1)) }
        var caught: TakeLedgerError?
        do throws(TakeLedgerError) {
            _ = try ledger.ingest(LedgerFixture.overflow(limit, frames: 1))
        } catch {
            caught = error
        }
        #expect(caught == .tooManyOverflows)
    }

    @Test
    func captureOverflowCoalescerRecorderSidePadsBecomeOneLedgerRecord() throws {
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1)
        var coalescer = try makeCoalescer()
        for _ in 0..<5_000 {
            let result = try pump.pad(frames: 512)
            let interval = try #require(result.paddedInterval)
            let step = try coalescer.offer(interval)
            #expect(step.isHeld)
        }
        var ledger = try LedgerFixture.ledger()
        #expect(pump.streamEnd == 2_560_000)
        try ledger.advance(LedgerFixture.take, to: LedgerFixture.stamp(2_560_000))
        let record = try #require(try coalescer.flush())
        #expect(try ledger.ingest(record) == [.recorded(LedgerFixture.take)])
        let take = try ledger.finish(LedgerFixture.take, reason: .user)
        #expect(take.droppedFrames == 2_560_000)
        #expect(take.droppedFrames == pump.paddedFrames)
        let segment = try #require(take.segments.first)
        #expect(segment.overflows.count == 1)
    }

    @Test
    func captureOverflowCoalescerFullRingPadsBecomeOneLedgerRecord() throws {
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1)
        let leases = try overflowLeases(2)
        let queued = try #require(leases.first)
        let spare = try #require(leases.last)
        let first = try pump.enqueue(lease: queued, frames: 512)
        #expect(first == .queued(pending: 1))
        var coalescer = try makeCoalescer()
        let intervals = 4_100
        let cap = CaptureOverflowLimits.maximumRecords
        #expect(intervals > cap)
        for _ in 0..<intervals {
            let result = try pump.enqueue(lease: spare, frames: 512)
            let interval = try #require(result.paddedInterval)
            let step = try coalescer.offer(interval)
            #expect(step.isHeld)
        }
        var ledger = try LedgerFixture.ledger()
        #expect(pump.streamEnd == 2_099_712)
        try ledger.advance(LedgerFixture.take, to: LedgerFixture.stamp(2_099_712))
        let record = try #require(try coalescer.flush())
        try expectRecord(record, frame: 512, frames: 2_099_200)
        #expect(try ledger.ingest(record) == [.recorded(LedgerFixture.take)])
        let take = try ledger.finish(LedgerFixture.take, reason: .user)
        #expect(take.droppedFrames == 2_099_200)
        #expect(take.droppedFrames == pump.paddedFrames)
    }

    @Test
    func captureOverflowCoalescerGappedRecordsFillTheLedgerCapAndTheNextIsSaturated() throws {
        let limit = CaptureOverflowLimits.maximumRecords
        let ledgerCap = TakeLedger.maximumOverflowsPerSegment
        #expect(limit == ledgerCap)
        var coalescer = try makeCoalescer()
        var ledger = try LedgerFixture.ledger()
        try ledger.advance(LedgerFixture.take, to: LedgerFixture.stamp(Int64(2 * limit + 4)))
        for index in 0..<limit {
            let step = try coalescer.offer(span(Int64(2 * index), 1))
            if let record = step.closedRecord { _ = try ledger.ingest(record) }
        }
        let held = try #require(try coalescer.flush())
        _ = try ledger.ingest(held)
        let next = try coalescer.offer(span(Int64(2 * limit), 1))
        #expect(next.saturatedInterval == span(Int64(2 * limit), 1))
        #expect(coalescer.unrecordedFrames == 1)
        let take = try ledger.finish(LedgerFixture.take, reason: .user)
        #expect(take.droppedFrames == Int64(limit))
        let segment = try #require(take.segments.first)
        #expect(segment.overflows.count == limit)
    }

    @Test
    func captureOverflowCoalescerFlushKeepsTheFrontierAndTheRecordCount() throws {
        var coalescer = try makeCoalescer()
        _ = try coalescer.offer(span(0, 10))
        let closed = try coalescer.flush()
        try expectRecord(closed, frame: 0, frames: 10)
        let before = refusal(of: span(5, 1), on: &coalescer)
        #expect(before == .overlapsPrevious(startFrame: 5, frontier: 10))
        let touching = try coalescer.offer(span(10, 5))
        #expect(touching.isHeld)
        #expect(coalescer.recordsUsed == 2)
        #expect(coalescer.pendingFrames == 5)
        let next = try coalescer.flush()
        try expectRecord(next, frame: 10, frames: 5)

        let successor = Identity(clock: 0, generation: 2, stream: 0)
        var fresh = try makeCoalescer(identity: successor)
        _ = try fresh.offer(span(0, 3))
        let record = try fresh.flush()
        try expectRecord(record, frame: 0, frames: 3, identity: successor)
        #expect(fresh.recordsUsed == 1)
    }

    @Test
    func captureOverflowCoalescerCounterInvariantHoldsAfterEachStepOfAFixedList() throws {
        var coalescer = try makeCoalescer(limit: 5)
        let offers = fixedOffers()
        #expect(offers.count == 40)
        var seamRecords = 0
        for offer in offers {
            let step = try coalescer.offer(offer)
            if step.closedRecord?.frames == UInt32.max { seamRecords += 1 }
            expectBalanced(coalescer)
        }
        #expect(seamRecords == 1)
        #expect(coalescer.isSaturated)
        #expect(coalescer.recordsUsed == 5)
        _ = try coalescer.flush()
        expectBalanced(coalescer)
    }

    /// 40 hand-patterned offers: a width seam first, then touches and gaps that exhaust a limit of 5 records.
    private func fixedOffers() -> [CaptureDrainOverflow] {
        let widest = CaptureOverflowLimits.maximumRecordFrames
        var offers = [span(0, widest), span(Int64(widest), 1)]
        var cursor = Int64(widest) + 1
        let gaps: [Int64] = [0, 0, 1, 0, 3, 0, 0, 2]
        for index in 0..<38 {
            cursor += gaps[index % gaps.count]
            let frames = 1 + index % 3
            offers.append(span(cursor, frames))
            cursor += Int64(frames)
        }
        return offers
    }
}
