import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The lowest-stable-buffer observation: four outcomes, mixed runs, criteria boundaries and refusals.
extension RunStatisticsTests {
    /// A run at `buffer` with `samples` renders, `misses` of them over the 100 ns deadline.
    private static func bufferRun(_ buffer: Int, samples: Int = 10, dropouts: Int = 0, misses: Int = 0,
                                  workload: String = "work.a", deadline: Int64 = 100) throws -> RunRecord {
        let renders = (0..<samples).map { $0 < misses ? Int64(200) : Int64(50) }
        return try record(renders, deadline: deadline, dropouts: dropouts,
                          variables: variables(buffer: buffer, workload: workload))
    }

    private static func criteria(dropouts: Int = 0, misses: Int = 0, samples: Int = 5) throws -> StabilityCriteria {
        try StabilityCriteria.make(maximumDropouts: dropouts, maximumDeadlineMisses: misses, minimumSamples: samples)
    }

    private static func finding(_ runs: [RunRecord],
                                _ criteria: StabilityCriteria? = nil) throws -> StableBufferFinding {
        try StableBufferFinding.make(runs: runs, criteria: criteria ?? self.criteria())
    }

    @Test func aStableSmallestTestedSizeReportsThatInstabilityWasNotObserved() throws {
        let finding = try Self.finding([Self.bufferRun(128), Self.bufferRun(64), Self.bufferRun(256)])
        #expect(finding.outcome == .instabilityNotObserved(smallestTested: 64))
        #expect(finding.tested.map(\.frames) == [64, 128, 256])
        #expect(!finding.unstableAboveLowestStable)
    }

    @Test func theLowestStableObservedSizeCarriesItsPooledEvidence() throws {
        let finding = try Self.finding([Self.bufferRun(256), Self.bufferRun(64, dropouts: 1),
                                        Self.bufferRun(128, samples: 12), Self.bufferRun(32, misses: 1)])
        let evidence = try #require(finding.tested.first { $0.frames == 128 })
        #expect(finding.outcome == .lowestStableObserved(frames: 128, evidence: evidence))
        #expect(evidence.verdict == .stable)
        #expect(evidence.runCount == 1 && evidence.stableRuns == 1)
        #expect(evidence.totalSamples == 12 && evidence.totalDropouts == 0 && evidence.totalDeadlineMisses == 0)
        #expect(finding.tested.map(\.verdict) == [.unstable, .unstable, .stable, .stable])
    }

    @Test func everyTestedSizeUnstableMeansNoneWasStable() throws {
        let finding = try Self.finding([Self.bufferRun(64, dropouts: 1), Self.bufferRun(128, misses: 1)])
        #expect(finding.outcome == .noneStable)
        #expect(finding.tested.count == 2)
        #expect(!finding.unstableAboveLowestStable)
    }

    @Test func insufficientSamplesAtTheSmallestNonUnstableSizeBlockAnyClaim() throws {
        let runs = try [Self.bufferRun(64, dropouts: 1), Self.bufferRun(128, samples: 4), Self.bufferRun(256),
                        Self.bufferRun(512, samples: 1)]
        let finding = try Self.finding(runs)
        #expect(finding.outcome == .insufficientEvidence(frames: [128, 512]))
        #expect(!finding.unstableAboveLowestStable)
        #expect(finding.tested.map(\.verdict) == [.unstable, .insufficient, .stable, .insufficient])
        let smallest = try Self.finding([Self.bufferRun(64, samples: 2), Self.bufferRun(128)])
        #expect(smallest.outcome == .insufficientEvidence(frames: [64]))
    }

    @Test func aSizeWithMixedRunOutcomesIsUnstableAndKeepsPerRunCounts() throws {
        let runs = try [Self.bufferRun(128), Self.bufferRun(128, dropouts: 2), Self.bufferRun(128, samples: 3),
                        Self.bufferRun(256), Self.bufferRun(256)]
        let finding = try Self.finding(runs)
        let mixed = try #require(finding.tested.first)
        #expect(mixed.verdict == .unstable)
        #expect(mixed.runCount == 3 && mixed.stableRuns == 1 && mixed.unstableRuns == 1 && mixed.insufficientRuns == 1)
        #expect(mixed.totalSamples == 23 && mixed.totalDropouts == 2)
        guard case .lowestStableObserved(let frames, let evidence) = finding.outcome else {
            Issue.record("expected lowestStableObserved, got \(finding.outcome)")
            return
        }
        #expect(frames == 256 && evidence.runCount == 2 && evidence.totalSamples == 20)
    }

