//
//  AssistantInferenceGovernorTests.swift
//  FluxKlangTests
//
//  The assistant inference governor (#120 AIB1): the builders every AssistantInferenceGovernorTests+*.swift file
//  shares, and the validity limits of the budget and of a load reading, each with the value on the limit and the
//  value one outside it. The governor is a pure value: nothing here reads a clock, an engine or a model.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct AssistantInferenceGovernorTests {
    /// What one `evaluate` produced: a decision or a refusal.
    enum Outcome: Equatable {
        case decided(AssistantInferenceDecision)
        case refused(AssistantInferenceRefusal)
    }

    /// resume 40, defer 60, suspend 80, misses 5, settle 3. Chosen so that every edge has a distinct neighbour; it is
    /// a fixture, not a recommendation.
    static let fixtureBudget = AssistantInferenceBudget(
        deferAtPercent: 60, suspendAtPercent: 80, resumeBelowPercent: 40, missSuspendCount: 5, settleEvaluations: 3
    )

    static func budget(
        deferAt: Int = 60,
        suspendAt: Int = 80,
        resumeBelow: Int = 40,
        misses: Int = 5,
        settle: Int = 3
    ) -> AssistantInferenceBudget {
        AssistantInferenceBudget(
            deferAtPercent: deferAt, suspendAtPercent: suspendAt, resumeBelowPercent: resumeBelow,
            missSuspendCount: misses, settleEvaluations: settle
        )
    }

    static func load(
        _ percent: Int,
        misses: Int = 0,
        context: AssistantInferenceContext = .edit
    ) -> AssistantInferenceLoad {
        AssistantInferenceLoad(renderLoadPercent: percent, recentDeadlineMisses: misses, context: context)
    }

    static func step(
        _ governor: inout AssistantInferenceGovernor,
        _ reading: AssistantInferenceLoad,
        request: AssistantInferenceRequestKind? = nil
    ) -> Outcome {
        do throws(AssistantInferenceRefusal) {
            let decision = try governor.evaluate(load: reading, request: request)
            return .decided(decision)
        } catch {
            return .refused(error)
        }
    }

    /// A governor of `fixtureBudget` that is running `kind`, reached by one calm start in the edit context.
    static func running(_ kind: AssistantInferenceRequestKind) -> AssistantInferenceGovernor {
        var governor = AssistantInferenceGovernor(budget: fixtureBudget)
        _ = step(&governor, load(0), request: kind)
        return governor
    }

    /// A governor of `fixtureBudget` that is suspended with `calm` calm evaluations seen (0, 1 or 2).
    static func suspended(_ kind: AssistantInferenceRequestKind, calm: Int) -> AssistantInferenceGovernor {
        var governor = running(kind)
        _ = step(&governor, load(100))
        var seen = 0
        while seen < calm {
            _ = step(&governor, load(0))
            seen += 1
        }
        return governor
    }

    // MARK: - Budget limits

    @Test
    func theResumeThresholdIsValidAtOneAndInvalidAtZero() {
        let atOne = Self.budget(resumeBelow: 1)
        let atZero = Self.budget(resumeBelow: 0)
        let validAtOne = atOne.isValid
        let validAtZero = atZero.isValid
        #expect(validAtOne)
        #expect(!validAtZero)
    }

    @Test
    func theSuspendThresholdIsValidAtOneHundredAndInvalidAtOneHundredAndOne() {
        let atHundred = Self.budget(suspendAt: 100)
        let pastHundred = Self.budget(suspendAt: 101)
        let validAtHundred = atHundred.isValid
        let validPastHundred = pastHundred.isValid
        #expect(validAtHundred)
        #expect(!validPastHundred)
    }

    @Test
    func theThreeThresholdsMustBeOrderedResumeThenDeferThenSuspendAndMayBeEqual() {
        let allEqual = Self.budget(deferAt: 50, suspendAt: 50, resumeBelow: 50)
        let resumeAboveDefer = Self.budget(deferAt: 50, suspendAt: 50, resumeBelow: 51)
        let deferAboveSuspend = Self.budget(deferAt: 51, suspendAt: 50, resumeBelow: 50)
        let negativeDefer = Self.budget(deferAt: -1, suspendAt: 80, resumeBelow: 40)
        let validAllEqual = allEqual.isValid
        let validResumeAboveDefer = resumeAboveDefer.isValid
        let validDeferAboveSuspend = deferAboveSuspend.isValid
        let validNegativeDefer = negativeDefer.isValid
        #expect(validAllEqual)
        #expect(!validResumeAboveDefer)
        #expect(!validDeferAboveSuspend)
        #expect(!validNegativeDefer)
    }

    @Test
    func theMissCountIsValidAtOneAndAThousandAndInvalidAtZeroAndAThousandAndOne() {
        let atOne = Self.budget(misses: 1)
        let atThousand = Self.budget(misses: 1_000)
        let atZero = Self.budget(misses: 0)
        let pastThousand = Self.budget(misses: 1_001)
        let validAtOne = atOne.isValid
        let validAtThousand = atThousand.isValid
        let validAtZero = atZero.isValid
        let validPastThousand = pastThousand.isValid
        #expect(validAtOne)
        #expect(validAtThousand)
        #expect(!validAtZero)
        #expect(!validPastThousand)
    }

    @Test
    func theSettleCountIsValidAtZeroAndSixtyFourAndInvalidAtMinusOneAndSixtyFive() {
        let atZero = Self.budget(settle: 0)
        let atSixtyFour = Self.budget(settle: 64)
        let belowZero = Self.budget(settle: -1)
        let pastSixtyFour = Self.budget(settle: 65)
        let validAtZero = atZero.isValid
        let validAtSixtyFour = atSixtyFour.isValid
        let validBelowZero = belowZero.isValid
        let validPastSixtyFour = pastSixtyFour.isValid
        #expect(validAtZero)
        #expect(validAtSixtyFour)
        #expect(!validBelowZero)
        #expect(!validPastSixtyFour)
    }

    @Test
    func theConservativePlaceholderBudgetPassesValidation() {
        let placeholder = AssistantInferenceBudget.conservative
        let valid = placeholder.isValid
        #expect(valid)
    }

    // MARK: - Load limits

    @Test
    func aLoadPercentIsValidAtZeroAndOneHundredAndInvalidAtMinusOneAndOneHundredAndOne() {
        let atZero = Self.load(0)
        let atHundred = Self.load(100)
        let belowZero = Self.load(-1)
        let pastHundred = Self.load(101)
        let validAtZero = atZero.isValid
        let validAtHundred = atHundred.isValid
        let validBelowZero = belowZero.isValid
        let validPastHundred = pastHundred.isValid
        #expect(validAtZero)
        #expect(validAtHundred)
        #expect(!validBelowZero)
        #expect(!validPastHundred)
    }

    @Test
    func aMissCountIsValidAtZeroAndAThousandAndInvalidAtMinusOneAndAThousandAndOne() {
        let atZero = Self.load(10, misses: 0)
        let atThousand = Self.load(10, misses: 1_000)
        let belowZero = Self.load(10, misses: -1)
        let pastThousand = Self.load(10, misses: 1_001)
        let validAtZero = atZero.isValid
        let validAtThousand = atThousand.isValid
        let validBelowZero = belowZero.isValid
        let validPastThousand = pastThousand.isValid
        #expect(validAtZero)
        #expect(validAtThousand)
        #expect(!validBelowZero)
        #expect(!validPastThousand)
    }
}
