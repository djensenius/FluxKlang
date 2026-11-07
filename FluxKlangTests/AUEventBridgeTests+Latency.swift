import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AUEventBridgeTests {
    private static let bothPlans: [InvalidatedPlan] = [.delayCompensation, .preparedRender]

    private static func plans(_ previous: CapabilityGeneration, _ live: CapabilityGeneration) -> [InvalidatedPlan] {
        BridgeLatencyInvalidation.decide(previous: previous, live: live)
    }

    @Test func identicalGenerationsInvalidateNothing() throws {
        for value in [CapabilityGeneration.initial, try Self.generation(7, 8, 9)] {
            #expect(Self.plans(value, value).isEmpty)
        }
    }

    @Test func aLatencyChangeAloneInvalidatesOnlyTheDelayCompensationPlan() throws {
        let previous = try Self.generation(3, 4, 5)
        let live = try Self.generation(3, 4, 6)
        #expect(Self.plans(previous, live) == [.delayCompensation])
        #expect(Self.plans(live, previous) == [.delayCompensation])
    }

    @Test func aResourcesChangeInvalidatesBothPlansInFixedOrder() throws {
        #expect(Self.plans(try Self.generation(3, 4, 5), try Self.generation(9, 4, 5)) == Self.bothPlans)
    }

    @Test func aSampleRateChangeInvalidatesBothPlansInFixedOrder() throws {
        #expect(Self.plans(try Self.generation(3, 4, 5), try Self.generation(3, 2, 5)) == Self.bothPlans)
    }

    @Test func aLatencyChangeBesideAnotherAxisStillInvalidatesBothPlans() throws {
        let previous = try Self.generation(3, 4, 5)
        for live in [try Self.generation(4, 4, 6), try Self.generation(3, 5, 6), try Self.generation(4, 5, 6)] {
            #expect(Self.plans(previous, live) == Self.bothPlans)
        }
    }

    @Test func theLatencyDecisionAgreesWithTheReprepareLedger() throws {
        let ledger = ReprepareLedger(budget: .standard)
        let latency = ledger.observing(.latency)
        #expect(latency.decision == .invalidateDelayPlans)
        #expect(latency.ledger == ledger)
        let previous = try Self.generation(1, 1, 1)
        #expect(Self.plans(previous, try Self.generation(1, 1, 2)) == [.delayCompensation])
        for change in [RenderLiveChange.sampleRate, .maximumFrames, .busLayout, .format] {
            #expect(ledger.observing(change).decision == .reprepare(attempt: 1))
        }
        #expect(Self.plans(previous, try Self.generation(1, 2, 1)).contains(.preparedRender))
        #expect(Self.plans(previous, try Self.generation(2, 1, 1)).contains(.preparedRender))
    }

    @Test func aLatencyChangeNeverSilencesTheLedgerWhateverTheBudget() throws {
        var ledger = ReprepareLedger(budget: try ReprepareBudget(maximumAttempts: 1))
        for _ in 0..<5 { ledger = ledger.observing(.latency).ledger }
        #expect(ledger.status == .rendering)
        #expect(ledger.attempts == 0)
    }

    @Test func theInvalidatedPlansAreTheTwoDocumentedCasesInDeclarationOrder() {
        #expect(InvalidatedPlan.allCases == [.delayCompensation, .preparedRender])
    }
}