    @Test func aSizeWithOnlyInsufficientAndStableRunsIsInsufficientButUnstableWinsOverIt() throws {
        let short = try Self.finding([Self.bufferRun(64), Self.bufferRun(64, samples: 4)])
        #expect(short.tested.first?.verdict == .insufficient)
        let failing = try Self.finding([Self.bufferRun(64, samples: 2, dropouts: 1), Self.bufferRun(128)])
        #expect(failing.tested.first?.verdict == .unstable)
        #expect(failing.outcome == .lowestStableObserved(frames: 128, evidence: failing.tested[1]))
    }

    @Test func anUnstableSizeAboveTheLowestStableOneIsFlagged() throws {
        let runs = try [Self.bufferRun(64, dropouts: 1), Self.bufferRun(128), Self.bufferRun(256, misses: 1)]
        let finding = try Self.finding(runs)
        #expect(finding.unstableAboveLowestStable)
        #expect(finding.outcome == .lowestStableObserved(frames: 128, evidence: finding.tested[1]))
        let monotone = try Self.finding([Self.bufferRun(64, dropouts: 1), Self.bufferRun(128), Self.bufferRun(256)])
        #expect(!monotone.unstableAboveLowestStable)
        let flagged = try Self.finding([Self.bufferRun(64), Self.bufferRun(128, dropouts: 1)])
        #expect(flagged.outcome == .instabilityNotObserved(smallestTested: 64))
        #expect(flagged.unstableAboveLowestStable)
    }

    @Test func anUnstableLargerSizeIsFlaggedInEveryOutcomeFromTheFirstStableSizeOnly() throws {
        let limits = try Self.criteria()
        let runs = try [Self.bufferRun(64, samples: 4), Self.bufferRun(128, samples: 5),
                        Self.bufferRun(256, samples: 5, dropouts: 1)]
        let insufficient = try Self.finding(runs, limits)
        #expect(insufficient.outcome == .insufficientEvidence(frames: [64]))
        #expect(insufficient.unstableAboveLowestStable)
        let noStable = try Self.finding([Self.bufferRun(64, samples: 4), Self.bufferRun(128, dropouts: 1)], limits)
        #expect(noStable.outcome == .insufficientEvidence(frames: [64]))
        #expect(!noStable.unstableAboveLowestStable)
        let twoStable = try Self.finding([Self.bufferRun(64), Self.bufferRun(128, dropouts: 1), Self.bufferRun(256)],
                                         limits)
        #expect(twoStable.outcome == .instabilityNotObserved(smallestTested: 64))
        #expect(twoStable.unstableAboveLowestStable)
    }

    @Test func theFindingCountsTheSameDeadlineMissesAsRunStatisticsForUnsortedRenders() throws {
        let first = try Self.record([101, 100, 99, 300, 1], deadline: 100, variables: Self.variables(buffer: 64))
        let second = try Self.record([100, 100, 7, 101], deadline: 100, variables: Self.variables(buffer: 64))
        let expected = RunStatistics.make(from: first).deadlineMisses + RunStatistics.make(from: second).deadlineMisses
        #expect(expected == 3)
        #expect(RunStatistics.deadlineMisses(in: first) == 2 && RunStatistics.deadlineMisses(in: second) == 1)
        let limits = try Self.criteria(misses: 3, samples: 1)
        let pooled = try #require(Self.finding([first, second], limits).tested.first)
        #expect(pooled.totalDeadlineMisses == expected)
        #expect(pooled.verdict == .stable)
        let tight = try Self.criteria(misses: 1, samples: 1)
        #expect(try Self.finding([first, second], tight).tested.first?.verdict == .unstable)
    }

    @Test func criteriaLimitsAcceptTheMaximumAndRefuseOneBeyondForDropoutsAndMisses() throws {
        let limits = try Self.criteria(dropouts: 2, misses: 1)
        let atLimit = try Self.finding([Self.bufferRun(64, dropouts: 2, misses: 1)], limits)
        #expect(atLimit.outcome == .instabilityNotObserved(smallestTested: 64))
        let dropoutsBeyond = try Self.finding([Self.bufferRun(64, dropouts: 3, misses: 1)], limits)
        #expect(dropoutsBeyond.outcome == .noneStable)
        let missesBeyond = try Self.finding([Self.bufferRun(64, dropouts: 2, misses: 2)], limits)
        #expect(missesBeyond.outcome == .noneStable)
    }

    @Test func minimumSamplesAcceptsTheBoundaryAndFlagsOneFewerAsInsufficient() throws {
        let enough = try Self.finding([Self.bufferRun(64, samples: 5)])
        #expect(enough.outcome == .instabilityNotObserved(smallestTested: 64))
        let fewer = try Self.finding([Self.bufferRun(64, samples: 4)])
        #expect(fewer.outcome == .insufficientEvidence(frames: [64]))
        let demanding = try Self.finding([Self.bufferRun(64, samples: 10)], Self.criteria(samples: 11))
        #expect(demanding.outcome == .insufficientEvidence(frames: [64]))
    }

