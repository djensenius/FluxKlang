/// Why a proposal was refused against what a plugin reports. Values carry counts, indices, direction and format only.
enum NegotiationRefusal: Error, Hashable, Sendable {
    case formatUnsupported(RenderSampleFormat)
    case sampleRateUnsupported(rateHz: Int)
    case framesExceedPlugin(requested: Int, supported: Int)
    case busCountMismatch(PluginBusDirection, requested: Int, reported: Int)
    case channelMismatch(PluginBusDirection, bus: Int, requested: Int, reported: Int)
}
