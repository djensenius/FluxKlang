import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Nearest-rank percentiles (`rank = ceil(p * n / 100)`), support thresholds, deadline misses and dropout evidence.
extension RunStatisticsTests {
    @Test func oneSampleSupportsOnlyTheMedianAndMaximum() throws {
        let stats = try Self.statistics([7])
        #expect(stats.sampleCount == 1)
        #expect(stats.p50 == .value(7))
        #expect(stats.p95 == .insufficientSamples(needed: 20, have: 1))
        #expect(stats.p99 == .insufficientSamples(needed: 100, have: 1))
        #expect(stats.maximumNanoseconds == 7)
    }

    @Test func twoSamplesTakeRankOneForTheMedianRegardlessOfInputOrder() throws {
        for renders: [Int64] in [[10, 20], [20, 10]] {
            let stats = try Self.statistics(renders)
            #expect(stats.p50 == .value(10))
            #expect(stats.p95 == .insufficientSamples(needed: 20, have: 2))
            #expect(stats.maximumNanoseconds == 20)
        }
    }

    @Test func twentySamplesSupportP95AtRank19ButNotP99() throws {
        let stats = try Self.statistics(Self.permuted(20))
        #expect(stats.p50 == .value(10))
        #expect(stats.p95 == .value(19))
        #expect(stats.p99 == .insufficientSamples(needed: 100, have: 20))
        #expect(stats.maximumNanoseconds == 20)
    }

    @Test func nineteenSamplesDoNotSupportP95BecauseItWouldBeTheMaximum() throws {
        let stats = try Self.statistics(Self.permuted(19))
        #expect(stats.p50 == .value(10))
        #expect(stats.p95 == .insufficientSamples(needed: 20, have: 19))
        #expect(stats.maximumNanoseconds == 19)
    }

    @Test func ninetyNineSamplesSupportP95AtRank95ButNotP99() throws {
        let stats = try Self.statistics(Self.permuted(99))
        #expect(stats.p50 == .value(50))
        #expect(stats.p95 == .value(95))
        #expect(stats.p99 == .insufficientSamples(needed: 100, have: 99))
        #expect(stats.maximumNanoseconds == 99)
    }

    @Test func oneHundredSamplesSupportP99AtRank99() throws {
        let stats = try Self.statistics(Self.permuted(100))
        #expect(stats.p50 == .value(50))
        #expect(stats.p95 == .value(95))
        #expect(stats.p99 == .value(99))
        #expect(stats.maximumNanoseconds == 100)
    }

    @Test func oneHundredAndOneSamplesRoundTheRankUp() throws {
        let stats = try Self.statistics(Self.permuted(101))
        #expect(stats.p50 == .value(51))
        #expect(stats.p95 == .value(96))
        #expect(stats.p99 == .value(100))
        #expect(stats.maximumNanoseconds == 101)
    }

    @Test func tiesAndRepeatedValuesKeepTheNearestRankValue() throws {
        let stats = try Self.statistics([9, 5, 5, 5, 5])
        #expect(stats.p50 == .value(5))
        #expect(stats.maximumNanoseconds == 9)
        let flat = try Self.statistics(Array(repeating: 42, count: 100))
        #expect([flat.p50, flat.p95, flat.p99] == [.value(42), .value(42), .value(42)])
    }

    @Test func percentilesDoNotDependOnTheInputOrder() throws {
        let ascending: [Int64] = (1...100).map { $0 * 3 }
        let forward = try Self.statistics(ascending)
        #expect(try Self.statistics(ascending.reversed()) == forward)
        #expect(try Self.statistics(Self.permuted(100).map { $0 * 3 }) == forward)
        #expect(forward.p99 == .value(297))
    }

    @Test func deadlineEqualityIsNotAMissAndOneNanosecondOverIs() throws {
        let equal = try Self.statistics([1_000, 1_000], deadline: 1_000)
        #expect(equal.deadlineMisses == 0)
        let over = try Self.statistics([1_000, 1_001], deadline: 1_000)
        #expect(over.deadlineMisses == 1)
        #expect(over.missRatio.numerator == 1 && over.missRatio.denominator == 2)
    }

    @Test func missRatioIsAnExactUnreducedFraction() throws {
        let stats = try Self.statistics(Self.permuted(100), deadline: 90)
        #expect(stats.deadlineMisses == 10)
        #expect(stats.missRatio.numerator == 10)
        #expect(stats.missRatio.denominator == 100)
        let none = try Self.statistics([5, 6, 7], deadline: 7)
        #expect(none.missRatio.numerator == 0 && none.missRatio.denominator == 3)
    }

    @Test func dropoutAndRecoveryEvidenceIsReportedExactly() throws {
        let run = try Self.record([5, 6], dropouts: 3, recoveries: [4, 9, 2])
        let stats = RunStatistics.make(from: run)
        #expect(stats.dropouts == 3)
        #expect(stats.recoveryCount == 3)
        #expect(stats.recoveryMaximumNanoseconds == 9)
        let quiet = try Self.statistics([5])
        #expect(quiet.dropouts == 0 && quiet.recoveryCount == 0 && quiet.recoveryMaximumNanoseconds == nil)
    }

    @Test func statisticsLeaveTheRecordUnchanged() throws {
        let run = try Self.record([30, 10, 20])
        _ = RunStatistics.make(from: run)
        #expect(run.renderNanoseconds == [30, 10, 20])
    }

    @Test func maximumSizedRunAndExtremeDurationsKeepExactValues() throws {
        let huge = Int64.max
        let stats = try Self.statistics([huge, 1, huge - 1], deadline: huge - 1)
        #expect(stats.p50 == .value(huge - 1))
        #expect(stats.maximumNanoseconds == huge)
        #expect(stats.deadlineMisses == 1)
        let full = try Self.statistics(Array(repeating: 3, count: RunLimits.maximumSamples))
        #expect(full.p99 == .value(3))
        #expect(full.sampleCount == 100_000)
    }
}
