import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Fixtures for the control input gate suites. Every session is built through `LearnSession`'s own transitions.
struct ControlInputGateTests {
    static let deviceA = DeviceID(validated: "dev.ctl-a")
    static let deviceB = DeviceID(validated: "dev.ctl-b")
    static let size = ParameterID(validated: "par.verb.size")
    static let level = ParameterID(validated: "par.mains.gain")
    static let newID = BindingID(validated: "bnd.knob5-size")
    static let absolute128 = EncoderProfile.absolute(resolution: 128)
    static let twos7 = EncoderProfile.twosComplement(width: .seven)

    struct Phased {
        let kind: LearnPhaseKind
        let session: LearnSession
    }

    static func sample(_ number: UInt16 = 5, raw: Int = 64, kind: ControlSourceKind = .controller,
                       origin: String = "lcxl-1", channel: UInt8 = 1) throws -> ControlIntakeSample {
        let key = try ControlSourceKey(origin: ControlSourceOrigin(origin), channel: channel, kind: kind,
                                       number: number)
        return ControlIntakeSample(key: key, raw: raw, width: kind.width,
                                   input: .absolute(normalized: Double(raw) / Double(kind.width.maximumRaw)))
    }

    static func context(now: UInt64, present: Set<DeviceID> = [deviceA],
                        existing: [ControlBinding] = []) -> ControlGateContext {
        ControlGateContext(present: present, existing: existing, now: now)
    }

    static func descriptor(_ id: ParameterID, unit: ParameterUnit = .normalized, range: ClosedRange<Double> = 0...1,
                           curve: ParameterCurve = .linear,
                           controlClass: ControlClass = .live) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
            ceiling: nil, curve: curve, ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    static func listening(on target: ParameterDescriptor? = nil, timeoutTicks: UInt64 = 100,
                          now: UInt64 = 0) throws -> LearnSession {
        var session = LearnSession()
        try session.start(target ?? descriptor(size), binding: newID, policy: LearnEligibilityPolicy(),
                          timeoutTicks: timeoutTicks, now: now)
        return session
    }

    static func reviewing() throws -> LearnSession {
        var session = try listening()
        let heard = LearnHeardControl(device: deviceA, source: ControlSourceID(validated: "ctl.setup"),
                                      profile: absolute128)
        _ = try session.hear(heard, present: [deviceA], existing: [], now: 1)
        return session
    }

    static func committed() throws -> LearnSession {
        var session = try reviewing()
        _ = try session.confirm(descriptor: descriptor(size), existing: [])
        return session
    }

    static func cancelled() throws -> LearnSession {
        var session = try listening()
        try session.cancel()
        return session
    }

    static func blocked() throws -> LearnSession {
        var session = LearnSession()
        try session.start(descriptor(level, unit: .decibels, range: 0...60, controlClass: .hazardous),
                          binding: newID, policy: LearnEligibilityPolicy(), timeoutTicks: 10, now: 0)
        return session
    }

    static func everyPhase() throws -> [Phased] {
        [Phased(kind: .idle, session: LearnSession()), Phased(kind: .listening, session: try listening()),
         Phased(kind: .awaitingReview, session: try reviewing()), Phased(kind: .committed, session: try committed()),
         Phased(kind: .cancelled, session: try cancelled()), Phased(kind: .blocked, session: try blocked())]
    }

    static func delivered(_ decision: ControlGateDecision) -> ControlIntakeSample? {
        if case .deliver(let delivery) = decision { return delivery.sample }
        return nil
    }

    static func binding(_ id: String, source: String, target: ParameterID) throws -> ControlBinding {
        try ControlBinding(.init(id: BindingID(id), source: ControlSourceID(source), target: target,
                                 unit: .normalized, profile: absolute128, pickup: .jump))
    }
}
