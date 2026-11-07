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
/// A Stop is two steps so it can never be lost. `stopping(atFrame:in:)` records the Stop frame and the resting
/// position and moves to `.stopping`; every other transition is then refused with `stopPending` until a plan that
/// holds the Stop has been stamped, handed over and passed to `settled(after:)`. A plan holds the Stop when its
/// window ends after the Stop frame: the Stop is planned at its own frame, or at the window's first frame when that
/// frame has already gone by. Each successful transition advances `generation` through `Generation.next()`;
/// `settled` is bookkeeping and leaves it alone.
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
        /// A Stop was requested at `stopFrame`; the transport will rest at `restingAtTicks`.
        case stopping(Run, stopFrame: Int64, restingAtTicks: Int64)
    }

    let generation: Generation
    let state: State

    private init(generation: Generation, state: State) {
        self.generation = generation
        self.state = state
    }

    /// Stopped at tick 0 on the first generation.
    static let initial = MIDIInternalTransport(generation: .initial, state: .stopped(atTicks: 0))

    /// A stopped transport at `ticks` (not negative) on `generation`. A Stop may rest beyond the Song Position
    /// range, so the upper bound is not checked here: `continuing` and `locating` refuse such a position.
    static func stopped(atTicks ticks: Int64, generation: Generation) throws(MIDIInternalClockError)
        -> MIDIInternalTransport {
        guard ticks >= 0 else { throw .positionOutOfRange(ticks: ticks) }
        return MIDIInternalTransport(generation: generation, state: .stopped(atTicks: ticks))
    }

    /// Starts from position 0 at `frame`. Refused while running or while a Stop is pending. The frame must not
    /// precede the first window that will be planned for the run; otherwise that window holds clocks only, with no
    /// Start, Continue or Song Position. The caller owns this (the transport does not know what was planned).
    func starting(atFrame frame: Int64) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        _ = try restingTicks(whileRunning: .alreadyRunning)
        return try advanced(to: .running(Run(fromTicks: 0, atFrame: frame, origin: .start)))
    }

    /// Continues from the stopped position at `frame`. The position must lie in
    /// `0...MIDIClockMath.maximumSongPositionTicks`; one that is not a whole Song Position unit is accepted here
    /// and refused when a plan would have to emit it (a Stop's resting position rarely is a whole unit, so move it
    /// with `locating(toTicks:)` first). While the run is running every window refuses such a position; once a Stop
    /// is pending, only the windows that begin at or before the run's first frame do, so a later window still plans
    /// the Stop. The frame must not precede the first window that will be planned for the run; otherwise that
    /// window holds clocks only, with no Start, Continue or Song Position. The caller owns this (the transport does
    /// not know what was planned).
    func continuing(atFrame frame: Int64) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        let ticks = try restingTicks(whileRunning: .alreadyRunning)
        try MIDISongPositionNeighbours.requireInRange(ticks)
        return try advanced(to: .running(Run(fromTicks: ticks, atFrame: frame, origin: .continue)))
    }

    /// Requests a Stop at `stopFrame`, one or more frames after the first frame of the run. `map` places the Stop:
    /// it must belong to this transport generation and gives the resting position (rounded half-up), which must
    /// not be negative. A resting position beyond the Song Position range is kept, so a transport can always stop.
    func stopping(atFrame stopFrame: Int64, in map: MusicalClockMap) throws(MIDIInternalClockError)
        -> MIDIInternalTransport {
        let run: Run
        switch state {
        case let .running(active): run = active
        case .stopped: throw .alreadyStopped
        case let .stopping(_, pending, _): throw .stopPending(stopFrame: pending)
        }
        guard map.musical.transport == generation else { throw .staleTransport }
        guard stopFrame > run.atFrame else {
            throw .stopNotAfterStart(startFrame: run.atFrame, stopFrame: stopFrame)
        }
        let resting: Int64
        do throws(ClockMapError) {
            resting = try map.ticks(atFrame: stopFrame)
        } catch {
            throw .clockMap(error)
        }
        guard resting >= 0 else { throw .positionOutOfRange(ticks: resting) }
        return try advanced(to: .stopping(run, stopFrame: stopFrame, restingAtTicks: resting))
    }

    /// Moves a stopped transport to `ticks`, which must lie in `0...MIDIClockMath.maximumSongPositionTicks`.
    func locating(toTicks ticks: Int64) throws(MIDIInternalClockError) -> MIDIInternalTransport {
        _ = try restingTicks(whileRunning: .locateWhileRunning)
        try MIDISongPositionNeighbours.requireInRange(ticks)
        return try advanced(to: .stopped(atTicks: ticks))
    }

    /// Completes a pending Stop once the plan that holds it has been stamped and handed over: the transport must be
    /// `.stopping`, `plan` must have been made for this transport's generation and must contain the Stop message.
    /// Any other plan, and every other state, returns the transport as it is. The generation is unchanged (the Stop
    /// request already advanced it). Settle only after `MIDIInternalClockPlan.stamped(with:current:)` has succeeded
    /// and its plan was delivered, not merely after the plan was made: a settled transport plans nothing, so a
    /// stamping refusal after an early settle would drop the Stop. Until then the Stop stays pending and the next
    /// window plans it again, so no window misses it.
    func settled(after plan: MIDIInternalClockPlan) -> MIDIInternalTransport {
        guard case let .stopping(_, _, resting) = state, plan.transportGeneration == generation,
              plan.events.contains(where: { $0.message == .stop }) else { return self }
        return MIDIInternalTransport(generation: generation, state: .stopped(atTicks: resting))
    }

    /// The resting position; a running transport is refused with `refusal`, a pending Stop with `stopPending`.
    private func restingTicks(whileRunning refusal: MIDIInternalClockError) throws(MIDIInternalClockError) -> Int64 {
        switch state {
        case let .stopped(ticks): return ticks
        case .running: throw refusal
        case let .stopping(_, pending, _): throw .stopPending(stopFrame: pending)
        }
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
