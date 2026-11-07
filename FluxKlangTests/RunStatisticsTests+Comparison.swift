import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Run comparison: signed `b - a` deltas, unavailable metrics, variable control and the absence of any ranking.
extension RunStatisticsTests {
    /// Values 1...100 with deadline 90 (10 misses), one dropout and one recovery of 5 ns.
    private static func baselineRun(variables: RunVariables? = nil) throws -> RunRecord {
        try record(permuted(100), deadline: 90, dropouts: 1, recoveries: [5], variables: variables)
    }

    /// Values 2, 4 ... 200 with deadline 90 (55 misses), four dropouts and recoveries of 12, 3 and 1 ns.
    private static func doubledRun(variables: RunVariables? = nil) throws -> RunRecord {
        try record(permuted(100).map { $0 * 2 }, deadline: 90, dropouts: 4, recoveries: [12, 3, 1],
                   variables: variables)
    }

    @Test func deltasAreSecondMinusFirstWithExactSignedValues() throws {
        let comparison = try RunComparison.compare(Self.baselineRun(), Self.doubledRun(), varying: .backend)
        #expect(comparison.varying == .backend)
        #expect(comparison.sampleCountDelta == 0)
        #expect(comparison.p50Delta == .delta(50))
        #expect(comparison.p95Delta == .delta(95))
        #expect(comparison.p99Delta == .delta(99))
        #expect(comparison.maximumDeltaNanoseconds == 100)
        #expect(comparison.deadlineMissesDelta == 45)
        #expect(comparison.missRatioDelta.numerator == 4_500 && comparison.missRatioDelta.denominator == 10_000)
        #expect(comparison.dropoutsDelta == 3)
        #expect(comparison.recoveryCountDelta == 2)
        #expect(comparison.recoveryMaximumDelta == .delta(7))
    }

    @Test func swappingTheRunsNegatesEveryDelta() throws {
        let comparison = try RunComparison.compare(Self.doubledRun(), Self.baselineRun(), varying: .backend)
        #expect(comparison.p50Delta == .delta(-50))
        #expect(comparison.p95Delta == .delta(-95))
        #expect(comparison.p99Delta == .delta(-99))
        #expect(comparison.maximumDeltaNanoseconds == -100)
        #expect(comparison.deadlineMissesDelta == -45)
        #expect(comparison.missRatioDelta.numerator == -4_500)
        #expect(comparison.dropoutsDelta == -3)
        #expect(comparison.recoveryCountDelta == -2)
        #expect(comparison.recoveryMaximumDelta == .delta(-7))
    }

    @Test func percentilesAndRecoveryMaximumAreUnavailableWhenEitherRunLacksThem() throws {
        let short = try Self.record(Self.permuted(20), deadline: 90, recoveries: [])
        let comparison = try RunComparison.compare(Self.baselineRun(), short, varying: .workload)
        #expect(comparison.p50Delta == .delta(-40))
        #expect(comparison.p95Delta == .delta(-76))
        #expect(comparison.p99Delta == .unavailable)
        #expect(comparison.recoveryMaximumDelta == .unavailable)
        #expect(comparison.sampleCountDelta == -80)
        let reverse = try RunComparison.compare(short, Self.baselineRun(), varying: .workload)
        #expect(reverse.p99Delta == .unavailable && reverse.p95Delta == .delta(76))
    }

    @Test func missRatioDeltaIsExactAcrossDifferentSampleCountsAndNotReduced() throws {
        let quarter = try Self.record([50, 50, 150, 50], deadline: 100)
        let half = try Self.record([50, 150], deadline: 100)
        let comparison = try RunComparison.compare(quarter, half, varying: .loadProfile)
        #expect(comparison.missRatioDelta.numerator == 2)
        #expect(comparison.missRatioDelta.denominator == 8)
        #expect(comparison.sampleCountDelta == -2)
    }

