//
//  AssistantInferenceGovernor.swift
//  FluxKlang
//
//  Decides, one evaluation at a time, whether the one on-device assistant inference may start, go on, must stop or
//  may resume. Live audio outranks assistance: pressure defers or suspends the assistant and nothing here touches
//  audio. Nothing is read from the engine and nothing is paused here: the caller passes plain numbers in, acts on
//  the answer, and reports the end of a run with `completed()`.
//

/// Where the single inference is.
enum AssistantInferencePhase: Equatable, Sendable {
    case idle
    case running(AssistantInferenceRequestKind)
    /// Suspended, with the consecutive calm evaluations seen so far. The evaluation that reaches the budget's settle
    /// count resumes, so this stays below that count (and stays 0 when the settle count is 0).
    case suspended(AssistantInferenceRequestKind, calmEvaluations: Int)
}

struct AssistantInferenceGovernor: Equatable, Sendable {
    let budget: AssistantInferenceBudget
    private(set) var phase: AssistantInferencePhase

    /// An invalid budget is not rejected here; `evaluate` refuses it at every call.
    init(budget: AssistantInferenceBudget) {
        self.budget = budget
        self.phase = .idle
    }

    /// Refusal order: `invalidBudget`, then `invalidLoad`, then `requestWhileActive`. A refusal changes nothing.
    mutating func evaluate(
        load: AssistantInferenceLoad,
        request: AssistantInferenceRequestKind?
    ) throws(AssistantInferenceRefusal) -> AssistantInferenceDecision {
        guard budget.isValid else { throw .invalidBudget }
        guard load.isValid else { throw .invalidLoad }
        switch phase {
        case .idle:
            guard let kind = request else { return .idle }
            return start(kind, load: load)
        case .running(let kind):
            guard request == nil else { throw .requestWhileActive }
            return run(kind, load: load)
        case .suspended(let kind, let calm):
            guard request == nil else { throw .requestWhileActive }
            return settle(kind, calm: calm, load: load)
        }
    }

    /// The caller reports that the running or suspended inference is over.
    mutating func completed() throws(AssistantInferenceRefusal) {
        guard phase != .idle else { throw .completedWhileIdle }
        phase = .idle
    }

    private mutating func start(
        _ kind: AssistantInferenceRequestKind,
        load: AssistantInferenceLoad
    ) -> AssistantInferenceDecision {
        if load.context == .perform && kind == .background { return .deferStart(.performContext) }
        if load.recentDeadlineMisses >= budget.missSuspendCount { return .deferStart(.deadlineMisses) }
        if load.renderLoadPercent >= budget.deferAtPercent { return .deferStart(.loadHigh) }
        phase = .running(kind)
        return .start(kind)
    }

    private mutating func run(
        _ kind: AssistantInferenceRequestKind,
        load: AssistantInferenceLoad
    ) -> AssistantInferenceDecision {
        if load.recentDeadlineMisses >= budget.missSuspendCount { return suspended(kind, .deadlineMisses) }
        if load.renderLoadPercent >= budget.suspendAtPercent { return suspended(kind, .loadHigh) }
        if load.context == .perform && kind == .background { return suspended(kind, .performContext) }
        return .continueRunning
    }

    private mutating func suspended(
        _ kind: AssistantInferenceRequestKind,
        _ reason: AssistantInferenceReason
    ) -> AssistantInferenceDecision {
        phase = .suspended(kind, calmEvaluations: 0)
        return .suspend(reason)
    }

    private mutating func settle(
        _ kind: AssistantInferenceRequestKind,
        calm: Int,
        load: AssistantInferenceLoad
    ) -> AssistantInferenceDecision {
        guard isCalm(kind, load: load) else {
            phase = .suspended(kind, calmEvaluations: 0)
            return .stayedSuspended(0)
        }
        let settled = calm + 1
        if settled >= budget.settleEvaluations {
            phase = .running(kind)
            return .resume
        }
        phase = .suspended(kind, calmEvaluations: settled)
        return .stayedSuspended(settled)
    }

    /// No misses, load below the resume threshold, and not a background run in the perform context.
    private func isCalm(_ kind: AssistantInferenceRequestKind, load: AssistantInferenceLoad) -> Bool {
        guard load.recentDeadlineMisses == 0 else { return false }
        guard load.renderLoadPercent < budget.resumeBelowPercent else { return false }
        return !(load.context == .perform && kind == .background)
    }
}
