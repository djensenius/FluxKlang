import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlInputGateTests {
    private enum Kind: CaseIterable {
        case delivered, heard, held
    }

    /// A session that makes one routed sample produce exactly one decision of `kind`.
    private static func scenario(_ kind: Kind) throws -> LearnSession {
        switch kind {
        case .delivered: LearnSession()
        case .heard: try listening()
        case .held: try reviewing()
        }
    }

    @Test
    func gateCountsEachDecisionKindInItsOwnCounterOnly() throws {
        for kind in Kind.allCases {
            var gate = ControlInputGate(delivered: 10, heard: 20, held: 30)
            var session = try Self.scenario(kind)
            _ = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128, session: &session,
                           context: Self.context(now: 2))
            switch kind {
            case .delivered: #expect(gate == ControlInputGate(delivered: 11, heard: 20, held: 30))
            case .heard: #expect(gate == ControlInputGate(delivered: 10, heard: 21, held: 30))
            case .held: #expect(gate == ControlInputGate(delivered: 10, heard: 20, held: 31))
            }
        }
    }

    @Test
    func gateCountersSumToTheNumberOfCallsAcrossAMixedRun() throws {
        var gate = ControlInputGate()
        #expect(gate.delivered == 0 && gate.heard == 0 && gate.held == 0)
        var idle = LearnSession()
        var listening = try Self.listening()
        var calls: UInt64 = 0
        for now in UInt64(1)...3 {
            _ = gate.route(try Self.sample(), from: Self.deviceA, profile: nil, session: &idle,
                           context: Self.context(now: now))
            _ = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128, session: &listening,
                           context: Self.context(now: now))
            calls += 2
        }
        #expect(gate == ControlInputGate(delivered: 3, heard: 1, held: 2))
        #expect(gate.delivered + gate.heard + gate.held == calls)
    }

    @Test
    func gateCountersSaturateAtUInt64MaxAndNeverWrapOrMoveTheOthers() throws {
        for kind in Kind.allCases {
            let top = UInt64.max
            for start in [top - 2, top - 1, top] {
                var gate = ControlInputGate(delivered: kind == .delivered ? start : 5,
                                            heard: kind == .heard ? start : 6,
                                            held: kind == .held ? start : 7)
                var session = try Self.scenario(kind)
                _ = gate.route(try Self.sample(), from: Self.deviceA, profile: Self.absolute128, session: &session,
                               context: Self.context(now: 2))
                let next = start == top ? top : start + 1
                let expected = ControlInputGate(delivered: kind == .delivered ? next : 5,
                                                heard: kind == .heard ? next : 6,
                                                held: kind == .held ? next : 7)
                #expect(gate == expected, "\(kind) from \(start)")
            }
        }
    }

    @Test
    func gateWithAllCountersAtMaxStillRoutesEveryKindExactly() throws {
        var gate = ControlInputGate(delivered: .max, heard: .max, held: .max)
        var idle = LearnSession()
        var listening = try Self.listening()
        let sample = try Self.sample()
        #expect(Self.delivered(gate.route(sample, from: Self.deviceA, profile: nil, session: &idle,
                                          context: Self.context(now: 1))) == sample)
        guard case .hear = gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &listening,
                                      context: Self.context(now: 1)) else {
            Issue.record("expected hear")
            return
        }
        #expect(gate.route(sample, from: Self.deviceA, profile: Self.absolute128, session: &listening,
                           context: Self.context(now: 2)) == .held(.awaitingReview))
        #expect(gate == ControlInputGate(delivered: .max, heard: .max, held: .max))
    }
}
