//
//  AssistantInferenceGovernorTests+Hysteresis.swift
//  FluxKlangTests
//
//  What the governor decides at the edges of each threshold and in which order the pressures are reported: a start
//  is blocked at the defer threshold, a run is suspended for load only at the higher suspend threshold, and a
//  suspended inference needs a count of calm evaluations. The fixture budget is resume 40, defer 60, suspend 80,
//  misses 5, settle 3.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AssistantInferenceGovernorTests {
    // MARK: - Start

    @Test
    func aStartIsDeferredForLoadAtTheDeferThresholdAndAllowedOneBelowIt() {
        var below = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        var onEdge = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let belowOutcome = Self.step(&below, Self.load(59), request: .interactive)
        let edgeOutcome = Self.step(&onEdge, Self.load(60), request: .interactive)
        let expectedBelow: Outcome = .decided(.start(.interactive))
        let expectedEdge: Outcome = .decided(.deferStart(.loadHigh))
        let belowPhase = below.phase
        let edgePhase = onEdge.phase
        let runningPhase: AssistantInferencePhase = .running(.interactive)
        #expect(belowOutcome == expectedBelow)
        #expect(edgeOutcome == expectedEdge)
        #expect(belowPhase == runningPhase)
        #expect(edgePhase == .idle)
    }

    @Test
    func aStartIsDeferredForMissesAtTheMissCountAndAllowedOneBelowIt() {
        var below = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        var onEdge = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let belowOutcome = Self.step(&below, Self.load(0, misses: 4), request: .background)
        let edgeOutcome = Self.step(&onEdge, Self.load(0, misses: 5), request: .background)
        let expectedBelow: Outcome = .decided(.start(.background))
        let expectedEdge: Outcome = .decided(.deferStart(.deadlineMisses))
        let belowPhase = below.phase
        let edgePhase = onEdge.phase
        let runningPhase: AssistantInferencePhase = .running(.background)
        #expect(belowOutcome == expectedBelow)
        #expect(edgeOutcome == expectedEdge)
        #expect(belowPhase == runningPhase)
        #expect(edgePhase == .idle)
    }

    @Test
    func aSingleMissDoesNotBlockAStartWhenTheMissCountIsLarger() {
        var governor = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let outcome = Self.step(&governor, Self.load(0, misses: 1), request: .interactive)
        let expected: Outcome = .decided(.start(.interactive))
        #expect(outcome == expected)
    }

    @Test
    func aBackgroundStartInThePerformContextIsDeferredButAnInteractiveStartIsNot() {
        var background = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        var interactive = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let backgroundOutcome = Self.step(&background, Self.load(0, context: .perform), request: .background)
        let interactiveOutcome = Self.step(&interactive, Self.load(0, context: .perform), request: .interactive)
        let expectedBackground: Outcome = .decided(.deferStart(.performContext))
        let expectedInteractive: Outcome = .decided(.start(.interactive))
        let backgroundPhase = background.phase
        #expect(backgroundOutcome == expectedBackground)
        #expect(interactiveOutcome == expectedInteractive)
        #expect(backgroundPhase == .idle)
    }

    @Test
    func anInteractiveStartInThePerformContextObeysTheMissAndLoadChecks() {
        var missed = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        var loaded = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let missedOutcome = Self.step(&missed, Self.load(0, misses: 5, context: .perform), request: .interactive)
        let loadedOutcome = Self.step(&loaded, Self.load(60, context: .perform), request: .interactive)
        let expectedMissed: Outcome = .decided(.deferStart(.deadlineMisses))
        let expectedLoaded: Outcome = .decided(.deferStart(.loadHigh))
        #expect(missedOutcome == expectedMissed)
        #expect(loadedOutcome == expectedLoaded)
    }

    @Test
    func aBackgroundStartInThePerformContextIsReportedAsPerformEvenWhenMissesAndLoadAlsoBlockIt() {
        var governor = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let reading = Self.load(100, misses: 1_000, context: .perform)
        let outcome = Self.step(&governor, reading, request: .background)
        let expected: Outcome = .decided(.deferStart(.performContext))
        #expect(outcome == expected)
    }

    @Test
    func aStartBlockedByMissesAndByLoadIsReportedAsMisses() {
        var governor = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let outcome = Self.step(&governor, Self.load(100, misses: 5), request: .interactive)
        let expected: Outcome = .decided(.deferStart(.deadlineMisses))
        #expect(outcome == expected)
    }

    @Test
    func anIdleGovernorWithNoRequestAnswersIdleWhateverTheLoadAndStaysIdle() {
        var governor = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let quiet = Self.step(&governor, Self.load(0))
        let busy = Self.step(&governor, Self.load(100, misses: 1_000, context: .perform))
        let expected: Outcome = .decided(.idle)
        let phase = governor.phase
        #expect(quiet == expected)
        #expect(busy == expected)
        #expect(phase == .idle)
    }

    // MARK: - Running

    @Test
    func aRunIsSuspendedForLoadAtTheSuspendThresholdAndContinuesOneBelowIt() {
        var below = Self.running(.interactive)
        var onEdge = Self.running(.interactive)
        let belowOutcome = Self.step(&below, Self.load(79))
        let edgeOutcome = Self.step(&onEdge, Self.load(80))
        let expectedBelow: Outcome = .decided(.continueRunning)
        let expectedEdge: Outcome = .decided(.suspend(.loadHigh))
        let belowPhase = below.phase
        let edgePhase = onEdge.phase
        let runningPhase: AssistantInferencePhase = .running(.interactive)
        let suspendedPhase: AssistantInferencePhase = .suspended(.interactive, calmEvaluations: 0)
        #expect(belowOutcome == expectedBelow)
        #expect(edgeOutcome == expectedEdge)
        #expect(belowPhase == runningPhase)
        #expect(edgePhase == suspendedPhase)
    }

    @Test
    func aRunIsSuspendedForMissesAtTheMissCountAndContinuesOneBelowIt() {
        var below = Self.running(.background)
        var onEdge = Self.running(.background)
        let belowOutcome = Self.step(&below, Self.load(0, misses: 4))
        let edgeOutcome = Self.step(&onEdge, Self.load(0, misses: 5))
        let expectedBelow: Outcome = .decided(.continueRunning)
        let expectedEdge: Outcome = .decided(.suspend(.deadlineMisses))
        #expect(belowOutcome == expectedBelow)
        #expect(edgeOutcome == expectedEdge)
    }

    @Test
    func loadBetweenTheDeferAndSuspendThresholdsKeepsARunGoingWhileBlockingANewStart() {
        var running = Self.running(.interactive)
        var idle = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let runningAtDefer = Self.step(&running, Self.load(60))
        let runningBelowSuspend = Self.step(&running, Self.load(79))
        let startAtDefer = Self.step(&idle, Self.load(60), request: .interactive)
        let expectedRun: Outcome = .decided(.continueRunning)
        let expectedStart: Outcome = .decided(.deferStart(.loadHigh))
        #expect(runningAtDefer == expectedRun)
        #expect(runningBelowSuspend == expectedRun)
        #expect(startAtDefer == expectedStart)
    }

    @Test
    func aRunSuspendedForMissesAndLoadIsReportedAsMisses() {
        var governor = Self.running(.interactive)
        let outcome = Self.step(&governor, Self.load(100, misses: 5))
        let expected: Outcome = .decided(.suspend(.deadlineMisses))
        #expect(outcome == expected)
    }

    @Test
    func aBackgroundRunSuspendedForLoadAndForThePerformContextIsReportedAsLoad() {
        var governor = Self.running(.background)
        let outcome = Self.step(&governor, Self.load(80, context: .perform))
        let expected: Outcome = .decided(.suspend(.loadHigh))
        #expect(outcome == expected)
    }

    @Test
    func aBackgroundRunSuspendedForMissesAndForThePerformContextIsReportedAsMisses() {
        var governor = Self.running(.background)
        let outcome = Self.step(&governor, Self.load(0, misses: 5, context: .perform))
        let expected: Outcome = .decided(.suspend(.deadlineMisses))
        #expect(outcome == expected)
    }

    @Test
    func aBackgroundRunIsSuspendedInThePerformContextAndAnInteractiveRunContinues() {
        var background = Self.running(.background)
        var interactive = Self.running(.interactive)
        let backgroundOutcome = Self.step(&background, Self.load(0, context: .perform))
        let interactiveOutcome = Self.step(&interactive, Self.load(0, context: .perform))
        let expectedBackground: Outcome = .decided(.suspend(.performContext))
        let expectedInteractive: Outcome = .decided(.continueRunning)
        #expect(backgroundOutcome == expectedBackground)
        #expect(interactiveOutcome == expectedInteractive)
    }

    // MARK: - Settling

    @Test
    func aSuspendedInferenceResumesOnlyAfterTheSettleCountOfConsecutiveCalmEvaluations() {
        var governor = Self.suspended(.interactive, calm: 0)
        let first = Self.step(&governor, Self.load(0))
        let second = Self.step(&governor, Self.load(39))
        let third = Self.step(&governor, Self.load(0))
        let expectedFirst: Outcome = .decided(.stayedSuspended(1))
        let expectedSecond: Outcome = .decided(.stayedSuspended(2))
        let expectedThird: Outcome = .decided(.resume)
        let phase = governor.phase
        let runningPhase: AssistantInferencePhase = .running(.interactive)
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
        #expect(third == expectedThird)
        #expect(phase == runningPhase)
    }

    @Test
    func oneSampleWithMissesResetsTheCalmStreakAndTheSettleCountStartsAgain() {
        var governor = Self.suspended(.interactive, calm: 2)
        let missed = Self.step(&governor, Self.load(0, misses: 1))
        let phaseAfterMiss = governor.phase
        let again = Self.step(&governor, Self.load(0))
        let expectedMissed: Outcome = .decided(.stayedSuspended(0))
        let expectedAgain: Outcome = .decided(.stayedSuspended(1))
        let zeroPhase: AssistantInferencePhase = .suspended(.interactive, calmEvaluations: 0)
        #expect(missed == expectedMissed)
        #expect(phaseAfterMiss == zeroPhase)
        #expect(again == expectedAgain)
    }

    @Test
    func loadAtTheResumeThresholdIsNotCalmAndOneBelowItIs() {
        var onEdge = Self.suspended(.interactive, calm: 2)
        var below = Self.suspended(.interactive, calm: 2)
        let edgeOutcome = Self.step(&onEdge, Self.load(40))
        let belowOutcome = Self.step(&below, Self.load(39))
        let expectedEdge: Outcome = .decided(.stayedSuspended(0))
        let expectedBelow: Outcome = .decided(.resume)
        #expect(edgeOutcome == expectedEdge)
        #expect(belowOutcome == expectedBelow)
    }

    @Test
    func loadFromTheResumeThresholdUpToFullResetsTheStreakWithoutAReason() {
        var governor = Self.suspended(.background, calm: 2)
        let expected: Outcome = .decided(.stayedSuspended(0))
        var outcomes: [Outcome] = []
        for percent in [40, 59, 60, 79, 80, 100] {
            outcomes.append(Self.step(&governor, Self.load(percent)))
        }
        let allReset = Array(repeating: expected, count: 6)
        #expect(outcomes == allReset)
    }

    @Test
    func aBackgroundInferenceSuspendedInThePerformContextNeverSettlesButAnInteractiveOneDoes() {
        var background = Self.suspended(.background, calm: 2)
        var interactive = Self.suspended(.interactive, calm: 2)
        let backgroundOutcome = Self.step(&background, Self.load(0, context: .perform))
        let interactiveOutcome = Self.step(&interactive, Self.load(0, context: .perform))
        let expectedBackground: Outcome = .decided(.stayedSuspended(0))
        let expectedInteractive: Outcome = .decided(.resume)
        #expect(backgroundOutcome == expectedBackground)
        #expect(interactiveOutcome == expectedInteractive)
    }

    @Test
    func aSettleCountOfZeroResumesAtTheFirstCalmEvaluationAndOneOfSixtyFourNeedsSixtyFour() {
        var immediate = AssistantInferenceGovernor(budget: Self.budget(settle: 0))
        _ = Self.step(&immediate, Self.load(0), request: .interactive)
        _ = Self.step(&immediate, Self.load(100))
        let immediateOutcome = Self.step(&immediate, Self.load(0))
        let expectedImmediate: Outcome = .decided(.resume)

        var patient = AssistantInferenceGovernor(budget: Self.budget(settle: 64))
        _ = Self.step(&patient, Self.load(0), request: .interactive)
        _ = Self.step(&patient, Self.load(100))
        var lastBeforeEnd: Outcome = .decided(.idle)
        var evaluations = 0
        while evaluations < 63 {
            lastBeforeEnd = Self.step(&patient, Self.load(0))
            evaluations += 1
        }
        let expectedLast: Outcome = .decided(.stayedSuspended(63))
        let finalOutcome = Self.step(&patient, Self.load(0))
        let expectedFinal: Outcome = .decided(.resume)
        #expect(immediateOutcome == expectedImmediate)
        #expect(lastBeforeEnd == expectedLast)
        #expect(finalOutcome == expectedFinal)
    }

    @Test
    func aResumedInferenceCanBeSuspendedAgainAndSettlesAgainFromZero() {
        var governor = Self.suspended(.interactive, calm: 2)
        let resumed = Self.step(&governor, Self.load(0))
        let suspendedAgain = Self.step(&governor, Self.load(0, misses: 5))
        let firstCalm = Self.step(&governor, Self.load(0))
        let expectedResumed: Outcome = .decided(.resume)
        let expectedSuspended: Outcome = .decided(.suspend(.deadlineMisses))
        let expectedFirstCalm: Outcome = .decided(.stayedSuspended(1))
        #expect(resumed == expectedResumed)
        #expect(suspendedAgain == expectedSuspended)
        #expect(firstCalm == expectedFirstCalm)
    }

    @Test
    func aMillionEvaluationsOfSuspendAndSettleKeepTheCountBelowTheSettleCount() {
        var governor = AssistantInferenceGovernor(budget: Self.budget(settle: 64))
        _ = Self.step(&governor, Self.load(0), request: .interactive)
        var evaluations = 0
        var resumes = 0
        var highestCount = 0
        let resumed: Outcome = .decided(.resume)
        let missing = Self.load(0, misses: 5)
        let calm = Self.load(0)
        while evaluations < 1_000_000 {
            let startsBlock = evaluations % 65 == 0
            let reading = startsBlock ? missing : calm
            let outcome = Self.step(&governor, reading)
            if outcome == resumed { resumes += 1 }
            if case .suspended(_, let count) = governor.phase, count > highestCount { highestCount = count }
            evaluations += 1
        }
        #expect(resumes == 15_384)
        #expect(highestCount == 63)
    }

    // MARK: - Completion

    @Test
    func completedReturnsARunningOrSuspendedGovernorToIdleAndRefusesWhileIdle() {
        var running = Self.running(.background)
        var suspended = Self.suspended(.interactive, calm: 1)
        var idle = AssistantInferenceGovernor(budget: Self.fixtureBudget)
        let idleBefore = idle
        var refusal: AssistantInferenceRefusal?
        do throws(AssistantInferenceRefusal) {
            try running.completed()
            try suspended.completed()
            try idle.completed()
        } catch {
            refusal = error
        }
        let runningPhase = running.phase
        let suspendedPhase = suspended.phase
        let expected: AssistantInferenceRefusal? = .completedWhileIdle
        #expect(runningPhase == .idle)
        #expect(suspendedPhase == .idle)
        #expect(refusal == expected)
        #expect(idle == idleBefore)
    }
}
