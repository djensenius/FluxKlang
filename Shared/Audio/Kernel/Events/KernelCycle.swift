// #64 E5a kernel cycle core: one bounded, render-owned block of event work composed from the accepted E2/E3 parts.
// Not wired into any render path, AU callback or audio buffer; plan adoption (`noPlan`), the output buffer, gate
// telemetry and the `.staleClock` decision are E5b's. Reference model; not RT-certified.

/// What one `KernelCycle.run` did. Every drained event that leaves the block buffer is counted in exactly one of
/// `dispatched`, `droppedLate`, `refused`, `skippedPulses`, `discardedWhileSilenced` or `discardedSuperseded`;
/// synthesized releases are counted only in `releasedNotes`.
/// Reference model; not RT-certified.
struct KernelCycleResult: Sendable, BitwiseCopyable, Equatable {
    /// `.ok`; `.silenced(.scopeFaulted)` while the critical scope is latched; else `.silenced(.safetyMute)` on panic.
    fileprivate(set) var status: KernelStatus = .ok
    /// Events moved from the fan-in into the block buffer.
    fileprivate(set) var drained = 0
    /// Events passed to `emit`, on time or late; in a silenced cycle, only `noteOff`s that released an owned note.
    fileprivate(set) var dispatched = 0
    /// `noteOn`s later than the deadline tolerance: discarded and counted, never emitted (E2 `dropLate`).
    fileprivate(set) var droppedLate = 0
    /// Due events the cycle could not apply and did not emit: a `noteOn` that `NoteOwnership` refused (scope,
    /// channel or note out of range) or a `rampTo` that `RampSlots` refused (parameter out of range, non-finite).
    fileprivate(set) var refused = 0
    /// Due clock pulses the gate skipped (stale or rate-limited); the gate keeps the cumulative counters.
    fileprivate(set) var skippedPulses = 0
    /// Note events consumed without emitting: a silenced cycle's buffered `noteOn`s and unowned `noteOff`s, and
    /// `noteOn`s decided while flushing (see the type's Flush watermark).
    fileprivate(set) var discardedWhileSilenced = 0
    /// Decided `noteOn`s a same-key `noteOff` strictly after their frame already released (`ReleaseTombstones`).
    fileprivate(set) var discardedSuperseded = 0
    /// A lane was still flushing after this cycle's drain (see the type's Flush watermark).
    fileprivate(set) var flushing = false
    /// Owned notes released by safety requests or by critical-fault recovery, each emitted as a synthesized
    /// `noteOff` at `blockStart`.
    fileprivate(set) var releasedNotes = 0
    /// The gate's single resync marker for the current stall was taken in this cycle.
    fileprivate(set) var resync = false
    /// Events left in the block buffer for a later cycle.
    fileprivate(set) var pending = 0
}

/// The render-owned parts one `KernelCycle` composes. Reference model; not RT-certified.
struct KernelCycleParts {
    /// Render-consumed events; its policy supplies the deadline horizon.
    let events: FanInHandoff<KernelEvent>
    /// The latch `events` raises on; its `criticalScope` must be prepared in it.
    let faults: FaultLatch
    let ownership: NoteOwnership
    /// Must have as many scopes as `ownership`.
    let safety: SafetyFlags
    let ramps: RampSlots
}

