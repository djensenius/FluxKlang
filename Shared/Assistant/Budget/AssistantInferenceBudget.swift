//
//  AssistantInferenceBudget.swift
//  FluxKlang
//
//  The plain numbers an assistant inference is judged by: how loaded the render side is, how often it recently
//  missed a deadline, what the musician is doing, and the thresholds that turn those into a decision. Both carriers
//  are built by the caller; every evaluation checks the budget and then the load, and refuses the first one that
//  is invalid.
//

/// What the musician is doing; performing is the more sensitive context.
enum AssistantInferenceContext: Equatable, Sendable, CaseIterable {
    case edit
    case perform
}

/// Why an inference was requested: the musician asked just now, or the assistant wants to work unprompted.
enum AssistantInferenceRequestKind: Equatable, Sendable, CaseIterable {
    case interactive
    case background
}

/// One reading of the audio side, as plain numbers.
struct AssistantInferenceLoad: Equatable, Sendable {
    /// The most deadline misses a reading may report.
    static let maximumMisses = 1_000

    let renderLoadPercent: Int
    let recentDeadlineMisses: Int
    let context: AssistantInferenceContext

    /// Percent in 0...100 and misses in 0...`maximumMisses`.
    var isValid: Bool {
        guard renderLoadPercent >= 0, renderLoadPercent <= 100 else { return false }
        return recentDeadlineMisses >= 0 && recentDeadlineMisses <= Self.maximumMisses
    }
}

/// The thresholds of a governor. Every field is a plain number, so a value can be built invalid; the governor
/// refuses an invalid budget at every evaluation.
struct AssistantInferenceBudget: Equatable, Sendable {
    /// The largest `missSuspendCount` a budget may hold.
    static let maximumMissSuspendCount = 1_000
    /// The largest `settleEvaluations` a budget may hold.
    static let maximumSettleEvaluations = 64

    /// A new inference may not start at or above this render load.
    let deferAtPercent: Int
    /// A running inference is suspended at or above this render load.
    let suspendAtPercent: Int
    /// A suspended inference can only settle while the render load is below this.
    let resumeBelowPercent: Int
    /// This many recent deadline misses defer a start and suspend a run.
    let missSuspendCount: Int
    /// The consecutive calm evaluations after which a suspended inference resumes: the evaluation that reaches this
    /// count is the one that answers `resume`, so with 0 the first calm evaluation resumes.
    let settleEvaluations: Int

    /// A placeholder, not measured on any device and not a recommendation.
    static let conservative = AssistantInferenceBudget(
        deferAtPercent: 60, suspendAtPercent: 80, resumeBelowPercent: 40, missSuspendCount: 1, settleEvaluations: 3
    )

    /// Holds iff 1 <= resume <= defer <= suspend <= 100, 1 <= misses <= 1_000 and 0 <= settle <= 64.
    var isValid: Bool {
        guard resumeBelowPercent >= 1, resumeBelowPercent <= deferAtPercent else { return false }
        guard deferAtPercent <= suspendAtPercent, suspendAtPercent <= 100 else { return false }
        guard missSuspendCount >= 1, missSuspendCount <= Self.maximumMissSuspendCount else { return false }
        return settleEvaluations >= 0 && settleEvaluations <= Self.maximumSettleEvaluations
    }
}
