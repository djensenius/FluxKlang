import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Edges of the capture write drain pump (#109 WDP1) found by the claims audit: the stopped branch of `pad`, a
/// reclaim after the seal and the poll count of a retried range. Pure values only.
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
}
