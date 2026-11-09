import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Edges of the capture write drain pump (#109 WDP1) found by the claims audit: the stopped branch of `pad`, a
/// reclaim after the seal and the poll count of a retried range; round 2 adds the block offset of a resubmitted write
/// (sample-aware short writes through a real stereo pool, and the request-level offset checks). Pure values only.
extension CaptureDrainTests {
    @Test func captureDrainAPadAfterAStopAddsExactlyItsFramesToTheAfterStopCounter() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        let ticket = try drainIssue(&pump)
        _ = try pump.fail(ticket.id, .diskFull)
        #expect(pump.counters.framesAfterStop == 0)
        let first = try pump.pad(frames: 3)
        #expect(first == .stopped(reason: .diskFull))
        #expect(pump.counters.framesAfterStop == 3)
        let second = try pump.pad(frames: 4)
        #expect(second == .stopped(reason: .diskFull))
        #expect(pump.counters.framesAfterStop == 7)
        let third = try pump.enqueue(lease: leases[1], frames: 9)
        #expect(third == .stopped(reason: .diskFull, returning: leases[1]))
        #expect(pump.counters.framesAfterStop == 16)
        #expect(pump.paddedFrames == 0)
        #expect(pump.streamEnd == 4)
        expectBalanced(pump)
    }

    @Test func captureDrainAStoppedPumpWithAFullRingStillAnswersAPadAsStoppedAndDoesNotPad() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        let ticket = try drainIssue(&pump)
        _ = try pump.fail(ticket.id, .diskFull)
        #expect(pump.pendingBlocks == pump.pendingBound)
        let padded = try pump.pad(frames: 5)
        #expect(padded == .stopped(reason: .diskFull))
        #expect(pump.paddedFrames == 0)
        #expect(pump.streamEnd == 4)
        #expect(pump.counters.framesAfterStop == 5)
        let late = try pump.enqueue(lease: leases[1], frames: 2)
        #expect(late == .stopped(reason: .diskFull, returning: leases[1]))
        #expect(pump.counters.backpressureBlocks == 0)
        expectBalanced(pump)
    }

    @Test func captureDrainAReclaimAfterTheSealIsAcceptedAndLeavesTheEarlierSummaryAsItWas() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 6)
        _ = try pump.enqueue(lease: leases[1], frames: 7)
        let ticket = try drainIssue(&pump)
        _ = try pump.fail(ticket.id, .diskFull)
        let result = try MediaWriteFinish.make(acceptedFrames: 0, durableFrames: 0)
        let summary = try pump.finish(result)
        #expect(summary.unwrittenFrames == 13)
        #expect(summary.reclaimedFrames == 0)
        let head = try pump.reclaim()
        let first = try #require(head)
        #expect(first.lease == leases[0])
        #expect(pump.state == .finished)
        #expect(pump.reclaimedFrames == 6)
        #expect(pump.unwrittenFrames == 7)
        let neck = try pump.reclaim()
        let second = try #require(neck)
        #expect(second.lease == leases[1])
        let none = try pump.reclaim()
        #expect(none == nil)
        #expect(pump.reclaimedFrames == 13)
        #expect(pump.unwrittenFrames == 0)
        #expect(summary.unwrittenFrames == 13)
        expectBalanced(pump)
    }

    @Test func captureDrainARetryRestartsThePollCountOfTheRangeItRetries() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let first = try drainIssue(&pump)
        let one = try pump.receive(first.id, .pending)
        #expect(one == .stillPending(polls: 1))
        let two = try pump.receive(first.id, .pending)
        #expect(two == .stillPending(polls: 2))
        let retry = try pump.fail(first.id, .ioFailure)
        #expect(retry == .retryScheduled(attempt: 1))
        #expect(pump.pendingPolls == 0)
        let second = try drainIssue(&pump)
        let again = try pump.receive(second.id, .pending)
        #expect(again == .stillPending(polls: 1))
        #expect(pump.counters.slowPolls == 3)
    }

    @Test func captureDrainAShortAcceptResubmitsTheRestAtItsBlockOffsetAndWritesEveryFrameOnce() throws {
        let fixture = try drainStereoBlocks(frameCounts: [10])
        var pump = try CaptureDrainPump.make(startFrame: 100, pendingBound: 2)
        _ = try pump.enqueue(lease: fixture.leases[0], frames: 10)
        var written: [Float] = []
        var offsets: [Int] = []
        var counts: [Int] = []
        var starts: [Int64] = []
        let accepts = [6, 3, 1]
        for accept in accepts {
            let ticket = try drainIssue(&pump)
            offsets.append(ticket.request.blockOffset)
            counts.append(ticket.request.frames)
            starts.append(ticket.request.startFrame)
            written += try drainWrittenSamples(fixture.pool, ticket.request, accepted: accept)
            _ = try pump.receive(ticket.id, .accepted(frames: accept))
        }
        let expectedOffsets = [0, 6, 9]
        let expectedCounts = [10, 4, 1]
        let expectedStarts: [Int64] = [100, 106, 109]
        #expect(offsets == expectedOffsets)
        #expect(counts == expectedCounts)
        #expect(starts == expectedStarts)
        #expect(written == fixture.samples[0])
        #expect(pump.pendingBlocks == 0)
        #expect(pump.acceptedFrames == 10)
    }

    @Test func captureDrainASecondBlocksShortAcceptCarriesItsOwnOffsetAndNotTheAcceptedTotal() throws {
        let fixture = try drainStereoBlocks(frameCounts: [10, 8])
        var pump = try CaptureDrainPump.make(startFrame: 100, pendingBound: 3)
        _ = try pump.enqueue(lease: fixture.leases[0], frames: 10)
        _ = try pump.enqueue(lease: fixture.leases[1], frames: 8)
        var written: [Float] = []
        var offsets: [Int] = []
        var starts: [Int64] = []
        let accepts = [10, 4, 4]
        for accept in accepts {
            let ticket = try drainIssue(&pump)
            offsets.append(ticket.request.blockOffset)
            starts.append(ticket.request.startFrame)
            written += try drainWrittenSamples(fixture.pool, ticket.request, accepted: accept)
            _ = try pump.receive(ticket.id, .accepted(frames: accept))
        }
        let expectedOffsets = [0, 0, 4]
        let expectedStarts: [Int64] = [100, 110, 114]
        let expectedWritten: [Float] = fixture.samples[0] + fixture.samples[1]
        #expect(offsets == expectedOffsets)
        #expect(starts == expectedStarts)
        #expect(written == expectedWritten)
        #expect(pump.acceptedFrames == 18)
    }

    @Test func captureDrainTheWriteRequestDefaultsToOffsetZeroAndKeepsAnExplicitOffset() throws {
        let lease = try drainLeases(1)[0]
        let plain = try MediaWriteRequest.make(lease: lease, startFrame: 5, frames: 3)
        #expect(plain.blockOffset == 0)
        let explicitZero = try MediaWriteRequest.make(lease: lease, startFrame: 5, frames: 3, blockOffset: 0)
        #expect(plain == explicitZero)
        let shifted = try MediaWriteRequest.make(lease: lease, startFrame: 5, frames: 3, blockOffset: 1)
        #expect(shifted.blockOffset == 1)
        #expect(shifted.startFrame == 5)
        #expect(shifted != plain)
        let last = try MediaWriteRequest.make(lease: lease, startFrame: 0, frames: 1, blockOffset: 65_535)
        #expect(last.blockOffset == 65_535)
        let whole = try MediaWriteRequest.make(lease: lease, startFrame: 0, frames: 65_536, blockOffset: 0)
        #expect(whole.frames == 65_536)
        #expect(whole.blockOffset == 0)
        let exact = drainRequestRefusal(lease, frames: 2, blockOffset: 65_534)
        #expect(exact == nil)
    }

    @Test func captureDrainABlockOffsetBelowZeroOrPastTheRequestLimitIsRefusedAtTheEdge() throws {
        let lease = try drainLeases(1)[0]
        let pastWhole = drainRequestRefusal(lease, frames: 65_536, blockOffset: 1)
        let expectedWhole = MediaIORequestRefusal.blockOffsetOutOfRange(blockOffset: 1, frames: 65_536, maximum: 65_536)
        #expect(pastWhole == expectedWhole)
        let pastTwo = drainRequestRefusal(lease, frames: 2, blockOffset: 65_535)
        let expectedTwo = MediaIORequestRefusal.blockOffsetOutOfRange(blockOffset: 65_535, frames: 2, maximum: 65_536)
        #expect(pastTwo == expectedTwo)
        let negative = drainRequestRefusal(lease, frames: 1, blockOffset: -1)
        let expectedNegative = MediaIORequestRefusal.blockOffsetOutOfRange(blockOffset: -1, frames: 1, maximum: 65_536)
        #expect(negative == expectedNegative)
        let huge = drainRequestRefusal(lease, frames: 1, blockOffset: Int.max)
        let expectedHuge = MediaIORequestRefusal.blockOffsetOutOfRange(blockOffset: Int.max, frames: 1, maximum: 65_536)
        #expect(huge == expectedHuge)
    }

    @Test func captureDrainTheBlockOffsetIsCheckedAfterTheFramesStartAndOverflowChecks() throws {
        let lease = try drainLeases(1)[0]
        let framesFirst = drainRequestRefusal(lease, frames: 0, blockOffset: -1)
        let expectedFrames = MediaIORequestRefusal.framesOutOfRange(frames: 0, maximum: 65_536)
        #expect(framesFirst == expectedFrames)
        let startFirst = drainRequestRefusal(lease, startFrame: -1, frames: 1, blockOffset: -1)
        let expectedStart = MediaIORequestRefusal.negativeStartFrame(-1)
        #expect(startFirst == expectedStart)
        let overflowFirst = drainRequestRefusal(lease, startFrame: Int64.max, frames: 1, blockOffset: -1)
        let expectedOverflow = MediaIORequestRefusal.frameOverflow(startFrame: Int64.max, frames: 1)
        #expect(overflowFirst == expectedOverflow)
    }
}
