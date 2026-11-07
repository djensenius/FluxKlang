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
        try pump.resume(sourceGeneration: 2)
        #expect(try playhead.adoptSourceGeneration(2) == 1)
        let (ticket, restored) = try Self.fill(&pump, frames: 64, position: 64)
        let delivery = try #require(Self.delivery(restored))
        #expect(ticket.sourceGeneration == 2 && ticket.startFrame == 64)
        #expect(Self.name(MediaIOFaultMapping.discontinuityKind(for: restored)) == "sourceRestored")
        #expect(try playhead.insert(delivery.block) == .resident)
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
}
