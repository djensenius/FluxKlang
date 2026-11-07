import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlInputGateTests {
    @Test
    func gateHearsTheFirstControlWithTheCallersDeviceAndProfile() throws {
        var gate = ControlInputGate()
        var session = try Self.listening()
        let sample = try Self.sample(9, raw: 1, origin: "enc-7", channel: 3)
        let decision = gate.route(sample, from: Self.deviceB, profile: Self.twos7, session: &session,
                                  context: Self.context(now: 4, present: [Self.deviceB]))
        let expected = LearnHeardControl(device: Self.deviceB, source: ControlSourceID(validated: "midi.enc-7.3.cc.9"),
                                         profile: Self.twos7)
        #expect(decision == .hear(expected))
        guard case .awaitingReview(let review) = session.phase else { Issue.record("not reviewing"); return }
        #expect(review.proposal.device == Self.deviceB)
        #expect(review.proposal.binding.source == expected.source)
        #expect(review.proposal.binding.profile == Self.twos7)
        #expect(session.lastTick == 4)
        #expect(gate == ControlInputGate(delivered: 0, heard: 1, held: 0))
    }

    @Test
    func gateHoldsTheNextSampleAfterARecordedControlAndLeavesTheProposalAlone() throws {
        var gate = ControlInputGate()
        var session = try Self.listening()
        let context = Self.context(now: 2)
        _ = gate.route(try Self.sample(5), from: Self.deviceA, profile: Self.absolute128, session: &session,
                       context: context)
        let reviewed = session
        let second = gate.route(try Self.sample(6, raw: 9), from: Self.deviceA, profile: Self.absolute128,
                                session: &session, context: Self.context(now: 3))
        #expect(second == .held(.awaitingReview))
        #expect(session == reviewed)
        #expect(gate == ControlInputGate(delivered: 0, heard: 1, held: 1))
    }

    @Test
    func gateHoldsAMissingProfileWithoutCallingHearEvenWhenHearWouldTimeOutOrIgnore() throws {
        var gate = ControlInputGate()
        var session = try Self.listening(timeoutTicks: 100, now: 0)
        let before = session
        let decision = gate.route(try Self.sample(), from: Self.deviceB, profile: nil, session: &session,
                                  context: Self.context(now: 500, present: []))
        #expect(decision == .held(.profileNotChosen))
        #expect(session == before)
        #expect(session.phase.kind == .listening && session.lastTick == 0)
        #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
    }

    @Test
    func gateNeverGuessesAProfileTheSameSampleHearsOnlyWithOne() throws {
        let sample = try Self.sample(11, raw: 3)
        var withoutProfile = try Self.listening()
        var withProfile = try Self.listening()
        var gate = ControlInputGate()
        #expect(gate.route(sample, from: Self.deviceA, profile: nil, session: &withoutProfile,
                           context: Self.context(now: 1)) == .held(.profileNotChosen))
        #expect(withoutProfile.phase.kind == .listening)
        guard case .hear(let heard) = gate.route(sample, from: Self.deviceA, profile: Self.twos7,
                                                 session: &withProfile, context: Self.context(now: 1)) else {
            Issue.record("expected hear")
            return
        }
        #expect(heard.profile == Self.twos7)
        #expect(withProfile.phase.kind == .awaitingReview)
    }

    @Test
    func gateHoldsARawValueTheChosenProfileCannotReadAtItsBoundary() throws {
        let inside = try Self.sample(1, raw: 127, kind: .controller14)
        let outside = try Self.sample(1, raw: 128, kind: .controller14)
        var accepted = try Self.listening()
        var gate = ControlInputGate()
        guard case .hear = gate.route(inside, from: Self.deviceA, profile: Self.absolute128, session: &accepted,
                                      context: Self.context(now: 1)) else {
            Issue.record("raw 127 should be heard")
            return
        }
        // Past the deadline and from an absent device as well: the raw check comes first and `hear` is not called.
        var session = try Self.listening()
        let before = session
        let decision = gate.route(outside, from: Self.deviceB, profile: Self.absolute128, session: &session,
                                  context: Self.context(now: 500, present: []))
        #expect(decision == .held(.rawOutsideProfile(.rawOutOfRange(128, lower: 0, upper: 127))))
        #expect(session == before)
        #expect(gate == ControlInputGate(delivered: 0, heard: 1, held: 1))
    }

    @Test
    func gateLeavesAnInvalidProfileToHearsRefusal() throws {
        for resolution in [1, 0, EncoderProfile.maximumResolution + 1] {
            var gate = ControlInputGate()
            var session = try Self.listening()
            let before = session
            let decision = gate.route(try Self.sample(), from: Self.deviceA,
                                      profile: .absolute(resolution: resolution), session: &session,
                                      context: Self.context(now: 1))
            #expect(decision == .held(.heardRefused(.invalidProfile(.invalidResolution(resolution)))))
            #expect(session == before)
            #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
        }
    }

    @Test
    func gateHoldsAbsentDevicesAsIgnoredAndKeepsListening() throws {
        var gate = ControlInputGate()
        var session = try Self.listening()
        let absent = gate.route(try Self.sample(), from: Self.deviceB, profile: Self.absolute128, session: &session,
                                context: Self.context(now: 1))
        #expect(absent == .held(.ignored(.deviceAbsent(Self.deviceB))))
        #expect(session.phase.kind == .listening && session.lastTick == 1)
        let present = gate.route(try Self.sample(), from: Self.deviceB, profile: Self.absolute128, session: &session,
                                 context: Self.context(now: 2, present: [Self.deviceB]))
        guard case .hear = present else { Issue.record("expected hear"); return }
        #expect(gate == ControlInputGate(delivered: 0, heard: 1, held: 1))
    }

    @Test
    func gateHoldsControlsThatCannotBindAsIgnoredWithTheirReason() throws {
        let taper = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, curve: .faderTaper)
        var gate = ControlInputGate()
        var tapered = try Self.listening(on: taper)
        let taperDecision = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128,
                                       session: &tapered, context: Self.context(now: 1))
        #expect(taperDecision == .held(.ignored(.incompatible(.undefinedCurve(.faderTaper)))))
        #expect(tapered.phase.kind == .listening)
        var flat = try Self.listening(on: Self.descriptor(Self.size, range: 0.5...0.5))
        #expect(gate.route(try Self.sample(raw: 1), from: Self.deviceA, profile: Self.twos7, session: &flat,
                           context: Self.context(now: 1)) == .held(.ignored(.noUsableStep)))
        #expect(flat.phase.kind == .listening)
        #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 2))
    }

    @Test
    func gateHearsTwoDifferentSamplesInBothOrdersFirstHeardSecondHeld() throws {
        let knob = try Self.sample(5, raw: 10)
        let fader = try Self.sample(6, raw: 20, origin: "lcxl-2", channel: 2)
        let knobSource = ControlSourceID(validated: "midi.lcxl-1.1.cc.5")
        let faderSource = ControlSourceID(validated: "midi.lcxl-2.2.cc.6")
        let orders = [(first: knob, second: fader, source: knobSource),
                      (first: fader, second: knob, source: faderSource)]
        for order in orders {
            var gate = ControlInputGate()
            var session = try Self.listening()
            let first = gate.route(order.first, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                   context: Self.context(now: 1))
            #expect(first == .hear(LearnHeardControl(device: Self.deviceA, source: order.source,
                                                     profile: Self.absolute128)))
            let reviewed = session
            let second = gate.route(order.second, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                    context: Self.context(now: 2))
            #expect(second == .held(.awaitingReview))
            #expect(session == reviewed)
            guard case .awaitingReview(let review) = session.phase else { Issue.record("not reviewing"); return }
            #expect(review.proposal.binding.source == order.source)
            #expect(gate == ControlInputGate(delivered: 0, heard: 1, held: 1))
        }
    }
}
