//
//  UndoRebindPlan.swift
//  FluxKlang
//
//  What a permitted rebind would do, and the ticket that must be presented again to confirm it.
//

/// The fate of one stack. `kept` exists so later code can name it; the rebind policy never produces it.
enum UndoStackDisposition: Equatable, Sendable {
    case kept
    case discarded(count: Int)

    var discardedCount: Int {
        switch self {
        case .kept: 0
        case .discarded(let count): count
        }
    }
}

/// Proof that a plan was issued for one session and one request. Presenting it to `confirm` re-checks the session
/// and recomputes the plan from the stored pair. Its memberwise initializer is internal because the policy that
/// issues it lives in another file, so a ticket can be built inside the module; `confirm` recomputes the plan from the
/// stored session and request, so a built ticket yields only what `plan` allows. A ticket has no used-once state:
/// presenting it again to an unchanged session gives the same plan, until the session moves.
struct UndoRebindTicket: Sendable {
    let session: UndoSessionSnapshot
    let request: UndoRebindRequest
}

/// A permitted rebind. Nothing has been applied: the plan only says what may happen to the stacks.
struct UndoRebindPlan: Sendable {
    let kind: UndoRebindKind
    let newBinding: UndoSessionBinding
    let undo: UndoStackDisposition
    let redo: UndoStackDisposition
    /// False for every kind: nothing is redoable after a rebind.
    let redoable: Bool
    let reason: String
    let ticket: UndoRebindTicket
}
