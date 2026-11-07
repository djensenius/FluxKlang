import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `LatencyChangePolicy`: variable latency is accepted inside its range, never blanket-rejected, and agrees with
/// the reprepare ledger's own latency answer (#78, PLG6, slice A).
extension PluginResourceTests {
    @Test func latencyAcceptsEveryNextFromZeroToTheBound() {
        #expect(Self.decide(10, 0, bound: 64) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(10, 9, bound: 64) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(10, 10, bound: 64) == .accept(invalidateDelayPlans: false))
        #expect(Self.decide(10, 11, bound: 64) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(10, 64, bound: 64) == .accept(invalidateDelayPlans: true))
        for next in 0...64 {
            let decision = Self.decide(10, next, bound: 64)
            #expect(decision == .accept(invalidateDelayPlans: next != 10))
        }
    }

    @Test func latencyRefusesOneAboveTheBoundAndNegativeNext() {
        #expect(Self.decide(0, 100, bound: 100) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(0, 101, bound: 100) == .refuse(.outOfRange(next: 101, bound: 100)))
        #expect(Self.decide(0, 0, bound: 100) == .accept(invalidateDelayPlans: false))
        #expect(Self.decide(0, -1, bound: 100) == .refuse(.outOfRange(next: -1, bound: 100)))
        #expect(Self.decide(5, Int.max, bound: 7) == .refuse(.outOfRange(next: Int.max, bound: 7)))
        #expect(Self.decide(5, Int.min, bound: 7) == .refuse(.outOfRange(next: Int.min, bound: 7)))
    }

    @Test func latencyBoundIsOneToSixteenThousandThreeHundredEightyFour() {
        #expect(Self.decide(0, 1, bound: 1) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(0, 2, bound: 1) == .refuse(.outOfRange(next: 2, bound: 1)))
        #expect(Self.decide(0, 16_384, bound: 16_384) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(0, 16_385, bound: 16_384) == .refuse(.outOfRange(next: 16_385, bound: 16_384)))
        for bad in [0, -1, 16_385, Int.max, Int.min] {
            #expect(Self.decide(0, 0, bound: bad) == .refuse(.invalidBound(bad)))
        }
    }

    @Test func latencyPreviousIsCheckedAgainstTheGlobalCapNotTheBound() {
        #expect(Self.decide(0, 10, bound: 64) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(16_384, 10, bound: 64) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(16_384, 16_384, bound: 16_384) == .accept(invalidateDelayPlans: false))
        for bad in [-1, 16_385, Int.max, Int.min] {
            #expect(Self.decide(bad, 10, bound: 64) == .refuse(.previousOutOfRange(bad)))
        }
    }

    @Test func anUnchangedLatencyIsAcceptedWithoutInvalidatingDelayPlans() {
        for value in [0, 1, 64, 16_384] {
            #expect(Self.decide(value, value, bound: 16_384) == .accept(invalidateDelayPlans: false))
        }
    }

    @Test func aChangedLatencyInvalidatesDelayPlansInBothDirections() {
        #expect(Self.decide(100, 99, bound: 200) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(100, 101, bound: 200) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(0, 200, bound: 200) == .accept(invalidateDelayPlans: true))
        #expect(Self.decide(200, 0, bound: 200) == .accept(invalidateDelayPlans: true))
    }

    @Test func latencyChecksTheBoundBeforeThePreviousLatency() {
        #expect(Self.decide(-1, 5, bound: 0) == .refuse(.invalidBound(0)))
        #expect(Self.decide(16_385, 16_385, bound: 16_385) == .refuse(.invalidBound(16_385)))
        #expect(Self.decide(20_000, -1, bound: -7) == .refuse(.invalidBound(-7)))
    }

    @Test func latencyChecksThePreviousLatencyBeforeTheNext() {
        #expect(Self.decide(-1, 11, bound: 10) == .refuse(.previousOutOfRange(-1)))
        #expect(Self.decide(16_385, 101, bound: 100) == .refuse(.previousOutOfRange(16_385)))
        #expect(Self.decide(3, 11, bound: 10) == .refuse(.outOfRange(next: 11, bound: 10)))
    }

    @Test func latencyAgreesWithTheRepreparePolicyInEveryStatus() throws {
        let rendering = ReprepareLedger(budget: .standard)
        let preparing = rendering.observing(.format).ledger
        let silenced = Self.silencedReprepareLedger()
        #expect(rendering.status == .rendering)
        #expect(preparing.status == .preparing)
        #expect(silenced.status == .silenced)
        for ledger in [rendering, preparing, silenced] {
            let transition = ledger.observing(.latency)
            #expect(transition.decision == .invalidateDelayPlans)
            #expect(transition.ledger == ledger)
        }
        #expect(Self.decide(1, 2, bound: 64) == .accept(invalidateDelayPlans: true))
    }

    @Test func everyOtherLiveChangeEscalatesWhereLatencyDoesNot() {
        let fresh = ReprepareLedger(budget: .standard)
        for change in RenderLiveChange.allCases where change != .latency {
            #expect(fresh.observing(change).decision == .reprepare(attempt: 1))
            #expect(Self.silencedReprepareLedger().observing(change).decision == .remainSilent)
        }
        #expect(fresh.observing(.latency).decision == .invalidateDelayPlans)
        #expect(Self.silencedReprepareLedger().observing(.latency).decision == .invalidateDelayPlans)
    }

    @Test func aLatencyDecisionIsNeverARepreparationOrASilence() {
        for next in [0, 1, 63, 64, 65, -1, Int.max] {
            switch Self.decide(10, next, bound: 64) {
            case .accept(let invalidate):
                #expect((0...64).contains(next))
                #expect(invalidate == (next != 10))
            case .refuse(let refusal):
                #expect(!(0...64).contains(next))
                #expect(refusal == .outOfRange(next: next, bound: 64))
            }
        }
    }
}
