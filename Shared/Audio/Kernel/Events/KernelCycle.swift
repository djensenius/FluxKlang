import Synchronization

// #64 E5 kernel cycle core: one bounded, render-owned block of event work composed from the accepted E2/E3 parts.
// E5a: silence and recovery. E5b: split by composition into `KernelBlockBuffer` (order), `KernelFlushWatermark`
// (drain) and `KernelBlockDecider` (decide, apply, ramps), each with private storage; cycle telemetry and the
// `.staleClock` decision. Not wired into any render path, AU callback or audio buffer; plan
// adoption (`noPlan`) and the output buffer are not modelled here. Reference model; not RT-certified.

/// What one `KernelCycle.run` did. Every drained event that leaves the block buffer is counted in exactly one of
/// `dispatched`, `droppedLate`, `refused`, `skippedPulses`, `discardedWhileSilenced`, `discardedSuperseded` or
/// `discardedDuringTakeover`; synthesized releases are counted only in `releasedNotes`.
/// Reference model; not RT-certified.
struct KernelCycleResult: Sendable, BitwiseCopyable, Equatable {
    /// `.ok`; `.silenced(.scopeFaulted)` while the critical scope is latched; else `.silenced(.safetyMute)` on panic;
    /// `.refused(.notOwner)` for a `run` after `retire()` (see `retired`).
    private(set) var status: KernelStatus
    /// Events moved from the fan-in into the block buffer.
    private(set) var drained: Int
    /// Events passed to `emit`, on time or late; in a silenced cycle, only `noteOff`s that released an owned note.
    private(set) var dispatched: Int
    /// `noteOn`s later than the deadline tolerance: discarded and counted, never emitted (E2 `dropLate`).
    private(set) var droppedLate: Int
    /// Due events the cycle could not apply and did not emit: a `noteOn` that `NoteOwnership` refused (scope,
    /// channel or note out of range) or a `rampTo` that `RampSlots` refused (parameter out of range, non-finite).
    private(set) var refused: Int
    /// Due clock pulses the gate skipped (stale or rate-limited); the gate keeps the cumulative counters.
    private(set) var skippedPulses: Int
    /// Note events consumed without emitting: a silenced cycle's buffered `noteOn`s and unowned `noteOff`s,
    /// `noteOn`s decided while flushing (see the type's Flush watermark), and the first `noteOff` this cycle sees for
    /// a note its takeover released (see the type's Takeover).
    private(set) var discardedWhileSilenced: Int
    /// Decided `noteOn`s a same-key `noteOff` strictly after their frame already released (`ReleaseTombstones`).
    private(set) var discardedSuperseded: Int
    /// Decided `noteOn`s (not flushing) in a scope a pending takeover has not finished releasing (see the type's
    /// Takeover); scopes it finished sound again.
    private(set) var discardedDuringTakeover: Int
    /// A lane was still flushing after this cycle's drain (see the type's Flush watermark).
    private(set) var flushing: Bool
    /// Owned notes released by a `.replacingCycle` takeover, safety requests or critical-fault recovery, each
    /// emitted as a synthesized `noteOff` at `blockStart`.
    private(set) var releasedNotes: Int
    /// The gate's single resync marker for the current stall was taken in this cycle.
    private(set) var resync: Bool
    /// Events left in the block buffer for a later cycle.
    private(set) var pending: Int
    /// The cycle had `retire()`d, so this `run` did nothing (round 2h): no drain, emission, ownership, tombstone,
    /// safety, ramp or telemetry change; status `.refused(.notOwner)` and every count 0.
    private(set) var retired: Bool

    /// The only construction: `KernelCycle.run` folds one cycle in. Nothing else can make or edit a result: no
    /// field has a default value, so an extension initializer in another file cannot make one either.
    fileprivate init(status: KernelStatus, drained: Int, tally: KernelCycleTally, flushing: Bool, releasedNotes: Int,
                     pending: Int) {
        self.status = status
        self.drained = drained
        dispatched = tally.dispatched
        droppedLate = tally.droppedLate
        refused = tally.refused
        skippedPulses = tally.skippedPulses
        discardedWhileSilenced = tally.discardedWhileSilenced
        discardedSuperseded = tally.discardedSuperseded
        discardedDuringTakeover = tally.discardedDuringTakeover
        self.flushing = flushing
        self.releasedNotes = releasedNotes
        resync = tally.resync
        self.pending = pending
        retired = false
    }

