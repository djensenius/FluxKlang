//
//  RigApproval.swift
// swiftlint:disable identifier_name
//  FluxKlang
//
//  Operator approvals and experiment stop conditions of the exclusive rig protocol (#48).
//

/// What an operator approved. Case order is the order in which approvals are stored and reported.
enum RigApprovalKind: String, CaseIterable, Sendable {
    case audibility
    case mappings
    case clockChange
    case configChange
    case restoration
}

/// One approval of one kind by one approver at one instant.
struct RigApproval: Hashable, Sendable {
    let kind: RigApprovalKind
    let approver: RigToken
    let at: RigInstant
}

/// A condition that must stop an experiment. Every experiment plan lists all of them.
enum RigStopCondition: String, CaseIterable, Sendable {
    case unexpectedClock
    case unexpectedLayout
    case unexpectedIdentity
    case clipping
    case feedback
    case permissionDenied
    case overload
}

/// Why an experiment stopped.
enum RigStopReason: Hashable, Sendable {
    case completed
    case operatorAbort
    case windowEnded
    case condition(RigStopCondition)
}
// swiftlint:enable identifier_name
