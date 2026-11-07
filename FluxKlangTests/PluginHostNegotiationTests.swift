import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Host-neutral render resource negotiation, dispatch guard and bounded reprepare-or-silence policy (#71/#72/#73).
/// Topic files: Spec, Negotiation, Generations, Dispatch, Reprepare. Every bound is restated here as a literal.
@Suite("PluginHostNegotiationTests")
struct PluginHostNegotiationTests {
    /// Builds buses from channel counts; every index in `disabled` becomes a disabled bus.
    static func buses(_ channels: [Int], disabled: [Int] = []) throws -> [RenderBusSpec] {
        var result: [RenderBusSpec] = []
        for (index, count) in channels.enumerated() {
            result.append(try RenderBusSpec(channels: count, isEnabled: !disabled.contains(index)))
        }
        return result
    }

    static func makeSpec(
        rate: Int = 48_000, frames: Int = 512, format: RenderSampleFormat = .float32,
        inputs: [RenderBusSpec]? = nil, outputs: [RenderBusSpec]? = nil
    ) throws -> RenderResourceSpec {
        try RenderResourceSpec(
            sampleRateHz: rate, maximumFrames: frames, format: format,
            inputs: try inputs ?? buses([2]), outputs: try outputs ?? buses([2]))
    }

    static func makeCaps(
        frames: Int = 16_384, minRate: Int = 8_000, maxRate: Int = 384_000,
        formats: [RenderSampleFormat] = [.float32, .float64]
    ) throws -> HostedRenderCapabilities {
        try HostedRenderCapabilities(
            maximumFramesToRender: frames, minimumSampleRateHz: minRate, maximumSampleRateHz: maxRate,
            formats: formats)
    }

    static func makeLayout(
        inputs: [Int] = [2], outputs: [Int] = [2], midi: Bool = false
    ) throws -> PluginBusLayout {
        try PluginBusLayout(
            inputChannels: inputs, outputChannels: outputs, acceptsMIDI: midi, producesMIDI: midi)
    }

    static func makeGeneration(_ resources: Int = 1, _ sampleRate: Int = 1, _ latency: Int = 1) throws
        -> CapabilityGeneration {
        CapabilityGeneration(
            resources: try Generation(resources), sampleRate: try Generation(sampleRate),
            latency: try Generation(latency))
    }

    /// Negotiates with the default plugin (stereo in, stereo out, both formats, 16_384 frames, all rates).
    static func negotiated(
        _ proposal: RenderResourceSpec? = nil, generation: CapabilityGeneration = .initial
    ) throws -> NegotiatedRender {
        try RenderResourceNegotiator.negotiate(
            try proposal ?? makeSpec(), layout: makeLayout(), capabilities: makeCaps(), generation: generation)
    }

    static func request(
        _ frames: Int, stamp: CapabilityGeneration = .initial, inputs: Int = 1, outputs: Int = 1
    ) -> DispatchRequest {
        DispatchRequest(frames: frames, stamp: stamp, inputBuses: inputs, outputBuses: outputs)
    }

    /// The default plugin negotiated at 16_384 frames, the shape most dispatch tests use.
    static func negotiatedMaximum(generation: CapabilityGeneration = .initial) throws -> NegotiatedRender {
        try negotiated(makeSpec(frames: 16_384), generation: generation)
    }
}
