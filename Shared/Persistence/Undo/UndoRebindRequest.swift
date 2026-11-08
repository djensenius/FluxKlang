//
//  UndoRebindRequest.swift
//  FluxKlang
//
//  A request to rebind an undo session after a restore, a replace or a clear.
//

/// Which rebind a request asks for.
enum UndoRebindKind: Hashable, Sendable {
    case restore
    case replace
    case clear
}

/// The state a restore or replace rebinds the session to. The revision is the new revision that state is saved as.
struct UndoRebindTarget: Equatable, Sendable {
    let graph: GraphID
    let revision: ContractRevision
    let content: UndoContentFingerprint
}

/// What the caller wants done to the session.
enum UndoRebindTrigger: Equatable, Sendable {
    case restore(UndoRebindTarget)
    case replace(UndoRebindTarget)
    case clear

    var kind: UndoRebindKind {
        switch self {
        case .restore: .restore
        case .replace: .replace
        case .clear: .clear
        }
    }
}

/// One rebind request. `claimed` is what the caller believes the session is bound to; `reason` is a user-visible
/// note of 1...64 UTF-8 bytes that is carried into the plan. Not `Equatable`: `String` equality is Character-level.
struct UndoRebindRequest: Sendable {
    static let reasonByteRange = 1...64

    let claimed: UndoSessionBinding
    let trigger: UndoRebindTrigger
    /// A saved record of the session's bound revision and content; see the policy for what is and is not checked.
    let preRestore: CheckpointRecord?
    let reason: String
}
