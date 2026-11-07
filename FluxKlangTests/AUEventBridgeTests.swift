import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// AU event and parameter bridge generation guards (#73, slice PLG3). Topic files: Events, Ramps, Latency, Order.
/// Every bound is restated here as a literal; fixtures are pure values (no AudioToolbox, no plugin).
@Suite("AUEventBridgeTests")
struct AUEventBridgeTests {
    static func generation(_ resources: Int = 1, _ sampleRate: Int = 1, _ latency: Int = 1) throws
        -> CapabilityGeneration {
        CapabilityGeneration(
            resources: try Generation(resources), sampleRate: try Generation(sampleRate),
            latency: try Generation(latency))
    }

    /// Negotiates a stereo-in, stereo-out spec of `frames` at `generation` with a plugin that renders 16,384 frames.
    static func negotiated(
        frames: Int = 512, at generation: CapabilityGeneration = .initial
    ) throws -> NegotiatedRender {
        let stereo = [try RenderBusSpec(channels: 2)]
        let spec = try RenderResourceSpec(
            sampleRateHz: 48_000, maximumFrames: frames, format: .float32, inputs: stereo, outputs: stereo)
        let capabilities = try HostedRenderCapabilities(
            maximumFramesToRender: 16_384, minimumSampleRateHz: 8_000, maximumSampleRateHz: 384_000,
            formats: [.float32, .float64])
        return try RenderResourceNegotiator.negotiate(
            spec, layout: try PluginBusLayout(inputChannels: [2], outputChannels: [2]), capabilities: capabilities,
            generation: generation)
    }

    /// A note-on whose note number is `note`, so two packets with different numbers are told apart.
    static func note(_ note: UInt8 = 60) -> UMPPacket {
        UMPPacket.midi1ChannelVoice(0x0090_0040 | UInt32(note) << 8)
    }

    /// A packet of message type `type`: the type nibble, then zero words up to the type's word count.
    static func packet(_ type: UMPMessageType) throws -> UMPPacket {
        try UMPPacket(words: [UInt32(type.rawValue) << 28] + [UInt32](repeating: 0, count: type.wordCount - 1))
    }

    static func ramp(
        parameter: UInt64 = 7, target: Float = 0.5, frames: Int = 64
    ) throws -> BridgeParameterRamp {
        try BridgeParameterRamp.make(parameter: parameter, target: target, durationFrames: frames)
    }

    static func event(
        _ offset: Int, _ payload: BridgeEventPayload? = nil, planned: CapabilityGeneration = .initial
    ) throws -> BridgeEvent {
        try BridgeEvent.make(frameOffset: offset, payload: payload ?? .midi(note()), planned: planned)
    }

    static func rampEvent(
        _ offset: Int, planned: CapabilityGeneration = .initial
    ) throws -> BridgeEvent {
        try event(offset, .ramp(try ramp()), planned: planned)
    }

    /// Validates against a render negotiated at `.initial` with 512 frames unless told otherwise.
    static func validate(
        _ events: [BridgeEvent], block: Int = 512, live: CapabilityGeneration = .initial,
        negotiated: NegotiatedRender? = nil
    ) throws -> BridgeBatchDecision {
        try BridgeEventBatch.validate(
            events, against: try negotiated ?? Self.negotiated(), live: live, blockFrames: block)
    }

    @Test func anEventKeepsItsOffsetItsPayloadAndItsPlannedGeneration() throws {
        let planned = try Self.generation(4, 5, 6)
        let built = try Self.event(37, .midi(Self.note(61)), planned: planned)
        #expect(built.frameOffset == 37)
        #expect(built.payload == .midi(Self.note(61)))
        #expect(built.planned == planned)
        let rampPayload = BridgeEventPayload.ramp(try Self.ramp(parameter: 9, target: -2, frames: 5))
        #expect(try Self.event(0, rampPayload).payload == rampPayload)
    }

    @Test func aNegativeOffsetIsRefusedAtConstructionAndZeroIsAccepted() throws {
        #expect(try Self.event(0).frameOffset == 0)
        #expect(throws: BridgeEventRefusal.negativeOffset(-1)) { try Self.event(-1) }
        #expect(throws: BridgeEventRefusal.negativeOffset(-300)) { try Self.event(-300) }
        #expect(throws: BridgeEventRefusal.negativeOffset(Int.min)) { try Self.event(Int.min) }
    }

    @Test func anEventAtTheLargestIntOffsetIsBuiltButTheBlockRefusesIt() throws {
        let huge = try Self.event(Int.max)
        let decision = try Self.validate([huge])
        #expect(decision.accepted.isEmpty)
        #expect(decision.rejected == [
            RejectedBridgeEvent(index: 0, reason: .offsetBeyondBlock(offset: Int.max, blockFrames: 512))
        ])
    }
}
