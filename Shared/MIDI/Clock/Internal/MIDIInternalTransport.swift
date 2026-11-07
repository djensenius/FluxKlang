//
//  MIDIInternalTransport.swift
//  FluxKlang
//
//  The internal clock master's run state: stopped at a position, running from a position at a frame, or
//  running with one Stop pending. A pure value: every transition returns a new value, a refusal changes
//  nothing, and every success advances the transport generation by exactly one. No timers, no wall clock.
//

/// The transport of the internal MIDI clock master (#84).
///
/// A Stop is two steps so it can never be lost. `stopping(atFrame:in:)` records the Stop frame and moves to
/// `.stopping`; every other transition is then refused with `stopPending` until a plan that holds the Stop has been
/// stamped, handed over and passed to `settled(after:)`. A plan holds the Stop when its window ends after the Stop
/// frame: the Stop is planned at its own frame, or at the window's first frame when that frame has already gone by.
/// Where the transport rests travels with that plan (`MIDIInternalClockPlan.restingTicks`): the plan's own map
/// places the requested Stop frame, so a tempo edit between the request and the plan moves the resting position
/// together with the clocks the receivers counted. Each successful transition advances `generation` through
/// `Generation.next()`; `settled` is bookkeeping and leaves it alone.
struct MIDIInternalTransport: Equatable, Sendable {
    /// How a run began. Start and Continue are distinct MIDI messages even at tick 0.
    enum Origin: Equatable, Sendable {
        case start
        case `continue`

        /// The real-time message that begins a run of this origin.
        var message: MIDIClockMessage {
            switch self {
            case .start: return .start
            case .continue: return .continue
            }
        }
    }

    /// A run: its first position, the sample frame it began at and how it began.
    struct Run: Equatable, Sendable {
        let fromTicks: Int64
        let atFrame: Int64
        let origin: Origin
    }

    enum State: Equatable, Sendable {
        case stopped(atTicks: Int64)
        case running(Run)
        /// A Stop was requested at `stopFrame`. Where the transport rests is not kept here: the plan that holds the
        /// Stop carries it (`MIDIInternalClockPlan.restingTicks`), so there is a single source of truth.
        case stopping(Run, stopFrame: Int64)
    }

    let generation: Generation
    let state: State

    private init(generation: Generation, state: State) {
        self.generation = generation
        self.state = state
    }

    /// Stopped at tick 0 on the first generation.
    static let initial = MIDIInternalTransport(generation: .initial, state: .stopped(atTicks: 0))

    /// The last frame any plan can hold. A window's end is exclusive and at most `Int64.max`, so `Int64.max - 1` is
    /// the last frame an event can be planned at. A Stop after it, or a run whose Stop would have to be, is refused.
    static let lastPlannableFrame = Int64.max - 1

    /// A stopped transport at `ticks` (not negative) on `generation`. A Stop may rest beyond the Song Position
    /// range, so the upper bound is not checked here: `continuing` and `locating` refuse such a position.
    static func stopped(atTicks ticks: Int64, generation: Generation) throws(MIDIInternalClockError)
        -> MIDIInternalTransport {
        guard ticks >= 0 else { throw .positionOutOfRange(ticks: ticks) }
        return MIDIInternalTransport(generation: generation, state: .stopped(atTicks: ticks))
    }

