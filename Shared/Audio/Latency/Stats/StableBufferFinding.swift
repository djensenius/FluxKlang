//
//  StableBufferFinding.swift
//  FluxKlang
//
//  The lowest buffer size at which every run of otherwise identical variables was stable: an observation only.
//

/// Caller-chosen stability limits. There are no defaults: what counts as stable is the caller's decision.
struct StabilityCriteria: Hashable, Sendable {
    let maximumDropouts: Int
    let maximumDeadlineMisses: Int
    let minimumSamples: Int

    private init(maximumDropouts: Int, maximumDeadlineMisses: Int, minimumSamples: Int) {
        self.maximumDropouts = maximumDropouts
        self.maximumDeadlineMisses = maximumDeadlineMisses
        self.minimumSamples = minimumSamples
    }

    /// Validates in the order maximum dropouts, maximum deadline misses, minimum samples (at least one).
    static func make(maximumDropouts: Int, maximumDeadlineMisses: Int,
                     minimumSamples: Int) throws(RunRefusal) -> Self {
        guard maximumDropouts >= 0 else { throw .invalidCriteria(.maximumDropouts, value: maximumDropouts) }
        guard maximumDeadlineMisses >= 0 else {
            throw .invalidCriteria(.maximumDeadlineMisses, value: maximumDeadlineMisses)
        }
        guard minimumSamples >= 1 else { throw .invalidCriteria(.minimumSamples, value: minimumSamples) }
        return Self(maximumDropouts: maximumDropouts, maximumDeadlineMisses: maximumDeadlineMisses,
                    minimumSamples: minimumSamples)
    }
}

/// Outcome of one run or one buffer size against the criteria.
enum BufferVerdict: Hashable, Sendable {
    /// Enough samples and within both limits.
    case stable
    /// A dropout or deadline-miss limit was exceeded. Wins over `insufficient`: an observed failure is evidence.
    case unstable
    /// Within the limits but with fewer samples than `minimumSamples`.
    case insufficient
}

/// Pooled counts for every run at one buffer size.
struct BufferEvidence: Hashable, Sendable {
    let frames: Int
    let verdict: BufferVerdict
    let runCount: Int
    let stableRuns: Int
    let unstableRuns: Int
    let insufficientRuns: Int
    let totalSamples: Int
    let totalDropouts: Int
    let totalDeadlineMisses: Int

    /// Pools per-run verdicts: any unstable run makes the size unstable, else any insufficient run makes it so.
    fileprivate init(frames: Int, runVerdicts: [BufferVerdict], samples: Int, dropouts: Int, misses: Int) {
        let unstable = runVerdicts.filter { $0 == .unstable }.count
        let insufficient = runVerdicts.filter { $0 == .insufficient }.count
        self.frames = frames
        verdict = unstable > 0 ? .unstable : (insufficient > 0 ? .insufficient : .stable)
        runCount = runVerdicts.count
        stableRuns = runVerdicts.count - unstable - insufficient
        unstableRuns = unstable
        insufficientRuns = insufficient
        totalSamples = samples
        totalDropouts = dropouts
        totalDeadlineMisses = misses
    }
}

/// What was observed. None of these cases is a floor or a recommendation.
enum StableBufferOutcome: Hashable, Sendable {
    /// The smallest tested size where every run was stable, with at least one smaller size tested and unstable.
    case lowestStableObserved(frames: Int, evidence: BufferEvidence)
    /// The smallest tested size is already stable: nothing says where instability begins.
    case instabilityNotObserved(smallestTested: Int)
    /// Every tested size had an unstable run.
    case noneStable
    /// The smallest non-unstable size lacks samples; every insufficient size is listed ascending. A larger unstable
    /// size is still reported through `StableBufferFinding.unstableAboveLowestStable`.
    case insufficientEvidence(frames: [Int])
}

