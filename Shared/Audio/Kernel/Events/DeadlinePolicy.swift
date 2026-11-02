// #64 E2 deadline policy: decides, once per block, whether an event is dispatched on time, dispatched late at the
// block start, dropped as too late, or left for a later block; and refuses producers that schedule beyond the
// lookahead or out of frame order. Arithmetic is exact and never traps. Reference model; not RT-certified.

/// What the render consumer does with one event in the current block. Reference model; not RT-certified.
enum DeadlineDecision: Sendable, Equatable, BitwiseCopyable {
    /// The event's frame is inside the block: dispatch it at that frame.
    case dispatch(atFrame: Int64)
    /// The event is late but must not be lost: dispatch it now, at the block's first frame. A late `noteOn` gets
    /// this only within `lateTolerance` (see the lane rules; plan row `lateNoteBeyondToleranceDroppedAndCounted`).
    case dispatchLate(atFrame: Int64)
    /// The event is late beyond tolerance and safe to lose: the caller discards and counts it (E5 `droppedLate`).
    case dropLate
    /// The event is due in a later block. Only events at or after `blockStart` get this; a late event never does,
    /// so lateness is never re-queued or postponed.
    case notYet
}

/// Deadline rules for one event handoff, built from a validated R6 frame horizon. A value type with no mutable
/// state, and both methods are pure: render calls `decide` on its copy; producers call `admit` before pushing.
///
/// Lane rules for a late event (`frame < blockStart`, lateness `blockStart − frame`):
/// - `release` (`noteOff`, the only `critical` class): always `dispatchLate`, at any lateness. Dropping a release
///   leaves a stuck note.
/// - `transport` (`clockPulse`): always `dispatchLate`. `ClockPulseGate` owns pulse staleness, so it can count the
///   skip and raise one resync; dropping here would hide stale pulses from it.
/// - `state` (`control`, `program`): always `dispatchLate`. They are stateful and never coalesced; dropping one
///   leaves the receiver in the wrong state indefinitely.
/// - `content`: `noteOn` is `dispatchLate` while lateness ≤ `lateTolerance` and `dropLate` beyond it, since a note
///   sounding long after its time is wrong and its later `noteOff` is a harmless unowned no-op. `rampTo` is
///   `dispatchLate` like `state`: it carries a target value, and E3 starts a replacing ramp from the current value.
///
/// Arithmetic: block membership, lateness and lookahead use the exact unsigned distance between two `Int64`
/// frames (wrapping subtraction of the ordered pair), so `Int64.min`, `Int64.max`, a lateness of `2^64 − 1` and
/// a block that reaches `Int64.max` are all exact. `blockStart + blockFrames` and `now + lookahead` are never
/// formed. Frames are monotonic render sample time.
///
/// Empty cycles: when a render cycle has `frames <= 0`, E5 drains no timed events and calls neither
/// `DeadlinePolicy.decide` nor `ClockPulseGate.admit` (safety and fault handling still run); timed events wait in
/// their queues for the next non-empty cycle. Producer-side `DeadlinePolicy.admit` is not part of the render
/// cycle and is unaffected.
/// `decide` still returns a defined, trap-free value for `blockFrames <= 0` as a guard, but callers must not rely
/// on it.
///
/// Caller ordering contract (stuck-note trap): order the block's events by their original `event.frame`, then
/// lane, producer and sequence, *before* deciding, and apply them in that order. Never re-sort by the decided
/// frame: `dispatchLate` collapses many late events onto `blockStart`, where a lane-first sort would put a
/// `noteOff` (release lane) ahead of the earlier `noteOn` it releases and leave the note stuck.
/// Always pass the original `event.frame` (the event itself), never a frame returned in a decision.
/// Reference model; not RT-certified.
struct DeadlinePolicy: Sendable, Equatable, BitwiseCopyable {
    /// Why a deadline policy could not be prepared.
    enum PreparationError: Error, Equatable, Sendable {
        /// The handoff policy fails `HandoffPolicy.validate()`.
        case policy(HandoffPolicyError)
        /// The horizon is `.none`: a render deadline needs frames.
        case noHorizon
        /// Outside R6: `0 <= lateTolerance <= lookahead` and `0 < lookahead <= KernelLimits.maximumHorizonFrames`.
        case horizonOutOfRange(lateTolerance: Int64, lookahead: Int64)
    }

