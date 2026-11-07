// #66 MET1 meter tap: accumulator to telemetry slots. Reference model; not RT-certified.

/// Writes an accumulator's channels to `TelemetrySlots<MeterTapValue>`: channel `c` goes to slot `firstSlot + c`, in
/// ascending channel order, with the caller's stamp copied unchanged (no clock is read). Same owner thread as the
/// accumulator.
enum MeterTapPublisher {
    /// The slot range is checked first and atomically: `firstSlot < 0`, an overflowing `firstSlot + channelCount`
    /// or a sum above `slots.slotCount` is `.refused(.slotOutOfRange)` with no slot written and no channel reset
    /// (a sum equal to `slotCount` is accepted). Then per channel: `.unfed` is skipped (slot, sequence and channel
    /// untouched, since no samples is not silence); `.invalid` publishes NaN; `.peak` publishes
    /// `MeterTapLevel.dBFS`. A published channel is then reset, so the value is the peak since the last publish.
    /// Returns `.ok` when at least one channel was published and `.empty` when every channel was unfed. A non-`.ok`
    /// status from `slots.publish` is returned at once without resetting that channel (unreachable after the range
    /// check; kept as a guard).
    static func publish(_ accumulator: MeterTapAccumulator, to slots: TelemetrySlots<MeterTapValue>,
                        firstSlot: Int, stamp: TelemetryStamp) -> KernelStatus {
        let (end, overflow) = firstSlot.addingReportingOverflow(accumulator.channelCount)
        guard firstSlot >= 0, !overflow, end <= slots.slotCount else { return .refused(.slotOutOfRange) }
        var published = false
        for channel in 0..<accumulator.channelCount {
            guard let value = value(of: accumulator.reading(channel: channel)) else { continue }
            let status = slots.publish(slot: firstSlot + channel, value: value, stamp: stamp)
            guard status == .ok else { return status }
            _ = accumulator.reset(channel: channel)
            published = true
        }
        return published ? .ok : .empty
    }

    private static func value(of reading: MeterTapReading?) -> MeterTapValue? {
        switch reading {
        case .none, .some(.unfed): nil
        case .some(.invalid): MeterTapValue(peakDBFS: .nan)
        case .some(.peak(let peak)): MeterTapValue(peakDBFS: MeterTapLevel.dBFS(fromLinearPeak: peak))
        }
    }
}