    /// What `run` reports on a retired cycle: it did nothing. Computed (no lazy global initialisation on render).
    fileprivate static var retiredRun: KernelCycleResult {
        var result = KernelCycleResult(status: .refused(.notOwner), drained: 0, tally: KernelCycleTally(),
                                       flushing: false, releasedNotes: 0, pending: 0)
        result.retired = true
        return result
    }
}

/// One render-owned kernel cycle per block. Reference model; not RT-certified.
///
/// `run` does, in order:
/// 0. Acknowledgement epoch: `ackRequests.loadForRender()` (acquire), before any latch read; published in step 7
///    as `ackEpochSeen`, and as `lastFaultedAckEpoch` (in the sample and the cycle-private atomic) by a
///    `.scopeFaulted` cycle.
/// 1. Takeover, `.replacingCycle` only, while pending: at most `blockCapacity` synthesized releases (see Takeover).
///    Safety: takes every scope's `SafetyFlags`; any request releases that scope's owned notes (bits, never
///    queue-capacity dependent); `panic` also silences this cycle (`.safetyMute`) for every scope.
/// 2. Faults: while `faults.isLatched(events.criticalScope)` (a critical `noteOff` was refused) every owned note
///    in every scope is released, every lane's flush bit is set and the cycle reports `.silenced(.scopeFaulted)`
///    until control acknowledges off-thread. Other scopes in the same latch never silence it.
/// 3. Drain, when `frames > 0` (silenced or not): the fan-in (fair, `perLaneQuota`) into the buffer's free room,
///    ordered by (original `event.frame`, lane, producer lane, `sequence`): a stable bottom-up merge sort of the
///    new run through preallocated scratch, then one stable linear merge behind the kept prefix.
/// 4. Decide, when `frames > 0` and not silenced: `DeadlinePolicy` in buffer order, never re-sorted by a decided
///    frame (a late `noteOn` stays ahead of its later `noteOff`). The first `notYet` and everything after it
///    stay buffered. Empty and silenced cycles call neither `decide` nor `ClockPulseGate.admit`.
/// 5. Silenced cycles (any `frames`) consume buffered note events undecided: `noteOn`s are discarded
///    (`discardedWhileSilenced`); a `noteOff` clears ownership and is emitted at `blockStart` only if it released
///    an owned note. Other events stay buffered in order. A panic flushes the buffer, not the lanes; leftover
///    `noteOn`s keep their own FIFO `noteOff`s. A panic is global: it cuts notes short in other scopes too.
/// 6. Ramps, when `frames > 0`, advance to the end of the block.
/// 7. Telemetry (any `frames`): the cumulative `KernelCycleTelemetry` is updated and, with an output, published;
///    a `.scopeFaulted` cycle first stores its epoch in the cycle-private `lastFaultedAckEpoch` (release).
///
/// Per due event: `noteOn` is emitted only if no same-key release after its frame was applied (release
/// tombstones; cross-lane order is otherwise not guaranteed), its scope is not held by a pending takeover and
/// `NoteOwnership` accepts it; `noteOff` records its tombstone, clears ownership and is emitted, except the first
/// unowned `noteOff` this cycle sees for a key its own takeover released, which is consumed (see Takeover);
/// `control`/`program` are never merged; `clockPulse` goes
/// through the gate with its original frame; `rampTo` replaces the ramp from its value at the dispatch frame.
/// `emit` gets the event and its frame.
///
/// Flush watermark. A latched loss means some lane may hold a `noteOn` ahead of its refused `noteOff`, possibly
/// behind a full buffer. Each latched cycle sets every lane's flush bit (a `.replacingCycle` start sets them all
/// too, see `KernelCycleStart`); a drain clears a lane's bit when it proves that lane empty (fewer delivered than
/// its limit). Events drained from a flushing lane are marked, and while any bit is set (even after
/// acknowledgement) or for a marked event, a decided `noteOn` is discarded and counted in
/// `discardedWhileSilenced`; `noteOff`s apply as usual. Lanes are FIFO, so once every bit clears every pre-fault
/// event has been drained, and a marked one never sounds. `KernelCycleResult.flushing` reports set bits.
///
/// Takeover. A replacement shares the retired cycle's `NoteOwnership` (and so its `ReleaseTombstones`: release
/// history survives replacement) but not its block buffer, so a `noteOff` buffered only there would never reach it
/// and its note would stick. A `.replacingCycle` start therefore releases every note the ownership still marks
/// sounding, through the same synthesized `noteOff` path as safety releases, and clears that ownership, independent
/// of the retired cycle's buffers. It cuts those notes short by design: no stuck note beats exact durations. Each
/// cycle releases at most `blockCapacity` of them, in (scope, channel, note) order, and carries the rest to the next
/// cycle, so with `n` notes sounding the takeover ends after `ceil(n / blockCapacity)` cycles
/// (`n <= scopes × 2,048`); no release is dropped. Until it ends, a decided `noteOn` in a scope at or after its scope
/// cursor (not yet fully released) is discarded and counted in `discardedDuringTakeover`, so it only cuts the
/// retired cycle's notes; scopes before the cursor sound again. The first unowned `noteOff` this cycle sees for a
/// key its takeover released (the retired cycle's event re-delivered, say; decided or consumed while silenced) is
/// consumed, not emitted, and never latched; decided, it is counted in `discardedWhileSilenced`. A re-struck (owned)
/// key's `noteOff` is emitted as usual and keeps the record. So within one cycle a takeover release is never
/// followed by a second `noteOff` for it; across replacements the record is not shared (a second replacement may
/// emit one redundant, harmless `noteOff` for a key its predecessor's takeover released). `.freshFanIn` takes nothing
/// over. No other event still pending in the retired cycle's buffer reaches the replacement (but see Retirement).
///
/// Retirement. Render calls `retire()` on the old cycle after its last `run` and before the replacement's first: every
/// `noteOff` still pending in the old block buffer records its tombstone (its own frame, unclamped, as a silenced cycle
/// does), so a same-key `noteOn` stamped before it, arriving later at the replacement, is superseded instead of
/// sounding with its release lost. Every other pending event is dropped and counted by kind in a `KernelRetirementLoss`
/// that the ownership holds from the claim's release to the replacement's acquire (its `inheritedRetirementLoss`).
/// Dropped `noteOn`s are lost, never stuck (never emitted or owned); dropped stateful events (`control`, `program`,
/// `rampTo`) set `receiverStateMayBeStale`, and control must then reconcile receiver state (re-send the current
/// program, controllers and ramp targets) before relying on it. Pending stateful events are also recorded, up to
/// `KernelRetirementCarry.capacity`, into a carry the next claim inherits (`inheritedRetirementCarry`) and a
/// replacement re-admits (rules, accounting, per-hop stale signal: `KernelCycle+Readmission.swift`). A
/// `.replacingCycle` cycle cannot be prepared over an ownership whose last cycle has not retired
/// (`PreparationError.ownershipClaim(.predecessorNotRetired)`), and `.freshFanIn` over one any cycle has used
/// (`.ownershipClaim(.alreadyUsed)`); a replacement over a retired cycle must also pass the fan-in's
/// `admissionRefusals` (`.admissionRefusalsRequired`, nothing claimed). The check and the claim are one
/// compare-exchange on the ownership's claim word, so a racing preparation cannot pass the check, wait out another
/// cycle's claim and retire, then claim fresh; a replacement that loses it to a cycle that has since retired is refused
/// `.ownershipClaim(.claimRaced)`. So a replacement is prepared after the retire, and render runs no cycle in between
/// (at least one block without event work). A `run` after `retire()` does nothing (`KernelCycleResult.retired`), and a
/// second `retire()` too (it returns no loss).
///
/// Acknowledgement contract. Control acknowledges a critical fault only after render has reported a silenced
/// (`.scopeFaulted`) cycle that began after control's `observe`; that cycle armed the watermark. An earlier
/// acknowledgement can let a queued `noteOn` sound and stick. Off-thread, control calls
/// `ackRequests.request(for: observation)` after `observe` (only this cycle's latch and critical scope), then
/// `acknowledgeCritical(observation, ticket)`, which reads this cycle's own telemetry slot and acknowledges only
/// when that sample's `KernelCycleTelemetry.permitsAcknowledgement(_:)` is `true` and the cycle-private
/// `lastFaultedAckEpoch` atomic (stored only by this cycle's render, on `.scopeFaulted` cycles) is at least the
/// ticket's epoch (the happens-before chain is on `KernelAckRequests`; its formal model-check is tracked in #190).
/// No caller-supplied sample is accepted, and a sample forged into the slot (all its fields are settable) cannot
/// approve alone: the atomic is reachable only from this file.
/// Step 0 of `run` acquire-loads the epoch before step 2's latch read. Tickets are bound to this cycle's
/// `ackRequests.identity` (published as `ackCycle`), so a replacement cycle on the same slots never approves them,
/// and to the observation they were requested for, so a re-raise after the request needs a new observation, a new
/// request and a new approval; `acknowledgeCritical` consumes the ticket, so it is never reused. Replacing a cycle
/// on the same fan-in starts the replacement flushing (`KernelCycleStart.replacingCycle`). Fail-closed: with no
/// telemetry output nothing is ever approved. Residual (#190): control must acknowledge critical scopes only via
/// `acknowledgeCritical`; `FaultLatch.acknowledge` is a shared API and is not type-restricted for critical scopes.
/// The ticket is type-enforced only for callers of `acknowledgeCritical`. Anything holding the `TelemetrySlots` can
/// still publish into the slot (breaking its single producer); that can only withhold or delay approval.
///
/// Stale clocks (E5b decision): the gate's one marker per stall is `KernelCycleResult.resync`, counted with the
/// gate's counters in telemetry; no `FaultKind.staleClock` is raised and the cycle adds no `FaultLatch.raise` site.
/// Frame order: the cycle tolerates a producer's frames going backwards (ordered by original frame, decided late or
/// dropped); producers admit through `ProducerAdmission`, which resets `lastAdmittedFrame` on a discontinuity.
/// Zero-length notes: a same-frame `noteOff` is ordered first and the `noteOn` (a tie, so a retrigger) then sounds
/// and sticks; producers must put the `noteOff` at least a frame later.
///
/// Bounds. All storage (block and scratch buffers, telemetry, flush bits, admission refusal counters, takeover bits,
/// gate, ramp words) is allocated in `init`, inside the private components; tombstones live in the shared
/// `NoteOwnership` (its `init`); re-admission: see `KernelCarryReadmission` Bounds. `retire()` passes the block buffer
/// once. A cycle drains at most the free room, sorts in O(n log n) moves, passes the buffer once more, visits each
/// owned-note word at most twice (a pending takeover adds at most two passes over each scope it reaches), each ramp
/// parameter once and each lane at most three times (drain, then the two refusal totals); a buffer full of future (or,
/// while silenced, non-note) events stops draining (M4/M5 backpressure; the lanes are decided later). Takeover worst
/// case per cycle: one cycle can sweep every remaining empty scope, up to 256, each with `ownedCount` and
/// `releaseFirst` (32 words each, so about 64 word reads per scope, about 16 Ki words in all). A `run` after `retire()`
/// is O(1).
///
/// Contracts. `run`, `retire`, `parameterValue`, `pulses`, `telemetry` and `bufferedCount` are the render consumer's
/// only (the fan-in's single consumer), with a distinct, advancing `blockStart` per non-empty cycle; `emit` must not
/// call back. `retire()` is the cycle's last render call: a `run` after it does nothing and reports `retired` (a
/// render-only flag, round 2h), so a stray `run` cannot drain the shared fan-in or touch the shared ownership,
/// tombstones, safety flags or telemetry slot once a replacement is live. Teardown: render must `retire()` the
/// last cycle over an ownership before releasing it, or the ownership stays claimed (see `NoteOwnership`).
/// `admissionRefusals` is any thread's (producers count through `ProducerAdmission`); `ackRequests`,
/// `latestTelemetry()` and `acknowledgeCritical` are control's, the last two being the only reads of the telemetry slot
/// (its single consumer, on the acknowledging control thread). The parts are kept for life. ARC, metadata and target
/// progress are unqualified (X1 probe), as in M5–M7.
/// `@unchecked Sendable`: all other mutable state is render-only, in storage preallocated in `init`; the refusal
/// counters, the acknowledgement epoch, `lastFaultedAckEpoch` and the ownership's cycle claim are atomic.
final class KernelCycle: @unchecked Sendable {
    /// Why `acknowledgeCritical` refused, checked in this order. Every refusal leaves the latch, the epoch and the
    /// cycle unchanged (`.notApproved` and `.latchRefused` have read the telemetry slot, which only moves the
    /// consumer to its latest sample); the ticket is consumed, so control observes, requests and waits again.
    enum AcknowledgeRefusal: Error, Equatable, Sendable {
        /// Another cycle's `ackRequests` issued the ticket.
        case foreignTicket
        /// `observation` was made by another `FaultLatch` (even one whose words match); checked before the slot is
        /// read.
        case foreignObservation
        /// `observation` is not of this cycle's critical scope.
        case notCriticalScope
        /// The ticket was requested for another observation (an earlier latched state of the scope).
        case ticketObservationMismatch
        /// This cycle publishes no telemetry, its slot holds no sample yet, the latest one does not yet
        /// `permitsAcknowledgement` the ticket, or no `.scopeFaulted` run of this cycle loaded the ticket's epoch
        /// (the private `lastFaultedAckEpoch`; a sample forged into the slot fails here).
        case notApproved
        /// `FaultLatch.acknowledge` refused this cycle's own observation: the scope was raised on or acknowledged
        /// since `observe` (another latch's observation is `.foreignObservation`).
        case latchRefused
    }