    @Test(arguments: RunVariable.allCases)
    func theVaryingVariableMayDifferButNoOtherVariable(variable: RunVariable) throws {
        let first = try Self.baselineRun()
        let second = try Self.baselineRun(variables: Self.variant(of: variable))
        #expect(try RunComparison.compare(first, second, varying: variable).varying == variable)
        for other in RunVariable.allCases where other != variable {
            #expect(throws: RunRefusal.variablesDiffer([variable])) {
                try RunComparison.compare(first, second, varying: other)
            }
            #expect(throws: RunRefusal.variablesDiffer([variable])) {
                try RunComparison.compare(second, first, varying: other)
            }
        }
    }

    @Test func everyDifferingVariableOtherThanTheVaryingOneIsListedInDeclarationOrder() throws {
        let first = try Self.baselineRun()
        let second = try Self.baselineRun(variables: Self.variables(buffer: 64, rate: 44_100, backend: "backend.b",
                                                                    workload: "work.b"))
        #expect(throws: RunRefusal.variablesDiffer([.bufferFrames, .sampleRate, .workload])) {
            try RunComparison.compare(first, second, varying: .backend)
        }
        #expect(throws: RunRefusal.variablesDiffer([.bufferFrames, .sampleRate, .backend, .workload])) {
            try RunComparison.compare(first, second, varying: .loadProfile)
        }
    }

    @Test func comparingEqualVariablesDescribesRepeatabilityWithZeroDeltas() throws {
        let run = try Self.baselineRun()
        let comparison = try RunComparison.compare(run, run, varying: .bufferFrames)
        #expect(comparison.p99Delta == .delta(0))
        #expect(comparison.maximumDeltaNanoseconds == 0)
        #expect(comparison.deadlineMissesDelta == 0 && comparison.dropoutsDelta == 0)
        #expect(comparison.missRatioDelta.numerator == 0 && comparison.missRatioDelta.denominator == 10_000)
        #expect(comparison.recoveryMaximumDelta == .delta(0))
    }

    @Test(arguments: RunVariable.allCases)
    func deadlinesMayDifferOnlyWhenTheBufferOrTheSampleRateVaries(variable: RunVariable) throws {
        let variables = try Self.variant(of: variable)
        let base = try Self.record([5, 6], deadline: 1_000)
        let sameDeadline = try Self.record([5, 6], deadline: 1_000, variables: variables)
        let longer = try Self.record([5, 6], deadline: 1_001, variables: variables)
        #expect(try RunComparison.compare(base, sameDeadline, varying: variable).varying == variable)
        if variable == .bufferFrames || variable == .sampleRate {
            #expect(try RunComparison.compare(base, longer, varying: variable).varying == variable)
        } else {
            #expect(throws: RunRefusal.deadlineMismatch(1_000, 1_001)) {
                try RunComparison.compare(base, longer, varying: variable)
            }
            #expect(throws: RunRefusal.deadlineMismatch(1_001, 1_000)) {
                try RunComparison.compare(longer, base, varying: variable)
            }
        }
    }

    @Test func aDeadlineDifferenceIsAcceptedOnlyWhenTheNamedBufferOrRateReallyDiffers() throws {
        let first = try Self.record([5], deadline: 1_000)
        let second = try Self.record([5], deadline: 1_001)
        #expect(throws: RunRefusal.deadlineMismatch(1_000, 1_001)) {
            try RunComparison.compare(first, second, varying: .workload)
        }
        #expect(throws: RunRefusal.deadlineMismatch(1_000, 1_001)) {
            try RunComparison.compare(first, second, varying: .bufferFrames)
        }
        #expect(throws: RunRefusal.deadlineMismatch(1_001, 1_000)) {
            try RunComparison.compare(second, first, varying: .sampleRate)
        }
        let larger = try Self.record([5], deadline: 1_001, variables: Self.variant(of: .bufferFrames))
        #expect(try RunComparison.compare(first, larger, varying: .bufferFrames).sampleCountDelta == 0)
        #expect(throws: RunRefusal.variablesDiffer([.bufferFrames])) {
            try RunComparison.compare(first, larger, varying: .workload)
        }
        #expect(throws: RunRefusal.variablesDiffer([.backend])) {
            try RunComparison.compare(first, Self.record([5], deadline: 1_001, variables: Self.variant(of: .backend)),
                                      varying: .workload)
        }
    }

    @Test func extremeDurationsAndDropoutCountsProduceExactDeltasWithoutOverflow() throws {
        let low = try Self.record([1], deadline: 1, dropouts: 0, recoveries: [1])
        let high = try Self.record([Int64.max], deadline: 1, dropouts: Int.max, recoveries: [Int64.max])
        let comparison = try RunComparison.compare(low, high, varying: .backend)
        #expect(comparison.maximumDeltaNanoseconds == Int64.max - 1)
        #expect(comparison.p50Delta == .delta(Int64.max - 1))
        #expect(comparison.dropoutsDelta == Int.max)
        #expect(comparison.recoveryMaximumDelta == .delta(Int64.max - 1))
        let reverse = try RunComparison.compare(high, low, varying: .backend)
        #expect(reverse.maximumDeltaNanoseconds == 1 - Int64.max)
        #expect(reverse.dropoutsDelta == -Int.max)
    }

    @Test func comparisonAndStatisticsExposeNoScoreRankingOrWinner() throws {
        let comparison = try RunComparison.compare(Self.baselineRun(), Self.doubledRun(), varying: .backend)
        let statistics = RunStatistics.make(from: try Self.baselineRun())
        let forbidden = ["score", "rank", "winner", "best", "better", "faster", "slower", "floor"]
        let labels = Mirror(reflecting: comparison).children.compactMap(\.label)
            + Mirror(reflecting: statistics).children.compactMap(\.label)
        #expect(labels.count == 21)
        for label in labels {
            #expect(!forbidden.contains { label.lowercased().contains($0) }, "unexpected label \(label)")
        }
    }
}
