import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AUEventBridgeTests {
    @Test func theOffsetBoundaryAcceptsTheBlockMinusOneAndRefusesTheBlock() throws {
        let first = try Self.event(0)
        let last = try Self.event(99)
        let atBlock = try Self.event(100)
        let beyond = try Self.event(101)
        let decision = try Self.validate([first, last, atBlock, beyond], block: 100)
        #expect(decision.accepted == [first, last])
        #expect(decision.rejected == [
            RejectedBridgeEvent(index: 2, reason: .offsetBeyondBlock(offset: 100, blockFrames: 100)),
            RejectedBridgeEvent(index: 3, reason: .offsetBeyondBlock(offset: 101, blockFrames: 100))
        ])
        let zero = try Self.event(0)
        let single = try Self.validate([zero, try Self.event(1)], block: 1)
        #expect(single.accepted == [zero])
        #expect(single.rejected == [
            RejectedBridgeEvent(index: 1, reason: .offsetBeyondBlock(offset: 1, blockFrames: 1))
        ])
    }

    @Test func aBlockBelowOneRefusesEveryEventAsAnInvalidBlock() throws {
        let events = [try Self.event(0), try Self.event(5)]
        for block in [0, -1, -512] {
            let decision = try Self.validate(events, block: block)
            #expect(decision.accepted.isEmpty)
            #expect(decision.rejected == [
                RejectedBridgeEvent(index: 0, reason: .invalidBlock(block)),
                RejectedBridgeEvent(index: 1, reason: .invalidBlock(block))
            ])
        }
        #expect(try Self.validate(events, block: 1).rejected.count == 1)
    }

    @Test func theBlockMayEqualTheNegotiatedMaximumAndOneMoreIsRefused() throws {
        let render = try Self.negotiated(frames: 300)
        let events = [try Self.event(0), try Self.event(299)]
        let atMaximum = try Self.validate(events, block: 300, negotiated: render)
        #expect(atMaximum.accepted == events)
        #expect(atMaximum.rejected.isEmpty)
        let over = try Self.validate(events, block: 301, negotiated: render)
        #expect(over.accepted.isEmpty)
        #expect(over.rejected == [
            RejectedBridgeEvent(index: 0, reason: .blockExceedsNegotiated(blockFrames: 301, maximumFrames: 300)),
            RejectedBridgeEvent(index: 1, reason: .blockExceedsNegotiated(blockFrames: 301, maximumFrames: 300))
        ])
    }

    @Test func theAbsoluteFrameCeilingIs16384AndOneMoreIsRefused() throws {
        let render = try Self.negotiated(frames: 16_384)
        let tail = try Self.event(16_383)
        let atCeiling = try Self.validate([tail], block: 16_384, negotiated: render)
        #expect(atCeiling.accepted == [tail])
        let over = try Self.validate([tail], block: 16_385, negotiated: render)
        #expect(over.rejected == [
            RejectedBridgeEvent(index: 0, reason: .blockExceedsNegotiated(blockFrames: 16_385, maximumFrames: 16_384))
        ])
        let beyond = try Self.validate([try Self.event(16_384)], block: 16_384, negotiated: render)
        #expect(beyond.rejected == [
            RejectedBridgeEvent(index: 0, reason: .offsetBeyondBlock(offset: 16_384, blockFrames: 16_384))
        ])
    }

    @Test func anEmptyBatchIsLegalWhateverTheBlock() throws {
        for block in [512, 0, -3, 99_999] {
            let decision = try Self.validate([], block: block)
            #expect(decision.accepted.isEmpty)
            #expect(decision.rejected.isEmpty)
        }
    }

    @Test func aBatchOf4096EventsIsAcceptedAndOneMoreRefusesTheWholeBatch() throws {
        let one = try Self.event(3)
        let full = [BridgeEvent](repeating: one, count: 4_096)
        let accepted = try Self.validate(full)
        #expect(accepted.accepted.count == 4_096)
        #expect(accepted.rejected.isEmpty)
        let tooMany = full + [one]
        #expect(throws: BridgeEventRefusal.batchTooLarge(4_097)) { try Self.validate(tooMany) }
        #expect(tooMany.count == 4_097)
    }

    @Test func aTooLargeBatchIsRefusedBeforeTheBlockIsJudged() throws {
        let events = [BridgeEvent](repeating: try Self.event(0), count: 5_000)
        #expect(throws: BridgeEventRefusal.batchTooLarge(5_000)) { try Self.validate(events, block: 0) }
    }

    @Test func aRejectedEventNeverAbortsTheBatch() throws {
        let events = [
            try Self.event(10), try Self.event(600), try Self.event(20),
            try Self.event(5, planned: try Self.generation(2)), try Self.event(30)
        ]
        let decision = try Self.validate(events)
        #expect(decision.accepted == [events[0], events[2], events[4]])
        #expect(decision.rejected == [
            RejectedBridgeEvent(index: 1, reason: .offsetBeyondBlock(offset: 600, blockFrames: 512)),
            RejectedBridgeEvent(index: 3, reason: .stale([.resources]))
        ])
    }

    @Test func onlySystemChannelVoiceAndDataSixtyFourPacketsAreAccepted() throws {
        let allowed: Set<UMPMessageType> = [.system, .midi1ChannelVoice, .data64, .midi2ChannelVoice]
        #expect(UMPMessageType.allCases.count == 16)
        for type in UMPMessageType.allCases {
            let packet = try Self.packet(type)
            let decision = try Self.validate([try Self.event(0, .midi(packet))])
            if allowed.contains(type) {
                #expect(decision.accepted.count == 1, "\(type) must be accepted")
                #expect(decision.rejected.isEmpty)
            } else {
                #expect(decision.accepted.isEmpty, "\(type) must be refused")
                #expect(decision.rejected == [RejectedBridgeEvent(index: 0, reason: .unsupportedPacket(type))])
            }
        }
    }

    @Test func validatingNeverChangesTheInputBatch() throws {
        let events = [try Self.event(900), try Self.event(2, planned: try Self.generation(1, 2)), try Self.event(1)]
        let before = events
        _ = try Self.validate(events)
        _ = try Self.validate(events, block: 0)
        #expect(events == before)
    }

    @Test func aSpecNegotiatedUnderOtherGenerationsRefusesEveryEventAndNamesTheAxes() throws {
        let events = [try Self.event(0), try Self.event(1)]
        let cases: [(CapabilityGeneration, [CapabilityAxis])] = [
            (try Self.generation(2, 1, 1), [.resources]),
            (try Self.generation(1, 3, 1), [.sampleRate]),
            (try Self.generation(5, 4, 9), [.resources, .sampleRate])
        ]
        for (specGeneration, axes) in cases {
            let render = try Self.negotiated(at: specGeneration)
            let decision = try Self.validate(events, negotiated: render)
            #expect(decision.accepted.isEmpty)
            #expect(decision.rejected == [
                RejectedBridgeEvent(index: 0, reason: .negotiationStale(axes)),
                RejectedBridgeEvent(index: 1, reason: .negotiationStale(axes))
            ])
        }
    }

    @Test func aLatencyOnlyDifferenceInTheSpecGenerationDoesNotStaleTheSpec() throws {
        let render = try Self.negotiated(at: try Self.generation(1, 1, 9))
        let decision = try Self.validate([try Self.event(0)], negotiated: render)
        #expect(decision.accepted.count == 1)
        #expect(decision.rejected.isEmpty)
    }

    private struct SpecStalenessCase {
        let spec: (Int, Int)
        let live: (Int, Int)
        let axes: [CapabilityAxis]
    }

    @Test func specStalenessIsExactPerAxisInBothDirections() throws {
        let cases = [
            SpecStalenessCase(spec: (2, 2), live: (2, 2), axes: []),
            SpecStalenessCase(spec: (1, 2), live: (2, 2), axes: [.resources]),
            SpecStalenessCase(spec: (3, 2), live: (2, 2), axes: [.resources]),
            SpecStalenessCase(spec: (2, 1), live: (2, 2), axes: [.sampleRate]),
            SpecStalenessCase(spec: (2, 3), live: (2, 2), axes: [.sampleRate])
        ]
        for item in cases {
            let live = try Self.generation(item.live.0, item.live.1)
            let render = try Self.negotiated(at: try Self.generation(item.spec.0, item.spec.1))
            let decision = try Self.validate([try Self.event(0, planned: live)], live: live, negotiated: render)
            if item.axes.isEmpty {
                #expect(decision.accepted.count == 1)
                #expect(decision.rejected.isEmpty)
            } else {
                #expect(decision.accepted.isEmpty)
                #expect(decision.rejected == [RejectedBridgeEvent(index: 0, reason: .negotiationStale(item.axes))])
            }
        }
    }

    @Test func aStaleSpecRefusesEventsAndRampsPlannedAtTheLiveGeneration() throws {
        let live = try Self.generation(4, 5, 6)
        let render = try Self.negotiated(at: try Self.generation(4, 4, 6))
        let events = [try Self.event(0, planned: live), try Self.rampEvent(1, planned: live)]
        let decision = try Self.validate(events, live: live, negotiated: render)
        #expect(decision.accepted.isEmpty)
        #expect(decision.rejected == [
            RejectedBridgeEvent(index: 0, reason: .negotiationStale([.sampleRate])),
            RejectedBridgeEvent(index: 1, reason: .negotiationStale([.sampleRate]))
        ])
    }

    @Test func aLiveLatencyAheadOfTheSpecStillAcceptsEventsAtTheLiveGeneration() throws {
        let live = try Self.generation(1, 1, 9)
        let render = try Self.negotiated(at: .initial)
        let decision = try Self.validate([try Self.event(0, planned: live)], live: live, negotiated: render)
        #expect(decision.accepted.count == 1)
        #expect(decision.rejected.isEmpty)
    }
}