/// Finding over runs that share every controlled variable except the buffer size.
///
/// A buffer size is `unstable` if ANY of its runs is unstable (mixed outcomes are unstable), else `insufficient` if
/// any run lacks samples, else `stable`. Sizes are examined in ascending order; unstable sizes are skipped and the
/// first other size decides the outcome. The result does not depend on the order of the input runs.
struct StableBufferFinding: Hashable, Sendable {
    let outcome: StableBufferOutcome
    /// Evidence for every tested buffer size, ascending by frames.
    let tested: [BufferEvidence]
    /// A larger size was unstable although a smaller one was stable (the first stable entry of `tested` is
    /// followed by an unstable entry): the observation is not monotonic. Derived in every outcome; false when no
    /// size is stable.
    let unstableAboveLowestStable: Bool

    private init(outcome: StableBufferOutcome, tested: [BufferEvidence], unstableAboveLowestStable: Bool) {
        self.outcome = outcome
        self.tested = tested
        self.unstableAboveLowestStable = unstableAboveLowestStable
    }

    /// Refuses, in this order: an empty set, too many runs, runs differing in any variable but buffer frames, runs
    /// pooled at one buffer size with different deadlines (`deadlineMismatch`; every size is checked, ascending, and
    /// the smallest offending size is reported; sizes may differ from each other), then an overflowing sum.
    static func make(runs: [RunRecord], criteria: StabilityCriteria) throws(RunRefusal) -> Self {
        try RunSetCheck.validate(runs, ignoring: .bufferFrames)
        let groups = Dictionary(grouping: runs, by: \.variables.bufferFrames)
        let sizes = groups.keys.sorted()
        for frames in sizes { try requireOneDeadline(groups[frames] ?? []) }
        var tested: [BufferEvidence] = []
        for frames in sizes {
            tested.append(try evidence(frames: frames, runs: groups[frames] ?? [], criteria: criteria))
        }
        let above = unstableAfterFirstStable(tested)
        guard let index = tested.firstIndex(where: { $0.verdict != .unstable }) else {
            return Self(outcome: .noneStable, tested: tested, unstableAboveLowestStable: above)
        }
        let candidate = tested[index]
        guard candidate.verdict == .stable else {
            let lacking = tested.filter { $0.verdict == .insufficient }.map(\.frames)
            return Self(outcome: .insufficientEvidence(frames: lacking), tested: tested,
                        unstableAboveLowestStable: above)
        }
        let outcome: StableBufferOutcome = index == 0
            ? .instabilityNotObserved(smallestTested: candidate.frames)
            : .lowestStableObserved(frames: candidate.frames, evidence: candidate)
        return Self(outcome: outcome, tested: tested, unstableAboveLowestStable: above)
    }

    /// True when some size above the smallest stable one is unstable; false when no size is stable.
    private static func unstableAfterFirstStable(_ tested: [BufferEvidence]) -> Bool {
        guard let stable = tested.firstIndex(where: { $0.verdict == .stable }) else { return false }
        return tested[(stable + 1)...].contains { $0.verdict == .unstable }
    }

    private static func requireOneDeadline(_ runs: [RunRecord]) throws(RunRefusal) {
        let deadlines = runs.map(\.deadlineNanoseconds)
        if let smallest = deadlines.min(), let largest = deadlines.max(), smallest != largest {
            throw .deadlineMismatch(smallest, largest)
        }
    }

    private static func verdict(of run: RunRecord, misses: Int, criteria: StabilityCriteria) -> BufferVerdict {
        if run.dropouts > criteria.maximumDropouts || misses > criteria.maximumDeadlineMisses { return .unstable }
        return run.renderNanoseconds.count < criteria.minimumSamples ? .insufficient : .stable
    }

    private static func evidence(frames: Int, runs: [RunRecord],
                                 criteria: StabilityCriteria) throws(RunRefusal) -> BufferEvidence {
        var verdicts: [BufferVerdict] = []
        var samples = 0
        var misses = 0
        var dropouts = 0
        for run in runs {
            let runMisses = RunStatistics.deadlineMisses(in: run)
            verdicts.append(verdict(of: run, misses: runMisses, criteria: criteria))
            samples += run.renderNanoseconds.count
            misses += runMisses
            let (sum, overflow) = dropouts.addingReportingOverflow(run.dropouts)
            guard !overflow else { throw .arithmeticOverflow }
            dropouts = sum
        }
        return BufferEvidence(frames: frames, runVerdicts: verdicts, samples: samples, dropouts: dropouts,
                              misses: misses)
    }
}
