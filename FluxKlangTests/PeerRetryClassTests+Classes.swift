import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerRetryClassTests {
    @Test func everyCommandOperationHasItsExactRetryClass() {
        let table = Fixture.everyOperation()
        #expect(table.count == 12)
        for entry in table {
            #expect(PeerRetryPolicy.classify(entry.operation) == entry.retryClass, "\(entry.operation)")
        }
        #expect(table.filter { $0.retryClass == .freshIntentOnly }.count == 2)
        #expect(Fixture.neverOperations().count == 10)
    }

    @Test func theRetryClassDoesNotDependOnTheOperationPayload() {
        let values = [-1.0, 0.0, -0.0, 0.5, 1.0, 1_000.0]
        for raw in values {
            #expect(PeerRetryPolicy.classify(Fixture.set(raw)) == .freshIntentOnly)
            #expect(PeerRetryPolicy.classify(Fixture.ramp(raw, Fixture.pan)) == .freshIntentOnly)
        }
        #expect(PeerRetryPolicy.classify(.locate(ticks: 0)) == .never)
        #expect(PeerRetryPolicy.classify(.locate(ticks: Int64.max)) == .never)
    }

    @Test func aTargetExistsExactlyForTheTwoParameterWriters() throws {
        let set = try #require(PeerIntentRevalidator.target(of: Fixture.set(0.25, Fixture.pan)))
        #expect(set.parameter == Fixture.pan)
        #expect(set.value == Fixture.value(0.25))
        let ramp = try #require(PeerIntentRevalidator.target(of: Fixture.ramp(0.75)))
        #expect(ramp.parameter == Fixture.gain)
        #expect(ramp.value == Fixture.value(0.75))
        for entry in Fixture.everyOperation() {
            let hasTarget = PeerIntentRevalidator.target(of: entry.operation) != nil
            #expect(hasTarget == (entry.retryClass == .freshIntentOnly), "\(entry.operation)")
        }
    }

    @Test func limitsAreBuiltForTheLowestAndHighestListLength() throws {
        #expect(try PeerRevalidationLimits.make(maximumListed: 1).maximumListed == 1)
        #expect(try PeerRevalidationLimits.make(maximumListed: 2).maximumListed == 2)
        #expect(try PeerRevalidationLimits.make(maximumListed: 255).maximumListed == 255)
        #expect(try PeerRevalidationLimits.make(maximumListed: 256).maximumListed == 256)
        #expect(PeerRevalidationLimits.maximumListedBounds == 1...256)
    }

    @Test func limitsRefuseZeroNegativeAndTwoHundredFiftySevenWithTheValue() {
        for bad in [0, -1, 257, Int.max, Int.min] {
            #expect(throws: PeerRevalidationRefusal.invalidLimits(maximumListed: bad)) {
                try PeerRevalidationLimits.make(maximumListed: bad)
            }
        }
    }

    @Test func theStandardLimitsListThirtyTwoEntries() throws {
        #expect(PeerRevalidationLimits.standard.maximumListed == 32)
        #expect(try PeerRevalidationLimits.make(maximumListed: 32) == .standard)
        #expect(try PeerRevalidationLimits.make(maximumListed: 33) != .standard)
    }

    @Test func validatingLimitsDirectlyRefusesEveryValueOutsideTheBounds() throws {
        for good in [1, 2, 32, 255, 256] {
            try PeerRevalidationLimits.validate(maximumListed: good)
        }
        for bad in [0, -1, 257, 1_000] {
            #expect(throws: PeerRevalidationRefusal.invalidLimits(maximumListed: bad)) {
                try PeerRevalidationLimits.validate(maximumListed: bad)
            }
        }
        try PeerRevalidationLimits.standard.validated()
        try Fixture.limits(256).validated()
    }

    @Test func theMaximumHeldCountIsTheQueueCapacityUpperBound() {
        #expect(PeerIntentRevalidator.maximumHeld == 4_096)
        #expect(PeerIntentRevalidator.maximumHeld == PeerOutboundQueue.capacityBounds.upperBound)
    }

    @Test func aReportKeepsTheFirstEntriesOfEachListAndTheExactCounts() throws {
        let limits = Fixture.limits(2)
        let candidates = (0..<3).map {
            PeerRetryCandidate(original: Fixture.id("command.retry.\($0)"), operation: Fixture.set(),
                               basis: Fixture.current)
        }
        let discarded = (0..<4).map { PeerDiscardedIntent(id: Fixture.id("command.drop.\($0)"), reason: .notFinite) }
        let unknown = Fixture.ids("command.sent", count: 5)
        let report = PeerRevalidationReport(retryable: candidates, discarded: discarded, unknownOutcome: unknown,
                                            limits: limits)
        #expect(report.retryable == Array(candidates.prefix(2)))
        #expect(report.discarded == Array(discarded.prefix(2)))
        #expect(report.unknownOutcome == Array(unknown.prefix(2)))
        #expect(report.retryableCount == 3)
        #expect(report.discardedCount == 4)
        #expect(report.unknownOutcomeCount == 5)
        #expect(report.truncatedCount == 1 + 2 + 3)
        #expect(!report.isEmpty)
        let empty = PeerRevalidationReport(retryable: [], discarded: [], unknownOutcome: [], limits: limits)
        #expect(empty.isEmpty)
        #expect(empty.truncatedCount == 0)
        let onlyAwaiting = PeerRevalidationReport(retryable: [], discarded: [], unknownOutcome: unknown, limits: limits)
        #expect(!onlyAwaiting.isEmpty)
    }
}