    /// Starts from position 0 at `frame`, which is at most `lastPlannableFrame - 1`: the run's Stop needs one more
    /// frame. Refused while running or while a Stop is pending. The frame must not precede the first window that
    /// will be planned for the run; otherwise that window holds clocks only, with no Start, Continue or Song
    /// Position. The caller owns this (the transport does not know what was planned).
    func starting(atFrame frame: Int64) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        _ = try restingTicks(whileRunning: .alreadyRunning)
        try Self.requireRunFrame(frame)
        return try advanced(to: .running(Run(fromTicks: 0, atFrame: frame, origin: .start)))
    }

    /// Continues from the stopped position at `frame`, which is at most `lastPlannableFrame - 1` as for `starting`.
    /// The position must lie in `0...MIDIClockMath.maximumSongPositionTicks`; one that is not a whole Song Position
    /// unit is accepted here and refused when a plan would have to emit it (a Stop's resting position rarely is a
    /// whole unit, so move it with `locating(toTicks:)` first). While the run is running every window refuses such a
    /// position; once a Stop is pending, only the windows that begin at or before the run's first frame do, so a
    /// later window still plans the Stop. The frame must not precede the first window that will be planned for the
    /// run; otherwise that window holds clocks only, with no Start, Continue or Song Position. The caller owns this
    /// (the transport does not know what was planned).
    func continuing(atFrame frame: Int64) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        let ticks = try restingTicks(whileRunning: .alreadyRunning)
        try MIDISongPositionNeighbours.requireInRange(ticks)
        try Self.requireRunFrame(frame)
        return try advanced(to: .running(Run(fromTicks: ticks, atFrame: frame, origin: .continue)))
    }

    /// Requests a Stop at `stopFrame`: at least one frame after the first frame of the run and at most
    /// `lastPlannableFrame`, or no plan could ever hold it. `map` must belong to this transport generation and place
    /// the frame (`stopRestingTicks`); a map that cannot is refused here with the refusal the plan that holds the
    /// Stop would give. The resting position is not kept: that plan evaluates it with its own map and carries it
    /// (`MIDIInternalClockPlan.restingTicks`). A position beyond the Song Position range is allowed, so a transport
    /// can always stop.
    func stopping(atFrame stopFrame: Int64, in map: MusicalClockMap) throws(MIDIInternalClockError)
        -> MIDIInternalTransport {
        let run: Run
        switch state {
        case let .running(active): run = active
        case .stopped: throw .alreadyStopped
        case let .stopping(_, pending): throw .stopPending(stopFrame: pending)
        }
        guard map.musical.transport == generation else { throw .staleTransport }
        guard stopFrame > run.atFrame else {
            throw .stopNotAfterStart(startFrame: run.atFrame, stopFrame: stopFrame)
        }
        guard stopFrame <= Self.lastPlannableFrame else { throw .frameNotPlannable(frame: stopFrame) }
        _ = try Self.stopRestingTicks(atFrame: stopFrame, in: map)
        return try advanced(to: .stopping(run, stopFrame: stopFrame))
    }

    /// Where a Stop at `stopFrame` leaves the transport: `map`'s tick position of that frame, rounded half-up. This
    /// is the one rule for the request (`stopping(atFrame:in:)`, which keeps nothing of it) and for the plan that
    /// holds the Stop (which carries it). A frame the map cannot place is refused with `clockMap`, a negative
    /// position with `positionOutOfRange`.
    static func stopRestingTicks(atFrame stopFrame: Int64, in map: MusicalClockMap)
        throws(MIDIInternalClockError) -> Int64 {
        let resting: Int64
        do throws(ClockMapError) {
            resting = try map.ticks(atFrame: stopFrame)
        } catch {
            throw .clockMap(error)
        }
        guard resting >= 0 else { throw .positionOutOfRange(ticks: resting) }
        return resting
    }

    /// Moves a stopped transport to `ticks`, which must lie in `0...MIDIClockMath.maximumSongPositionTicks`.
    func locating(toTicks ticks: Int64) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        _ = try restingTicks(whileRunning: .locateWhileRunning)
        try MIDISongPositionNeighbours.requireInRange(ticks)
        return try advanced(to: .stopped(atTicks: ticks))
    }

    /// Completes a pending Stop once the STAMPED plan that holds it has been handed over, and rests the transport
    /// where that plan says (`MIDIInternalClockPlan.restingTicks`, the plan's own map at the requested Stop frame).
    /// The transport must be `.stopping`, and `plan` must have been made for its generation and carry a position,
    /// which only a plan that holds the Stop does. Any other plan, and every other state, returns the transport as
    /// it is. The generation is unchanged (the Stop request already advanced it). Settle only after
    /// `MIDIInternalClockPlan.stamped(with:current:)` has succeeded and its plan was delivered, not merely after the
    /// plan was made: a settled transport plans nothing, so a stamping refusal after an early settle would drop the
    /// Stop. Until then the Stop stays pending and the next window plans it again, so no window misses it.
    func settled(after plan: MIDIInternalClockPlan) -> MIDIInternalTransport {
        guard case .stopping = state, plan.transportGeneration == generation,
              let resting = plan.restingTicks else { return self }
        return MIDIInternalTransport(generation: generation, state: .stopped(atTicks: resting))
    }

    /// The resting position; a running transport is refused with `refusal`, a pending Stop with `stopPending`.
    private func restingTicks(whileRunning refusal: MIDIInternalClockError) throws(MIDIInternalClockError) -> Int64 {
        switch state {
        case let .stopped(ticks): return ticks
        case .running: throw refusal
        case let .stopping(_, pending): throw .stopPending(stopFrame: pending)
        }
    }

    /// A run needs one frame after its first for the Stop that ends it, so its first frame is at most
    /// `lastPlannableFrame - 1`. A later frame would leave no plan able to hold the run's Stop.
    private static func requireRunFrame(_ frame: Int64) throws(MIDIInternalClockError) {
        guard frame <= lastPlannableFrame - 1 else { throw .frameNotPlannable(frame: frame) }
    }

    private func advanced(to newState: State) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        let next: Generation
        do throws(RevisionError) {
            next = try generation.next()
        } catch {
            throw .generationOverflow
        }
        return MIDIInternalTransport(generation: next, state: newState)
    }
}
