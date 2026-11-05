// #64 E5b kernel-cycle telemetry: render publishes cumulative cycle, deadline and clock-gate counters after every
// `KernelCycle.run`, latest-only, through M8 `TelemetrySlots`. Reference model; not RT-certified.

/// Cumulative counters after one `KernelCycle.run`. Counters saturate at `UInt64.max`.
///
/// Stale clocks are reported here and in `KernelCycleResult.resync`, not on the `FaultLatch`: a stall is
/// recoverable and lossy by design (E2 skips stale pulses and keeps one resync marker), so it never needs a sticky,
/// acknowledged fault, and the cycle adds no `FaultLatch.raise` site.
///
/// Single producer, single consumer per slot (`TelemetrySlots`' contract, checked at preparation only): at any time
/// exactly one `KernelCycle` publishes to a `KernelCycleTelemetryOutput` slot (from the render thread) and one reader
/// reads it: the control thread that acknowledges. During a replacement the old cycle must stop publishing (its last
/// `run` returned, on the render thread) before the replacement's first `run` publishes; two cycles publishing to one
/// slot concurrently permanently corrupt that slot. No runtime check exists: `TelemetrySlots` has no owner word, and a
/// render-path check would cost an atomic per cycle in Release. The only reads are `KernelCycle.latestTelemetry()` and
/// `KernelCycle.acknowledgeCritical`, both on that control thread and never concurrently; a UI meter gets samples from
/// control, never reads the slot itself. Approval never comes from a caller-held value, so a forged
/// `KernelCycleTelemetry` (all fields are settable: a report, not a capability) cannot approve a ticket. Anything
/// holding the `TelemetrySlots` could still publish one into the cycle's slot, breaking the single-producer contract
/// (trusted control code, not type-restricted), but even then it cannot approve: `acknowledgeCritical` also
/// requires the cycle-private `lastFaultedAckEpoch` atomic (round 2g), so a forgery can only withhold or delay it.
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

    /// `KernelAckRequests.loadForRender()` at the start of this cycle: the latest requested epoch render saw.
    var ackEpochSeen: UInt64 = 0
    /// The `ackEpochSeen` of the latest `.silenced(.scopeFaulted)` cycle (the one `lastFaultedCycle` names); 0
    /// before any.
    var lastFaultedAckEpoch: UInt64 = 0
    /// The publishing cycle's `KernelAckRequests.identity`; 0 for a sample no cycle made.
    var ackCycle: UInt64 = 0

    /// Control only: the acknowledgement handshake, as `KernelCycle.acknowledgeCritical` applies it to its own
    /// slot's latest sample, together with its private `lastFaultedAckEpoch` (on its own it is advisory only).
    /// `true` when this sample was published by the cycle that issued `ticket` (`ackCycle == ticket.cycle`; any
    /// other cycle never approves it, even on the same slots) and shows a `.scopeFaulted` cycle that loaded
    /// `ticket`'s epoch or a later one before reading the latch, so it began after control's `observe` and
    /// `request` and armed the flush watermark. A stale sample
    /// (published before render loaded the epoch, or never refreshed) only delays acknowledgement. The
    /// happens-before chain is on `KernelAckRequests`; its formal model-check is tracked in #190. Epoch 0 (never
    /// handed out) is refused as defence in depth: every sample has `lastFaultedAckEpoch >= 0`.
    func permitsAcknowledgement(_ ticket: borrowing KernelAckTicket) -> Bool {
        let (epoch, cycle) = (ticket.epoch, ticket.cycle)
        return epoch > 0 && ackCycle == cycle && lastFaultedAckEpoch >= epoch
    }

    /// Adds `count` to `counter`, saturating at `UInt64.max`.
    static func saturatingAdd(_ counter: UInt64, _ count: Int) -> UInt64 {
        let (sum, overflow) = counter.addingReportingOverflow(UInt64(truncatingIfNeeded: max(count, 0)))
        return overflow ? .max : sum
    }
}

/// Where a `KernelCycle` publishes its telemetry: one slot of a render → control `TelemetrySlots`, stamped with a
/// clock generation that is fixed for the cycle's life. One publishing cycle per slot at a time (see
/// `KernelCycleTelemetry`), replacements included; read the slot only through `KernelCycle.latestTelemetry()`.
/// Reference model; not RT-certified.
struct KernelCycleTelemetryOutput: Sendable {
    let slots: TelemetrySlots<KernelCycleTelemetry>
    /// Must be in `0..<slots.slotCount`; `KernelCycle.init` checks it.
    let slot: Int
    let clockGeneration: UInt64
}
