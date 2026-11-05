// #64 E5b kernel-cycle telemetry: render publishes cumulative cycle, deadline and clock-gate counters after every
// `KernelCycle.run`, latest-only, through M8 `TelemetrySlots`. Reference model; not RT-certified.

/// Cumulative counters after one `KernelCycle.run`. Counters saturate at `UInt64.max`.
///
/// Stale clocks are reported here and in `KernelCycleResult.resync`, not on the `FaultLatch`: a stall is
/// recoverable and lossy by design (E2 skips stale pulses and keeps one resync marker), so it never needs a sticky,
/// acknowledged fault, and the cycle adds no `FaultLatch.raise` site.
/// Reference model; not RT-certified.
struct KernelCycleTelemetry: Sendable, BitwiseCopyable, Equatable {
    /// `run` calls so far, this one included; empty (`frames <= 0`) cycles count. The first cycle is 1.
    var cycle: UInt64 = 0
    /// The `cycle` of the latest `.silenced(.scopeFaulted)` cycle; 0 before any.
    var lastFaultedCycle: UInt64 = 0
    /// Sum of every cycle's `KernelCycleResult.droppedLate`.
    var droppedLate: UInt64 = 0
    /// Cycles whose `KernelCycleResult.resync` was set: one per continuous clock stall.
    var resyncs: UInt64 = 0
    /// `ClockPulseGate.skippedStale`.
    var skippedStale: UInt64 = 0
    /// `ClockPulseGate.rateLimited`.
    var rateLimited: UInt64 = 0
    /// This cycle's `KernelCycleResult.pending`.
    var pending = 0
    /// This cycle's `KernelCycleResult.flushing`.
    var flushing = false
    /// Sum of every cycle's `KernelCycleResult.discardedWhileSilenced`.
    var discardedWhileSilenced: UInt64 = 0
    /// Sum of every cycle's `KernelCycleResult.discardedSuperseded`.
    var discardedSuperseded: UInt64 = 0
    /// `KernelAdmissionRefusals.total(.nonMonotonic)` at publication: every lane's `.nonMonotonic` refusals.
    var refusedNonMonotonic: UInt64 = 0
    /// `KernelAdmissionRefusals.total(.beyondLookahead)` at publication.
    var refusedBeyondLookahead: UInt64 = 0
    /// Drained events the block buffer refused: a tripwire, 0 unless the fan-in delivers more than the drain's
    /// room-clamped total. Never trapped.
    var blockAppendRefused: UInt64 = 0

    /// Control only: the acknowledgement handshake. `readCycle` is the `cycle` of a sample control read after
    /// `FaultLatch.observe` (0 when none was published yet). At that read cycle `readCycle + 1` had not published
    /// and may have been running since before the observation; cycle `readCycle + 2` starts only after
    /// `readCycle + 1` publishes, so after the read. `true` (this later sample shows a `.scopeFaulted` cycle at
    /// or after `readCycle + 2`) proves the flush watermark was armed after the observed loss, so control may
    /// acknowledge. The argument is sequential; the memory-model proof for the latch's callers is #190's.
    func provesFaultedCycleBegan(after readCycle: UInt64) -> Bool {
        lastFaultedCycle > readCycle && lastFaultedCycle &- readCycle >= 2
    }

    /// Adds `count` to `counter`, saturating at `UInt64.max`.
    static func saturatingAdd(_ counter: UInt64, _ count: Int) -> UInt64 {
        let (sum, overflow) = counter.addingReportingOverflow(UInt64(truncatingIfNeeded: max(count, 0)))
        return overflow ? .max : sum
    }
}

/// Where a `KernelCycle` publishes its telemetry: one slot of a render → UI/control `TelemetrySlots`, stamped with a
/// clock generation that is fixed for the cycle's life. Reference model; not RT-certified.
struct KernelCycleTelemetryOutput: Sendable {
    let slots: TelemetrySlots<KernelCycleTelemetry>
    /// Must be in `0..<slots.slotCount`; `KernelCycle.init` checks it.
    let slot: Int
    let clockGeneration: UInt64
}
