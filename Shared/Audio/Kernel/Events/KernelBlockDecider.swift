// #64 E5b kernel cycle component: deciding and applying buffered events, the silenced consume and the ramps,
// split by composition from `KernelCycle.swift`. Storage is private. Reference model; not RT-certified.

/// What the decide and silenced-consume steps did; `KernelCycle` folds it into its `KernelCycleResult`.
/// Reference model; not RT-certified.
struct KernelCycleTally: Sendable, BitwiseCopyable, Equatable {
    var dispatched = 0
    var droppedLate = 0
    var refused = 0
    var skippedPulses = 0
    var discardedWhileSilenced = 0
    var discardedSuperseded = 0
    var discardedDuringTakeover = 0
    var resync = false
}

/// Steps 4–6 of a `KernelCycle`: decides buffered events in buffer order, applies them to ownership, tombstones,
/// the clock gate and ramps, consumes notes while silenced and advances ramps. All storage is allocated in
/// `init`. Render only after init; owned privately by one `KernelCycle`. Reference model; not RT-certified.
final class KernelBlockDecider {
    let deadline: DeadlinePolicy
    private let ownership: NoteOwnership
    /// The ramps and each parameter's last known value (`RampSlots.lastValue`): shared state, not this cycle's, so
    /// a `.replacingCycle` replacement given the same slots starts every ramp from the value the retired cycle left
    /// (round 2l). This decider never caches a value itself.
    private let ramps: RampSlots
    /// Latest release frame per note key: `ownership.tombstones`, shared by every cycle over that ownership (see
    /// `ReleaseTombstones`).
    private let tombstones: ReleaseTombstones
    /// The gate's cumulative counters and resync state.
    private let gate: UnsafeMutablePointer<ClockPulseGate>
    /// Each parameter's frame offset already advanced in the current block. Per cycle: `advanceRamps` resets every
    /// offset to 0 at the end of each block, so between runs (and so at any retirement) all are 0 and a replacement's
    /// zeroed offsets continue exactly.
    private let advanced: UnsafeMutablePointer<Int64>
    /// The next scope a `.replacingCycle` takeover releases; `ownership.scopeCount` once none is pending.
    private let takeoverScope: UnsafeMutablePointer<Int>
    /// One bit per note key (`NoteOwnership`'s layout) this cycle's takeover released: the key's next unowned
    /// `noteOff` this cycle sees (decided, or consumed while silenced) is consumed and clears the bit, so this cycle
    /// never emits a second `noteOff` for that release. An owned (re-struck) note's `noteOff` releases it as usual
    /// and keeps the bit. Per cycle: a later replacement starts with no bits.
    private let takenOver: UnsafeMutablePointer<UInt64>
    /// The inherited carry's prepared slots (#364 KCR1), merged into `decide`; empty unless a carry was inherited.
    private let readmission: KernelCarryReadmission

    /// `takeover`: a `.replacingCycle` start, so the notes `ownership` marks sounding are released (see
    /// `releaseTakeover`).
    init(deadline: DeadlinePolicy, ownership: NoteOwnership, ramps: RampSlots, pulses: ClockPulseGate,
         takeover: Bool, readmission: KernelCarryReadmission) {
        self.deadline = deadline
        self.readmission = readmission
        self.ownership = ownership
        self.ramps = ramps
        tombstones = ownership.tombstones
        takeoverScope = .allocate(capacity: 1)
        takeoverScope.initialize(to: takeover ? 0 : ownership.scopeCount)
        takenOver = .allocate(capacity: ownership.scopeCount &* NoteOwnership.wordsPerScope)
        takenOver.initialize(repeating: 0, count: ownership.scopeCount &* NoteOwnership.wordsPerScope)
        gate = .allocate(capacity: 1)
        gate.initialize(to: pulses)
        advanced = .allocate(capacity: ramps.parameterCount)
        advanced.initialize(repeating: 0, count: ramps.parameterCount)
    }

    deinit {
        gate.deallocate()
        advanced.deallocate()
        takeoverScope.deallocate()
        takenOver.deallocate()
    }

    /// A `.replacingCycle` takeover still has notes to release.
    var takeoverPending: Bool { takeoverScope.pointee < ownership.scopeCount }

    /// `true` while the takeover has not yet finished `scope` (`scope` at or after its cursor): a decided `noteOn`
    /// there is discarded (`discardedDuringTakeover`), so the takeover only ever cuts notes the retired cycle left
    /// sounding. Scopes before the cursor are fully released and sound again; out-of-range scopes are refused as
    /// usual. `false` once the takeover ended.
    private func heldByTakeover(_ scope: UInt32) -> Bool {
        let index = Int(scope)
        return index >= takeoverScope.pointee && index < ownership.scopeCount
    }

