import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Pump recovery (`locate`, `resume`), counter monotonicity and a fixed-seed long session.
extension MediaIOWorkerTests {
    /// A seeded linear congruential generator that uses the HIGH bits; the seed is fixed in every test.
    private struct Io2SeededLcg {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private struct Io2SessionResult: Equatable {
        var log: [String] = []
        var deliveredFrames: UInt64 = 0
        var pump: PrefetchFillPump
    }

    @Test
    func io2LocateBumpsTheReadGenerationAbandonsTheTicketAndMovesTheCursor() throws {
        var pump = try Self.pump()
        let ticket = try Self.issue(&pump)
        try pump.locate(to: 500)
        #expect(pump.readGeneration == 6 && pump.nextFrame == 500 && pump.inFlight == nil && pump.state == .idle)
        #expect(pump.counters.ticketsAbandoned == 1 && pump.counters.ticketsIssued == 1)
        #expect(try pump.receive(ticket.id, Self.readyPoll(999)) == .discardedStale)
        let next = try Self.issue(&pump, position: 500)
        #expect(next.startFrame == 500 && next.readGeneration == 6 && next.id == 2)
    }

    @Test
    func io2LocateResetsTheFailureRunAndLeavesEveryStateButFailedForIdle() throws {
        var retrying = try Self.pump()
        _ = try Self.failNext(&retrying, .ioFailure)
        _ = try Self.failNext(&retrying, .ioFailure)
        try retrying.locate(to: 0)
        #expect(retrying.state == .idle && retrying.counters.ticketsAbandoned == 0)
        #expect(try Self.failNext(&retrying, .ioFailure) == .retryScheduled(attempt: 1))
        var ended = try Self.pump(position: 1_000)
        _ = try ended.nextRequest(position: 1_000, residentBlocks: 0)
        #expect(ended.state == .ended)
        try ended.locate(to: 0)
        #expect(ended.state == .idle && ended.nextFrame == 0)
        var idle = try Self.pump()
        try idle.locate(to: 7)
        #expect(idle.state == .idle && idle.counters.ticketsAbandoned == 0 && idle.readGeneration == 6)
    }

    @Test
    func io2LocateAcceptsZeroThroughSourceFramesAndRefusesOutsideThem() throws {
        var pump = try Self.pump(position: 10)
        try pump.locate(to: 0)
        try pump.locate(to: 1_000)
        #expect(pump.nextFrame == 1_000 && pump.readGeneration == 7)
        Self.expectRefusal(&pump, .negativePosition(-1)) { try $0.locate(to: -1) }
        Self.expectRefusal(&pump, .positionBeyondSource(position: 1_001, sourceFrames: 1_000)) {
            try $0.locate(to: 1_001)
        }
        var inFlight = try Self.pump()
        _ = try Self.issue(&inFlight)
        Self.expectRefusal(&inFlight, .negativePosition(-1)) { try $0.locate(to: -1) }
    }

    @Test
    func io2LocateChecksPositionsBeforeTheGenerationOverflow() throws {
        var top = try Self.pump(readGeneration: UInt64.max)
        Self.expectRefusal(&top, .generationOverflow) { try $0.locate(to: 5) }
        Self.expectRefusal(&top, .negativePosition(-1)) { try $0.locate(to: -1) }
        Self.expectRefusal(&top, .positionBeyondSource(position: 1_001, sourceFrames: 1_000)) {
            try $0.locate(to: 1_001)
        }
        var below = try Self.pump(readGeneration: UInt64.max - 1)
        try below.locate(to: 5)
        #expect(below.readGeneration == UInt64.max)
        Self.expectRefusal(&below, .generationOverflow) { try $0.locate(to: 5) }
        var inFlight = try Self.pump(readGeneration: UInt64.max)
        _ = try Self.issue(&inFlight)
        Self.expectRefusal(&inFlight, .generationOverflow) { try $0.locate(to: 5) }
    }

    @Test
    func io2LocateWhileFailedStaysFailed() throws {
        var pump = try Self.pump()
        _ = try Self.failNext(&pump, .unavailable)
        try pump.locate(to: 10)
        #expect(pump.state == .failed(.unavailable) && pump.nextFrame == 10 && pump.readGeneration == 6)
        #expect(pump.counters.ticketsAbandoned == 0)
        #expect(try pump.nextRequest(position: 10, residentBlocks: 0) == .wait(.failed))
    }

