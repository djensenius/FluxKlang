//
//  RunComparison.swift
//  FluxKlang
//
//  Signed per-metric differences between two runs. There is no score, ranking or winner anywhere in this model.
//

/// A signed difference that exists only when both runs measured the metric.
enum MetricDelta: Hashable, Sendable {
    case delta(Int64)
    /// A percentile that either run's sample count cannot support, or a recovery maximum one run lacks.
    case unavailable
}

/// An exact signed fraction `numerator / denominator` with a positive denominator; never reduced.
struct SignedRatio: Hashable, Sendable {
    let numerator: Int
    let denominator: Int

    fileprivate init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// `b - a` for every metric of two runs whose controlled variables agree except `varying`.
///
/// A positive delta only says the second run's number is larger; it does not say which run is better. Comparing two
/// runs whose `varying` variable is equal is allowed and describes run-to-run repeatability.
struct RunComparison: Hashable, Sendable {
    let varying: RunVariable
    let sampleCountDelta: Int
    let p50Delta: MetricDelta
    let p95Delta: MetricDelta
    let p99Delta: MetricDelta
    let maximumDeltaNanoseconds: Int64
    let deadlineMissesDelta: Int
    let missRatioDelta: SignedRatio
    let dropoutsDelta: Int
    let recoveryCountDelta: Int
    let recoveryMaximumDelta: MetricDelta

    private init(varying: RunVariable, first: RunStatistics, second: RunStatistics) {
        self.varying = varying
        sampleCountDelta = second.sampleCount - first.sampleCount
        p50Delta = Self.delta(first.p50.nanoseconds, second.p50.nanoseconds)
        p95Delta = Self.delta(first.p95.nanoseconds, second.p95.nanoseconds)
        p99Delta = Self.delta(first.p99.nanoseconds, second.p99.nanoseconds)
        // Both are at least 1 nanosecond and at most Int64.max, so the difference cannot overflow.
        maximumDeltaNanoseconds = second.maximumNanoseconds - first.maximumNanoseconds
        deadlineMissesDelta = second.deadlineMisses - first.deadlineMisses
        // Numerators are at most 100_000 and denominators at most 100_000, so products stay below 10^10.
        missRatioDelta = SignedRatio(
            numerator: second.missRatio.numerator * first.missRatio.denominator
                - first.missRatio.numerator * second.missRatio.denominator,
            denominator: first.missRatio.denominator * second.missRatio.denominator)
        // Both counts are non-negative, so the difference cannot overflow.
        dropoutsDelta = second.dropouts - first.dropouts
        recoveryCountDelta = second.recoveryCount - first.recoveryCount
        recoveryMaximumDelta = Self.delta(first.recoveryMaximumNanoseconds, second.recoveryMaximumNanoseconds)
    }

    /// Refuses runs that differ in any controlled variable other than `varying`; deltas are `b - a`.
    ///
    /// Also refuses runs with different deadlines (`deadlineMismatch`) unless `varying` is `.bufferFrames` or
    /// `.sampleRate` and the two runs really differ in that variable; naming it without a difference is not enough.
    static func compare(_ first: RunRecord, _ second: RunRecord,
                        varying: RunVariable) throws(RunRefusal) -> Self {
        let actual = second.variables.differing(from: first.variables)
        let differing = actual.filter { $0 != varying }
        guard differing.isEmpty else { throw .variablesDiffer(differing) }
        // The deadline follows the buffer size and sample rate, so it may differ only when one of them truly differs.
        let deadlineMayDiffer = (varying == .bufferFrames || varying == .sampleRate) && actual.contains(varying)
        guard deadlineMayDiffer || first.deadlineNanoseconds == second.deadlineNanoseconds else {
            throw .deadlineMismatch(first.deadlineNanoseconds, second.deadlineNanoseconds)
        }
        return Self(varying: varying, first: RunStatistics.make(from: first), second: RunStatistics.make(from: second))
    }

    private static func delta(_ first: Int64?, _ second: Int64?) -> MetricDelta {
        guard let first, let second else { return .unavailable }
        return .delta(second - first)
    }
}
