import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The capture write drain pump (#109 WDP1): the coordinator's golden run, the pinned refusal orders, the retry
/// budget and the latch, the frame invariant. Pure values only: no file, thread, time or randomness.
@Suite("Capture write drain pump", .productionAccessAudit)
struct CaptureDrainTests {
    @Test func captureDrainMakeRefusesTheBoundBeforeTheStartFrameWhenBothAreWrong() {
        let refusal = drainRefusal { try CaptureDrainPump.make(startFrame: -1, pendingBound: 0) }
        #expect(refusal == .pendingBoundOutOfRange(bound: 0, maximum: 1_024))
        let negative = drainRefusal { try CaptureDrainPump.make(startFrame: -1, pendingBound: 3) }
        #expect(negative == .request(.negativeStartFrame(-1)))
    }

    @Test func captureDrainMakeBuildsAnEmptyRunningPumpAtTheGivenStartFrame() throws {
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        #expect(pump.state == .running)
        #expect(pump.streamEnd == 0)
        #expect(pump.pendingBlocks == 0)
        #expect(pump.inFlight == nil)
        #expect(pump.counters.values == [UInt64](repeating: 0, count: 10))
        let step = try pump.nextWrite()
        #expect(step == .idle(.empty))
    }

    @Test func captureDrainGoldenQueuesThreeBlocksThenPadsTheNewestAndTheRecorderReportedDrop() throws {
        let leases = try drainLeases()
        var pump = try drainGoldenQueued(leases)
        #expect(pump.streamEnd == 135)
        #expect(pump.unwrittenFrames == 35)
        #expect(pump.pendingBlocks == 3)
        let padded = try pump.enqueue(lease: leases[3], frames: 7)
        #expect(padded == .padded(CaptureDrainOverflow(startFrame: 135, frames: 7), returning: leases[3]))
        #expect(pump.streamEnd == 142)
        #expect(pump.paddedFrames == 7)
        #expect(pump.pendingBlocks == 3)
        #expect(pump.counters.backpressureBlocks == 1)
        #expect(pump.counters.blocksQueued == 3)
        let dropped = try pump.pad(frames: 4)
        #expect(dropped == .padded(CaptureDrainOverflow(startFrame: 142, frames: 4)))
        #expect(pump.streamEnd == 146)
        #expect(pump.paddedFrames == 11)
        #expect(pump.unwrittenFrames == 35)
    }

    @Test func captureDrainGoldenShortAcceptIsResubmittedAndTheCompletedBlockIsHandedBack() throws {
        let leases = try drainLeases()
        var pump = try drainGoldenPadded(leases)
        let first = try drainIssue(&pump)
        drainExpect(first, id: 1, lease: leases[0], start: 100, frames: 10)
        let partial = try pump.receive(1, .accepted(frames: 6))
        #expect(partial == .partial(accepted: 6, remaining: 4))
        #expect(pump.acceptedFrames == 6)
        #expect(pump.unwrittenFrames == 29)
        #expect(pump.pendingBlocks == 3)
        let second = try drainIssue(&pump)
        drainExpect(second, id: 2, lease: leases[0], start: 106, frames: 4)
        let done = try pump.receive(2, .accepted(frames: 4))
        let block = try #require(done.writtenBlock)
        #expect(block.lease == leases[0])
        #expect(block.startFrame == 100)
        #expect(block.frames == 10)
        #expect(pump.acceptedFrames == 10)
        #expect(pump.pendingBlocks == 2)
        #expect(pump.unwrittenFrames == 25)
        #expect(pump.counters.shortAccepts == 1)
        #expect(pump.counters.blocksWritten == 1)
    }

    @Test func captureDrainGoldenThreeRetriesAreScheduledAndTheFourthFailureLatchesAsDeviceLost() throws {
        let leases = try drainLeases()
        var pump = try drainGoldenWritten(leases)
        let faults: [MediaWriteFault] = [.ioFailure, .interrupted, .ioFailure]
        for (index, fault) in faults.enumerated() {
            let ticket = try drainIssue(&pump)
            drainExpect(ticket, id: UInt64(3 + index), lease: leases[1], start: 110, frames: 20)
            let outcome = try pump.fail(ticket.id, fault)
            #expect(outcome == .retryScheduled(attempt: index + 1))
        }
        let last = try drainIssue(&pump)
        drainExpect(last, id: 6, lease: leases[1], start: 110, frames: 20)
        let latched = try pump.fail(6, .ioFailure)
        #expect(latched == .captureStopped(reason: .deviceLost, fault: .ioFailure))
        #expect(pump.state == .stopped(.ioFailure))
        #expect(pump.pendingBlocks == 2)
        #expect(pump.inFlight == nil)
        #expect(pump.counters.faultsLatched == 1)
        #expect(pump.counters.retriesScheduled == 3)
    }

    @Test func captureDrainGoldenAStoppedPumpReturnsNewBlocksReclaimsTheQueueInOrderAndFinishesPartial() throws {
        let leases = try drainLeases()
        var pump = try drainGoldenLatched(leases)
        let after = try pump.enqueue(lease: leases[4], frames: 9)
        #expect(after == .stopped(reason: .deviceLost, returning: leases[4]))
        #expect(pump.streamEnd == 146)
        #expect(pump.counters.framesAfterStop == 9)
        #expect(pump.counters.blocksQueued == 3)
        let head = try pump.reclaim()
        let first = try #require(head)
        #expect(first.lease == leases[1])
        #expect(first.startFrame == 110)
        #expect(first.frames == 20)
        let neck = try pump.reclaim()
        let second = try #require(neck)
        #expect(second.lease == leases[2])
        #expect(second.startFrame == 130)
        #expect(second.frames == 5)
        let none = try pump.reclaim()
        #expect(none == nil)
        #expect(pump.reclaimedFrames == 25)
        #expect(pump.unwrittenFrames == 0)
        #expect(pump.counters.blocksReclaimed == 2)
        let result = try MediaWriteFinish.make(acceptedFrames: 10, durableFrames: 7)
        let summary = try pump.finish(result)
        #expect(summary.startFrame == 100)
        #expect(summary.streamFrames == 46)
        #expect(summary.acceptedFrames == 10)
        #expect(summary.paddedFrames == 11)
        #expect(summary.reclaimedFrames == 25)
        #expect(summary.unwrittenFrames == 0)
        #expect(summary.sealing == .sealed(durableFrames: 7))
        #expect(summary.isPartial)
        #expect(summary.missingFrames == 3)
        #expect(summary.stopReason == .deviceLost)
        #expect(pump.state == .finished)
        expectDrainRefused(&pump, .alreadyFinished) { _ = try $0.finish(result) }
    }

    @Test func captureDrainDiskFullLatchesAtOnceAsDiskFullWithoutARetry() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let ticket = try drainIssue(&pump)
        let outcome = try pump.fail(ticket.id, .diskFull)
        #expect(outcome == .captureStopped(reason: .diskFull, fault: .diskFull))
        #expect(pump.state == .stopped(.diskFull))
        #expect(pump.counters.retriesScheduled == 0)
        #expect(pump.counters.faultsLatched == 1)
        #expect(pump.pendingBlocks == 1)
    }

    @Test func captureDrainUnavailableLatchesAtOnceAsDeviceLostWithoutARetry() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let ticket = try drainIssue(&pump)
        let outcome = try pump.fail(ticket.id, .unavailable)
        #expect(outcome == .captureStopped(reason: .deviceLost, fault: .unavailable))
        #expect(pump.state == .stopped(.unavailable))
        #expect(pump.counters.retriesScheduled == 0)
    }

    @Test func captureDrainTwoShortAcceptsInARowResubmitExactlyTheRestEachTime() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 40, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        _ = try pump.enqueue(lease: leases[1], frames: 5)
        let first = try drainIssue(&pump)
        drainExpect(first, id: 1, lease: leases[0], start: 40, frames: 10)
        _ = try pump.receive(1, .accepted(frames: 3))
        let second = try drainIssue(&pump)
        drainExpect(second, id: 2, lease: leases[0], start: 43, frames: 7)
        let again = try pump.receive(2, .accepted(frames: 3))
        #expect(again == .partial(accepted: 3, remaining: 4))
        let third = try drainIssue(&pump)
        drainExpect(third, id: 3, lease: leases[0], start: 46, frames: 4)
        let done = try pump.receive(3, .accepted(frames: 4))
        #expect(done.writtenBlock?.frames == 10)
        let next = try drainIssue(&pump)
        drainExpect(next, id: 4, lease: leases[1], start: 50, frames: 5)
        #expect(pump.acceptedFrames == 10)
        #expect(pump.counters.shortAccepts == 2)
    }

    @Test func captureDrainUnknownTicketsAreRefusedForANeverIssuedACompletedAndAStoppedId() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        expectDrainRefused(&pump, .unknownTicket(1)) { _ = try $0.receive(1, .pending) }
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        _ = try pump.enqueue(lease: leases[1], frames: 4)
        let ticket = try drainIssue(&pump)
        expectDrainRefused(&pump, .unknownTicket(7)) { _ = try $0.receive(7, .accepted(frames: 4)) }
        _ = try pump.receive(ticket.id, .accepted(frames: 4))
        expectDrainRefused(&pump, .unknownTicket(1)) { _ = try $0.receive(1, .accepted(frames: 4)) }
        expectDrainRefused(&pump, .unknownTicket(1)) { _ = try $0.fail(1, .ioFailure) }
        let second = try drainIssue(&pump)
        _ = try pump.fail(second.id, .diskFull)
        expectDrainRefused(&pump, .unknownTicket(2)) { _ = try $0.receive(2, .pending) }
        expectDrainRefused(&pump, .unknownTicket(2)) { _ = try $0.fail(2, .diskFull) }
    }

    @Test func captureDrainAWrongIdWinsOverAnOverAcceptAndTheTicketStaysInFlight() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        let ticket = try drainIssue(&pump)
        expectDrainRefused(&pump, .unknownTicket(9)) { _ = try $0.receive(9, .accepted(frames: 99)) }
        #expect(pump.inFlight == ticket)
        let outcome = try pump.receive(ticket.id, .accepted(frames: 4))
        #expect(outcome.writtenBlock?.frames == 4)
    }

    @Test func captureDrainAnAcceptOfZeroAndAnOverAcceptAreRefusedAndTheTicketStaysInFlight() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        let ticket = try drainIssue(&pump)
        expectDrainRefused(&pump, .acceptedFramesOutOfRange(accepted: 0, requested: 4)) {
            _ = try $0.receive(ticket.id, .accepted(frames: 0))
        }
        expectDrainRefused(&pump, .acceptedFramesOutOfRange(accepted: 5, requested: 4)) {
            _ = try $0.receive(ticket.id, .accepted(frames: 5))
        }
        expectDrainRefused(&pump, .acceptedFramesOutOfRange(accepted: -1, requested: 4)) {
            _ = try $0.receive(ticket.id, .accepted(frames: -1))
        }
        #expect(pump.inFlight == ticket)
        let outcome = try pump.receive(ticket.id, .accepted(frames: 4))
        #expect(outcome.writtenBlock?.frames == 4)
    }

    @Test func captureDrainOneHundredPendingPollsNeverFailOrLatchAndALaterAcceptStillLands() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 6)
        let ticket = try drainIssue(&pump)
        for index in 1...100 {
            let outcome = try pump.receive(ticket.id, .pending)
            #expect(outcome == .stillPending(polls: UInt64(index)))
        }
        #expect(pump.state == .running)
        #expect(pump.inFlight == ticket)
        #expect(pump.counters.slowPolls == 100)
        #expect(pump.counters.faultsLatched == 0)
        _ = try pump.receive(ticket.id, .accepted(frames: 2))
        let next = try drainIssue(&pump)
        let again = try pump.receive(next.id, .pending)
        #expect(again == .stillPending(polls: 1))
        let done = try pump.receive(next.id, .accepted(frames: 4))
        #expect(done.writtenBlock?.frames == 6)
    }

    @Test func captureDrainAnAcceptResetsTheRetryRunSoThreeFailuresTwiceAreAllRetried() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let accepts = [3, 4]
        let remains = [7, 3]
        for round in 0..<2 {
            for attempt in 1...3 {
                let ticket = try drainIssue(&pump)
                let outcome = try pump.fail(ticket.id, .ioFailure)
                #expect(outcome == .retryScheduled(attempt: attempt))
            }
            let ticket = try drainIssue(&pump)
            let outcome = try pump.receive(ticket.id, .accepted(frames: accepts[round]))
            #expect(outcome == .partial(accepted: accepts[round], remaining: remains[round]))
        }
        #expect(pump.state == .running)
        #expect(pump.counters.retriesScheduled == 6)
    }

    @Test func captureDrainInterruptedAndIoFailureShareOneRetryRunAndTheFourthLatches() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let faults: [MediaWriteFault] = [.interrupted, .ioFailure, .interrupted]
        for fault in faults {
            let ticket = try drainIssue(&pump)
            _ = try pump.fail(ticket.id, fault)
        }
        let last = try drainIssue(&pump)
        let outcome = try pump.fail(last.id, .interrupted)
        #expect(outcome == .captureStopped(reason: .deviceLost, fault: .interrupted))
        #expect(pump.counters.retriesScheduled == 3)
    }

    @Test func captureDrainAPendingPollBetweenTwoFailuresDoesNotResetTheRetryRun() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let one = try drainIssue(&pump)
        _ = try pump.fail(one.id, .ioFailure)
        let two = try drainIssue(&pump)
        _ = try pump.receive(two.id, .pending)
        let polled = try pump.fail(two.id, .ioFailure)
        #expect(polled == .retryScheduled(attempt: 2))
    }

    @Test func captureDrainCaptureStoppedIsReportedOnceAndALaterFailIsRefused() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        let ticket = try drainIssue(&pump)
        let outcome = try pump.fail(ticket.id, .diskFull)
        #expect(outcome == .captureStopped(reason: .diskFull, fault: .diskFull))
        expectDrainRefused(&pump, .unknownTicket(ticket.id)) { _ = try $0.fail(ticket.id, .diskFull) }
        #expect(pump.counters.faultsLatched == 1)
        let step = try pump.nextWrite()
        #expect(step == .idle(.stopped))
    }

    @Test func captureDrainNextWriteSaysWhyItIssuedNothingForEachIdleReason() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        let empty = try pump.nextWrite()
        #expect(empty == .idle(.empty))
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        let ticket = try drainIssue(&pump)
        let busy = try pump.nextWrite()
        #expect(busy == .idle(.inFlight))
        #expect(pump.inFlight == ticket)
        _ = try pump.receive(ticket.id, .accepted(frames: 4))
        let result = try MediaWriteFinish.make(acceptedFrames: 4, durableFrames: 4)
        _ = try pump.finish(result)
        let finished = try pump.nextWrite()
        #expect(finished == .idle(.finished))
        #expect(pump.counters.ticketsIssued == 1)
    }

    @Test func captureDrainReclaimIsRefusedWhileRunningThenDrainsInOrderAndThenAnswersNil() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 6)
        _ = try pump.enqueue(lease: leases[1], frames: 7)
        expectDrainRefused(&pump, .notStopped) { _ = try $0.reclaim() }
        let ticket = try drainIssue(&pump)
        _ = try pump.receive(ticket.id, .accepted(frames: 2))
        let next = try drainIssue(&pump)
        _ = try pump.fail(next.id, .diskFull)
        let head = try pump.reclaim()
        let first = try #require(head)
        #expect(first.lease == leases[0])
        #expect(first.frames == 6)
        #expect(pump.reclaimedFrames == 4)
        #expect(pump.unwrittenFrames == 7)
        #expect(pump.acceptedFrames == 2)
        let neck = try pump.reclaim()
        let second = try #require(neck)
        #expect(second.lease == leases[1])
        #expect(pump.reclaimedFrames == 11)
        #expect(pump.unwrittenFrames == 0)
        let none = try pump.reclaim()
        #expect(none == nil)
        #expect(pump.pendingBlocks == 0)
        let again = try pump.enqueue(lease: leases[0], frames: 1)
        #expect(again == .stopped(reason: .diskFull, returning: leases[0]))
        let late = try pump.pad(frames: 3)
        #expect(late == .stopped(reason: .diskFull))
        #expect(pump.paddedFrames == 0)
    }

    @Test func captureDrainFinishRefusesAWriteInFlightBeforeQueuedBlocksAndThoseBeforeAMismatch() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 6)
        let bad = try MediaWriteFinish.make(acceptedFrames: 99, durableFrames: 0)
        expectDrainRefused(&pump, .blocksStillPending(count: 1)) { _ = try $0.finish(bad) }
        let ticket = try drainIssue(&pump)
        expectDrainRefused(&pump, .writeInFlight) { _ = try $0.finish(bad) }
        expectDrainRefused(&pump, .writeInFlight) { _ = try $0.finishFailed(.ioFailure) }
        _ = try pump.receive(ticket.id, .accepted(frames: 6))
        expectDrainRefused(&pump, .acceptedMismatch(worker: 99, pump: 6)) { _ = try $0.finish(bad) }
        let good = try MediaWriteFinish.make(acceptedFrames: 6, durableFrames: 6)
        let summary = try pump.finish(good)
        #expect(!summary.isPartial)
        #expect(summary.missingFrames == 0)
        #expect(summary.stopReason == nil)
        expectDrainRefused(&pump, .alreadyFinished) { _ = try $0.finish(good) }
        expectDrainRefused(&pump, .alreadyFinished) { _ = try $0.finishFailed(.ioFailure) }
    }

    @Test func captureDrainAStoppedPumpMayFinishWithAQueueAndReportsItsFramesAsUnwritten() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 6)
        _ = try pump.enqueue(lease: leases[1], frames: 7)
        let ticket = try drainIssue(&pump)
        _ = try pump.receive(ticket.id, .accepted(frames: 2))
        let next = try drainIssue(&pump)
        _ = try pump.fail(next.id, .diskFull)
        let good = try MediaWriteFinish.make(acceptedFrames: 2, durableFrames: 2)
        let summary = try pump.finish(good)
        #expect(summary.acceptedFrames == 2)
        #expect(summary.unwrittenFrames == 11)
        #expect(summary.reclaimedFrames == 0)
        #expect(summary.stopReason == .diskFull)
        #expect(!summary.isPartial)
    }

    @Test func captureDrainFinishFailedReportsASealFailureAndTheLatchedReasonElseTheFaultReason() throws {
        let leases = try drainLeases()
        var calm = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        let failed = try calm.finishFailed(.diskFull)
        #expect(failed.sealing == .sealFailed(.diskFull))
        #expect(failed.stopReason == .diskFull)
        #expect(!failed.isPartial)
        #expect(failed.missingFrames == 0)
        #expect(calm.state == .finished)
        var stopped = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try stopped.enqueue(lease: leases[0], frames: 4)
        let first = try drainIssue(&stopped)
        _ = try stopped.receive(first.id, .accepted(frames: 2))
        let ticket = try drainIssue(&stopped)
        _ = try stopped.fail(ticket.id, .unavailable)
        let latched = try stopped.finishFailed(.diskFull)
        #expect(latched.stopReason == .deviceLost)
        #expect(latched.sealing == .sealFailed(.diskFull))
        #expect(latched.missingFrames == 0)
        #expect(!latched.isPartial)
    }
}