    @Test
    func io2ResumeIsRefusedUnlessFailedAndUnlessTheGenerationIsNewer() throws {
        var idle = try Self.pump()
        Self.expectRefusal(&idle, .notFailed) { try $0.resume(sourceGeneration: 2, position: 0) }
        Self.expectRefusal(&idle, .notFailed) { try $0.resume(sourceGeneration: 0, position: 0) }
        var failed = try Self.pump()
        _ = try Self.failNext(&failed, .unavailable)
        Self.expectRefusal(&failed, .generationNotNewer(current: 1, proposed: 1)) {
            try $0.resume(sourceGeneration: 1, position: 0)
        }
        Self.expectRefusal(&failed, .generationNotNewer(current: 1, proposed: 0)) {
            try $0.resume(sourceGeneration: 0, position: 0)
        }
        try failed.resume(sourceGeneration: 2, position: 0)
        #expect(failed.state == .idle && failed.sourceGeneration == 2)
        var top = try Self.pump()
        _ = try Self.failNext(&top, .unavailable)
        try top.resume(sourceGeneration: UInt64.max, position: 0)
        #expect(top.sourceGeneration == UInt64.max)
    }

    @Test
    func io2ResumeReportsTheRestoredSourceOnTheFirstDeliveryOnly() throws {
        var pump = try Self.pump()
        _ = try Self.failNext(&pump, .unavailable)
        try pump.resume(sourceGeneration: 2, position: 0)
        let (ticket, first) = try Self.fill(&pump, frames: 64)
        #expect(ticket.sourceGeneration == 2 && Self.delivery(first)?.restoredSource == true)
        #expect(Self.delivery(first)?.block.sourceGeneration == 2)
        let (_, second) = try Self.fill(&pump, frames: 64)
        #expect(Self.delivery(second)?.restoredSource == false)
    }

    @Test
    func io2ResumeKeepsTheRestoreFlagAcrossAnEmptyEndAndResetsTheRuns() throws {
        var pump = try Self.pump()
        for _ in 1...3 { _ = try Self.failNext(&pump, .ioFailure) }
        #expect(try Self.failNext(&pump, .ioFailure) == .sourceLost(.ioFailure))
        try pump.resume(sourceGeneration: 2, position: 0)
        #expect(try Self.failNext(&pump, .ioFailure) == .retryScheduled(attempt: 1))
        let (_, outcome) = try Self.fill(&pump, frames: 64)
        #expect(Self.delivery(outcome)?.restoredSource == true)
    }

    @Test
    func io2ResumeKeepsTheRememberedAbandonedTicketAndANewAbandonmentOverwritesIt() throws {
        var pump = try Self.pump()
        let first = try Self.issue(&pump)
        try pump.locate(to: 0)
        let second = try Self.issue(&pump)
        _ = try pump.fail(second.id, .unavailable)
        try pump.resume(sourceGeneration: 2, position: 0)
        #expect(try pump.receive(first.id, Self.readyPoll(1)) == .discardedStale)
        var overwritten = try Self.pump()
        let older = try Self.issue(&overwritten)
        try overwritten.locate(to: 0)
        let newer = try Self.issue(&overwritten)
        try overwritten.locate(to: 0)
        Self.expectRefusal(&overwritten, .unknownTicket(older.id)) { try $0.receive(older.id, Self.readyPoll(1)) }
        #expect(try overwritten.receive(newer.id, Self.readyPoll(1)) == .discardedStale)
    }

    @Test
    func io2PumpRepeatsAFixedScriptedSessionIdentically() throws {
        func run() throws -> (outcomes: [PrefetchFillOutcome], pump: PrefetchFillPump) {
            var pump = try Self.pump(source: 150)
            var reader = ScriptedMediaReader(script: try MediaReadScript(steps: [
                .pending, .ready(frames: 30), .fail(.interrupted), .ready(frames: 34), .pending, .readyAtEnd(frames: 20)
            ]))
            let lease = try Self.lease()
            var outcomes: [PrefetchFillOutcome] = []
            while pump.state != .ended, outcomes.count < 20 {
                var current = pump.inFlight
                if current == nil { current = try Self.issue(&pump, position: 0) }
                let ticket = try #require(current)
                let request = try ticket.readRequest(lease: lease)
                do {
                    outcomes.append(try pump.receive(ticket.id, try reader.read(request)))
                } catch let fault as MediaReadFault {
                    outcomes.append(try pump.fail(ticket.id, fault))
                }
            }
            return (outcomes, pump)
        }
        let first = try run()
        let second = try run()
        #expect(first.outcomes == second.outcomes && first.pump == second.pump)
        #expect(first.outcomes.count == 6 && first.pump.state == .ended)
        #expect(first.outcomes.first == .stillPending(polls: 1))
        #expect(first.outcomes.dropFirst().first == .accumulated(frames: 30))
        #expect(first.pump.counters.shortReads == 1 && first.pump.counters.earlyEnds == 1)
        #expect(first.pump.counters.retriesScheduled == 1 && first.pump.counters.framesDelivered == 84)
    }

