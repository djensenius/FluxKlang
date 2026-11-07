import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlInputGateTests {
    @Test
    func gatePhaseTableDeliversOnlyOutsideActiveSessions() throws {
        let sample = try Self.sample()
        for item in try Self.everyPhase() {
            var gate = ControlInputGate()
            var session = item.session
            let before = session
            let decision = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &session,
                                      context: Self.context(now: 5))
            switch item.kind {
            case .idle, .committed, .cancelled, .blocked:
                #expect(Self.delivered(decision) == sample, "phase \(item.kind)")
                #expect(session == before)
                #expect(gate == ControlInputGate(delivered: 1, heard: 0, held: 0))
            case .listening:
                let source = ControlSourceID(validated: "midi.lcxl-1.1.cc.5")
                let heard = LearnHeardControl(device: Self.deviceA, source: source, profile: Self.absolute128)
                #expect(decision == .hear(heard))
                #expect(session.phase.kind == .awaitingReview)
                #expect(gate == ControlInputGate(delivered: 0, heard: 1, held: 0))
            case .awaitingReview:
                #expect(decision == .held(.awaitingReview))
                #expect(session == before)
                #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
            }
        }
    }

    @Test
    func gateNeverDeliversWhileActiveForAnyProfileSampleOrTick() throws {
        let samples = try [Self.sample(), Self.sample(1, raw: 128, kind: .controller14)]
        let profiles: [EncoderProfile?] = [nil, Self.absolute128, Self.twos7, .absolute(resolution: 1)]
        for item in try Self.everyPhase() {
            for sample in samples {
                for profile in profiles {
                    for now in [UInt64(0), 1, 99, 100, 1_000] {
                        var gate = ControlInputGate()
                        var session = item.session
                        let wasActive = session.phase.isActive
                        let decision = gate.route(sample, from: Self.deviceB, profile: profile, session: &session,
                                                  context: Self.context(now: now))
                        #expect((Self.delivered(decision) != nil) == !wasActive, "\(item.kind) \(now)")
                        #expect(Self.delivered(decision) == nil || Self.delivered(decision) == sample)
                        #expect(gate.delivered == (wasActive ? 0 : 1))
                    }
                }
            }
        }
    }

    @Test
    func gateDeliversInactivePhasesWithoutConsultingProfileTimeOrPresence() throws {
        let samples = try [Self.sample(),
                           Self.sample(7, raw: 16_000, kind: .controller14, origin: "pad-9", channel: 16)]
        for item in try Self.everyPhase() where !item.session.phase.isActive {
            for sample in samples {
                var gate = ControlInputGate()
                var session = item.session
                let decision = gate.route(sample, from: Self.deviceB, profile: nil, session: &session,
                                          context: Self.context(now: 1_000_000, present: [], existing: []))
                #expect(Self.delivered(decision) == sample)
                #expect(session == item.session)
            }
        }
    }

    @Test
    func gateHoldsAwaitingReviewBeforeAnyProfileTimeOrRawCheck() throws {
        let bothDefects = try Self.sample(1, raw: 128, kind: .controller14)
        let reviewing = try Self.reviewing()
        let profiles: [EncoderProfile?] = [nil, Self.absolute128, .absolute(resolution: 1)]
        for profile in profiles {
            var gate = ControlInputGate()
            var session = reviewing
            let decision = gate.route(bothDefects, from: Self.deviceB, profile: profile, session: &session,
                                      context: Self.context(now: 0, present: [], existing: []))
            #expect(decision == .held(.awaitingReview))
            #expect(session == reviewing)
            #expect(gate == ControlInputGate(delivered: 0, heard: 0, held: 1))
        }
    }

    @Test
    func gateDeliveredSampleEqualsTheInputSampleExactly() throws {
        let samples = try [
            Self.sample(0, raw: 0), Self.sample(127, raw: 127), Self.sample(1, raw: 16_383, kind: .controller14),
            Self.sample(0, raw: 8_192, kind: .pitchBend, origin: "a", channel: 16),
            Self.sample(0, raw: 3, kind: .channelPressure, origin: "pad-0123456789", channel: 9)
        ]
        for sample in samples {
            var gate = ControlInputGate()
            var session = LearnSession()
            let decision = gate.route(sample, from: Self.deviceA, profile: nil, session: &session,
                                      context: Self.context(now: 0))
            let delivered = try #require(Self.delivered(decision))
            #expect(delivered == sample)
            #expect(delivered.key == sample.key && delivered.raw == sample.raw)
            #expect(delivered.width == sample.width && delivered.input == sample.input)
        }
    }
}
