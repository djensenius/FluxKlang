// `ControlGateDelivery` is built only in this file (fileprivate initializer): the only way to hold one is to get it
// from `ControlInputGate.route` for a session that was not active.

/// A sample the gate released to the intent path. It carries exactly the routed sample.
struct ControlGateDelivery: Equatable, Sendable {
    let sample: ControlIntakeSample

    fileprivate init(_ sample: ControlIntakeSample) {
        self.sample = sample
    }
}

/// The session-side facts `LearnSession.hear` needs. They are passed through unchanged and re-validated by `hear`.
struct ControlGateContext: Equatable, Sendable {
    let present: Set<DeviceID>
    let existing: [ControlBinding]
    let now: UInt64
}

/// Routes control samples around a `LearnSession`. While the session is active (`listening` or `awaitingReview`) no
/// sample is ever delivered: it is heard or held. Otherwise it is delivered untouched. The gate stores only three
/// saturating counters, never a sample, a queue or a time; it never binds, confirms or cancels, and it changes the
/// session only through `LearnSession.hear` (a refusal leaves the session unchanged).
struct ControlInputGate: Equatable, Sendable {
    private(set) var delivered: UInt64
    private(set) var heard: UInt64
    private(set) var held: UInt64

    init() {
        self.init(delivered: 0, heard: 0, held: 0)
    }

    /// Counters carry no invariant; this exists so saturation can be exercised.
    init(delivered: UInt64, heard: UInt64, held: UInt64) {
        self.delivered = delivered
        self.heard = heard
        self.held = held
    }

    /// Decides on `session.phase` as it is at the call, before `hear` can change it. `profile` is the encoder profile
    /// the user chose in review; `nil` is never replaced by a guess. Every call increments exactly one counter.
    mutating func route(
        _ sample: ControlIntakeSample, from device: DeviceID, profile: EncoderProfile?,
        session: inout LearnSession, context: ControlGateContext
    ) -> ControlGateDecision {
        let decision = decide(sample, from: device, profile: profile, session: &session, context: context)
        switch decision {
        case .deliver: Self.bump(&delivered)
        case .hear: Self.bump(&heard)
        case .held: Self.bump(&held)
        }
        return decision
    }

    private func decide(
        _ sample: ControlIntakeSample, from device: DeviceID, profile: EncoderProfile?,
        session: inout LearnSession, context: ControlGateContext
    ) -> ControlGateDecision {
        switch session.phase {
        case .idle, .committed, .cancelled, .blocked:
            return .deliver(ControlGateDelivery(sample))
        case .awaitingReview:
            return .held(.awaitingReview)
        case .listening:
            guard let profile else { return .held(.profileNotChosen) }
            if let reason = Self.rawRefusal(sample, profile) { return .held(reason) }
            return listen(LearnHeardControl(device: device, source: sample.source, profile: profile),
                          session: &session, context: context)
        }
    }

    private func listen(
        _ heard: LearnHeardControl, session: inout LearnSession, context: ControlGateContext
    ) -> ControlGateDecision {
        do throws(LearnRefusal) {
            switch try session.hear(heard, present: context.present, existing: context.existing, now: context.now) {
            case .recorded: return .hear(heard)
            case .ignored(let reason): return .held(.ignored(reason))
            case .timedOut: return .held(.timedOut)
            }
        } catch {
            return .held(.heardRefused(error))
        }
    }

    /// Only a valid profile that cannot read the raw value counts; an invalid profile is `hear`'s refusal.
    private static func rawRefusal(_ sample: ControlIntakeSample, _ profile: EncoderProfile) -> ControlHoldReason? {
        do {
            _ = try profile.decode(raw: sample.raw)
            return nil
        } catch {
            if case .rawOutOfRange = error { return .rawOutsideProfile(error) }
            return nil
        }
    }

    private static func bump(_ counter: inout UInt64) {
        let (next, overflow) = counter.addingReportingOverflow(1)
        counter = overflow ? UInt64.max : next
    }
}