    /// Largest block buffer (inclusive). Ordering is a stable merge sort, so a cycle orders at most
    /// `blockCapacity` events in O(`blockCapacity` log `blockCapacity`) moves.
    static let maximumBlockCapacity = 4_096
    /// `sequence` of every synthesized release.
    static let releaseSequence = UInt64.max

    /// The deadline horizon from the fan-in's policy.
    var deadline: DeadlinePolicy { decider.deadline }
    let blockCapacity: Int
    let perLaneQuota: Int
    /// The producers' admission refusal counts for `events` (see `ProducerAdmission`): producers count through it,
    /// and each cycle publishes its totals. Its API only counts and reads; its storage is private.
    let admissionRefusals: KernelAdmissionRefusals
    /// Control's acknowledgement requests (see the type's Acknowledgement contract). Its API only requests and
    /// loads; its epoch is private.
    let ackRequests: KernelAckRequests
    /// Any thread, immutable: only the immediate predecessor's retirement loss (not cumulative; see Retirement).
    var inheritedRetirementLoss: KernelRetirementLoss { ownershipClaim.inherited }
    /// Any thread, immutable: the pending stateful events the immediate predecessor recorded at retirement (a
    /// snapshot, not cumulative, never consumed by a read; see Retirement).
    var inheritedRetirementCarry: KernelRetirementCarry { ownershipClaim.inheritedCarry }
    /// Any thread: the inherited carry's re-admission report, slot capacity and resolved stateful events by kind.
    var carryReadmissionReport: KernelCarryReadmissionReport { carryReadmission.report }
    var carryReadmissionCapacity: Int { carryReadmission.capacity }
    var carryResolution: KernelCarryResolution { carryReadmission.resolved() }

