import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Pump completions: deliveries, short reads, ends, pending polls and stalls, stale completions and the retry budget.
extension MediaIOWorkerTests {
    private static func ready(_ frames: Int, end: Bool = false) -> MediaReadPoll {
        .ready(MediaReadResult(frames: frames, reachedEnd: end))
    }

    @Test
    func io2PumpFullDeliveryBuildsTheBlockAndAdvancesTheCursor() throws {
        var pump = try Self.pump()
        let (ticket, outcome) = try Self.fill(&pump, frames: 64)
        let delivery = try #require(Self.delivery(outcome))
        #expect(delivery.block.startFrame == 0 && delivery.block.frames == 64 && delivery.block.endFrame == 64)
        #expect(delivery.block.sourceGeneration == 1 && delivery.block.readGeneration == 5)
        #expect(!delivery.restoredSource && !delivery.reachedEnd)
        #expect(pump.nextFrame == 64 && pump.state == .idle && pump.inFlight == nil)
        #expect(pump.counters.blocksDelivered == 1 && pump.counters.framesDelivered == 64)
        #expect(pump.counters.shortReads == 0 && pump.counters.earlyEnds == 0)
        var late = pump
        Self.expectRefusal(&late, .unknownTicket(ticket.id)) { try $0.receive(ticket.id, Self.ready(64)) }
    }

    @Test
    func io2PumpShortReadIsDeliveredAndTheNextTicketContinuesAfterIt() throws {
        var pump = try Self.pump()
        let (_, outcome) = try Self.fill(&pump, frames: 20)
        #expect(Self.delivery(outcome)?.block.frames == 20 && Self.delivery(outcome)?.reachedEnd == false)
        #expect(pump.counters.shortReads == 1 && pump.counters.framesDelivered == 20 && pump.nextFrame == 20)
        let next = try Self.issue(&pump)
        #expect(next.startFrame == 20 && next.frames == 64 && next.id == 2)
    }