    @Test func findingDoesNotDependOnTheOrderOfRuns() throws {
        let runs = try [Self.bufferRun(256), Self.bufferRun(64, dropouts: 1), Self.bufferRun(128),
                        Self.bufferRun(128, samples: 7), Self.bufferRun(64, misses: 1)]
        let forward = try Self.finding(runs)
        #expect(try Self.finding(runs.reversed()) == forward)
        #expect(try Self.finding(Array(runs[2...] + runs[..<2])) == forward)
        #expect(forward.tested.map(\.frames) == [64, 128, 256])
    }

    @Test(arguments: RunVariable.allCases.filter { $0 != .bufferFrames })
    func runsDifferingInAnyVariableButBufferFramesAreRefusedByTheFinding(variable: RunVariable) throws {
        let base = try Self.record([50, 50, 50, 50, 50], deadline: 100)
        let other = try Self.record([50, 50, 50, 50, 50], deadline: 100, variables: Self.variant(of: variable))
        #expect(throws: RunRefusal.variablesDiffer([variable])) { try Self.finding([base, other]) }
        #expect(throws: RunRefusal.variablesDiffer([variable])) { try Self.finding([other, base]) }
    }

    @Test func bufferFramesMayDifferAndEveryOtherDifferenceIsListedInOrder() throws {
        let other = try Self.record([50], deadline: 100, variables: Self.variables(buffer: 64, rate: 44_100,
                                                                                     backend: "backend.b"))
        let base = try Self.bufferRun(128)
        #expect(throws: RunRefusal.variablesDiffer([.sampleRate, .backend])) { try Self.finding([base, other]) }
        #expect(throws: RunRefusal.variablesDiffer([.sampleRate, .backend])) { try Self.finding([other, base]) }
    }

