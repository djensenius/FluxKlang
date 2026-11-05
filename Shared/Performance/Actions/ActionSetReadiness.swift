//
//  ActionSetReadiness.swift
//  FluxKlang
//
//  Set readiness: ready only when every member is `ready` against current
//  generations and none of its trigger requirements is stale
//  (media-contract.md §7). Otherwise the set takes its worst member's state
//  and reports every not-ready member with its own reason.
//

import Foundation

struct ActionSetMemberStatus: Hashable, Sendable {
    let action: ActionID
    let state: ReadinessState
    let reason: ReadinessReason?
    /// Trigger requirements whose generation is no longer current, in requirement order.
    var staleRequirements: [GenerationKey] = []

    var isReady: Bool { state == .ready && staleRequirements.isEmpty }
}

struct ActionSetReadinessReport: Hashable, Sendable {
    let set: ActionSetID
    let state: ReadinessState
    /// Every member, in member order.
    let members: [ActionSetMemberStatus]

    var isReady: Bool { state == .ready }
    var notReady: [ActionSetMemberStatus] { members.filter { !$0.isReady } }
}

enum ActionSetReadinessAggregate {
    /// Worst first.
    static let precedence: [ReadinessState] = [.failed, .invalidated, .unprepared, .preparing, .ready]

    static func evaluate(_ resolved: ResolvedActionSet, readiness: ActionReadiness, ledger: GenerationLedger,
                         stale: [ActionID: [GenerationKey]] = [:]) -> ActionSetReadinessReport {
        let members = resolved.set.members.map { action in
            status(of: action, readiness: readiness, ledger: ledger, stale: stale[action] ?? [])
        }
        return ActionSetReadinessReport(set: resolved.set.id, state: combine(members.map(\.state)), members: members)
    }

    static func combine(_ states: [ReadinessState]) -> ReadinessState {
        precedence.first(where: states.contains) ?? .unprepared
    }

    private static func status(of action: ActionID, readiness: ActionReadiness, ledger: GenerationLedger,
                               stale: [GenerationKey]) -> ActionSetMemberStatus {
        let state = readiness.state(action)
        // A ready member prepared or stamped against a superseded generation is not fireable.
        if state == .ready, !stale.isEmpty || !readiness.isCurrent(action, ledger: ledger) {
            return ActionSetMemberStatus(action: action, state: .invalidated, reason: .sourceChanged,
                                         staleRequirements: stale)
        }
        return ActionSetMemberStatus(action: action, state: state, reason: readiness.reasons[action],
                                     staleRequirements: stale)
    }
}
