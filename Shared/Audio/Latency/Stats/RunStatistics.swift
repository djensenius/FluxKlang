//
//  RunStatistics.swift
//  FluxKlang
//
//  Integer-only nearest-rank percentiles, deadline misses and dropout evidence for one run.
//

/// A percentile that is either a measured value or an explicit statement that the sample count cannot support it.
enum PercentileResult: Hashable, Sendable {
    case value(Int64)
    case insufficientSamples(needed: Int, have: Int)

    /// The value, or nil when the sample count cannot support the percentile.
    var nanoseconds: Int64? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// An exact fraction; never reduced and never converted to floating point.
struct DeadlineMissRatio: Hashable, Sendable {
    let numerator: Int
    let denominator: Int

    fileprivate init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// Percentile, deadline and dropout evidence for one run.
///
/// Percentile rule (nearest-rank, integers only): sort ascending, `rank = ceil(p * n / 100)`, result is the
/// element at 1-based `rank`. A percentile needs `n >= 1` (p50), `n >= 20` (p95) or `n >= 100` (p99); below that the
/// rank would be the maximum itself, so it is reported as `insufficientSamples`. A deadline miss is
/// `render > deadline` (strict): a render exactly at the deadline is not a miss.
struct RunStatistics: Hashable, Sendable {
    static let p50Percent = 50
    static let p95Percent = 95
    static let p99Percent = 99
    static let p50Needed = 1
    static let p95Needed = 20
    static let p99Needed = 100

    let sampleCount: Int
    let p50: PercentileResult
    let p95: PercentileResult
    let p99: PercentileResult
    let maximumNanoseconds: Int64
    let deadlineMisses: Int
    let missRatio: DeadlineMissRatio
    let dropouts: Int
    let recoveryCount: Int
    /// The longest recovery, or nil when the run recorded none.
    let recoveryMaximumNanoseconds: Int64?

    private init(sorted: [Int64], record: RunRecord) {
        let count = sorted.count
        sampleCount = count
        p50 = Self.percentile(Self.p50Percent, needed: Self.p50Needed, sorted: sorted)
        p95 = Self.percentile(Self.p95Percent, needed: Self.p95Needed, sorted: sorted)
        p99 = Self.percentile(Self.p99Percent, needed: Self.p99Needed, sorted: sorted)
        maximumNanoseconds = sorted[count - 1]
        let misses = Self.deadlineMisses(in: record)
        deadlineMisses = misses
        missRatio = DeadlineMissRatio(numerator: misses, denominator: count)
        dropouts = record.dropouts
        recoveryCount = record.recoveryNanoseconds.count
        recoveryMaximumNanoseconds = record.recoveryNanoseconds.max()
    }

    /// Total: a `RunRecord` is already validated, so it has at least one sample.
    static func make(from record: RunRecord) -> Self {
        Self(sorted: record.renderNanoseconds.sorted(), record: record)
    }

    /// The single definition of a deadline miss (`render > deadline`, strict), as one linear scan without sorting.
    static func deadlineMisses(in record: RunRecord) -> Int {
        record.renderNanoseconds.reduce(0) { $0 + ($1 > record.deadlineNanoseconds ? 1 : 0) }
    }

    private static func percentile(_ percent: Int, needed: Int, sorted: [Int64]) -> PercentileResult {
        let count = sorted.count
        guard count >= needed else { return .insufficientSamples(needed: needed, have: count) }
        let rank = (percent * count + 99) / 100
        return .value(sorted[rank - 1])
    }
}
