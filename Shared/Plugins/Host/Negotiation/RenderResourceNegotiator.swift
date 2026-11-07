/// The pure checks of a render negotiation; `negotiate` (in `NegotiatedRender.swift`) is the only way to a result.
///
/// The plugin's descriptor reports its DEFAULT bus layout and this layer negotiates only that layout (each bus enabled
/// or disabled), so bus counts and channel counts must EQUAL the reported ones, disabled buses included. Channel
/// layout alternatives, bus-count changes beyond the reported layout and MIDI flags are not negotiated. All inputs are
/// immutable values: a refusal changes nothing. Checks, first failure wins: format, sample rate, frames, input bus
/// count, output bus count, input channels in ascending bus index, output channels in ascending bus index.
enum RenderResourceNegotiator {
    static func check(
        _ proposal: RenderResourceSpec, layout: PluginBusLayout, capabilities: HostedRenderCapabilities
    ) throws(NegotiationRefusal) {
        guard capabilities.formats.contains(proposal.format) else { throw .formatUnsupported(proposal.format) }
        guard (capabilities.minimumSampleRateHz...capabilities.maximumSampleRateHz).contains(proposal.sampleRateHz)
        else { throw .sampleRateUnsupported(rateHz: proposal.sampleRateHz) }
        guard proposal.maximumFrames <= capabilities.maximumFramesToRender else {
            throw .framesExceedPlugin(requested: proposal.maximumFrames, supported: capabilities.maximumFramesToRender)
        }
        try checkCounts(.input, proposal.inputs, reported: layout.inputChannels)
        try checkCounts(.output, proposal.outputs, reported: layout.outputChannels)
        try checkChannels(.input, proposal.inputs, reported: layout.inputChannels)
        try checkChannels(.output, proposal.outputs, reported: layout.outputChannels)
    }

    private static func checkCounts(
        _ direction: PluginBusDirection, _ buses: [RenderBusSpec], reported: [Int]
    ) throws(NegotiationRefusal) {
        guard buses.count == reported.count else {
            throw .busCountMismatch(direction, requested: buses.count, reported: reported.count)
        }
    }

    private static func checkChannels(
        _ direction: PluginBusDirection, _ buses: [RenderBusSpec], reported: [Int]
    ) throws(NegotiationRefusal) {
        for (bus, pair) in zip(buses, reported).enumerated() where pair.0.channels != pair.1 {
            throw .channelMismatch(direction, bus: bus, requested: pair.0.channels, reported: pair.1)
        }
    }
}
