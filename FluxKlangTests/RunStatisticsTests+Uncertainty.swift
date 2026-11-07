import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Uncertainty notes: counts, p99 spread across repeated runs and the explicit "not claimed" flags.
extension RunStatisticsTests {
    private static func scaledRun(count: Int, scale: Int64 = 1, variables: RunVariables? = nil,
                                  experiment: String? = nil) throws -> RunRecord {
        try record(permuted(count).map { $0 * scale }, variables: variables, experiment: experiment)
    }

    @Test func singleRunIsFlaggedAndHasASingleValuedSpread() throws {
        let note = try UncertaintyNote.make(runs: [Self.scaledRun(count: 100)])
        #expect(note.runCount == 1)
        #expect(note.totalSampleCount == 100)
        #expect(note.singleRun)
        #expect(!note.tailUnsupported)
        #expect(note.p99SupportedRunCount == 1)
        #expect(note.p99Spread?.minimumNanoseconds == 99)
        #expect(note.p99Spread?.maximumNanoseconds == 99)
    }

    @Test func repeatedRunsReportTheSpreadOfPerRunP99WithoutPoolingSamples() throws {
        let runs = try [Self.scaledRun(count: 100), Self.scaledRun(count: 100, scale: 2),
                        Self.scaledRun(count: 100, scale: 3, experiment: "exp.3")]
        let note = try UncertaintyNote.make(runs: runs)
        #expect(note.runCount == 3)
        #expect(note.totalSampleCount == 300)
        #expect(!note.singleRun)
        #expect(!note.tailUnsupported)
        #expect(note.p99Spread?.minimumNanoseconds == 99)
        #expect(note.p99Spread?.maximumNanoseconds == 297)
    }

    @Test func aRunTooShortForP99FlagsTheTailAndIsExcludedFromTheSpread() throws {
        let runs = try [Self.scaledRun(count: 99), Self.scaledRun(count: 100, scale: 2), Self.scaledRun(count: 101)]
        let note = try UncertaintyNote.make(runs: runs)
        #expect(note.tailUnsupported)
        #expect(note.p99SupportedRunCount == 2)
        #expect(note.totalSampleCount == 300)
        #expect(note.p99Spread?.minimumNanoseconds == 100)
        #expect(note.p99Spread?.maximumNanoseconds == 198)
    }

    @Test func noRunSupportingP99LeavesNoSpreadAtAll() throws {
        let note = try UncertaintyNote.make(runs: [Self.scaledRun(count: 99), Self.scaledRun(count: 20)])
        #expect(note.p99Spread == nil)
        #expect(note.p99SupportedRunCount == 0)
        #expect(note.tailUnsupported)
        #expect(note.totalSampleCount == 119)
    }

    @Test func noteDoesNotDependOnTheOrderOfRuns() throws {
        let runs = try [Self.scaledRun(count: 100), Self.scaledRun(count: 99, scale: 5),
                        Self.scaledRun(count: 101, scale: 2)]
        #expect(try UncertaintyNote.make(runs: runs) == UncertaintyNote.make(runs: runs.reversed()))
        #expect(try UncertaintyNote.make(runs: runs).p99Spread?.maximumNanoseconds == 200)
    }

    @Test func runCountAcceptsTheMaximumAndRefusesNoneAndOneBeyond() throws {
        let one = try Self.record([1])
        let limit = RunLimits.maximumRuns
        #expect(limit == 256)
        #expect(try UncertaintyNote.make(runs: Array(repeating: one, count: limit)).runCount == limit)
        #expect(throws: RunRefusal.noRuns) { try UncertaintyNote.make(runs: []) }
        #expect(throws: RunRefusal.tooManyRuns(count: limit + 1)) {
            try UncertaintyNote.make(runs: Array(repeating: one, count: limit + 1))
        }
    }

    @Test(arguments: RunVariable.allCases)
    func runsDifferingInAnyControlledVariableAreRefusedByTheNote(variable: RunVariable) throws {
        let base = try Self.record([1, 2])
        let other = try Self.record([1, 2], variables: Self.variant(of: variable))
        #expect(throws: RunRefusal.variablesDiffer([variable])) { try UncertaintyNote.make(runs: [base, other]) }
        #expect(throws: RunRefusal.variablesDiffer([variable])) { try UncertaintyNote.make(runs: [other, base]) }
    }

    @Test func differingVariablesAreListedOnceInDeclarationOrderForEitherRunOrder() throws {
        let base = try Self.record([1])
        let workload = try Self.record([1], variables: Self.variant(of: .workload))
        let buffer = try Self.record([1], variables: Self.variant(of: .bufferFrames))
        let expected = RunRefusal.variablesDiffer([.bufferFrames, .workload])
        #expect(throws: expected) { try UncertaintyNote.make(runs: [base, workload, buffer, workload]) }
        #expect(throws: expected) { try UncertaintyNote.make(runs: [workload, buffer, base]) }
    }

    @Test func runCountIsCheckedBeforeVariablesAreCompared() throws {
        let base = try Self.record([1])
        let other = try Self.record([1], variables: Self.variant(of: .backend))
        let runs = [base, other] + Array(repeating: base, count: RunLimits.maximumRuns - 1)
        #expect(throws: RunRefusal.tooManyRuns(count: RunLimits.maximumRuns + 1)) {
            try UncertaintyNote.make(runs: runs)
        }
    }

    @Test func theLimitsBoundEverySumAndProductBelowInt64() {
        let samples = RunLimits.maximumSamples
        let runs = RunLimits.maximumRuns
        #expect(runs * samples == 25_600_000)
        #expect(Int64(runs) * Int64(samples) < Int64.max)
        let (product, overflow) = samples.multipliedReportingOverflow(by: samples)
        #expect(!overflow && product == 10_000_000_000)
    }

    @Test func differentExperimentReferencesDoNotCountAsDifferentVariables() throws {
        let runs = try [Self.record([1], experiment: "exp.a"), Self.record([1], experiment: "exp.b"),
                        Self.record([1])]
        #expect(try UncertaintyNote.make(runs: runs).runCount == 3)
    }
}
