//
//  ActionSetRefusal.swift
//  FluxKlang
//
//  Typed refusals of the preloaded performance action-set model (#107 A1).
//  A refused call changes nothing.
//

import Foundation

enum ActionSetRefusal: Error, Equatable, Sendable {
    case emptySet
    case tooManyMembers(Int)
    case duplicateMember(ActionID)
    /// A present name must be 1…128 UTF-8 bytes.
    case invalidName(Int)
    case tooManySets(Int)
    case duplicateSet(ActionSetID)
    case unknownSet(ActionSetID)
    case unknownMember(ActionID)
    /// The project lists this action ID more than once, so membership is ambiguous.
    case ambiguousProjectAction(ActionID)
    case invalidContext(GenerationKey)
    /// A counter the trigger must require has no live generation.
    case undeclaredCounter(GenerationKey)
    case tooManyRequirements(ActionID, Int)
    /// Clock, transport, context, cancel-scope and musical-map requirements are the builder's alone.
    case invalidMemberRequirement(ActionID, GenerationKey)
    case triggerIDTooLong(Int)
    case invalidTrigger(ActionID, TriggerValidationError)
    case pendingCapacity
    /// The stamp does not carry exactly one cancel-scope requirement.
    case notSetTrigger(TriggerID)
    case duplicatePending(TriggerID)
    /// The stamp's cancel-scope generation is not current: an old epoch never becomes fresh.
    case staleScope(TriggerID)
    case cancelFailed(GenerationLedgerError)
}