    @Test func dropoutSumsAcceptTheExactMaximumAndRefuseOverflow() throws {
        let limits = try Self.criteria(dropouts: Int.max)
        let exact = try Self.finding([Self.bufferRun(64, dropouts: Int.max), Self.bufferRun(64)], limits)
        #expect(exact.tested.first?.totalDropouts == Int.max)
        let apart = try Self.finding([Self.bufferRun(64, dropouts: Int.max), Self.bufferRun(128, dropouts: Int.max)],
                                     limits)
        #expect(apart.outcome == .instabilityNotObserved(smallestTested: 64))
        #expect(throws: RunRefusal.arithmeticOverflow) {
            try Self.finding([Self.bufferRun(64, dropouts: Int.max), Self.bufferRun(64, dropouts: 1)], limits)
        }
    }

    @Test func emptyAndOversizedRunSetsAreRefusedBeforeVariablesAreCompared() throws {
        let limits = try Self.criteria()
        #expect(throws: RunRefusal.noRuns) { try Self.finding([], limits) }
        let base = try Self.bufferRun(64)
        let other = try Self.bufferRun(64, workload: "work.b")
        let runs = [base, other] + Array(repeating: base, count: RunLimits.maximumRuns - 1)
        #expect(throws: RunRefusal.tooManyRuns(count: RunLimits.maximumRuns + 1)) { try Self.finding(runs, limits) }
        let exact = Array(repeating: base, count: RunLimits.maximumRuns)
        #expect(try Self.finding(exact, limits).tested.first?.runCount == RunLimits.maximumRuns)
    }

    @Test func runsPooledAtOneBufferSizeMustShareOneDeadlineAndSizesMayDiffer() throws {
        let same = try Self.finding([Self.bufferRun(64, deadline: 100), Self.bufferRun(64, deadline: 100)])
        #expect(same.tested.first?.runCount == 2)
        let sizes = try Self.finding([Self.bufferRun(64, deadline: 100), Self.bufferRun(128, deadline: 200)])
        #expect(sizes.tested.map(\.frames) == [64, 128])
        let expected = RunRefusal.deadlineMismatch(100, 101)
        #expect(throws: expected) { try Self.finding([Self.bufferRun(64), Self.bufferRun(64, deadline: 101)]) }
        #expect(throws: expected) { try Self.finding([Self.bufferRun(64, deadline: 101), Self.bufferRun(64)]) }
        let three = try [Self.bufferRun(64), Self.bufferRun(64, deadline: 102), Self.bufferRun(64, deadline: 101)]
        #expect(throws: RunRefusal.deadlineMismatch(100, 102)) { try Self.finding(three) }
    }

    @Test func aVariableMismatchIsReportedBeforeADeadlineMismatchOfTheSameRuns() throws {
        let runs = try [Self.bufferRun(64), Self.bufferRun(64, workload: "work.b", deadline: 101)]
        #expect(throws: RunRefusal.variablesDiffer([.workload])) { try Self.finding(runs) }
        #expect(throws: RunRefusal.variablesDiffer([.workload])) { try Self.finding(runs.reversed()) }
    }

    @Test func aDeadlineMismatchAtAnySizeIsReportedBeforeADropoutOverflowAtAnotherSize() throws {
        let limits = try Self.criteria(dropouts: Int.max)
        let runs = try [Self.bufferRun(64, dropouts: Int.max), Self.bufferRun(64, dropouts: 1),
                        Self.bufferRun(128), Self.bufferRun(128, deadline: 101)]
        #expect(throws: RunRefusal.deadlineMismatch(100, 101)) { try Self.finding(runs, limits) }
        #expect(throws: RunRefusal.deadlineMismatch(100, 101)) { try Self.finding(runs.reversed(), limits) }
        let overflowOnly = Array(runs.prefix(2))
        #expect(throws: RunRefusal.arithmeticOverflow) { try Self.finding(overflowOnly, limits) }
    }

    @Test func theSmallestSizeWithADeadlineMismatchIsTheOneReported() throws {
        let runs = try [Self.bufferRun(128, deadline: 200), Self.bufferRun(128, deadline: 300),
                        Self.bufferRun(64), Self.bufferRun(64, deadline: 101)]
        #expect(throws: RunRefusal.deadlineMismatch(100, 101)) { try Self.finding(runs) }
        #expect(throws: RunRefusal.deadlineMismatch(100, 101)) { try Self.finding(runs.reversed()) }
    }

    @Test func aDeadlineMismatchIsReportedBeforeADropoutOverflowOfTheSameRuns() throws {
        let limits = try Self.criteria(dropouts: Int.max)
        let runs = try [Self.bufferRun(64, dropouts: Int.max), Self.bufferRun(64, dropouts: 1, deadline: 101)]
        #expect(throws: RunRefusal.deadlineMismatch(100, 101)) { try Self.finding(runs, limits) }
        #expect(throws: RunRefusal.deadlineMismatch(100, 101)) { try Self.finding(runs.reversed(), limits) }
    }

    @Test func variableMismatchIsReportedBeforeAnOverflowOfTheSameRuns() throws {
        let limits = try Self.criteria(dropouts: Int.max)
        let runs = try [Self.bufferRun(64, dropouts: Int.max), Self.bufferRun(64, dropouts: 1, workload: "work.b")]
        #expect(throws: RunRefusal.variablesDiffer([.workload])) { try Self.finding(runs, limits) }
    }

    @Test func criteriaAcceptZeroLimitsAndOneSampleAndRefuseOneBeyondInDocumentedOrder() throws {
        let zero = try Self.criteria(dropouts: 0, misses: 0, samples: 1)
        #expect(zero.maximumDropouts == 0 && zero.maximumDeadlineMisses == 0 && zero.minimumSamples == 1)
        #expect(throws: RunRefusal.invalidCriteria(.maximumDropouts, value: -1)) {
            try StabilityCriteria.make(maximumDropouts: -1, maximumDeadlineMisses: -2, minimumSamples: 0)
        }
        #expect(throws: RunRefusal.invalidCriteria(.maximumDeadlineMisses, value: -2)) {
            try StabilityCriteria.make(maximumDropouts: 0, maximumDeadlineMisses: -2, minimumSamples: 0)
        }
        #expect(throws: RunRefusal.invalidCriteria(.minimumSamples, value: 0)) {
            try StabilityCriteria.make(maximumDropouts: 0, maximumDeadlineMisses: 0, minimumSamples: 0)
        }
    }

    @Test func pooledEvidenceSumsSamplesDropoutsAndMissesAcrossRunsAtOneSize() throws {
        let limits = try Self.criteria(dropouts: 5, misses: 5)
        let finding = try Self.finding([Self.bufferRun(64, samples: 6, dropouts: 1, misses: 1),
                                        Self.bufferRun(64, samples: 7, dropouts: 2, misses: 2)], limits)
        let evidence = try #require(finding.tested.first)
        #expect(evidence.verdict == .stable)
        #expect(evidence.runCount == 2 && evidence.stableRuns == 2)
        #expect(evidence.totalSamples == 13 && evidence.totalDropouts == 3 && evidence.totalDeadlineMisses == 3)
    }

    @Test func theFindingHasNoRankingSurface() throws {
        let finding = try Self.finding([Self.bufferRun(64), Self.bufferRun(128)])
        let forbidden = ["score", "rank", "winner", "best", "better", "floor", "recommend"]
        let labels = Mirror(reflecting: finding).children.compactMap(\.label)
            + Mirror(reflecting: finding.tested[0]).children.compactMap(\.label)
        #expect(!labels.isEmpty)
        for label in labels {
            #expect(!forbidden.contains { label.lowercased().contains($0) }, "unexpected label \(label)")
        }
    }
}