    /// Largest lateness, in frames, at which a droppable event is still dispatched (inclusive).
    let lateTolerance: Int64
    /// Furthest ahead of `now`, in frames, that a producer may schedule (inclusive).
    let lookahead: Int64

    /// Control-side preparation. Accepts the same bounds R6 enforces for a declared frame horizon.
    init(lateTolerance: Int64, lookahead: Int64) throws(PreparationError) {
        guard lateTolerance >= 0, lateTolerance <= lookahead, lookahead > 0,
              lookahead <= KernelLimits.maximumHorizonFrames else {
            throw .horizonOutOfRange(lateTolerance: lateTolerance, lookahead: lookahead)
        }
        self.lateTolerance = lateTolerance
        self.lookahead = lookahead
    }

    /// Control-side preparation from a declared horizon; `.none` throws `.noHorizon`.
    init(horizon: DeadlineHorizon) throws(PreparationError) {
        switch horizon {
        case .none:
            throw .noHorizon
        case .frames(let lateTolerance, let lookahead):
            try self.init(lateTolerance: lateTolerance, lookahead: lookahead)
        }
    }

    /// Control-side preparation from a handoff policy, which must validate and declare a frame horizon.
    init(policy: HandoffPolicy) throws(PreparationError) {
        do {
            try policy.validate()
        } catch {
            throw .policy(error)
        }
        try self.init(horizon: policy.deadline)
    }

    /// Decides `event` for the block `[blockStart, blockStart + blockFrames)`.
    ///
    /// Callers pass only non-empty blocks (see "Empty cycles" above). As a trap-free guard, `blockFrames <= 0` is
    /// treated as a block containing no frame: events at or after `blockStart` are `notYet`, and late events get
    /// the same decision as in any block. A block may reach `Int64.max`; frames past it do not exist, so nothing
    /// is lost.
    func decide(_ event: KernelEvent, blockStart: Int64, blockFrames: Int64) -> DeadlineDecision {
        if event.frame >= blockStart {
            guard blockFrames > 0,
                  Self.distance(from: blockStart, to: event.frame) < UInt64(bitPattern: blockFrames) else {
                return .notYet
            }
            return .dispatch(atFrame: event.frame)
        }
        guard Self.dropsWhenLate(event.payload),
              Self.distance(from: event.frame, to: blockStart) > UInt64(bitPattern: lateTolerance) else {
            return .dispatchLate(atFrame: blockStart)
        }
        return .dropLate
    }

    /// Producer-side admission. Refuses `.beyondLookahead` when `eventFrame > now + lookahead` (checked first),
    /// then `.nonMonotonic` when `eventFrame < lastAdmittedFrame` (the producer's previous admitted frame; equal
    /// frames are allowed). A frame at or before `now` is admitted: `decide` handles lateness.
    ///
    /// `lastAdmittedFrame` is the caller's per-producer state: update it only after the event was actually pushed
    /// (a refused or failed push leaves it unchanged), and reset it to `nil` on a timeline discontinuity
    /// (relocation, restart), since frames are otherwise monotonic render sample time.
    func admit(eventFrame: Int64, now: Int64, lastAdmittedFrame: Int64? = nil) -> KernelStatus {
        if eventFrame > now, Self.distance(from: now, to: eventFrame) > UInt64(bitPattern: lookahead) {
            return .refused(.beyondLookahead)
        }
        if let lastAdmittedFrame, eventFrame < lastAdmittedFrame { return .refused(.nonMonotonic) }
        return .ok
    }

    /// Whether a late event of this payload may be dropped beyond `lateTolerance`. Only `noteOn`; see the lane rules.
    static func dropsWhenLate(_ payload: KernelEventPayload) -> Bool {
        switch payload {
        case .noteOn: true
        case .noteOff, .clockPulse, .control, .program, .rampTo: false
        }
    }

    /// Exactly `later − earlier` for `later >= earlier`. The true difference is in `0...UInt64.max`, and the
    /// wrapping subtraction yields exactly that bit pattern, so this never traps.
    static func distance(from earlier: Int64, to later: Int64) -> UInt64 {
        UInt64(bitPattern: later &- earlier)
    }
}
