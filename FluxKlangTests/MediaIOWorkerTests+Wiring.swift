import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The pump, a scripted reader, a real pool (for leases only) and the existing playhead working together.
extension MediaIOWorkerTests {
    @Test
    func io2WiringFillsTheHeadAndTheHeadBecomesResident() throws {
        var pump = try Self.pump()
        var playhead = try PrefetchPlayhead.make(plan: Self.plan(), stream: 2, sourceGeneration: 1, readGeneration: 5)
        var reader = ScriptedMediaReader(script: try MediaReadScript(steps: [
            .ready(frames: 64), .pending, .ready(frames: 64)
        ]))
        let pool = try MediaBlockPool.make(plan: Self.plan(), channelCount: 2)
        var resident = 0
        for _ in 0..<3 {
            let step = try pump.nextRequest(position: playhead.position, residentBlocks: resident)
            guard case .request(let ticket) = step else { break }
            let lease = try pool.lease()
            let poll = try reader.read(try ticket.readRequest(lease: lease))
            var outcome = try pump.receive(ticket.id, poll)
            if outcome == .stillPending(polls: 1) {
                outcome = try pump.receive(ticket.id, try reader.read(try ticket.readRequest(lease: lease)))
            }
            if let block = Self.delivery(outcome)?.block {
                #expect(try playhead.insert(block) == .resident)
                resident += 1
            }
        }
        #expect(playhead.isHeadResident && resident == 2 && reader.callCount == 3)
        #expect(try pump.nextRequest(position: 0, residentBlocks: 2) == .wait(.satisfied))
        #expect(pool.statistics.copiesCompleted == 0 && pool.statistics.leasedCount == 2)
    }

    @Test
    func io2WiringSourceLossAndRestoreMapToDiscontinuitiesAndDropResidentBlocks() throws {
        var pump = try Self.pump()
        var playhead = try PrefetchPlayhead.make(plan: Self.plan(), stream: 2, sourceGeneration: 1, readGeneration: 5)
        let (_, first) = try Self.fill(&pump, frames: 64)
        let firstBlock = try #require(Self.delivery(first)?.block)
        #expect(try playhead.insert(firstBlock) == .resident)
        let lost = try Self.failNext(&pump, .unavailable)
        #expect(Self.name(MediaIOFaultMapping.discontinuityKind(for: lost)) == "sourceLost")
        #expect(try pump.nextRequest(position: 64, residentBlocks: 1) == .wait(.failed))
        try pump.resume(sourceGeneration: 2, position: playhead.position)
        #expect(try playhead.adoptSourceGeneration(2) == 1)
        let (ticket, restored) = try Self.fill(&pump, frames: 64, position: playhead.position)
        let delivery = try #require(Self.delivery(restored))
        #expect(ticket.sourceGeneration == 2 && ticket.startFrame == 0)
        #expect(Self.name(MediaIOFaultMapping.discontinuityKind(for: restored)) == "sourceRestored")
        #expect(try playhead.insert(delivery.block) == .resident)
    }

    @Test
    func io2WiringFourSixteenFrameReadsCompleteABlockInsteadOfFillingThePool() throws {
        var pump = try Self.pump()
        var playhead = try PrefetchPlayhead.make(plan: Self.plan(), stream: 2, sourceGeneration: 1, readGeneration: 5)
        var ticketFrames: [Int] = []
        var residentAfter: [Int] = []
        for _ in 0..<8 {
            let ticket = try Self.issue(&pump, position: playhead.position, resident: playhead.blocks.count)
            ticketFrames.append(ticket.frames)
            let outcome = try pump.receive(ticket.id, .ready(MediaReadResult(frames: 16, reachedEnd: false)))
            if let block = Self.delivery(outcome)?.block {
                #expect(try playhead.insert(block) == .resident)
            }
            residentAfter.append(playhead.blocks.count)
        }
        #expect(ticketFrames == [64, 48, 32, 16, 64, 48, 32, 16])
        #expect(residentAfter == [0, 0, 0, 1, 1, 1, 1, 2])
        #expect(playhead.isHeadResident && playhead.blocks.map(\.startFrame) == [0, 64])
        #expect(pump.partialBlock == nil && pump.nextFrame == 128 && pump.counters.shortReads == 6)
        #expect(try pump.nextRequest(position: 0, residentBlocks: playhead.blocks.count) == .wait(.satisfied))
    }

    @Test
    func io2WiringShortReadsNeverLetThePoolFillBeforeTheHeadIsResident() throws {
        var pump = try Self.pump()
        var playhead = try PrefetchPlayhead.make(plan: Self.plan(), stream: 2, sourceGeneration: 1, readGeneration: 5)
        var reads = 0
        while !playhead.isHeadResident, reads < 200 {
            reads += 1
            let ticket = try Self.issue(&pump, position: playhead.position, resident: playhead.blocks.count)
            let outcome = try pump.receive(ticket.id, .ready(MediaReadResult(frames: 1, reachedEnd: false)))
            if let block = Self.delivery(outcome)?.block {
                #expect(try playhead.insert(block) == .resident)
            }
            #expect(playhead.blocks.count <= 2)
        }
        #expect(playhead.isHeadResident && reads == 128 && playhead.blocks.count == 2)
    }

