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
    var resync = false
}

/// Steps 4–6 of a `KernelCycle`: decides buffered events in buffer order, applies them to ownership, tombstones,
/// the clock gate and ramps, consumes notes while silenced and advances ramps. All storage is allocated in
/// `init`. Render only after init; owned privately by one `KernelCycle`. Reference model; not RT-certified.
final class KernelBlockDecider {
    let deadline: DeadlinePolicy
    private let ownership: NoteOwnership
    private let ramps: RampSlots
    /// Latest release frame per note key; see `ReleaseTombstones`.
    private let tombstones: ReleaseTombstones
    /// The gate's cumulative counters and resync state.
    private let gate: UnsafeMutablePointer<ClockPulseGate>
    /// Each parameter's last known value: where a replacing ramp starts when none is active.
    private let values: UnsafeMutablePointer<Float>
    /// Each parameter's frame offset already advanced in the current block.
    private let advanced: UnsafeMutablePointer<Int64>

    init(deadline: DeadlinePolicy, ownership: NoteOwnership, ramps: RampSlots, pulses: ClockPulseGate) {
        self.deadline = deadline
        self.ownership = ownership
        self.ramps = ramps
        tombstones = ReleaseTombstones(scopes: ownership.scopeCount)
        gate = .allocate(capacity: 1)
        gate.initialize(to: pulses)
        values = .allocate(capacity: ramps.parameterCount)
        values.initialize(repeating: 0, count: ramps.parameterCount)
        advanced = .allocate(capacity: ramps.parameterCount)
        advanced.initialize(repeating: 0, count: ramps.parameterCount)
    }

    deinit {
        gate.deallocate()
        values.deallocate()
        advanced.deallocate()
    }

    /// The gate's cumulative counters and resync state.
    var pulses: ClockPulseGate { gate.pointee }

    /// `parameter`'s value at the end of the last block, or `nil` when out of range.
    func parameterValue(_ parameter: UInt32) -> Float? {
        guard parameter < UInt32(truncatingIfNeeded: ramps.parameterCount) else { return nil }
        return values[Int(parameter)]
    }

    /// Step 4: decides and applies `block`'s entries in order; keeps the first `notYet` and everything after it.
    /// `flushing`: a lane's flush bit is set, so every decided `noteOn` is discarded.
    func decide(_ block: KernelBlockBuffer, flushing: Bool, _ window: (start: Int64, frames: Int64),
                _ tally: inout KernelCycleTally, _ emit: (KernelEvent, Int64) -> Void) {
        let (blockStart, frames) = window
        var index = 0
        while index < block.count {
            let entry = block[index]
            let event = entry.event
            switch deadline.decide(event, blockStart: blockStart, blockFrames: frames) {
            case .notYet:
                block.removeFirst(index)
                tally.resync = gate.pointee.takeResync()
                return
            case .dropLate:
                tally.droppedLate &+= 1
            case .dispatch(let frame), .dispatchLate(let frame):
                if case .noteOn = event.payload, entry.flushed || flushing {
                    tally.discardedWhileSilenced &+= 1
                } else {
                    apply(event, at: frame, blockStart, &tally, emit)
                }
            }
            index &+= 1
        }
        block.removeFirst(index)
        tally.resync = gate.pointee.takeResync()
    }

    /// Step 5: a silenced cycle discards buffered `noteOn`s, applies buffered `noteOff`s to ownership (emitting
    /// only real releases) and keeps every other event in order.
    func consumeNotesWhileSilenced(_ block: KernelBlockBuffer, _ blockStart: Int64, _ tally: inout KernelCycleTally,
                                   _ emit: (KernelEvent, Int64) -> Void) {
        block.retain { entry in
            switch entry.event.payload {
            case .noteOn:
                tally.discardedWhileSilenced &+= 1
            case .noteOff(let channel, let note):
                tombstones.release(entry.event)
                guard ownership.noteOff(scope: entry.event.scope, channel: channel, note: note) else {
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
            _ = ownership.noteOff(scope: event.scope, channel: channel, note: note)
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
    func advanceRamps(to frames: Int64) {
        for index in 0..<ramps.parameterCount {
            if let value = ramps.advance(parameter: UInt32(truncatingIfNeeded: index),
                                         frames: frames &- advanced[index]) {
                values[index] = value
            }
            advanced[index] = 0
        }
    }
}