    // Render-owned components and parts; private, so only this file can reach them.
    private let events: FanInHandoff<KernelEvent>
    private let faults: FaultLatch
    private let ownership: NoteOwnership
    private let safety: SafetyFlags
    private let criticalScope: FaultScope
    private let telemetryOutput: KernelCycleTelemetryOutput?
    private let block: KernelBlockBuffer
    private let watermark: KernelFlushWatermark
    private let decider: KernelBlockDecider
    /// The inherited carry, planned in `init`; render drains it in step 4 and re-carries what is left in `retire()`.
    private let carryReadmission: KernelCarryReadmission
    /// The cumulative telemetry counters.
    private let counters: UnsafeMutablePointer<KernelCycleTelemetry>
    /// The epoch loaded by this cycle's latest `.scopeFaulted` run; 0 before any. Render stores it (release) once per
    /// faulted cycle; `acknowledgeCritical` acquire-loads it. Private, so no sample forged into the slot approves.
    private let lastFaultedAckEpoch = Atomic<UInt64>(0)
    /// This cycle's hold on `ownership`; `retire()` hands it back.
    private let ownershipClaim: NoteOwnership.CycleClaim
    /// `retire()` ran: render-only plain memory (render-thread-confined), checked first by `run` and `retire()`.
    private var retired = false

