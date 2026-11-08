//
//  SetupFlowRefusal.swift
//  FluxKlang
//
//  Why a setup flow value could not be built or an event was not accepted, and the small enums the refusals name.
//  A refusal returns no value and changes nothing.
//

/// The four steps of the flow, in order.
enum SetupFlowStep: Equatable, Sendable {
    case identify
    case map
    case review
    case decide
}

/// The two panes the operator reviews separately at the review step.
enum SetupFlowPane: Equatable, Sendable {
    case home
    case runtimeMap
}

/// A count in the facts that has a range.
enum SetupFlowField: Equatable, Sendable {
    case presentDevices
    case lostMuted
    case undecidedRoles
}

enum SetupFlowRefusal: Error, Equatable, Sendable {
    /// More than 16 offered rigs; carries the count given.
    case tooManyRigs(Int)
    /// A count outside its range; carries the field and the value given.
    case factOutOfRange(SetupFlowField, Int)
    /// The first offered rig that equals an earlier one.
    case duplicateRig(SetupFlowRigID)
    /// The flow has ended; every event is refused.
    case flowEnded
    /// The flow is suspended; only `reopen` and `stayManual` are accepted.
    case suspended
    /// `reopen` while the flow is running.
    case notSuspended
    /// `next` at the decide step.
    case noNextStep
    /// `back` at the identify step.
    case noPreviousStep
    /// The event belongs to another step.
    case wrongStep(expected: SetupFlowStep)
    /// A picked rig that is not among the offered rigs (also when none is offered).
    case rigNotOffered(SetupFlowRigID)
    /// Gate 1: only `granted` passes.
    case permissionNotGranted(SetupFlowAccess)
    /// Gate 2: no device is present.
    case noPresentDevice
    /// Gate 3: rigs are offered and none is picked.
    case rigNotChosen
    /// Gate 4: roles that still await a decision.
    case rolesUndecided(Int)
    /// Gates 5 and 6: the pane was not acknowledged under the current facts.
    case paneNotReviewed(SetupFlowPane)
}
