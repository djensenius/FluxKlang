import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginHostNegotiationTests {
    @Test("dispatch frames table gives the exact decision at every boundary")
    func dispatchFramesTable() throws {
        let negotiated = try Self.negotiatedMaximum()
        let table: [(frames: Int, decision: DispatchDecision)] = [
            (0, .idle),
            (1, .dispatch(frames: 1)),
            (16_383, .dispatch(frames: 16_383)),
            (16_384, .dispatch(frames: 16_384)),
            (16_385, .silence(.oversizedCallback(frames: 16_385, maximum: 16_384))),
            (Int.max, .silence(.oversizedCallback(frames: Int.max, maximum: 16_384))),
            (-1, .silence(.invalidFrameCount(-1))),
            (Int.min, .silence(.invalidFrameCount(Int.min)))
        ]
        for row in table {
            let decision = DispatchGuard.decide(Self.request(row.frames), negotiated: negotiated, live: .initial)
            #expect(decision == row.decision)
        }
    }

    @Test("dispatch stale resources generation silences with staleResources")
    func dispatchStaleResourcesSilences() throws {
        let negotiated = try Self.negotiatedMaximum()
        let live = try CapabilityGeneration.initial.advancing(.resources)
        #expect(DispatchGuard.decide(Self.request(64), negotiated: negotiated, live: live) == .silence(.staleResources))
    }

    @Test("dispatch stale sample rate generation silences with staleSampleRate")
    func dispatchStaleSampleRateSilences() throws {
        let negotiated = try Self.negotiatedMaximum()
        let live = try CapabilityGeneration.initial.advancing(.sampleRate)
        let decision = DispatchGuard.decide(Self.request(64), negotiated: negotiated, live: live)
        #expect(decision == .silence(.staleSampleRate))
    }

    @Test("dispatch silences when the negotiated generation is stale even if the callback stamp is current")
    func dispatchStaleNegotiationWithCurrentStampSilences() throws {
        let negotiated = try Self.negotiatedMaximum()
        let liveResources = try CapabilityGeneration.initial.advancing(.resources)
        let first = DispatchGuard.decide(
            Self.request(64, stamp: liveResources), negotiated: negotiated, live: liveResources)
        #expect(first == .silence(.staleResources))
        let liveRate = try CapabilityGeneration.initial.advancing(.sampleRate)
        let second = DispatchGuard.decide(Self.request(64, stamp: liveRate), negotiated: negotiated, live: liveRate)
        #expect(second == .silence(.staleSampleRate))
    }

    @Test("dispatch silences a callback whose own stamp is stale even when the negotiation is current")
    func dispatchStaleRequestStampSilences() throws {
        let negotiated = try Self.negotiatedMaximum()
        let staleResources = try CapabilityGeneration.initial.advancing(.resources)
        let staleRate = try CapabilityGeneration.initial.advancing(.sampleRate)
        let staleLatency = try CapabilityGeneration.initial.advancing(.latency)
        let one = Self.request(64, stamp: staleResources)
        #expect(DispatchGuard.decide(one, negotiated: negotiated, live: .initial) == .silence(.staleResources))
        let two = Self.request(64, stamp: staleRate)
        #expect(DispatchGuard.decide(two, negotiated: negotiated, live: .initial) == .silence(.staleSampleRate))
        let three = Self.request(64, stamp: staleLatency)
        #expect(DispatchGuard.decide(three, negotiated: negotiated, live: .initial) == .dispatch(frames: 64))
    }

    @Test("dispatch still renders after a latency only change")
    func dispatchLatencyChangeStillDispatches() throws {
        let negotiated = try Self.negotiatedMaximum()
        let live = try CapabilityGeneration.initial.advancing(.latency)
        #expect(DispatchGuard.decide(Self.request(64), negotiated: negotiated, live: live) == .dispatch(frames: 64))
        #expect(DispatchGuard.decide(Self.request(0), negotiated: negotiated, live: live) == .idle)
    }

    @Test("dispatch bus shape must match the enabled buses one fewer or one more is silenced")
    func dispatchBusShapeBoundaries() throws {
        let negotiated = try Self.negotiatedMaximum()
        let shapes: [(inputs: Int, outputs: Int)] = [(0, 1), (2, 1), (1, 0), (1, 2)]
        let matching = DispatchGuard.decide(
            Self.request(64, inputs: 1, outputs: 1), negotiated: negotiated, live: .initial)
        #expect(matching == .dispatch(frames: 64))
        for shape in shapes {
            let decision = DispatchGuard.decide(
                Self.request(64, inputs: shape.inputs, outputs: shape.outputs), negotiated: negotiated, live: .initial)
            #expect(decision == .silence(.busShapeMismatch(inputs: shape.inputs, outputs: shape.outputs)))
        }
    }

    @Test("dispatch bus shape counts only enabled buses of the negotiated spec")
    func dispatchBusShapeCountsOnlyEnabledBuses() throws {
        let spec = try Self.makeSpec(
            frames: 256, inputs: Self.buses([2, 2], disabled: [1]), outputs: Self.buses([2, 2, 2], disabled: [0, 2]))
        let layout = try Self.makeLayout(inputs: [2, 2], outputs: [2, 2, 2])
        let negotiated = try RenderResourceNegotiator.negotiate(
            spec, layout: layout, capabilities: Self.makeCaps(), generation: .initial)
        #expect(DispatchGuard.decide(Self.request(8), negotiated: negotiated, live: .initial) == .dispatch(frames: 8))
        let total = DispatchGuard.decide(
            Self.request(8, inputs: 2, outputs: 3), negotiated: negotiated, live: .initial)
        #expect(total == .silence(.busShapeMismatch(inputs: 2, outputs: 3)))
        let instrument = try Self.makeSpec(frames: 256, inputs: [], outputs: Self.buses([2]))
        let instrumentNegotiated = try RenderResourceNegotiator.negotiate(
            instrument, layout: Self.makeLayout(inputs: [], outputs: [2]), capabilities: Self.makeCaps(),
            generation: .initial)
        let noInput = DispatchGuard.decide(
            Self.request(8, inputs: 0, outputs: 1), negotiated: instrumentNegotiated, live: .initial)
        #expect(noInput == .dispatch(frames: 8))
    }

    @Test("dispatch precedence: negative frames beat a stale generation")
    func dispatchPrecedenceNegativeFramesBeatStale() throws {
        let live = try CapabilityGeneration.initial.advancing(.resources)
        let decision = DispatchGuard.decide(Self.request(-1), negotiated: try Self.negotiatedMaximum(), live: live)
        #expect(decision == .silence(.invalidFrameCount(-1)))
    }

    @Test("dispatch precedence: stale resources beat a stale sample rate")
    func dispatchPrecedenceResourcesBeatSampleRate() throws {
        let live = try CapabilityGeneration.initial.advancing(.resources).advancing(.sampleRate)
        let decision = DispatchGuard.decide(Self.request(64), negotiated: try Self.negotiatedMaximum(), live: live)
        #expect(decision == .silence(.staleResources))
    }

    @Test("dispatch precedence: a stale sample rate beats a bus shape mismatch")
    func dispatchPrecedenceSampleRateBeatsBusShape() throws {
        let live = try CapabilityGeneration.initial.advancing(.sampleRate)
        let decision = DispatchGuard.decide(
            Self.request(64, inputs: 5, outputs: 5), negotiated: try Self.negotiatedMaximum(), live: live)
        #expect(decision == .silence(.staleSampleRate))
    }

    @Test("dispatch precedence: a bus shape mismatch beats an oversized callback")
    func dispatchPrecedenceBusShapeBeatsOversize() throws {
        let decision = DispatchGuard.decide(
            Self.request(16_385, inputs: 5, outputs: 1), negotiated: try Self.negotiatedMaximum(), live: .initial)
        #expect(decision == .silence(.busShapeMismatch(inputs: 5, outputs: 1)))
    }

    @Test("dispatch precedence: stale generation and bus mismatch silence even a zero frame callback")
    func dispatchPrecedenceStalenessBeatsIdle() throws {
        let negotiated = try Self.negotiatedMaximum()
        let live = try CapabilityGeneration.initial.advancing(.resources)
        #expect(DispatchGuard.decide(Self.request(0), negotiated: negotiated, live: live) == .silence(.staleResources))
        let sampleRate = try CapabilityGeneration.initial.advancing(.sampleRate)
        #expect(DispatchGuard.decide(Self.request(0), negotiated: negotiated, live: sampleRate)
            == .silence(.staleSampleRate))
        #expect(DispatchGuard.decide(Self.request(0, inputs: 0), negotiated: negotiated, live: .initial)
            == .silence(.busShapeMismatch(inputs: 0, outputs: 1)))
    }

    @Test("dispatch with the fake processor drops oversized blocks and never goes out of bounds")
    func dispatchFakeProcessorNeverGoesOutOfBounds() throws {
        let negotiated = try Self.negotiatedMaximum()
        var fake = FakeHostedProcessor(capabilities: try Self.makeCaps(), layout: try Self.makeLayout(), script: [])
        for frames in [64, 128, 16_384, 16_385, 0, 32] {
            let decision = DispatchGuard.decide(Self.request(frames), negotiated: negotiated, live: .initial)
            fake.dispatch(decision, negotiated: negotiated)
        }
        #expect(fake.dispatchedFrames == [64, 128, 16_384, 32])
        #expect(fake.outOfBoundsAttempts == 0)
        #expect(fake.silencedCalls == 1)
        #expect(fake.idleCalls == 1)
        #expect(fake.droppedCalls == 0)
    }

    @Test("dispatch control: an unguarded oversized block is counted as an out of bounds attempt")
    func dispatchControlUnguardedOversizedBlockIsDetected() throws {
        let negotiated = try Self.negotiatedMaximum()
        var fake = FakeHostedProcessor(capabilities: try Self.makeCaps(), layout: try Self.makeLayout(), script: [])
        fake.dispatch(.dispatch(frames: 16_385), negotiated: negotiated)
        fake.dispatch(.dispatch(frames: -1), negotiated: negotiated)
        fake.dispatch(.dispatch(frames: 16_384), negotiated: negotiated)
        #expect(fake.outOfBoundsAttempts == 2)
        #expect(fake.dispatchedFrames == [16_385, -1, 16_384])
    }

    @Test("dispatch fake script refusal is returned once and then every negotiation is accepted")
    func dispatchFakeScriptRefusalIsReturnedOnce() throws {
        let refusal = NegotiationRefusal.formatUnsupported(.float64)
        var fake = FakeHostedProcessor(
            capabilities: try Self.makeCaps(), layout: try Self.makeLayout(), script: [.refuse(refusal), .accept])
        let proposal = try Self.makeSpec()
        #expect(throws: refusal) { try fake.negotiate(proposal, generation: .initial) }
        #expect(try fake.negotiate(proposal, generation: .initial).spec == proposal)
        #expect(try fake.negotiate(proposal, generation: .initial).spec == proposal)
    }

    @Test("dispatch fake accepted steps still apply the real negotiation checks")
    func dispatchFakeAcceptStillNegotiatesForReal() throws {
        var fake = FakeHostedProcessor(
            capabilities: try Self.makeCaps(frames: 256), layout: try Self.makeLayout(), script: [])
        let oversized = try Self.makeSpec(frames: 512)
        #expect(throws: NegotiationRefusal.framesExceedPlugin(requested: 512, supported: 256)) {
            try fake.negotiate(oversized, generation: .initial)
        }
    }

    @Test("dispatch fake record keeps 256 block sizes and counts the 257th as dropped")
    func dispatchFakeRecordIsBounded() throws {
        let negotiated = try Self.negotiatedMaximum()
        var fake = FakeHostedProcessor(capabilities: try Self.makeCaps(), layout: try Self.makeLayout(), script: [])
        for _ in 0..<256 { fake.dispatch(.dispatch(frames: 8), negotiated: negotiated) }
        #expect(fake.dispatchedFrames.count == 256)
        #expect(fake.droppedCalls == 0)
        fake.dispatch(.dispatch(frames: 8), negotiated: negotiated)
        #expect(fake.dispatchedFrames.count == 256)
        #expect(fake.droppedCalls == 1)
        fake.dispatch(.dispatch(frames: 99_999), negotiated: negotiated)
        #expect(fake.droppedCalls == 2)
        #expect(fake.outOfBoundsAttempts == 1)
    }
}
