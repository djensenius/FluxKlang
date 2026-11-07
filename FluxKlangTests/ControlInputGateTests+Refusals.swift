import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlInputGateTests {
    @Test
    func gateTimeoutHearsOneTickBeforeTheDeadlineAndSwallowsTheSampleAtIt() throws {
        for (start, timeout) in [(UInt64(0), UInt64(100)), (50, 10)] {
            let sample = try Self.sample()
            var early = try Self.listening(timeoutTicks: timeout, now: start)
            var gate = ControlInputGate()
            guard case .hear = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &early,
                                          context: Self.context(now: start + timeout - 1)) else {
                Issue.record("N-1 should hear")
                continue
            }
            var session = try Self.listening(timeoutTicks: timeout, now: start)
            let decision = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                      context: Self.context(now: start + timeout))
            #expect(decision == .held(.timedOut))
            #expect(session.phase == .cancelled(.timedOut) && session.lastTick == start + timeout)
            let after = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                   context: Self.context(now: start + timeout + 1))
            #expect(Self.delivered(after) == sample)
            #expect(gate == ControlInputGate(delivered: 1, heard: 1, held: 1))
        }
    }

    @Test
    func gateReportsTimedOutBeforeAnyPresenceOrBindingBoundWhenSeveralDefectsCoincide() throws {
        let devices = try (0...LearnSession.maximumPresentDevices).map { try DeviceID("dev.d\($0)") }
        let existing = try (0...LearnConflicts.maximumExistingBindings).map {
            try Self.binding("bnd.n\($0)", source: "ctl.n\($0)", target: Self.level)
        }
        let invalid = EncoderProfile.absolute(resolution: 1)
        for profile in [Self.absolute128, invalid] {
            var gate = ControlInputGate()
            var session = try Self.listening(timeoutTicks: 5, now: 0)
            let decision = gate.route(try Self.sample(), from: Self.deviceA, profile: profile, session: &session,
                                      context: Self.context(now: 5, present: Set(devices), existing: existing))
            #expect(decision == .held(.timedOut))
            #expect(session.phase == .cancelled(.timedOut))
            #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
        }
    }

    @Test
    func gateRefusesARegressedTickAndLeavesTheSessionEqual() throws {
        let sample = try Self.sample()
        var gate = ControlInputGate()
        var session = try Self.listening(now: 10)
        let before = session
        let decision = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                  context: Self.context(now: 9))
        #expect(decision == .held(.heardRefused(.tickRegressed(last: 10, now: 9))))
        #expect(session == before)
        #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
        guard case .hear = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                      context: Self.context(now: 10)) else {
            Issue.record("an equal tick is allowed")
            return
        }
    }

    @Test
    func gatePassesTwoHundredFiftySixPresentDevicesAndRefusesTwoHundredFiftySeven() throws {
        let others = try (0..<(LearnSession.maximumPresentDevices - 1)).map { try DeviceID("dev.d\($0)") }
        let atLimit = Set(others + [Self.deviceA])
        let overLimit = atLimit.union([try DeviceID("dev.extra")])
        #expect(atLimit.count == 256 && overLimit.count == 257)
        var gate = ControlInputGate()
        var accepted = try Self.listening()
        guard case .hear = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128,
                                      session: &accepted, context: Self.context(now: 1, present: atLimit)) else {
            Issue.record("256 present devices should hear")
            return
        }
        var refused = try Self.listening()
        let before = refused
        let decision = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128, session: &refused,
                                  context: Self.context(now: 1, present: overLimit))
        #expect(decision == .held(.heardRefused(.tooManyPresentDevices(257))))
        #expect(refused == before)
    }

    @Test
    func gatePassesFourThousandNinetySixExistingBindingsAndRefusesFourThousandNinetySeven() throws {
        let many = try (0...LearnConflicts.maximumExistingBindings).map {
            try Self.binding("bnd.n\($0)", source: "ctl.n\($0)", target: Self.level)
        }
        var gate = ControlInputGate()
        var accepted = try Self.listening()
        guard case .hear = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128,
                                      session: &accepted,
                                      context: Self.context(now: 1, existing: Array(many.dropLast()))) else {
            Issue.record("4096 bindings should hear")
            return
        }
        var refused = try Self.listening()
        let before = refused
        let decision = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128, session: &refused,
                                  context: Self.context(now: 1, existing: many))
        #expect(decision == .held(.heardRefused(.tooManyBindings(4_097))))
        #expect(refused == before)
    }

    @Test
    func gateHoldsEveryRefusalWithoutDeliveringChangingTheSessionOrCountingItAsHeard() throws {
        let duplicates = try [Self.binding("bnd.dup", source: "ctl.a", target: Self.level),
                              Self.binding("bnd.dup", source: "ctl.b", target: Self.level)]
        struct Case {
            let profile: EncoderProfile
            let now: UInt64
            let existing: [ControlBinding]
            let refusal: LearnRefusal
        }
        let cases = [
            Case(profile: .absolute(resolution: 1), now: 3, existing: [],
                 refusal: .invalidProfile(.invalidResolution(1))),
            Case(profile: Self.absolute128, now: 2, existing: [], refusal: .tickRegressed(last: 3, now: 2)),
            Case(profile: Self.absolute128, now: 4, existing: duplicates,
                 refusal: .duplicateBinding(BindingID(validated: "bnd.dup")))
        ]
        for item in cases {
            var gate = ControlInputGate()
            var session = try Self.listening(now: 3)
            let before = session
            let decision = gate.route(try Self.sample(), from: Self.deviceA, profile: item.profile, session: &session,
                                      context: Self.context(now: item.now, existing: item.existing))
            #expect(decision == .held(.heardRefused(item.refusal)))
            #expect(Self.delivered(decision) == nil)
            #expect(session == before)
            #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
        }
    }

    @Test
    func gateFullSessionSequenceDeliversOnlyOutsideTheActiveWindow() throws {
        var gate = ControlInputGate()
        var session = LearnSession()
        let sample = try Self.sample()
        func route(_ now: UInt64) -> ControlGateDecision {
            gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &session,
                       context: Self.context(now: now))
        }
        #expect(Self.delivered(route(0)) == sample)
        try session.start(Self.descriptor(Self.size), binding: Self.newID, policy: LearnEligibilityPolicy(),
                          timeoutTicks: 100, now: 1)
        guard case .hear = route(2) else { Issue.record("expected hear"); return }
        #expect(route(3) == .held(.awaitingReview))
        _ = try session.confirm(descriptor: Self.descriptor(Self.size), existing: [])
        #expect(Self.delivered(route(4)) == sample)
        try session.start(Self.descriptor(Self.size), binding: Self.newID, policy: LearnEligibilityPolicy(),
                          timeoutTicks: 10, now: 5)
        try session.cancel()
        #expect(Self.delivered(route(6)) == sample)
        #expect(gate == ControlInputGate(delivered: 3, heard: 1, held: 1))
    }
}
