import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Pump construction and the decision of the next read: tickets, wait reasons, clipping and skipping.
extension MediaIOWorkerTests {
    private static func make(
        source: Int64 = 1_000,
        generation: UInt64 = 1,
        position: Int64 = 0
    ) -> PrefetchFillRefusal? {
        refusal(PrefetchFillRefusal.self) {
            try PrefetchFillPump.make(plan: plan(), sourceFrames: source, sourceGeneration: generation,
                                      readGeneration: 0, position: position)
        }
    }

    /// A pump that latched `unavailable`.
    private static func failedPump() throws -> PrefetchFillPump {
        var pump = try Self.pump()
        _ = try failNext(&pump, .unavailable)
        return pump
    }

    @Test
    func io2PumpMakeAcceptsTheMinimalSourceAndStartsIdle() throws {
        let pump = try PrefetchFillPump.make(plan: Self.plan(), sourceFrames: 1, sourceGeneration: 1,
                                             readGeneration: 0, position: 0)
        #expect(pump.state == .idle && pump.nextFrame == 0 && pump.inFlight == nil)
        #expect(pump.sourceFrames == 1 && pump.sourceGeneration == 1 && pump.readGeneration == 0)
        #expect(pump.plan == (try Self.plan()))
        #expect(pump.counters == PrefetchFillCounters() && pump.counters.values == Array(repeating: 0, count: 11))
        let atEnd = try Self.pump(position: 1_000)
        #expect(atEnd.nextFrame == 1_000 && atEnd.state == .idle)
    }

    @Test
    func io2PumpMakeBoundsAreExact() {
        #expect(Self.make(source: 0) == .sourceFramesNotPositive(0))
        #expect(Self.make(source: -1) == .sourceFramesNotPositive(-1))
        #expect(Self.make(source: 1) == nil)
        #expect(Self.make(generation: 0) == .sourceGenerationNotPositive)
        #expect(Self.make(generation: 1) == nil)
        #expect(Self.make(position: -1) == .negativePosition(-1))
        #expect(Self.make(position: 0) == nil)
        #expect(Self.make(position: 1_000) == nil)
        #expect(Self.make(position: 1_001) == .positionBeyondSource(position: 1_001, sourceFrames: 1_000))
    }

    @Test
    func io2PumpMakeChecksSourceFramesThenGenerationThenPosition() {
        #expect(Self.make(source: 0, generation: 0, position: -1) == .sourceFramesNotPositive(0))
        #expect(Self.make(source: 0, position: 5) == .sourceFramesNotPositive(0))
        #expect(Self.make(generation: 0, position: -1) == .sourceGenerationNotPositive)
        #expect(Self.make(generation: 0, position: 1_001) == .sourceGenerationNotPositive)
        #expect(Self.make(source: 10, position: 11) == .positionBeyondSource(position: 11, sourceFrames: 10))
    }

