// #66 MET1 meter tap: a non-resetting read of one channel. Reference model; not RT-certified.

/// What one accumulator channel holds since its last reset or publish.
enum MeterTapReading: Equatable, Sendable, BitwiseCopyable {
    /// No sample arrived: no samples is not silence, so nothing is published for the channel.
    case unfed
    /// The channel saw a NaN, +infinity or -infinity. It is published as NaN and its finite peak is discarded.
    case invalid
    /// The largest finite magnitude seen, linear (0 is digital silence, which is not `unfed`).
    case peak(Float)
}
