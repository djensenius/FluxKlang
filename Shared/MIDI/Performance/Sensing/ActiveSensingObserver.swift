/// Where one input stands. Deadlines and stamps are host ticks.
enum ActiveSensingPhase: Equatable, Sendable {
    /// No Active Sensing byte (0xFE) seen yet, or reset by 0xFF. Such an input can never be reported lost.
    case unarmed
    /// Sensing is live: loss is reported at the first stamp at or after `deadline`.
    case armed(deadline: UInt64)
    /// Loss was reported; `since` is the deadline that elapsed (not the stamp of the call that noticed it).
    case lost(since: UInt64)

    fileprivate var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }
}

/// The result of one `observe` or `poll`.
enum ActiveSensingOutcome: Equatable, Sendable {
    /// Nothing to report.
    case none
    /// The input moved to `armed` because of a 0xFE it sent.
    case armed
    /// Sensing was lost; reported exactly once per arming. `requestInputLost` copies the policy's loss action.
    case lost(input: MIDIInputID, requestInputLost: Bool)
}

/// Observes the Active Sensing traffic of one MIDI input. Pure: no clock, timer, thread or MIDI I/O.
///
/// - The observer arms on the first 0xFE; before that no gap is ever a loss (legacy devices keep working).
/// - Once armed, any event from the input (channel, system common, SysEx, real-time including clock) refreshes the
///   deadline to `stamp + timeoutTicks`; 0xFE is not special after arming. 0xFF (System Reset) disarms.
/// - Loss fires when `stamp >= deadline` and fires once; later polls return `.none` until a new 0xFE re-arms.
///   An event arriving at or after the deadline first reports the loss, then is processed (it re-arms only if it
///   is 0xFE, and 0xFF still disarms).
/// - Time is monotonic: a stamp below the last accepted one is refused; an equal stamp is accepted; 0 is a stamp.
/// - A refused call leaves the whole value unchanged. The observer reports; it never releases notes by itself.
/// - Framing hides a SysEx until its F7, so a transfer longer than the timeout looks like silence if only parsed
///   events are fed. Feed every received byte through `observe(byte:at:)` at its packet's stamp; feeding only parsed
///   events is allowed, but then a long SysEx CAN be reported lost.
struct ActiveSensingObserver: Equatable, Sendable {
    let input: MIDIInputID
    let policy: ActiveSensingPolicy
    private(set) var phase: ActiveSensingPhase
    private(set) var lastTick: UInt64?

    init(input: MIDIInputID, policy: ActiveSensingPolicy) {
        self.input = input
        self.policy = policy
        phase = .unarmed
        lastTick = nil
    }

    /// Feeds one event of this input at `stamp`. Refusals: `invalidTimeout`, `tickRegressed`, `deadlineOverflow`.
    ///
    /// A framing parser emits nothing for a SysEx until its F7, so feeding only parsed events makes a transfer longer
    /// than the timeout look like silence and it CAN be reported lost; see `observe(byte:at:)`.
    mutating func observe(
        _ event: MIDI1Event,
        at stamp: HostStamp
    ) throws(ActiveSensingRefusal) -> ActiveSensingOutcome {
        commit(try evaluate(Self.traffic(of: event), at: stamp.ticks), at: stamp.ticks)
    }

    /// Feeds one raw received byte of this input at its packet's `stamp`, before any message framing.
    ///
    /// Why it exists: the framing parser returns nothing for F0 and the payload bytes until F7, so a SysEx dump longer
    /// than the timeout is continuous activity that produces no event. Feed every received byte, at the stamp of the
    /// packet that carried it (bytes of one packet share a stamp; equal stamps are accepted), so the activity refreshes
    /// the deadline. 0xFE arms or refreshes, 0xFF disarms, every other value (data or status) is plain activity: it
    /// refreshes an armed deadline and never arms. Same refusals, order, late-event rule and atomicity as
    /// `observe(_:at:)`.
    mutating func observe(
        byte: UInt8,
        at stamp: HostStamp
    ) throws(ActiveSensingRefusal) -> ActiveSensingOutcome {
        commit(try evaluate(Self.traffic(ofByte: byte), at: stamp.ticks), at: stamp.ticks)
    }

    /// Advances time without an event. Refusals: `invalidTimeout`, `tickRegressed`.
    mutating func poll(at stamp: HostStamp) throws(ActiveSensingRefusal) -> ActiveSensingOutcome {
        commit(try evaluate(nil, at: stamp.ticks), at: stamp.ticks)
    }
}

extension ActiveSensingObserver {
    private enum Traffic {
        case sensing
        case reset
        case other
    }

    private struct Step {
        var phase: ActiveSensingPhase
        var outcome: ActiveSensingOutcome
    }

    private mutating func commit(_ step: Step, at now: UInt64) -> ActiveSensingOutcome {
        phase = step.phase
        lastTick = now
        return step.outcome
    }

    private static func traffic(ofByte byte: UInt8) -> Traffic {
        switch byte {
        case 0xFE: return .sensing
        case 0xFF: return .reset
        default: return .other
        }
    }

    private static func traffic(of event: MIDI1Event) -> Traffic {
        switch event {
        case .realTime(let status):
            return traffic(ofByte: status)
        case .channel, .systemCommon, .sysEx:
            return .other
        }
    }

    private func nextDeadline(from now: UInt64) throws(ActiveSensingRefusal) -> UInt64 {
        let (deadline, overflow) = now.addingReportingOverflow(policy.timeoutTicks)
        guard !overflow else { throw .deadlineOverflow }
        return deadline
    }

    /// Computes the next phase and outcome without touching `self`, so a refusal changes nothing.
    private func evaluate(_ traffic: Traffic?, at now: UInt64) throws(ActiveSensingRefusal) -> Step {
        try policy.validate()
        if let last = lastTick, now < last { throw .tickRegressed(last: last, found: now) }
        var step = Step(phase: phase, outcome: .none)
        if case .armed(let deadline) = phase, now >= deadline {
            step.phase = .lost(since: deadline)
            step.outcome = .lost(input: input, requestInputLost: policy.lossAction == .requestInputLost)
        }
        guard let traffic else { return step }
        switch traffic {
        case .reset:
            step.phase = .unarmed
        case .sensing:
            if !step.phase.isArmed && step.outcome == .none { step.outcome = .armed }
            step.phase = .armed(deadline: try nextDeadline(from: now))
        case .other:
            if step.phase.isArmed { step.phase = .armed(deadline: try nextDeadline(from: now)) }
        }
        return step
    }
}
