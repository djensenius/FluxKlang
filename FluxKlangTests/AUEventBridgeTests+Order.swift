import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AUEventBridgeTests {
    private func firstReason(_ decision: BridgeBatchDecision) throws -> BridgeEventRefusal {
        try #require(decision.rejected.first).reason
    }

    @Test func anInvalidBlockOutranksAStaleSpecAndAStaleEvent() throws {
        let render = try Self.negotiated(at: try Self.generation(2, 1, 1))
        let both = try Self.event(600, planned: try Self.generation(1, 1, 2))
        let decision = try Self.validate([both], block: 0, negotiated: render)
        #expect(try firstReason(decision) == .invalidBlock(0))
        #expect(decision.accepted.isEmpty)
    }

    @Test func anOversizedBlockOutranksAStaleSpecAndAStaleEvent() throws {
        let render = try Self.negotiated(frames: 512, at: try Self.generation(2, 1, 1))
        let both = try Self.event(600, planned: try Self.generation(1, 1, 2))
        let decision = try Self.validate([both], block: 513, negotiated: render)
        #expect(try firstReason(decision) == .blockExceedsNegotiated(blockFrames: 513, maximumFrames: 512))
    }

    @Test func aStaleSpecOutranksAStaleEvent() throws {
        let render = try Self.negotiated(at: try Self.generation(2, 1, 1))
        let stale = try Self.event(5, planned: try Self.generation(1, 3, 1))
        let decision = try Self.validate([stale], negotiated: render)
        #expect(try firstReason(decision) == .negotiationStale([.resources]))
    }

    @Test func aStaleEventOutranksAnOffsetBeyondTheBlock() throws {
        let both = try Self.event(600, planned: try Self.generation(1, 1, 2))
        let decision = try Self.validate([both])
        #expect(try firstReason(decision) == .stale([.latency]))
    }

    @Test func anOffsetBeyondTheBlockOutranksAnUnsupportedPacket() throws {
        let both = try Self.event(600, .midi(try Self.packet(.utility)))
        let decision = try Self.validate([both])
        #expect(try firstReason(decision) == .offsetBeyondBlock(offset: 600, blockFrames: 512))
    }

    @Test func eachEventIsJudgedByItsOwnFirstDefectInBothInputOrders() throws {
        let staleAndBeyond = try Self.event(600, planned: try Self.generation(1, 2, 1))
        let beyondAndUnsupported = try Self.event(700, .midi(try Self.packet(.stream)))
        let unsupported = try Self.event(1, .midi(try Self.packet(.flexData)))
        let expected = [
            RejectedBridgeEvent(index: 0, reason: .stale([.sampleRate])),
            RejectedBridgeEvent(index: 1, reason: .offsetBeyondBlock(offset: 700, blockFrames: 512)),
            RejectedBridgeEvent(index: 2, reason: .unsupportedPacket(.flexData))
        ]
        let forward = try Self.validate([staleAndBeyond, beyondAndUnsupported, unsupported])
        #expect(forward.rejected == expected)
        let backward = try Self.validate([unsupported, beyondAndUnsupported, staleAndBeyond])
        #expect(backward.rejected == [
            RejectedBridgeEvent(index: 0, reason: .unsupportedPacket(.flexData)),
            RejectedBridgeEvent(index: 1, reason: .offsetBeyondBlock(offset: 700, blockFrames: 512)),
            RejectedBridgeEvent(index: 2, reason: .stale([.sampleRate]))
        ])
        #expect(forward.accepted.isEmpty && backward.accepted.isEmpty)
    }

    @Test func staleAxesAreReportedInResourcesSampleRateLatencyOrder() throws {
        let planned = try Self.generation(2, 2, 2)
        let midi = try Self.validate([try Self.event(0, planned: planned)])
        #expect(try firstReason(midi) == .stale([.resources, .sampleRate, .latency]))
        let ramp = try Self.validate([try Self.rampEvent(0, planned: planned)])
        #expect(try firstReason(ramp) == .stale([.resources, .sampleRate]))
        let render = try Self.negotiated(at: planned)
        let spec = try Self.validate([try Self.event(0)], negotiated: render)
        #expect(try firstReason(spec) == .negotiationStale([.resources, .sampleRate]))
    }

    @Test func acceptedEventsAreOrderedByOffsetWhateverTheInputOrder() throws {
        let events = [
            try Self.event(30, .midi(Self.note(1))), try Self.event(10, .midi(Self.note(2))),
            try Self.event(20, .midi(Self.note(3))), try Self.event(0, .midi(Self.note(4)))
        ]
        let sorted = [events[3], events[1], events[2], events[0]]
        #expect(try Self.validate(events).accepted == sorted)
        #expect(try Self.validate(events.reversed()).accepted == sorted)
        #expect(try Self.validate([events[2], events[0], events[3], events[1]]).accepted == sorted)
    }

    @Test func equalOffsetsKeepTheirInputOrder() throws {
        let first = try Self.event(5, .midi(Self.note(60)))
        let second = try Self.event(5, .midi(Self.note(61)))
        let third = try Self.event(5, .ramp(try Self.ramp(parameter: 3)))
        let early = try Self.event(2, .midi(Self.note(62)))
        #expect(try Self.validate([first, second, third, early]).accepted == [early, first, second, third])
        #expect(try Self.validate([third, second, early, first]).accepted == [early, third, second, first])
        #expect(try Self.validate([second, early, first, third]).accepted == [early, second, first, third])
    }

    @Test func rejectedEventsAreListedInAscendingInputIndexWhateverTheirOffsets() throws {
        let events = [
            try Self.event(900), try Self.event(1), try Self.event(700), try Self.event(600), try Self.event(2)
        ]
        let decision = try Self.validate(events)
        #expect(decision.rejected.map(\.index) == [0, 2, 3])
        #expect(decision.accepted == [events[1], events[4]])
    }

    @Test func aLargeShuffledBatchOfDistinctOffsetsGivesTheSameOrderEveryTime() throws {
        let events = try (0..<200).map { try Self.event(($0 * 37) % 200, .midi(Self.note(UInt8($0 % 100)))) }
        let expected = events.sorted { $0.frameOffset < $1.frameOffset }
        #expect(try Self.validate(events).accepted == expected)
        #expect(try Self.validate(events.reversed()).accepted == expected)
        #expect(expected.map(\.frameOffset) == Array(0..<200))
    }
}