    /// Step 1, `.replacingCycle` only: releases at most `limit` notes `ownership` still marks sounding (left by the
    /// retired cycle, whose buffered `noteOff`s this cycle never sees), in (scope, channel, note) order, each as a
    /// synthesized `noteOff` at `blockStart` with `releaseSequence`, and clears their ownership. The rest carry to
    /// the next cycle; nothing is dropped. Returns the count.
    func releaseTakeover(_ blockStart: Int64, limit: Int, sequence: UInt64,
                         _ emit: (KernelEvent, Int64) -> Void) -> Int {
        var released = 0
        while takeoverScope.pointee < ownership.scopeCount {
            let scope = UInt32(truncatingIfNeeded: takeoverScope.pointee)
            released &+= ownership.releaseFirst(scope: scope, limit: limit &- released) { channel, note in
                takenOver[Self.key(scope, channel, note)] |= Self.bit(note)
                emit(KernelEvent(frame: blockStart, scope: scope, sequence: sequence,
                                 payload: .noteOff(channel: channel, note: note)), blockStart)
            }
            guard ownership.ownedCount(scope: scope) == 0 else { break }
            takeoverScope.pointee &+= 1
        }
        return released
    }

    /// Clears the key's takeover bit; `true` when it was set (the takeover already released that note).
    private func clearTakenOver(_ scope: UInt32, _ channel: UInt8, _ note: UInt8) -> Bool {
        guard scope < UInt32(truncatingIfNeeded: ownership.scopeCount), Int(channel) < NoteOwnership.channels,
              Int(note) < NoteOwnership.notesPerChannel else { return false }
        let index = Self.key(scope, channel, note)
        let bit = Self.bit(note)
        guard takenOver[index] & bit != 0 else { return false }
        takenOver[index] &= ~bit
        return true
    }

    private static func key(_ scope: UInt32, _ channel: UInt8, _ note: UInt8) -> Int {
        Int(scope) &* NoteOwnership.wordsPerScope &+ Int(channel) &* 2 &+ Int(note &>> 6)
    }

    private static func bit(_ note: UInt8) -> UInt64 {
        1 &<< UInt64(note & 63)
    }

    /// The gate's cumulative counters and resync state.
    var pulses: ClockPulseGate { gate.pointee }

    /// `parameter`'s last known value in the shared `RampSlots` (at the end of the last block run over them, by this
    /// cycle or its retired predecessor), or `nil` when out of range.
    func parameterValue(_ parameter: UInt32) -> Float? {
        ramps.lastValue(parameter: parameter)
    }

    /// Step 4: decides and applies `block`'s entries in order; keeps the first `notYet` and everything after it.
    /// `flushing`: a lane's flush bit is set, so every decided `noteOn` is discarded (`discardedWhileSilenced`);
    /// otherwise a `noteOn` in a scope the takeover still holds is discarded (`discardedDuringTakeover`).
    /// Re-admitted carried events (`KernelCarryReadmission`) are merged in by original frame, each before a buffered
    /// event of the same frame; they are not counted in `tally`.
    func decide(_ block: KernelBlockBuffer, flushing: Bool, _ window: (start: Int64, frames: Int64),
                _ tally: inout KernelCycleTally, _ emit: (KernelEvent, Int64) -> Void) {
        let (blockStart, frames) = window
        var index = 0
        while index < block.count {
            let entry = block[index]
            let event = entry.event
            readmit(through: event.frame, window, emit)
            switch deadline.decide(event, blockStart: blockStart, blockFrames: frames) {
            case .notYet:
                block.removeFirst(index)
                readmit(through: Int64.max, window, emit)
                tally.resync = gate.pointee.takeResync()
                return
            case .dropLate:
                tally.droppedLate &+= 1
            case .dispatch(let frame), .dispatchLate(let frame):
                if case .noteOn = event.payload, entry.flushed || flushing {
                    tally.discardedWhileSilenced &+= 1
                } else if case .noteOn = event.payload, heldByTakeover(event.scope) {
                    tally.discardedDuringTakeover &+= 1
                } else {
                    let before = tally.dispatched
                    apply(event, at: frame, blockStart, &tally, emit)
                    if tally.dispatched != before { readmission.supersede(by: event) }
                }
            }
            index &+= 1
        }
        block.removeFirst(index)
        readmit(through: Int64.max, window, emit)
        tally.resync = gate.pointee.takeResync()
    }