/// One render-owned kernel cycle per block. Reference model; not RT-certified.
///
/// `run` does, in order:
/// 1. Safety: takes every scope's `SafetyFlags`; any request releases that scope's owned notes (bits, never
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
///
/// Per due event: `noteOn` is emitted only if no same-key release after its frame was applied (release
/// tombstones; cross-lane order is otherwise not guaranteed) and `NoteOwnership` accepts it; `noteOff` records its
/// tombstone, clears ownership and is always emitted; `control`/`program` are never merged; `clockPulse` goes
/// through the gate with its original frame; `rampTo` replaces the ramp from its value at the dispatch frame.
/// `emit` gets the event and its frame.
///
/// Flush watermark. A latched loss means some lane may hold a `noteOn` ahead of its refused `noteOff`, possibly
/// behind a full buffer. Each latched cycle sets every lane's flush bit; a drain clears a lane's bit when it proves
/// that lane empty (fewer delivered than its limit). Events drained from a flushing lane are marked, and while any
/// bit is set (even after acknowledgement) or for a marked event, a decided `noteOn` is discarded and counted in
/// `discardedWhileSilenced`; `noteOff`s apply as usual. Lanes are FIFO, so once every bit clears every pre-fault
/// event has been drained, and a marked one never sounds. `KernelCycleResult.flushing` reports set bits.
///
/// Acknowledgement contract. Control acknowledges a critical fault only after render has reported a silenced
/// (`.scopeFaulted`) cycle that began after control's `observe`; that cycle armed the watermark. An earlier
/// acknowledgement can let a queued `noteOn` sound and stick. The E5b telemetry handshake is a follow-up.
///
/// Stale clocks: the gate's one marker per stall is `KernelCycleResult.resync`; E5a intentionally raises no
/// `.staleClock` (E5b's decision) and adds no `FaultLatch.raise` site. Frame order: E5a tolerates a producer's
/// frames going backwards (ordered by original frame, decided late or dropped); producers reset discontinuities
/// via `DeadlinePolicy.admit` before pushing. Zero-length notes: a same-frame `noteOff` is ordered first and the
/// `noteOn` (a tie, so a retrigger) then sounds and sticks; producers must put the `noteOff` at least a frame later.
///
/// Bounds. All storage (block and scratch buffers, render state, flush bits, tombstones, gate, ramp words) is
/// allocated in `init`. A cycle drains at most the free room, sorts in O(n log n) moves, passes the buffer once
/// more, visits each owned-note word at most twice and each ramp parameter and lane once; a buffer full of future
/// (or, while silenced, non-note) events stops draining (M4/M5 backpressure; the lanes are decided later).
///
/// Contracts. `run`, `parameterValue`, `pulses` and `bufferedCount` are the render consumer's only (the fan-in's
/// single consumer), with a distinct, advancing `blockStart` per non-empty cycle; `emit` must not call back. The
/// parts are kept for life. ARC, metadata and target progress are unqualified (X1 probe), as in M5–M7.
/// `@unchecked Sendable`: all mutable state is render-only, in storage preallocated in `init`.
final class KernelCycle: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// The fan-in is not `.events` consumed on `.render`.
        case notRenderEvents
        /// The fan-in's policy does not give a deadline policy.
        case deadline(DeadlinePolicy.PreparationError)
        /// `blockCapacity` is outside `1...maximumBlockCapacity`.
        case blockCapacityOutOfRange(Int)
        /// `perLaneQuota` is outside `1...KernelLimits.maximumCapacity`.
        case perLaneQuotaOutOfRange(Int)
        /// `ownership` and `safety` do not cover the same scopes.
        case scopeCountMismatch(ownership: Int, safety: Int)
    }

    /// Largest block buffer (inclusive). Ordering is a stable merge sort, so a cycle orders at most
    /// `blockCapacity` events in O(`blockCapacity` log `blockCapacity`) moves.
    static let maximumBlockCapacity = 4_096
    /// `sequence` of every synthesized release.
    static let releaseSequence = UInt64.max

    private struct Buffered: BitwiseCopyable {
        let event: KernelEvent
        let producer: UInt8
        /// Drained from a lane still flushing: a `noteOn` is discarded whenever it is decided.
        let flushed: Bool
    }

    private struct RenderState: BitwiseCopyable {
        var buffered = 0
        var flushingLanes = 0
    }

    let deadline: DeadlinePolicy
    let blockCapacity: Int
    let perLaneQuota: Int

    private let events: FanInHandoff<KernelEvent>
    private let faults: FaultLatch
    private let ownership: NoteOwnership
    private let safety: SafetyFlags
    private let ramps: RampSlots
    private let criticalScope: FaultScope
    private let buffer: UnsafeMutablePointer<Buffered>
    /// Where the newly drained run is merge-sorted; `blockCapacity` slots.
    private let scratch: UnsafeMutablePointer<Buffered>
    /// The buffered count and the number of set flush bits.
    private let state: UnsafeMutablePointer<RenderState>
    /// One flush bit per fan-in lane.
    private let flushLanes: UnsafeMutablePointer<Bool>
    /// Latest release frame per note key; see `ReleaseTombstones`.
    private let tombstones: ReleaseTombstones
    /// The gate's cumulative counters and resync state.
    private let gate: UnsafeMutablePointer<ClockPulseGate>
    /// Each parameter's last known value: where a replacing ramp starts when none is active.
    private let values: UnsafeMutablePointer<Float>
    /// Each parameter's frame offset already advanced in the current block.
    private let advanced: UnsafeMutablePointer<Int64>

    /// Control-side preparation; allocates the block buffer and the ramp bookkeeping.
    init(_ parts: KernelCycleParts, pulses: ClockPulseGate, blockCapacity: Int,
         perLaneQuota: Int) throws(PreparationError) {
        let policy = parts.events.policy
        guard policy.purpose == .events, policy.consumer == .render else { throw .notRenderEvents }
        do {
            deadline = try DeadlinePolicy(policy: policy)
        } catch {
            throw .deadline(error)
        }
        guard blockCapacity >= 1, blockCapacity <= Self.maximumBlockCapacity else {
            throw .blockCapacityOutOfRange(blockCapacity)
        }
        guard perLaneQuota >= 1, perLaneQuota <= KernelLimits.maximumCapacity else {
            throw .perLaneQuotaOutOfRange(perLaneQuota)
        }
        guard parts.ownership.scopeCount == parts.safety.scopeCount else {
            throw .scopeCountMismatch(ownership: parts.ownership.scopeCount, safety: parts.safety.scopeCount)
        }
        self.blockCapacity = blockCapacity
        self.perLaneQuota = perLaneQuota
        events = parts.events
        faults = parts.faults
        ownership = parts.ownership
        safety = parts.safety
        ramps = parts.ramps
        criticalScope = parts.events.criticalScope
        buffer = .allocate(capacity: blockCapacity)
        scratch = .allocate(capacity: blockCapacity)
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState())
        flushLanes = .allocate(capacity: parts.events.laneCount)
        flushLanes.initialize(repeating: false, count: parts.events.laneCount)
        tombstones = ReleaseTombstones(scopes: parts.ownership.scopeCount)
        gate = .allocate(capacity: 1)
        gate.initialize(to: pulses)
        values = .allocate(capacity: parts.ramps.parameterCount)
        values.initialize(repeating: 0, count: parts.ramps.parameterCount)
        advanced = .allocate(capacity: parts.ramps.parameterCount)
        advanced.initialize(repeating: 0, count: parts.ramps.parameterCount)
    }

    /// Control-side teardown only.
    deinit {
        buffer.deallocate()
        scratch.deallocate()
        state.deallocate()
        flushLanes.deallocate()
        gate.deallocate()
        values.deallocate()
        advanced.deallocate()
    }

    /// Render only. Runs one block `[blockStart, blockStart + frames)`; see the type's steps. Never throws, traps
    /// or blocks, for any `blockStart` and `frames`.
    func run(blockStart: Int64, frames: Int64, emit: (KernelEvent, Int64) -> Void) -> KernelCycleResult {
        var result = KernelCycleResult()
        let panicked = applySafety(blockStart, &result, emit)
        if faults.isLatched(criticalScope) {
            for scope in 0..<ownership.scopeCount {
                result.releasedNotes &+= release(UInt32(truncatingIfNeeded: scope), blockStart, emit)
            }
            result.status = .silenced(.scopeFaulted)
            armFlush()
        } else if panicked {
            result.status = .silenced(.safetyMute)
        }
        if frames > 0 { drainIntoBuffer(&result) }
        result.flushing = state.pointee.flushingLanes > 0
        if result.status != .ok {
            consumeNotesWhileSilenced(blockStart, &result, emit)
        } else if frames > 0 {
            decideBlock(blockStart, frames, &result, emit)
        }
        if frames > 0 { advanceRamps(to: frames) }
        result.pending = buffered
        return result
    }

    /// Render only. `parameter`'s value at the end of the last block, or `nil` when out of range.
    func parameterValue(_ parameter: UInt32) -> Float? {
        guard parameter < UInt32(truncatingIfNeeded: ramps.parameterCount) else { return nil }
        return values[Int(parameter)]
    }

    /// Events waiting in the block buffer. Render only.
    var bufferedCount: Int { buffered }

    /// The gate's cumulative counters and resync state. Render only.
    var pulses: ClockPulseGate { gate.pointee }

    private var buffered: Int {
        get { state.pointee.buffered }
        set { state.pointee.buffered = newValue }
    }

    /// Sets every lane's flush bit; called on every latched cycle, so a loss during the latch re-arms too.
    private func armFlush() {
        flushLanes.update(repeating: true, count: events.laneCount)
        state.pointee.flushingLanes = events.laneCount
    }

    /// Takes every scope's safety requests; returns `true` when any was `panic`.
    private func applySafety(_ blockStart: Int64, _ result: inout KernelCycleResult,
                             _ emit: (KernelEvent, Int64) -> Void) -> Bool {
        var panicked = false
        for index in 0..<safety.scopeCount {
            let scope = UInt32(truncatingIfNeeded: index)
            let requests = safety.take(scope: scope)
            guard !requests.isEmpty else { continue }
            if requests.contains(.panic) { panicked = true }
            result.releasedNotes &+= release(scope, blockStart, emit)
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

    /// Step 3: drains into the buffer's free room and orders the buffer.
    private func drainIntoBuffer(_ result: inout KernelCycleResult) {
        let first = buffered
        let room = blockCapacity &- first
        guard room > 0 else { return }
        let slots = buffer
        let flags = flushLanes
        let render = state
        var next = first
        result.drained = events.drain(perLaneQuota: perLaneQuota, total: room, emptied: { lane in
            guard flags[Int(lane)] else { return }
            flags[Int(lane)] = false
            render.pointee.flushingLanes &-= 1
        }, { lane, event in
            (slots + next).initialize(to: Buffered(event: event, producer: lane, flushed: flags[Int(lane)]))
            next &+= 1
        })
        buffered = next
        order(from: first)
    }

    /// Step 5: a silenced cycle discards buffered `noteOn`s, applies buffered `noteOff`s to ownership (emitting
    /// only real releases) and keeps every other event in order.
    private func consumeNotesWhileSilenced(_ blockStart: Int64, _ result: inout KernelCycleResult,
                                           _ emit: (KernelEvent, Int64) -> Void) {
        var kept = 0
        var index = 0
        while index < buffered {
            let item = buffer[index]
            index &+= 1
            switch item.event.payload {
            case .noteOn:
                result.discardedWhileSilenced &+= 1
            case .noteOff(let channel, let note):
                tombstones.release(item.event)
                guard ownership.noteOff(scope: item.event.scope, channel: channel, note: note) else {
                    result.discardedWhileSilenced &+= 1
                    continue
                }
                result.dispatched &+= 1
                emit(item.event, blockStart)
            case .control, .program, .clockPulse, .rampTo:
                buffer[kept] = item
                kept &+= 1
            }
        }
        buffered = kept
    }

    /// Step 4: decides and applies buffered events in order; keeps `notYet` events buffered.
    private func decideBlock(_ blockStart: Int64, _ frames: Int64, _ result: inout KernelCycleResult,
                             _ emit: (KernelEvent, Int64) -> Void) {
        var index = 0
        while index < buffered {
            let item = buffer[index]
            let event = item.event
            switch deadline.decide(event, blockStart: blockStart, blockFrames: frames) {
            case .notYet:
                compact(removing: index)
                result.resync = gate.pointee.takeResync()
                return
            case .dropLate:
                result.droppedLate &+= 1
            case .dispatch(let frame), .dispatchLate(let frame):
                if case .noteOn = event.payload, item.flushed || state.pointee.flushingLanes > 0 {
                    result.discardedWhileSilenced &+= 1
                } else {
                    apply(event, at: frame, blockStart, &result, emit)
                }
            }
            index &+= 1
        }
        compact(removing: index)
        result.resync = gate.pointee.takeResync()
    }

    /// Applies one due event and emits it, or counts why it was not emitted.
    private func apply(_ event: KernelEvent, at frame: Int64, _ blockStart: Int64, _ result: inout KernelCycleResult,
                       _ emit: (KernelEvent, Int64) -> Void) {
        switch event.payload {
        case .noteOn(let channel, let note, _):
            guard !tombstones.supersedes(event, blockStart: blockStart, lateTolerance: deadline.lateTolerance) else {
                result.discardedSuperseded &+= 1
                return
            }
            guard ownership.noteOn(scope: event.scope, channel: channel, note: note) == .ok else {
                result.refused &+= 1
                return
            }
        case .noteOff(let channel, let note):
            tombstones.release(event)
            _ = ownership.noteOff(scope: event.scope, channel: channel, note: note)
        case .clockPulse:
            guard gate.pointee.admit(pulseFrame: event.frame, blockStart: blockStart) == .emit else {
                result.skippedPulses &+= 1
                return
            }
        case .rampTo(let parameter, let value, let durationFrames):
            // A due frame is in `blockStart..<blockStart + frames`, so the offset is exact and non-negative.
            let offset = Int64(bitPattern: DeadlinePolicy.distance(from: blockStart, to: frame))
            guard startRamp(parameter, value, durationFrames, at: offset) else {
                result.refused &+= 1
                return
            }
        case .control, .program:
            break
        }
        result.dispatched &+= 1
        emit(event, frame)
    }

    /// Advances `parameter`'s active ramp to `offset`, then replaces it from that value (or the last known value
    /// when idle). `false` when `RampSlots` refuses; the old ramp then keeps running from `offset`.
    private func startRamp(_ parameter: UInt32, _ target: Float, _ duration: Int64, at offset: Int64) -> Bool {
        guard parameter < UInt32(truncatingIfNeeded: ramps.parameterCount) else { return false }
        let index = Int(parameter)
        // Due events are decided in frame order, so `offset >= advanced[index]` within a block.
        if let value = ramps.advance(parameter: parameter, frames: offset &- advanced[index]) {
            values[index] = value
        }
        advanced[index] = offset
        return ramps.set(parameter: parameter, target: target, durationFrames: duration,
                         current: values[index]) == .ok
    }

    /// Step 6: advances every parameter to the block's end and resets the per-block offsets.
    private func advanceRamps(to frames: Int64) {
        for index in 0..<ramps.parameterCount {
            if let value = ramps.advance(parameter: UInt32(truncatingIfNeeded: index),
                                         frames: frames &- advanced[index]) {
                values[index] = value
            }
            advanced[index] = 0
        }
    }

    /// Orders the new run `buffer[first..<buffered]` by a stable bottom-up merge sort that ping-pongs between
    /// the run and `scratch`, then merges it stably behind the already ordered prefix `buffer[0..<first]`. Equal
    /// keys keep their drain order and prefix events precede run events with equal keys.
    private func order(from first: Int) {
        let count = buffered &- first
        guard count > 0 else { return }
        var source = buffer + first
        var target = scratch
        var width = 1
        while width < count {
            var low = 0
            while low < count {
                let mid = min(low &+ width, count)
                let high = min(mid &+ width, count)
                Self.merge(source, low, mid, high, into: target)
                low = high
            }
            swap(&source, &target)
            width &*= 2
        }
        if source != scratch { scratch.initialize(from: source, count: count) }
        mergeBehindPrefix(first, count)
    }

    /// Merges the sorted run in `scratch[0..<count]` behind `buffer[0..<prefix]`, from the back; on equal keys
    /// the run element takes the later slot.
    private func mergeBehindPrefix(_ prefix: Int, _ count: Int) {
        var left = prefix &- 1
        var right = count &- 1
        var out = prefix &+ count &- 1
        while right >= 0 {
            if left >= 0, Self.precedes(scratch[right], buffer[left]) {
                buffer[out] = buffer[left]
                left &-= 1
            } else {
                buffer[out] = scratch[right]
                right &-= 1
            }
            out &-= 1
        }
    }

    /// Stably merges `source[low..<mid]` and `source[mid..<high]` into `target[low..<high]`.
    private static func merge(_ source: UnsafeMutablePointer<Buffered>, _ low: Int, _ mid: Int, _ high: Int,
                              into target: UnsafeMutablePointer<Buffered>) {
        var left = low
        var right = mid
        var out = low
        while out < high {
            if right < high, left == mid || precedes(source[right], source[left]) {
                (target + out).initialize(to: source[right])
                right &+= 1
            } else {
                (target + out).initialize(to: source[left])
                left &+= 1
            }
            out &+= 1
        }
    }

    /// Moves `buffer[count..<buffered]` to the front.
    private func compact(removing count: Int) {
        guard count > 0 else { return }
        var index = count
        while index < buffered {
            buffer[index &- count] = buffer[index]
            index &+= 1
        }
        buffered &-= count
    }

    /// Strict (original frame, lane, producer lane, sequence) order.
    private static func precedes(_ lhs: Buffered, _ rhs: Buffered) -> Bool {
        if lhs.event.frame != rhs.event.frame { return lhs.event.frame < rhs.event.frame }
        if lhs.event.lane != rhs.event.lane { return lhs.event.lane < rhs.event.lane }
        if lhs.producer != rhs.producer { return lhs.producer < rhs.producer }
        return lhs.event.sequence < rhs.event.sequence
    }
}
