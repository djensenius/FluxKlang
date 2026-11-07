import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AUEventBridgeTests {
    @Test func aRampDurationOfOneAndTwoToThe31MinusOneAreAcceptedAndOthersRefused() throws {
        #expect(try Self.ramp(frames: 1).durationFrames == 1)
        #expect(try Self.ramp(frames: 2_147_483_647).durationFrames == 2_147_483_647)
        #expect(BridgeParameterRamp.maximumDurationFrames == 2_147_483_647)
        for bad in [0, -1, 2_147_483_648, Int.max, Int.min] {
            #expect(throws: BridgeRampRefusal.invalidDuration(bad)) { try Self.ramp(frames: bad) }
        }
    }

    @Test func aRampTargetMustBeFinite() throws {
        for bad in [Float.nan, Float.infinity, -Float.infinity, Float.signalingNaN] {
            #expect(throws: BridgeRampRefusal.nonFiniteTarget) { try Self.ramp(target: bad) }
        }
        let finite: [Float] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0, -0.0, .leastNonzeroMagnitude]
        for good in finite {
            #expect(try Self.ramp(target: good).target == good)
        }
    }

    @Test func aRampWithBothDefectsReportsTheDurationFirst() throws {
        #expect(throws: BridgeRampRefusal.invalidDuration(0)) { try Self.ramp(target: .nan, frames: 0) }
        #expect(throws: BridgeRampRefusal.invalidDuration(2_147_483_648)) {
            try Self.ramp(target: .infinity, frames: 2_147_483_648)
        }
    }

    @Test func aRampKeepsEveryParameterAddressAndItsTarget() throws {
        for address in [UInt64.zero, 1, UInt64.max, 0x8000_0000_0000_0000] {
            let built = try Self.ramp(parameter: address, target: -3.25, frames: 17)
            #expect(built.parameter == address)
            #expect(built.target == -3.25)
            #expect(built.durationFrames == 17)
        }
    }

    @Test func aRampLongerThanTheBlockIsAcceptedAtItsOffset() throws {
        let long = try Self.event(511, .ramp(try Self.ramp(frames: 2_147_483_647)))
        let decision = try Self.validate([long])
        #expect(decision.accepted == [long])
        #expect(decision.rejected.isEmpty)
    }

    @Test func aRampBindsTheResourcesAndSampleRateAxesAndIgnoresLatency() throws {
        let cases: [(CapabilityGeneration, BridgeEventRefusal?)] = [
            (try Self.generation(1, 1, 7), nil),
            (try Self.generation(2, 1, 1), .stale([.resources])),
            (try Self.generation(1, 2, 1), .stale([.sampleRate])),
            (try Self.generation(3, 4, 1), .stale([.resources, .sampleRate])),
            (try Self.generation(3, 4, 5), .stale([.resources, .sampleRate]))
        ]
        for (planned, expected) in cases {
            let ramp = try Self.rampEvent(4, planned: planned)
            let decision = try Self.validate([ramp])
            if let expected {
                #expect(decision.accepted.isEmpty)
                #expect(decision.rejected == [RejectedBridgeEvent(index: 0, reason: expected)])
            } else {
                #expect(decision.accepted == [ramp])
                #expect(decision.rejected.isEmpty)
            }
        }
    }

    @Test func aSampleRateChangeAloneAlwaysRejectsARampWhateverTheResources() throws {
        let live = try Self.generation(1, 2, 1)
        let render = try Self.negotiated(at: live)
        let stale = try Self.rampEvent(0)
        let fresh = try Self.rampEvent(0, planned: live)
        let decision = try Self.validate([stale, fresh], live: live, negotiated: render)
        #expect(decision.accepted == [fresh])
        #expect(decision.rejected == [RejectedBridgeEvent(index: 0, reason: .stale([.sampleRate]))])
    }

    @Test func aMidiEventBindsAllThreeAxesIncludingLatency() throws {
        let cases: [(CapabilityGeneration, [CapabilityAxis])] = [
            (try Self.generation(1, 1, 2), [.latency]),
            (try Self.generation(2, 1, 1), [.resources]),
            (try Self.generation(1, 2, 1), [.sampleRate]),
            (try Self.generation(1, 2, 3), [.sampleRate, .latency]),
            (try Self.generation(4, 1, 3), [.resources, .latency])
        ]
        for (planned, axes) in cases {
            let decision = try Self.validate([try Self.event(0, planned: planned)])
            #expect(decision.accepted.isEmpty)
            #expect(decision.rejected == [RejectedBridgeEvent(index: 0, reason: .stale(axes))])
        }
    }

    @Test func aRampOfAnOldGenerationIsRejectedBesideAFreshMidiEvent() throws {
        let live = try Self.generation(2, 1, 1)
        let render = try Self.negotiated(at: live)
        let note = try Self.event(9, planned: live)
        let oldRamp = try Self.rampEvent(3)
        let decision = try Self.validate([oldRamp, note], live: live, negotiated: render)
        #expect(decision.accepted == [note])
        #expect(decision.rejected == [RejectedBridgeEvent(index: 0, reason: .stale([.resources]))])
    }
}
