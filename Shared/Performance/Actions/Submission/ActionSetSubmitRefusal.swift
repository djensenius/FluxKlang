//
//  ActionSetSubmitRefusal.swift
//  FluxKlang
//
//  Typed refusals of an atomic action-set submission or scope sweep (#107 A2).
//  A refused call leaves the scheduler, the pending registry and the ledger
//  exactly as they were: every step runs on staged copies, published only on
//  full success.
//

/// Why a fire or a scope sweep was refused. `index` is the member index, in member order.
enum ActionSetSubmitRefusal: Error, Sendable {
    /// `ActionSetTriggerBuilder.decide` refused the fire (`fire(...)` only).
    case decision(ActionSetRefusal)
    /// A drop report names a different set than the one submitted.
    case setMismatch(expected: ActionSetID, actual: ActionSetID)
    /// The decision does not carry exactly one stamp per member.
    case memberCount(expected: Int, actual: Int)
    /// The stamp at `index` is not the member at `index`, or does not carry the set's cancel scope
    /// at the generation every other stamp of the fire carries.
    case memberMismatch(index: Int)
    /// The registry cannot hold every member; checked before any scheduler submit.
    case pendingCapacity(pending: Int, requested: Int)
    /// A requirement of the stamp at `index` is not current in the submit snapshot. An old epoch
    /// is refused here rather than admitted as an immediately stale completion.
    case staleRequirement(index: Int, GenerationKey)
    /// A requirement of the stamp at `index` names a counter the submit snapshot's ledger never
    /// declared (no generation at all). A caller error, kept distinct from `staleRequirement`.
    case undeclaredRequirement(index: Int, GenerationKey)
    /// The pending registry refused the stamp at `index` (for example `duplicatePending`).
    case registry(index: Int, ActionSetRefusal)
    /// The scheduler refused the stamp at `index`; its error is kept as thrown, never stringified.
    case scheduler(index: Int, any Error)
    /// The scope's `userCancel` bump was refused.
    case cancel(ActionSetRefusal)
    /// The scheduler's stale sweep failed (unreachable in practice: it is all or nothing).
    case sweep(any Error)

    /// The member index the refusal names, if any.
    var memberIndex: Int? {
        switch self {
        case .memberMismatch(let index), .staleRequirement(let index, _), .undeclaredRequirement(let index, _),
             .registry(let index, _), .scheduler(let index, _):
            index
        case .decision, .setMismatch, .memberCount, .pendingCapacity, .cancel, .sweep:
            nil
        }
    }

    /// The scheduler's or sweep's original error, unchanged.
    var underlyingError: (any Error)? {
        switch self {
        case .scheduler(_, let error), .sweep(let error): error
        default: nil
        }
    }
}