    @Test
    func io2PumpFirstTicketIsStampedAndEchoedIntoTheReadRequest() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        #expect(ticket.id == 1 && ticket.startFrame == 0 && ticket.frames == 64)
        #expect(ticket.sourceGeneration == 1 && ticket.readGeneration == 5)
        #expect(pump.state == .awaitingCompletion && pump.inFlight == ticket && pump.nextFrame == 0)
        #expect(pump.counters.ticketsIssued == 1 && pump.counters.framesSkipped == 0)
        let lease = try Self.lease()
        let request = try ticket.readRequest(lease: lease)
        #expect(request == (try MediaReadRequest.make(lease: lease, startFrame: 0, frames: 64,
                                                      sourceGeneration: 1, readGeneration: 5)))
    }

    @Test
    func io2PumpNeverKeepsTwoTicketsInFlight() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        let before = pump
        #expect(try pump.nextRequest(position: 0, residentBlocks: 0) == .wait(.inFlight))
        #expect(pump == before && pump.counters.ticketsIssued == 1 && pump.inFlight == ticket)
    }

    @Test
    func io2PumpIssuesUntilTheHeadIsCoveredExactly() throws {
        var pump = try Self.pump()
        for expectedStart in [Int64(0), 64] {
            let (ticket, outcome) = try Self.fill(&pump, frames: 64)
            #expect(ticket.startFrame == expectedStart)
            #expect(Self.delivery(outcome)?.block.startFrame == expectedStart)
        }
        #expect(pump.nextFrame == 128)
        var satisfied = pump
        #expect(try satisfied.nextRequest(position: 0, residentBlocks: 2) == .wait(.satisfied))
        #expect(satisfied == pump)
        var ahead = pump
        let ticket = try Self.issue(&ahead, position: 1, resident: 2)
        #expect(ticket.startFrame == 128 && ticket.id == 3)
    }

    @Test
    func io2PumpPoolFullWaitsAtBlockCountAndIssuesBelowIt() throws {
        let pump = try Self.pump()
        var below = pump
        _ = try Self.issue(&below, resident: 3)
        var full = pump
        #expect(try full.nextRequest(position: 0, residentBlocks: 4) == .wait(.poolFull))
        #expect(full == pump)
        var over = pump
        Self.expectRefusal(&over, .residentBlocksOutOfRange(count: 5, maximum: 4)) {
            try $0.nextRequest(position: 0, residentBlocks: 5)
        }
        Self.expectRefusal(&over, .residentBlocksOutOfRange(count: -1, maximum: 4)) {
            try $0.nextRequest(position: 0, residentBlocks: -1)
        }
        var empty = pump
        _ = try Self.issue(&empty, resident: 0)
    }

    @Test
    func io2PumpClipsTheLastTicketToTheRemainingFrames() throws {
        var pump = try Self.pump()
        var frames: [Int] = []
        var nextRequests = 0
        while nextRequests < 40 {
            nextRequests += 1
            guard case .request(let ticket) = try pump.nextRequest(position: pump.nextFrame, residentBlocks: 0) else {
                break
            }
            frames.append(ticket.frames)
            _ = try pump.receive(ticket.id, .ready(MediaReadResult(frames: ticket.frames, reachedEnd: false)))
        }
        #expect(frames == Array(repeating: 64, count: 15) + [40])
        #expect(pump.nextFrame == 1_000 && pump.state == .ended)
        #expect(try pump.nextRequest(position: 1_000, residentBlocks: 0) == .wait(.ended))
        #expect(pump.counters.ticketsIssued == 16 && pump.counters.framesDelivered == 1_000)
    }

    @Test
    func io2PumpClipsAtTheBlockSizeBoundary() throws {
        for (source, expected) in [(Int64(63), 63), (64, 64), (65, 64)] {
            var pump = try Self.pump(source: source)
            #expect(try Self.issue(&pump).frames == expected)
        }
    }

    @Test
    func io2PumpEndWaitChangesTheStateButNoCounter() throws {
        var pump = try Self.pump(position: 1_000)
        let counters = pump.counters
        #expect(try pump.nextRequest(position: 1_000, residentBlocks: 0) == .wait(.ended))
        #expect(pump.state == .ended && pump.counters == counters && pump.nextFrame == 1_000)
        let skip = try Self.pump(position: 0)
        var jumped = skip
        #expect(try jumped.nextRequest(position: 1_000, residentBlocks: 0) == .wait(.ended))
        #expect(jumped.state == .ended && jumped.nextFrame == 0 && jumped.counters == skip.counters)
    }

    @Test
    func io2PumpConsumerAheadSkipsSourceFramesAndCountsThem() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump, position: 200)
        #expect(ticket.startFrame == 200 && ticket.frames == 64 && pump.nextFrame == 200)
        #expect(pump.counters.framesSkipped == 200 && pump.counters.ticketsIssued == 1)
        _ = try pump.receive(ticket.id, .ready(MediaReadResult(frames: 64, reachedEnd: false)))
        let behind = try Self.issue(&pump, position: 200)
        #expect(behind.startFrame == 264 && pump.counters.framesSkipped == 200)
        _ = try pump.receive(behind.id, .ready(MediaReadResult(frames: 64, reachedEnd: false)))
        let barely = try Self.issue(&pump, position: 329)
        #expect(barely.startFrame == 329 && pump.counters.framesSkipped == 201)
    }

    @Test
    func io2PumpRetryReissuesTheSameRangeWithANewTicketId() throws {
        var pump = try Self.pump()
        let first = try Self.issue(&pump)
        #expect(try pump.fail(first.id, .ioFailure) == .retryScheduled(attempt: 1))
        #expect(pump.state == .retrying && pump.inFlight == nil)
        let second = try Self.issue(&pump)
        #expect(second.id == 2 && second.startFrame == first.startFrame && second.frames == first.frames)
        #expect(pump.counters.ticketsIssued == 2 && pump.counters.retriesScheduled == 1)
    }

    @Test
    func io2PumpWaitReasonsFollowTheDocumentedOrder() throws {
        let failed = try Self.failedPump()
        var failedAtEnd = failed
        #expect(try failedAtEnd.nextRequest(position: 1_000, residentBlocks: 4) == .wait(.failed))
        #expect(failedAtEnd == failed)
        var pump = try Self.pump(position: 1_000)
        _ = try pump.nextRequest(position: 1_000, residentBlocks: 4)
        #expect(pump.state == .ended)
        var inFlight = try Self.pump()
        _ = try Self.issue(&inFlight)
        var flightFull = inFlight
        #expect(try flightFull.nextRequest(position: 0, residentBlocks: 4) == .wait(.inFlight))
        var flightEnded = inFlight
        #expect(try flightEnded.nextRequest(position: 1_000, residentBlocks: 0) == .wait(.inFlight))
        #expect(flightEnded == inFlight)
        var idleEnded = try Self.pump(position: 1_000)
        #expect(try idleEnded.nextRequest(position: 1_000, residentBlocks: 4) == .wait(.ended))
        var satisfied = try Self.pump()
        _ = try Self.fill(&satisfied, frames: 64)
        _ = try Self.fill(&satisfied, frames: 64, position: 0)
        var satisfiedFull = satisfied
        #expect(try satisfiedFull.nextRequest(position: 0, residentBlocks: 4) == .wait(.poolFull))
        #expect(try satisfied.nextRequest(position: 0, residentBlocks: 3) == .wait(.satisfied))
    }

    @Test
    func io2PumpNextRequestRefusalsBeatEveryWaitAndLeaveThePumpUnchanged() throws {
        var failed = try Self.failedPump()
        Self.expectRefusal(&failed, .negativePosition(-1)) { try $0.nextRequest(position: -1, residentBlocks: 0) }
        Self.expectRefusal(&failed, .positionBeyondSource(position: 1_001, sourceFrames: 1_000)) {
            try $0.nextRequest(position: 1_001, residentBlocks: 0)
        }
        Self.expectRefusal(&failed, .residentBlocksOutOfRange(count: 5, maximum: 4)) {
            try $0.nextRequest(position: 0, residentBlocks: 5)
        }
        var inFlight = try Self.pump()
        _ = try Self.issue(&inFlight)
        Self.expectRefusal(&inFlight, .residentBlocksOutOfRange(count: -1, maximum: 4)) {
            try $0.nextRequest(position: 0, residentBlocks: -1)
        }
        Self.expectRefusal(&inFlight, .negativePosition(-5)) { try $0.nextRequest(position: -5, residentBlocks: 99) }
        Self.expectRefusal(&inFlight, .positionBeyondSource(position: 2_000, sourceFrames: 1_000)) {
            try $0.nextRequest(position: 2_000, residentBlocks: -1)
        }
        var idle = try Self.pump()
        Self.expectRefusal(&idle, .negativePosition(-1)) { try $0.nextRequest(position: -1, residentBlocks: 0) }
    }

    @Test
    func io2PumpAfterAnEarlyEndNeverReissuesUntilLocate() throws {
        var pump = try Self.pump()
        let (_, outcome) = try Self.fill(&pump, frames: 10, reachedEnd: true)
        #expect(Self.delivery(outcome)?.reachedEnd == true && pump.state == .ended && pump.nextFrame == 10)
        var again = pump
        #expect(try again.nextRequest(position: 10, residentBlocks: 0) == .wait(.ended))
        #expect(again.counters == pump.counters && again.inFlight == nil)
        try pump.locate(to: 0)
        #expect(try pump.nextRequest(position: 0, residentBlocks: 0) != .wait(.ended))
    }
}