    /// Applies and emits, in order, the pending re-admitted events with an original frame at or before `limit` that
    /// are due in `window`; stops at the first one not yet due. A carried event is never dropped late (only
    /// `noteOn`s are), so an already-due one dispatches at `blockStart`.
    private func readmit(through limit: Int64, _ window: (start: Int64, frames: Int64),
                         _ emit: (KernelEvent, Int64) -> Void) {
        while let event = readmission.next, event.frame <= limit {
            var counted = KernelCycleTally()
            switch deadline.decide(event, blockStart: window.start, blockFrames: window.frames) {
            case .notYet:
                return
            case .dropLate:
                break
            case .dispatch(let frame), .dispatchLate(let frame):
                apply(event, at: frame, window.start, &counted, emit)
            }
            readmission.consumeNext(delivered: counted.dispatched == 1)
        }
    }

    /// Step 5: a silenced cycle discards buffered `noteOn`s, applies buffered `noteOff`s to ownership (emitting
    /// only real releases; an unowned one also clears its takeover bit, being the key's next unowned `noteOff`) and
    /// keeps every other event in order.
    func consumeNotesWhileSilenced(_ block: KernelBlockBuffer, _ blockStart: Int64, _ tally: inout KernelCycleTally,
                                   _ emit: (KernelEvent, Int64) -> Void) {
        block.retain { entry in
            switch entry.event.payload {
            case .noteOn:
                tally.discardedWhileSilenced &+= 1
            case .noteOff(let channel, let note):
                tombstones.release(entry.event)
                guard ownership.noteOff(scope: entry.event.scope, channel: channel, note: note) else {
                    _ = clearTakenOver(entry.event.scope, channel, note)
                    tally.discardedWhileSilenced &+= 1
                    return false
                }
                tally.dispatched &+= 1
                emit(entry.event, blockStart)
            case .control, .program, .clockPulse, .rampTo:
                return true
            }
            return false
        }
    }

    /// Applies one due event and emits it, or counts why it was not emitted.
    private func apply(_ event: KernelEvent, at frame: Int64, _ blockStart: Int64, _ tally: inout KernelCycleTally,
                       _ emit: (KernelEvent, Int64) -> Void) {
        switch event.payload {
        case .noteOn(let channel, let note, _):
            guard !tombstones.supersedes(event, blockStart: blockStart, lateTolerance: deadline.lateTolerance) else {
                tally.discardedSuperseded &+= 1
                return
            }
            guard ownership.noteOn(scope: event.scope, channel: channel, note: note) == .ok else {
                tally.refused &+= 1
                return
            }
        case .noteOff(let channel, let note):
            tombstones.release(event)
            if !ownership.noteOff(scope: event.scope, channel: channel, note: note),
               clearTakenOver(event.scope, channel, note) {
                // This cycle's takeover already released this note: its late `noteOff` is consumed, not emitted again.
                tally.discardedWhileSilenced &+= 1
                return
            }
        case .clockPulse:
            guard gate.pointee.admit(pulseFrame: event.frame, blockStart: blockStart) == .emit else {
                tally.skippedPulses &+= 1
                return
            }
        case .rampTo(let parameter, let value, let durationFrames):
            // A due frame is in `blockStart..<blockStart + frames`, so the offset is exact and non-negative.
            let offset = Int64(bitPattern: DeadlinePolicy.distance(from: blockStart, to: frame))
            guard startRamp(parameter, value, durationFrames, at: offset) else {
                tally.refused &+= 1
                return
            }
        case .control, .program:
            break
        }
        tally.dispatched &+= 1
        emit(event, frame)
    }

    /// Advances `parameter`'s active ramp to `offset`, then replaces it from that value (or the last known value
    /// when idle, which `RampSlots` keeps). `false` when `RampSlots` refuses; the old ramp then keeps running from
    /// `offset`.
    private func startRamp(_ parameter: UInt32, _ target: Float, _ duration: Int64, at offset: Int64) -> Bool {
        guard let current = ramps.lastValue(parameter: parameter) else { return false }
        let index = Int(parameter)
        // Due events are decided in frame order, so `offset >= advanced[index]` within a block.
        let value = ramps.advance(parameter: parameter, frames: offset &- advanced[index]) ?? current
        advanced[index] = offset
        return ramps.set(parameter: parameter, target: target, durationFrames: duration, current: value) == .ok
    }

    /// Step 6: advances every parameter to the block's end and resets the per-block offsets.
    func advanceRamps(to frames: Int64) {
        for index in 0..<ramps.parameterCount {
            _ = ramps.advance(parameter: UInt32(truncatingIfNeeded: index), frames: frames &- advanced[index])
            advanced[index] = 0
        }
    }
}