    @Test
    func io2WiringRecoveryRefillsFromTheConsumerPositionAfterTheBlocksWereDropped() throws {
        var pump = try Self.pump()
        var playhead = try PrefetchPlayhead.make(plan: Self.plan(), stream: 2, sourceGeneration: 1, readGeneration: 5)
        let (_, first) = try Self.fill(&pump, frames: 64)
        #expect(try playhead.insert(try #require(Self.delivery(first)?.block)) == .resident)
        _ = try Self.failNext(&pump, .unavailable)
        try pump.resume(sourceGeneration: 2, position: playhead.position)
        #expect(try playhead.adoptSourceGeneration(2) == 1)
        #expect(playhead.blocks.isEmpty && !playhead.isHeadResident && pump.nextFrame == 0)
        for expectedStart in [Int64(0), 64] {
            let (ticket, outcome) = try Self.fill(&pump, frames: 64, position: playhead.position)
            #expect(ticket.startFrame == expectedStart && ticket.sourceGeneration == 2)
            #expect(try playhead.insert(try #require(Self.delivery(outcome)?.block)) == .resident)
        }
        #expect(playhead.isHeadResident && playhead.blocks.count == 2)
        #expect(try pump.nextRequest(position: 0, residentBlocks: 2) == .wait(.satisfied))
    }

    @Test
    func io2WiringLocateDiscardsTheOldReadOnBothSides() throws {
        var pump = try Self.pump()
        var playhead = try PrefetchPlayhead.make(plan: Self.plan(), stream: 2, sourceGeneration: 1, readGeneration: 5)
        let (_, outcome) = try Self.fill(&pump, frames: 64)
        let stale = try #require(Self.delivery(outcome)?.block)
        try pump.locate(to: 500)
        try playhead.locate(to: 500)
        #expect(try playhead.insert(stale) == .discardedStale)
        #expect(pump.readGeneration == playhead.readGeneration)
        let next = try Self.issue(&pump, position: 500)
        #expect(next.readGeneration == playhead.readGeneration && next.startFrame == playhead.position)
    }

    private static func headSetup(head: Int) throws -> (PrefetchFillPump, PrefetchPlayhead) {
        let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: 4, headFrames: head)
        let pump = try PrefetchFillPump.make(plan: plan, sourceFrames: 1_000, sourceGeneration: 1,
                                             readGeneration: 5, position: 0)
        return (pump, try PrefetchPlayhead.make(plan: plan, stream: 2, sourceGeneration: 1, readGeneration: 5))
    }

    /// Asks for a ticket against the real playhead, answers it with `frames`, inserts a published block.
    private static func readInto(_ pump: inout PrefetchFillPump, _ playhead: inout PrefetchPlayhead,
                                 frames: Int, reachedEnd: Bool = false) throws -> PrefetchFillOutcome {
        let ticket = try issue(&pump, position: playhead.position, resident: playhead.blocks.count)
        let outcome = try pump.receive(ticket.id, .ready(MediaReadResult(frames: frames, reachedEnd: reachedEnd)))
        if let block = delivery(outcome)?.block {
            #expect(try playhead.insert(block) == .resident)
        }
        return outcome
    }

    @Test
    func io2WiringHeadSmallerThanABlockKeepsRequestingUntilTheBlockIsPublished() throws {
        var (pump, playhead) = try Self.headSetup(head: 1)
        #expect(try Self.readInto(&pump, &playhead, frames: 1) == .accumulated(frames: 1))
        #expect(playhead.blocks.isEmpty && !playhead.isHeadResident)
        let again = try Self.issue(&pump, position: 0, resident: 0)
        #expect(again.startFrame == 1 && again.frames == 63)
        let outcome = try pump.receive(again.id, .ready(MediaReadResult(frames: 63, reachedEnd: false)))
        #expect(try playhead.insert(try #require(Self.delivery(outcome)?.block)) == .resident)
        #expect(playhead.isHeadResident && playhead.blocks.count == 1)
        #expect(try pump.nextRequest(position: 0, residentBlocks: 1) == .wait(.satisfied))
        var ended = try Self.headSetup(head: 1)
        #expect(try Self.readInto(&ended.0, &ended.1, frames: 1) == .accumulated(frames: 1))
        let last = try Self.readInto(&ended.0, &ended.1, frames: 0, reachedEnd: true)
        #expect(Self.delivery(last)?.block.frames == 1 && ended.1.isHeadResident && ended.1.blocks.count == 1)
    }

    @Test
    func io2WiringHeadOfOneHundredIsNotSatisfiedByAPartialBlockThatReachesIt() throws {
        var (pump, playhead) = try Self.headSetup(head: 100)
        _ = try Self.readInto(&pump, &playhead, frames: 64)
        #expect(try Self.readInto(&pump, &playhead, frames: 36) == .accumulated(frames: 36))
        #expect(pump.nextFrame == 100 && playhead.blocks.count == 1 && !playhead.isHeadResident)
        let step = try pump.nextRequest(position: 0, residentBlocks: 1)
        guard case .request(let ticket) = step else {
            Issue.record("expected a request, got \(step)")
            return
        }
        #expect(ticket.startFrame == 100 && ticket.frames == 28)
        let outcome = try pump.receive(ticket.id, .ready(MediaReadResult(frames: 28, reachedEnd: false)))
        #expect(try playhead.insert(try #require(Self.delivery(outcome)?.block)) == .resident)
        #expect(playhead.isHeadResident && playhead.blocks.count == 2)
        #expect(try pump.nextRequest(position: 0, residentBlocks: 2) == .wait(.satisfied))
    }

    @Test
    func io2WiringHeadBoundaryIsSatisfiedAtTheBlockEdgeAndNotOneFrameEarlier() throws {
        for (head, satisfied) in [(64, true), (65, false)] {
            var (pump, playhead) = try Self.headSetup(head: head)
            _ = try Self.readInto(&pump, &playhead, frames: 64)
            #expect(playhead.isHeadResident == satisfied)
            let step = try pump.nextRequest(position: 0, residentBlocks: 1)
            #expect((step == .wait(.satisfied)) == satisfied)
        }
    }
}