    @Test
    func io2PumpSeededSessionKeepsItsInvariantsAndReplaysExactly() throws {
        let first = try Self.seededSession(seed: 0x2F6E_2B1A_9C3D_5E47)
        let second = try Self.seededSession(seed: 0x2F6E_2B1A_9C3D_5E47)
        #expect(first == second)
        #expect(first.log.count == 2_000)
        #expect(first.deliveredFrames == first.pump.counters.framesDelivered)
        let counters = first.pump.counters
        #expect(counters.blocksDelivered > 10)
        #expect(counters.retriesScheduled > 0)
        #expect(counters.stalls > 0)
        #expect(counters.faultsLatched > 0)
        #expect(counters.staleCompletions > 0)
        #expect(counters.shortReads > 0)
        #expect(counters.framesSkipped > 0)
        #expect(counters.earlyEnds > 0)
        let other = try Self.seededSession(seed: 0x0123_4567_89AB_CDEF)
        #expect(other.log != first.log)
    }

    private static func readyPoll(_ frames: Int) -> MediaReadPoll {
        .ready(MediaReadResult(frames: frames, reachedEnd: false))
    }

    /// Drives one pump with a seeded mix of scripted reads, position moves, locates and resumes; checks the
    /// invariants after every step and returns the log of every outcome.
    private static func seededSession(seed: UInt64) throws -> Io2SessionResult {
        var rng = Io2SeededLcg(seed: seed)
        var result = Io2SessionResult(pump: try pump(source: 2_000))
        var reader = ScriptedMediaReader(script: try MediaReadScript(steps: []))
        var position: Int64 = 0
        var abandoned: PrefetchFillTicket?
        let lease = try Self.lease()
        for index in 0..<2_000 {
            let before = result.pump
            let action = rng.next(below: 20)
            var entry = "\(index)"
            if action < 8 {
                let step = try result.pump.nextRequest(position: position, residentBlocks: rng.next(below: 5))
                entry += ":\(step)"
            } else if action < 17, let ticket = result.pump.inFlight {
                if reader.remainingSteps == 0 {
                    let burst = [MediaReadStep](repeating: .pending, count: 9)
                    reader = ScriptedMediaReader(script: try MediaReadScript(steps: burst + (0..<247).map { _ in
                        randomStep(&rng)
                    }))
                }
                let outcome = try complete(&result.pump, ticket, &reader, lease: lease)
                if let block = delivery(outcome)?.block { result.deliveredFrames += UInt64(block.frames) }
                entry += ":\(outcome)"
            } else if action == 17 {
                position = min(position + Int64(rng.next(below: 40)), 2_000)
                if let late = abandoned, let outcome = try? result.pump.receive(late.id, readyPoll(1)) {
                    entry += ":\(outcome)"
                    abandoned = nil
                }
            } else if action == 18 {
                let frame = Int64(rng.next(below: 2_001))
                abandoned = result.pump.inFlight ?? abandoned
                try result.pump.locate(to: frame)
                position = frame
            } else if case .failed = result.pump.state {
                try result.pump.resume(sourceGeneration: result.pump.sourceGeneration + 1, position: position)
            }
            result.log.append(entry)
            let pump = result.pump
            #expect(zip(before.counters.values, pump.counters.values).allSatisfy { $0 <= $1 })
            #expect(pump.nextFrame >= 0 && pump.nextFrame <= pump.sourceFrames)
            #expect((pump.inFlight != nil) == (pump.state == .awaitingCompletion))
        }
        return result
    }

    private static func randomStep(_ rng: inout Io2SeededLcg) -> MediaReadStep {
        switch rng.next(below: 16) {
        case 0, 1, 2, 3: .pending
        case 4: .fail(.ioFailure)
        case 5: .fail(.interrupted)
        case 6: .ready(frames: 0)
        case 7: .readyAtEnd(frames: 17)
        case 8: .ready(frames: 70)
        case 9: .fail(.unavailable)
        case 10, 11: .ready(frames: 17)
        default: .ready(frames: 64)
        }
    }

    /// Reads once for `ticket`; a worker result the pump refuses becomes an `ioFailure`, after proving the refusal
    /// changed nothing.
    private static func complete(
        _ pump: inout PrefetchFillPump,
        _ ticket: PrefetchFillTicket,
        _ reader: inout ScriptedMediaReader,
        lease: MediaBlockLease
    ) throws -> PrefetchFillOutcome {
        let request = try ticket.readRequest(lease: lease)
        do {
            let poll = try reader.read(request)
            if case .ready(let result) = poll, !(0...ticket.frames).contains(result.frames) {
                expectRefusal(&pump, .deliveredFramesOutOfRange(delivered: result.frames, requested: ticket.frames)) {
                    try $0.receive(ticket.id, poll)
                }
                return try pump.fail(ticket.id, .ioFailure)
            }
            return try pump.receive(ticket.id, poll)
        } catch let fault as MediaReadFault {
            return try pump.fail(ticket.id, fault)
        }
    }
}