    /// Control-side preparation; allocates the block buffer and the ramp bookkeeping.
    init(_ parts: KernelCycleParts, pulses: ClockPulseGate, blockCapacity: Int,
         perLaneQuota: Int) throws(PreparationError) {
        let checked = try Self.prepare(parts, blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
        let deadline = checked.deadline
        guard let ackRequests = KernelAckRequests(faults: parts.faults, criticalScope: parts.events.criticalScope)
        else { throw .ackIdentitiesExhausted }
        do {
            ownershipClaim = try parts.ownership.claimForCycle(fresh: checked.fresh, from: checked.claimState)
        } catch {
            throw .ownershipClaim(error)
        }
        self.ackRequests = ackRequests
        self.blockCapacity = blockCapacity
        self.perLaneQuota = perLaneQuota
        events = parts.events
        faults = parts.faults
        ownership = parts.ownership
        safety = parts.safety
        criticalScope = parts.events.criticalScope
        telemetryOutput = parts.telemetry
        block = KernelBlockBuffer(capacity: blockCapacity)
        carryReadmission = KernelCarryReadmission(carry: ownershipClaim.inheritedCarry, blockCapacity: blockCapacity)
        watermark = KernelFlushWatermark(laneCount: parts.events.laneCount, armed: parts.start == .replacingCycle)
        decider = KernelBlockDecider(deadline: deadline, ownership: parts.ownership, ramps: parts.ramps,
                                     pulses: pulses, takeover: parts.start == .replacingCycle,
                                     readmission: carryReadmission)
        admissionRefusals = parts.admissionRefusals ?? KernelAdmissionRefusals(laneCount: parts.events.laneCount,
                                                                               handoff: parts.events.identity)
        counters = .allocate(capacity: 1)
        counters.initialize(to: KernelCycleTelemetry(ackCycle: ackRequests.identity))
    }

    /// Control-side teardown only.
    deinit {
        counters.deallocate()
    }

    /// Render only. Runs one block `[blockStart, blockStart + frames)`; see the type's steps. Never throws, traps
    /// or blocks, for any `blockStart` and `frames`. After `retire()` it does nothing and returns a result with
    /// `retired` set.
    func run(blockStart: Int64, frames: Int64, emit: (KernelEvent, Int64) -> Void) -> KernelCycleResult {
        guard !retired else { return .retiredRun }
        // Step 0: before the latch read, so a latched read here follows every request this epoch covers.
        let ackEpoch = ackRequests.loadForRender()
        var status = KernelStatus.ok
        var releasedNotes = 0
        if decider.takeoverPending {
            releasedNotes &+= decider.releaseTakeover(blockStart, limit: blockCapacity, sequence: Self.releaseSequence,
                                                      emit)
        }
        let panicked = applySafety(blockStart, &releasedNotes, emit)
        if faults.isLatched(criticalScope) {
            for scope in 0..<ownership.scopeCount {
                releasedNotes &+= release(UInt32(truncatingIfNeeded: scope), blockStart, emit)
            }
            status = .silenced(.scopeFaulted)
            watermark.arm()
        } else if panicked {
            status = .silenced(.safetyMute)
        }
        let drained = frames > 0
            ? watermark.drain(events, perLaneQuota: perLaneQuota, limit: block.room, into: block) : 0
        let flushing = watermark.isFlushing
        var tally = KernelCycleTally()
        if status != .ok {
            decider.consumeNotesWhileSilenced(block, blockStart, &tally, emit)
        } else if frames > 0 {
            decider.decide(block, flushing: flushing, (blockStart, frames), &tally, emit)
        }
        if frames > 0 { decider.advanceRamps(to: frames) }
        let result = KernelCycleResult(status: status, drained: drained, tally: tally, flushing: flushing,
                                       releasedNotes: releasedNotes, pending: block.count)
        publishTelemetry(blockStart, ackEpoch, result)
        return result
    }

    /// Control only; takes the latch's control lock, so never call from render. The Acknowledgement contract's
    /// entry point: re-arms the critical scope and returns `observation.record` only when `ticket` was issued by
    /// this cycle for exactly `observation` (made by this cycle's latch, of its critical scope) and the latest
    /// sample in this cycle's own telemetry slot permits it, as does the private `lastFaultedAckEpoch` (acquire)
    /// that only this cycle's faulted runs store; otherwise a typed refusal that changes nothing, in
    /// `AcknowledgeRefusal`'s order (identity checks before the slot is read). Consumes `ticket` either way. It
    /// reads the slot through `latestTelemetry()`, as its single consumer, so call it only from the acknowledging
    /// control thread, never concurrently with another read of the slot.
    func acknowledgeCritical(_ observation: FaultObservation,
                             _ ticket: consuming KernelAckTicket) throws(AcknowledgeRefusal) -> FaultRecord {
        guard ticket.cycle == ackRequests.identity else { throw .foreignTicket }
        guard observation.isObservation(of: faults) else { throw .foreignObservation }
        guard observation.record.scope == criticalScope else { throw .notCriticalScope }
        guard ticket.isBound(to: observation) else { throw .ticketObservationMismatch }
        guard let sample = latestTelemetry(), sample.value.permitsAcknowledgement(ticket),
              lastFaultedAckEpoch.load(ordering: .acquiring) >= ticket.epoch else { throw .notApproved }
        guard let record = faults.acknowledge(observation) else { throw .latchRefused }
        return record
    }

    /// Render only, once, after this cycle's last `run` and before its replacement is prepared (see the type's
    /// Retirement): records the tombstone of every `noteOff` still pending in the block buffer at its own frame,
    /// unclamped, in the shared `ownership.tombstones`, drops and counts every other pending event and records the
    /// stateful ones in a carry, then (as re-carried, `KernelRetirementCarry.beginRecarried()`) does the same for the
    /// re-admitted events still pending that no pending own event covers
    /// (`KernelCarryReadmission.retire(coveredBy:_:)`); stores that loss and carry in the ownership, then hands
    /// the cycle claim back (release). No allocation, lock, emission or telemetry. A repeated call does nothing and
    /// returns no loss; a later `run` does nothing, reporting `retired`.
    @discardableResult
    func retire() -> KernelRetirementLoss {
        guard !retired else { return KernelRetirementLoss() }
        retired = true
        var loss = KernelRetirementLoss()
        var carry = KernelRetirementCarry()
        for index in 0..<block.count {
            let event = block[index].event
            ownership.tombstones.release(event)
            loss.drop(event.payload)
            carry.record(event)
        }
        carry.beginRecarried()
        carryReadmission.retire(coveredBy: block) { loss.drop($0.payload); carry.record($0) }
        ownership.releaseCycleClaim(ownershipClaim, loss: loss, carry: carry)
        return loss
    }

    /// Control only: this cycle's latest published sample, or `nil` with no telemetry output or before the first
    /// publish. With `acknowledgeCritical`, the only read of this cycle's telemetry slot: both are its single
    /// consumer, so call them only from the acknowledging control thread, never concurrently. A UI meter gets
    /// samples from control and never reads the slot itself.
    func latestTelemetry() -> TelemetrySample<KernelCycleTelemetry>? {
        guard let output = telemetryOutput, case .measured(let sample) = output.slots.latest(slot: output.slot) else {
            return nil
        }
        return sample
    }

    /// Render only. `parameter`'s value at the end of the last block, or `nil` when out of range.
    func parameterValue(_ parameter: UInt32) -> Float? { decider.parameterValue(parameter) }

    /// Events waiting in the block buffer. Render only.
    var bufferedCount: Int { block.count }

    /// The gate's cumulative counters and resync state. Render only.
    var pulses: ClockPulseGate { decider.pulses }

    /// The cumulative counters after the last `run`, as published. Render only.
    var telemetry: KernelCycleTelemetry { counters.pointee }

    /// Step 7: folds `result` into the cumulative counters and publishes them when an output is set.
    private func publishTelemetry(_ blockStart: Int64, _ ackEpoch: UInt64, _ result: KernelCycleResult) {
        var totals = counters.pointee
        totals.cycle = KernelCycleTelemetry.saturatingAdd(totals.cycle, 1)
        totals.ackEpochSeen = ackEpoch
        if result.status == .silenced(.scopeFaulted) {
            totals.lastFaultedCycle = totals.cycle
            totals.lastFaultedAckEpoch = ackEpoch
            lastFaultedAckEpoch.store(ackEpoch, ordering: .releasing)
        }
        totals.droppedLate = KernelCycleTelemetry.saturatingAdd(totals.droppedLate, result.droppedLate)
        if result.resync { totals.resyncs = KernelCycleTelemetry.saturatingAdd(totals.resyncs, 1) }
        totals.skippedStale = decider.pulses.skippedStale
        totals.rateLimited = decider.pulses.rateLimited
        totals.pending = result.pending
        totals.flushing = result.flushing
        totals.discardedWhileSilenced = KernelCycleTelemetry.saturatingAdd(totals.discardedWhileSilenced,
                                                                           result.discardedWhileSilenced)
        totals.discardedSuperseded = KernelCycleTelemetry.saturatingAdd(totals.discardedSuperseded,
                                                                        result.discardedSuperseded)
        totals.discardedDuringTakeover = KernelCycleTelemetry.saturatingAdd(totals.discardedDuringTakeover,
                                                                            result.discardedDuringTakeover)
        totals.refusedNonMonotonic = admissionRefusals.total(.nonMonotonic)
        totals.refusedBeyondLookahead = admissionRefusals.total(.beyondLookahead)
        totals.blockAppendRefused = watermark.appendRefused
        counters.pointee = totals
        guard let output = telemetryOutput else { return }
        _ = output.slots.publish(slot: output.slot, value: totals,
                                 stamp: TelemetryStamp(clockGeneration: output.clockGeneration, frame: blockStart))
    }

    /// Takes every scope's safety requests; returns `true` when any was `panic`.
    private func applySafety(_ blockStart: Int64, _ releasedNotes: inout Int,
                             _ emit: (KernelEvent, Int64) -> Void) -> Bool {
        var panicked = false
        for index in 0..<safety.scopeCount {
            let scope = UInt32(truncatingIfNeeded: index)
            let requests = safety.take(scope: scope)
            guard !requests.isEmpty else { continue }
            if requests.contains(.panic) { panicked = true }
            releasedNotes &+= release(scope, blockStart, emit)
        }
        return panicked
    }

    /// Releases every note `scope` owns, emitting each as a synthesized `noteOff` at `blockStart`.
    private func release(_ scope: UInt32, _ blockStart: Int64, _ emit: (KernelEvent, Int64) -> Void) -> Int {
        ownership.releaseAll(scope: scope) { channel, note in
            emit(KernelEvent(frame: blockStart, scope: scope, sequence: Self.releaseSequence,
                             payload: .noteOff(channel: channel, note: note)), blockStart)
        }
    }
}
