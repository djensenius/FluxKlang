// #66 MET1 meter tap: typed refusal of the validated accumulator init. Reference model; not RT-certified.

/// Why a `MeterTapAccumulator` could not be built. It carries the offending value only, never text.
enum MeterTapRefusal: Error, Equatable, Sendable {
    /// The channel count is outside `1...MeterTapLimits.maximumChannels`.
    case channelCountOutOfRange(Int)
}
