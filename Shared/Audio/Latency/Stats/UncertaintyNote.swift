//
//  UncertaintyNote.swift
//  FluxKlang
//
//  What a set of repeated runs may and may not claim.
//

/// Minimum and maximum of the per-run p99 over the runs that support a p99. It is a spread, not a confidence interval.
struct P99Spread: Hashable, Sendable {
    let minimumNanoseconds: Int64
    let maximumNanoseconds: Int64

    fileprivate init(minimumNanoseconds: Int64, maximumNanoseconds: Int64) {
        self.minimumNanoseconds = minimumNanoseconds
        self.maximumNanoseconds = maximumNanoseconds
    }
}

/// Shared validation for a set of runs that must agree on every controlled variable except an optional one.
enum RunSetCheck {
    /// Checks count (`noRuns`, `tooManyRuns`), then variables against the first run, listing the union of differing
    /// variables (excluding `ignoring`) in declaration order.
    static func validate(_ runs: [RunRecord], ignoring: RunVariable? = nil) throws(RunRefusal) {
        guard let first = runs.first else { throw .noRuns }
        guard runs.count <= RunLimits.maximumRuns else { throw .tooManyRuns(count: runs.count) }
        var differing = Set<RunVariable>()
        for run in runs {
            differing.formUnion(run.variables.differing(from: first.variables))
        }
        if let ignoring { differing.remove(ignoring) }
        let ordered = RunVariable.allCases.filter { differing.contains($0) }
        guard ordered.isEmpty else { throw .variablesDiffer(ordered) }
    }
}

/// The honest limits of a report built from repeated runs of the SAME controlled variables.
///
/// It records counts, the spread of per-run p99 and explicit flags. It never invents a confidence interval, never
/// pools samples into a new percentile and never extrapolates a tail the samples cannot support.
struct UncertaintyNote: Hashable, Sendable {
    let runCount: Int
    /// Sum of the per-run sample counts.
    let totalSampleCount: Int
    /// Nil when no run has the 100 samples that a p99 needs.
    let p99Spread: P99Spread?
    let p99SupportedRunCount: Int
    /// Exactly one run: no run-to-run spread can be stated.
    let singleRun: Bool
    /// At least one run is too short to support a p99.
    let tailUnsupported: Bool

    private init(runCount: Int, totalSampleCount: Int, p99Spread: P99Spread?, p99SupportedRunCount: Int) {
        self.runCount = runCount
        self.totalSampleCount = totalSampleCount
        self.p99Spread = p99Spread
        self.p99SupportedRunCount = p99SupportedRunCount
        singleRun = runCount == 1
        tailUnsupported = p99SupportedRunCount < runCount
    }

    /// Refuses an empty set, more than `RunLimits.maximumRuns` runs, or runs whose controlled variables differ.
    static func make(runs: [RunRecord]) throws(RunRefusal) -> Self {
        try RunSetCheck.validate(runs)
        let p99s = runs.compactMap { RunStatistics.make(from: $0).p99.nanoseconds }
        let spread: P99Spread? = if let low = p99s.min(), let high = p99s.max() {
            P99Spread(minimumNanoseconds: low, maximumNanoseconds: high)
        } else {
            nil
        }
        // At most 256 runs of at most 100_000 samples each cannot overflow Int.
        let total = runs.reduce(0) { $0 + $1.renderNanoseconds.count }
        return Self(runCount: runs.count, totalSampleCount: total, p99Spread: spread, p99SupportedRunCount: p99s.count)
    }
}
