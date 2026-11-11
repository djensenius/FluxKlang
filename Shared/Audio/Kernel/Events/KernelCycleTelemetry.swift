// #64 E5b kernel-cycle telemetry: render publishes cumulative cycle, deadline and clock-gate counters after every
// `KernelCycle.run`, latest-only, through M8 `TelemetrySlots`. Also the cycle's preparation inputs (`KernelCycleStart`,
// `KernelCycleParts`), moved here in round 2h to keep `KernelCycle.swift` within its length. Reference model; not
// RT-certified.

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
    /// Sum of every cycle's `KernelCycleResult.discardedDuringTakeover` (Copilot round 4).
    var discardedDuringTakeover: UInt64 = 0
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

/// How a `KernelCycle` takes over its fan-in and its `NoteOwnership`. Reference model; not RT-certified.
enum KernelCycleStart: Sendable, Equatable {
    /// No earlier cycle consumed `events` or was built over `ownership`: the flush watermark starts clear and
    /// nothing is taken over. `KernelCycle.init` refuses it (`.ownershipClaim(.alreadyUsed)`) once any cycle was
    /// built over the ownership, so a cycle sharing ownership (and so tombstones) always takes over.
    case freshFanIn
    /// The fail-safe default: an earlier cycle may have consumed `events` and may have been acknowledged while a
    /// lane was still flushing, so a pre-fault `noteOn` may still be queued. The cycle starts with every lane's
    /// flush bit set, as if its first cycle were latched: events drained before a lane is proved empty are marked
    /// and their `noteOn`s discarded. Liveness is as after any latch: each bit clears once its lane's drain
    /// delivers fewer than its limit, so a queued `noteOn` is lost but never sounds and sticks. It also takes over
    /// the shared `NoteOwnership`: every note still marked sounding is released (see `KernelCycle`'s Takeover).
    /// Contract: the cycle last built over the ownership must have `retire()`d (render, after its last `run`)
    /// before this one is prepared; `KernelCycle.init` refuses otherwise (`.ownershipClaim(.predecessorNotRetired)`).
    /// It must also pass that cycle's `admissionRefusals` (see `admissionRefusals`), else `.admissionRefusalsRequired`.
    /// If it loses the claim to a preparation that has since retired, it is refused `.ownershipClaim(.claimRaced)`.
    /// Pending stateful events are also recorded in a carry that `inheritedRetirementCarry` exposes and this cycle
    /// re-admits (#364 KCR1). `inheritedRetirementLoss` still counts what its immediate predecessor dropped (that one
    /// retirement only, never cumulative); `unresolvedRetirementLoss` counts what this cycle has not yet delivered or
    /// superseded, so control checks it on every replacement (per hop) and reconciles receiver state first whenever it
    /// `receiverStateMayBeStale`.
    /// Ramp values (round 2l): given the retired cycle's `RampSlots`, it reports and ramps from the last known values
    /// the slots keep (`RampSlots.lastValue`), not from 0. Happens-before: the retired cycle's last slot writes are
    /// sequenced before its `retire()`'s releasing claim CAS, which this cycle's acquiring claim CAS in `init` reads,
    /// and the host's install of the prepared cycle (release/acquire) orders that before its first render read; no
    /// further atomic. A run after `retire()` touches nothing, so the two never use the slots at once.
    case replacingCycle
}

/// The render-owned parts one `KernelCycle` composes. Reference model; not RT-certified.
struct KernelCycleParts {
    /// Render-consumed events; its policy supplies the deadline horizon.
    let events: FanInHandoff<KernelEvent>
    /// The latch `events` raises on; its `criticalScope` must be prepared in it.
    let faults: FaultLatch
    /// Notes sounding and, in `ownership.tombstones`, the release history: shared by every cycle over it, one at a
    /// time (`KernelCycle.init` claims it, `retire()` hands it back).
    let ownership: NoteOwnership
    /// Must have as many scopes as `ownership`.
    let safety: SafetyFlags
    /// The ramps and each parameter's last known value, which outlive a cycle: a `.replacingCycle` cycle continues
    /// from what its retired predecessor left. A new `RampSlots` starts every parameter at 0, so a `.freshFanIn`
    /// cycle given new slots starts from 0; one given used slots continues from their values (and active ramps).
    let ramps: RampSlots
    /// Where every cycle publishes its `KernelCycleTelemetry`; `nil` publishes nothing (the cycle still keeps it).
    /// Fail-closed: with `nil`, `acknowledgeCritical` has no sample to read, so it never approves and a critical
    /// fault can never be acknowledged through the contract. The slot's single consumer is the control thread that
    /// acknowledges: read it only through `KernelCycle.latestTelemetry()` and `acknowledgeCritical` on that thread
    /// (a UI meter gets samples from control, never reads the slot itself from another thread).
    var telemetry: KernelCycleTelemetryOutput?
    /// The producers' admission refusal table for `events`, which lives as long as the fan-in (Copilot round 4):
    /// a replacement over the same fan-in passes the retired cycle's `admissionRefusals`, so a producer admitted
    /// before it (whose `ProducerAdmission` keeps its table) still counts where telemetry reads. `nil` makes a new
    /// table only for a first cycle (an ownership no cycle has claimed). A replacement over a retired cycle must
    /// pass that cycle's `admissionRefusals`; with `nil`, `KernelCycle.init` throws `.admissionRefusalsRequired`
    /// and claims nothing. It must be `events`' (same identity and lanes).
    var admissionRefusals: KernelAdmissionRefusals?
    /// `.freshFanIn` only when no earlier cycle consumed `events` or used `ownership` (refused otherwise); anything
    /// else starts flushing and takes over (fail-safe).
    var start = KernelCycleStart.replacingCycle
}