    @Test
    func io2PumpDeliveredFramesMustLieBetweenZeroAndTheTicketFrames() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        Self.expectRefusal(&pump, .deliveredFramesOutOfRange(delivered: 65, requested: 64)) {
            try $0.receive(ticket.id, Self.ready(65))
        }
        Self.expectRefusal(&pump, .deliveredFramesOutOfRange(delivered: -1, requested: 64)) {
            try $0.receive(ticket.id, Self.ready(-1, end: true))
        }
        #expect(pump.inFlight == ticket && pump.state == .awaitingCompletion)
        let outcome = try pump.receive(ticket.id, Self.ready(64))
        #expect(Self.delivery(outcome)?.block.frames == 64)
    }

    @Test
    func io2PumpZeroFrameReadWithoutEndIsCountedAndRetriedWithoutAbandoning() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        #expect(try pump.receive(ticket.id, Self.ready(0)) == .retryScheduled(attempt: 1))
        #expect(pump.state == .retrying && pump.inFlight == nil)
        #expect(pump.counters.shortReads == 1 && pump.counters.retriesScheduled == 1)
        #expect(pump.counters.ticketsAbandoned == 0 && pump.counters.blocksDelivered == 0)
        Self.expectRefusal(&pump, .unknownTicket(ticket.id)) { try $0.receive(ticket.id, Self.ready(64)) }
    }

    @Test
    func io2PumpEarlyEndIsDeliveredCountedAndEnded() throws {
        var pump = try Self.pump()
        let (_, outcome) = try Self.fill(&pump, frames: 10, reachedEnd: true)
        #expect(Self.delivery(outcome)?.reachedEnd == true && Self.delivery(outcome)?.block.frames == 10)
        #expect(pump.state == .ended && pump.nextFrame == 10)
        #expect(pump.counters.earlyEnds == 1 && pump.counters.shortReads == 0)
    }

    @Test
    func io2PumpEndAtTheSourceEndIsNotAnEarlyEnd() throws {
        var flagged = try Self.pump(source: 64)
        let (_, outcome) = try Self.fill(&flagged, frames: 64, reachedEnd: true)
        #expect(Self.delivery(outcome)?.reachedEnd == true && flagged.state == .ended)
        #expect(flagged.counters.earlyEnds == 0)
        var implied = try Self.pump(source: 100)
        _ = try Self.fill(&implied, frames: 64)
        #expect(implied.state == .idle)
        let (ticket, last) = try Self.fill(&implied, frames: 36)
        #expect(ticket.frames == 36 && Self.delivery(last)?.reachedEnd == true)
        #expect(implied.state == .ended && implied.counters.earlyEnds == 0 && implied.counters.shortReads == 0)
    }

    @Test
    func io2PumpEmptyReadAtTheEndIsEndedWithoutData() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        #expect(try pump.receive(ticket.id, Self.ready(0, end: true)) == .endedWithoutData)
        #expect(pump.state == .ended && pump.inFlight == nil && pump.nextFrame == 0)
        #expect(pump.counters.earlyEnds == 1 && pump.counters.blocksDelivered == 0)
        #expect(pump.counters.retriesScheduled == 0 && pump.counters.shortReads == 0)
    }

    @Test
    func io2PumpRefusesUnknownAndWrongTicketsAndLeavesTheTicketInFlight() throws {
        var idle = try Self.pump()
        Self.expectRefusal(&idle, .unknownTicket(1)) { try $0.receive(1, Self.ready(1)) }
        Self.expectRefusal(&idle, .unknownTicket(0)) { try $0.fail(0, .ioFailure) }
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        Self.expectRefusal(&pump, .unknownTicket(2)) { try $0.receive(2, Self.ready(1)) }
        Self.expectRefusal(&pump, .unknownTicket(0)) { try $0.fail(0, .unavailable) }
        Self.expectRefusal(&pump, .unknownTicket(2)) { try $0.receive(2, .pending) }
        #expect(pump.inFlight == ticket)
    }

    @Test
    func io2PumpNinthConsecutivePendingPollIsAStallThatAbandonsTheTicket() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        for polls in 1...8 {
            #expect(try pump.receive(ticket.id, .pending) == .stillPending(polls: polls))
            #expect(pump.inFlight == ticket && pump.state == .awaitingCompletion)
        }
        #expect(pump.counters.stalls == 0 && pump.counters.ticketsAbandoned == 0)
        #expect(try pump.receive(ticket.id, .pending) == .retryScheduled(attempt: 1))
        #expect(pump.counters.stalls == 1 && pump.counters.ticketsAbandoned == 1)
        #expect(pump.counters.retriesScheduled == 1 && pump.state == .retrying && pump.inFlight == nil)
        #expect(try pump.receive(ticket.id, Self.ready(999)) == .discardedStale)
        #expect(pump.counters.staleCompletions == 1)
        Self.expectRefusal(&pump, .unknownTicket(ticket.id)) { try $0.receive(ticket.id, .pending) }
        #expect(pump.counters.staleCompletions == 1)
    }

    @Test
    func io2PumpFaultOfAnAbandonedTicketIsAlsoDiscardedOnce() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        try pump.locate(to: 0)
        #expect(try pump.fail(ticket.id, .unavailable) == .discardedStale)
        #expect(pump.state == .idle && pump.counters.faultsLatched == 0 && pump.counters.staleCompletions == 1)
        Self.expectRefusal(&pump, .unknownTicket(ticket.id)) { try $0.fail(ticket.id, .unavailable) }
    }

    @Test
    func io2PumpPendingPollsDoNotResetTheFailureRun() throws {
        var pump = try Self.pump()
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 1))
        let ticket = try Self.issue(&pump)
        for polls in 1...3 {
            #expect(try pump.receive(ticket.id, .pending) == .stillPending(polls: polls))
        }
        #expect(try pump.fail(ticket.id, .interrupted) == .retryScheduled(attempt: 2))
        let fresh = try Self.issue(&pump)
        #expect(try pump.receive(fresh.id, .pending) == .stillPending(polls: 1))
    }

    @Test
    func io2PumpRetriesExactlyThreeFailuresInARowThenLatchesTheFourth() throws {
        var pump = try Self.pump()
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 1))
        #expect(try Self.failNext(&pump, .interrupted) == .retryScheduled(attempt: 2))
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 3))
        #expect(pump.state == .retrying && pump.counters.retriesScheduled == 3 && pump.counters.faultsLatched == 0)
        #expect(try Self.failNext(&pump, .interrupted) == .sourceLost(.interrupted))
        #expect(pump.state == .failed(.interrupted) && pump.inFlight == nil)
        #expect(pump.counters.faultsLatched == 1 && pump.counters.retriesScheduled == 3)
    }

    @Test
    func io2PumpDeliveryBetweenFailuresResetsTheRun() throws {
        var pump = try Self.pump()
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 1))
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 2))
        _ = try Self.fill(&pump, frames: 64)
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 1))
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 2))
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 3))
        #expect(try Self.failNext(&pump, .ioFailure) == .sourceLost(.ioFailure))
    }

    @Test
    func io2PumpUnavailableLatchesAtOnceWithoutRetry() throws {
        var pump = try Self.pump()
        #expect(try Self.failNext(&pump, .unavailable) == .sourceLost(.unavailable))
        #expect(pump.state == .failed(.unavailable) && pump.counters.retriesScheduled == 0)
        #expect(pump.counters.faultsLatched == 1)
    }

    @Test
    func io2PumpReportsOneSourceLostPerLatchAndThenWaitsFailed() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        #expect(try pump.fail(ticket.id, .unavailable) == .sourceLost(.unavailable))
        Self.expectRefusal(&pump, .unknownTicket(ticket.id)) { try $0.fail(ticket.id, .unavailable) }
        let latched = pump
        for _ in 0..<3 {
            #expect(try pump.nextRequest(position: 0, residentBlocks: 0) == .wait(.failed))
        }
        #expect(pump == latched && pump.counters.faultsLatched == 1)
    }

    @Test
    func io2PumpStallThatExhaustsTheBudgetLatchesIoFailure() throws {
        var pump = try Self.pump()
        for attempt in 1...3 {
            #expect(try Self.failNext(&pump, .interrupted) == .retryScheduled(attempt: attempt))
        }
        let ticket = try Self.issue(&pump)
        for _ in 1...8 { _ = try pump.receive(ticket.id, .pending) }
        #expect(try pump.receive(ticket.id, .pending) == .sourceLost(.ioFailure))
        #expect(pump.state == .failed(.ioFailure) && pump.counters.stalls == 1 && pump.counters.faultsLatched == 1)
        #expect(try pump.receive(ticket.id, Self.ready(5)) == .discardedStale)
    }

    @Test
    func io2PumpStaleCompletionDoesNotDisturbTheLiveTicket() throws {
        var pump = try Self.pump()
        let old = try Self.issue(&pump)
        try pump.locate(to: 64)
        let live = try Self.issue(&pump)
        #expect(live.id == 2 && live.startFrame == 64 && live.readGeneration == 6)
        #expect(try pump.receive(old.id, Self.ready(64)) == .discardedStale)
        #expect(pump.inFlight == live && pump.counters.blocksDelivered == 0 && pump.nextFrame == 64)
        #expect(Self.delivery(try pump.receive(live.id, Self.ready(64)))?.block.startFrame == 64)
    }
}
