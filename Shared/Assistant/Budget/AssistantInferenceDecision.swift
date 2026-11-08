//
//  AssistantInferenceDecision.swift
//  FluxKlang
//
//  What the governor answers and why it refuses. Refusals carry no text and no number, so hostile input cannot be
//  echoed back.
//

/// The pressure that blocked a start or forced a suspend.
enum AssistantInferenceReason: Equatable, Sendable, CaseIterable {
    case deadlineMisses
    case loadHigh
    case performContext
}

/// The answer to one evaluation.
enum AssistantInferenceDecision: Equatable, Sendable {
    /// Nothing is running and nothing was asked.
    case idle
    /// The request may begin; the governor now counts it as running.
    case start(AssistantInferenceRequestKind)
    /// The request may not begin now; the governor stays idle.
    case deferStart(AssistantInferenceReason)
    /// The running inference may go on.
    case continueRunning
    /// The running inference must stop using the CPU now; the governor counts it as suspended.
    case suspend(AssistantInferenceReason)
    /// The inference stays suspended; the count is the consecutive calm evaluations so far.
    case stayedSuspended(Int)
    /// The suspended inference may go on; the governor counts it as running.
    case resume
}

/// Why an evaluation or a completion was refused. A refusal changes nothing.
enum AssistantInferenceRefusal: Error, Equatable, Sendable, CaseIterable {
    /// The budget does not satisfy its limits.
    case invalidBudget
    /// The load reading is out of range.
    case invalidLoad
    /// A request was passed while an inference is already running or suspended.
    case requestWhileActive
    /// `completed()` was called while nothing is running or suspended.
    case completedWhileIdle
}
