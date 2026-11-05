//
//  MIDIClockFollower.swift
//  FluxKlang
//
//  The Start/Continue/Stop/Song Position Pointer state machine of one external
//  MIDI clock source. Host time is always supplied by the caller. The follower
//  reports positions and advisory generation reasons; it never writes the
//  transport or the generation ledger itself.
//
//  Clocks sharing one host time are valid and are ordinary pulses. The tempo
//  estimator measures the span of its timestamp window, so batched or late
//  delivery only costs an endpoint error of (maximum lag) / window. A window
//  whose halves disagree by more than 4 x (maximum lag) / window holds the last
//  estimate, and while locked the estimate follows gradual ramps. One absolute
//  dropout bound governs both arriving gaps and the silence check.
//

/// What a received clock message did to the follower.
enum MIDIClockFollowerEvent: Equatable, Sendable {
    /// Start: armed at tick 0; the next clock plays tick 0.
    case started
    /// Continue: armed at `ticks`; `relocated` when that differs from the last reported position.
    case continued(ticks: Int64, relocated: Bool)
    /// Stop; the next Continue resumes at `ticks`.
    case stopped(ticks: Int64)
    /// A Song Position Pointer while not running moved the next pulse to `ticks`.
    case located(ticks: Int64)
    /// A clock while running played `ticks`; `located` when a Song Position Pointer
    /// received while running took effect at this pulse.
    case pulse(ticks: Int64, host: HostStamp, located: Bool)

    /// The advisory generation bump for the transport, if any.
    var bumpReason: GenerationBumpReason? {
        switch self {
        case .started: .transportRestart
        case let .continued(ticks, relocated): relocated ? .locate(ticks: ticks) : nil
        case .stopped: nil
        case let .located(ticks): .locate(ticks: ticks)
        case let .pulse(ticks, _, located): located ? .locate(ticks: ticks) : nil
        }
    }
}

/// Follows one external clock source. Competing sources are arbitrated elsewhere.
struct MIDIClockFollower: Sendable {
    enum State: Equatable, Sendable {
        case stopped, armed, running
    }

    private(set) var state = State.stopped
    /// The tick the next clock plays once armed or running.
    private(set) var nextPulseTicks: Int64
    /// A Song Position Pointer received while running, applied at the next clock.
    private(set) var pendingLocateTicks: Int64?
    private(set) var lastHost: HostStamp?
    /// The next-pulse position last reported to the transport; nil until one is.
    private var reportedTicks: Int64?

    /// A stopped follower whose next Continue resumes at `position`.
    init(position: Int64 = 0) throws(MIDIClockError) {
        guard position >= 0 else { throw .negativeTicks(position) }
        nextPulseTicks = position
    }

    /// Applies one message at `host`. Messages may share a host time but never go back.
    /// Clocks while stopped return nil and leave the position alone.
    mutating func receive(_ message: MIDIClockMessage,
                          at host: HostStamp) throws(MIDIClockError) -> MIDIClockFollowerEvent? {
        if let lastHost, host.ticks < lastHost.ticks {
            throw .nonMonotonicHost(previous: lastHost.ticks, current: host.ticks)
        }
        let event: MIDIClockFollowerEvent?
        switch message {
        case .clock: event = try clock(at: host)
        case .start: event = start()
        case .continue: event = resume()
        case .stop: event = stop()
        case let .songPosition(position): event = try locate(MIDIClockMath.ticks(forSongPosition: position))
        }
        lastHost = host
        return event
    }

    private mutating func clock(at host: HostStamp) throws(MIDIClockError) -> MIDIClockFollowerEvent? {
        guard state != .stopped else { return nil }
        let ticks = pendingLocateTicks ?? nextPulseTicks
        let (next, overflow) = ticks.addingReportingOverflow(MIDIClockMath.ticksPerPulse)
        guard !overflow else { throw .positionOverflow }
        let located = pendingLocateTicks != nil
        state = .running
        pendingLocateTicks = nil
        nextPulseTicks = next
        reportedTicks = next
        return .pulse(ticks: ticks, host: host, located: located)
    }

    private mutating func start() -> MIDIClockFollowerEvent {
        state = .armed
        pendingLocateTicks = nil
        nextPulseTicks = 0
        reportedTicks = 0
        return .started
    }

    private mutating func resume() -> MIDIClockFollowerEvent? {
        guard state == .stopped else { return nil }
        state = .armed
        let relocated = reportedTicks != nextPulseTicks
        reportedTicks = nextPulseTicks
        return .continued(ticks: nextPulseTicks, relocated: relocated)
    }

    private mutating func stop() -> MIDIClockFollowerEvent? {
        guard state != .stopped else { return nil }
        state = .stopped
        if let pendingLocateTicks {
            // The jump was never played, so the next Continue reports it as a locate.
            nextPulseTicks = pendingLocateTicks
            self.pendingLocateTicks = nil
        }
        return .stopped(ticks: nextPulseTicks)
    }

    private mutating func locate(_ ticks: Int64) -> MIDIClockFollowerEvent? {
        guard state != .running else {
            pendingLocateTicks = ticks
            return nil
        }
        nextPulseTicks = ticks
        reportedTicks = ticks
        return .located(ticks: ticks)
    }
}
