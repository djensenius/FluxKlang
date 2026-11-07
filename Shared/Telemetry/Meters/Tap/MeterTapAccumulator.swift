// #66 MET1 meter tap: per-channel peak accumulator. Allocates only in `init`; `accumulate` does no allocation,
// locking or Foundation calls. Reference model; not RT-certified.

/// Per-channel linear peak of planar `Float` render samples, since the channel's last reset or publish.
///
/// Threading: exactly ONE owner thread calls `accumulate`, `reading`, `reset`, `resetAll` and
/// `MeterTapPublisher.publish`; it is not safe for concurrent use. `@unchecked Sendable` only because a class is
/// needed for stable preallocated pointers (as `TelemetrySlots`).
///
/// Invalid rule: a channel that saw any NaN, +infinity or -infinity is invalid until it is published or reset. Invalid
/// is sticky, wins over any finite peak and is published as NaN, never +infinity (a deliberate narrowing of the
/// `MeterTapValue` doc, which lets +infinity latch a clip; an invalid channel is not evidence of clipping).
/// Denormals are finite and are not flushed; `-0.0` has magnitude 0.
///
/// Storage is two buffers allocated once in `init` (a `Float` peak and a flags byte per channel: fed, invalid).
final class MeterTapAccumulator: @unchecked Sendable {
    private static let fedBit: UInt8 = 0b01
    private static let invalidBit: UInt8 = 0b10

    let channelCount: Int
    private let peaks: UnsafeMutablePointer<Float>
    private let flags: UnsafeMutablePointer<UInt8>

    /// Refuses a count outside `1...MeterTapLimits.maximumChannels`; nothing is constructed then.
    init(channelCount: Int) throws(MeterTapRefusal) {
        guard channelCount >= 1, channelCount <= MeterTapLimits.maximumChannels else {
            throw .channelCountOutOfRange(channelCount)
        }
        let newPeaks = UnsafeMutablePointer<Float>.allocate(capacity: channelCount)
        newPeaks.initialize(repeating: 0, count: channelCount)
        let newFlags = UnsafeMutablePointer<UInt8>.allocate(capacity: channelCount)
        newFlags.initialize(repeating: 0, count: channelCount)
        self.channelCount = channelCount
        peaks = newPeaks
        flags = newFlags
    }

    deinit {
        peaks.deallocate()
        flags.deallocate()
    }

    /// Hot path. Folds `samples` into the channel's peak. An out-of-range channel is refused with
    /// `.refused(.slotOutOfRange)` and changes nothing; an empty buffer returns `.ok`, changes nothing and does not
    /// mark the channel fed. Accumulating a buffer in any split of consecutive calls gives the same `reading` (an
    /// invalid channel's private peak is not stored, and is cleared by reset).
    func accumulate(channel: Int, samples: UnsafeBufferPointer<Float>) -> KernelStatus {
        guard channel >= 0, channel < channelCount else { return .refused(.slotOutOfRange) }
        guard !samples.isEmpty else { return .ok }
        let flag = flags[channel]
        flags[channel] = flag | Self.fedBit
        guard flag & Self.invalidBit == 0 else { return .ok }
        var peak = peaks[channel]
        for sample in samples {
            let magnitude = sample.magnitude
            if !magnitude.isFinite {
                flags[channel] = flag | Self.fedBit | Self.invalidBit
                return .ok
            }
            if magnitude > peak { peak = magnitude }
        }
        peaks[channel] = peak
        return .ok
    }

    /// Non-resetting read; nil for an out-of-range channel.
    func reading(channel: Int) -> MeterTapReading? {
        guard channel >= 0, channel < channelCount else { return nil }
        let flag = flags[channel]
        if flag & Self.fedBit == 0 { return .unfed }
        if flag & Self.invalidBit != 0 { return .invalid }
        return .peak(peaks[channel])
    }

    /// Clears the channel's peak, fed and invalid state. An out-of-range channel is refused and changes nothing.
    func reset(channel: Int) -> KernelStatus {
        guard channel >= 0, channel < channelCount else { return .refused(.slotOutOfRange) }
        peaks[channel] = 0
        flags[channel] = 0
        return .ok
    }

    /// Clears every channel.
    func resetAll() {
        peaks.update(repeating: 0, count: channelCount)
        flags.update(repeating: 0, count: channelCount)
    }
}
