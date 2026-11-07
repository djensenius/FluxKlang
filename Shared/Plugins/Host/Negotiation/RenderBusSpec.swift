/// One audio bus of a render resource spec: a channel count and whether the bus is enabled.
///
/// A removed or disabled bus stays in its array with `isEnabled == false` so bus indices stay stable; an added bus is
/// a longer array. A value exists only if `init` accepted it.
struct RenderBusSpec: Hashable, Sendable {
    let channels: Int
    let isEnabled: Bool

    /// Throws `.invalidChannelCount` unless `channels` is in `1...RenderNegotiationLimits.channelsPerBus`.
    init(channels: Int, isEnabled: Bool = true) throws(RenderSpecFault) {
        guard (1...RenderNegotiationLimits.channelsPerBus).contains(channels) else {
            throw .invalidChannelCount(channels)
        }
        self.channels = channels
        self.isEnabled = isEnabled
    }
}
