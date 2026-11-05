//
//  ActionSetCancellation.swift
//  FluxKlang
//
//  Pending set triggers indexed by cancel scope (media-contract.md §5.1,
//  §5.8). A `userCancel` bumps the scope's `cancelScope` counter, which
//  makes the scheduler cancel or reject every trigger stamped against the
//  old generation, and returns exactly the registered triggers in that scope.
//

import Foundation

struct ActionSetPendingTriggers: Sendable {
    static let maximumPending = 256

    private var scopes: [TriggerID: GenerationKey] = [:]

    var count: Int { scopes.count }

    func pending(in scope: GenerationSubject) -> [TriggerID] {
        let key = GenerationKey(kind: .cancelScope, subject: scope)
        return scopes.filter { $0.value == key }.keys.sorted()
    }

    /// Registers every stamp or none.
    mutating func register(_ stamps: [TriggerStamp], ledger: GenerationLedger) throws(ActionSetRefusal) {
        var next = self
        for stamp in stamps { try next.register(stamp, ledger: ledger) }
        self = next
    }

    mutating func register(_ stamp: TriggerStamp, ledger: GenerationLedger) throws(ActionSetRefusal) {
        let scoped = stamp.requires.filter { $0.key.kind == .cancelScope }
        guard scoped.count == 1, let scope = scoped.first else { throw .notSetTrigger(stamp.id) }
        guard scopes[stamp.id] == nil else { throw .duplicatePending(stamp.id) }
        guard ledger.isCurrent(scope) else { throw .staleScope(stamp.id) }
        guard scopes.count < Self.maximumPending else { throw .pendingCapacity }
        scopes[stamp.id] = scope.key
    }

    /// Forgets a trigger once it has an outcome; returns whether it was pending.
    @discardableResult
    mutating func complete(_ trigger: TriggerID) -> Bool {
        scopes.removeValue(forKey: trigger) != nil
    }

    /// Bumps `cancelScope/<scope>` (`userCancel`) and returns, sorted, the pending
    /// triggers it cancelled. Repeating it returns nothing. A refused bump changes nothing.
    mutating func userCancel(scope: GenerationSubject,
                             ledger: inout GenerationLedger) throws(ActionSetRefusal) -> [TriggerID] {
        let key = GenerationKey(kind: .cancelScope, subject: scope)
        do {
            try ledger.bump(key, reason: .userCancel)
        } catch {
            throw .cancelFailed(error)
        }
        let cancelled = pending(in: scope)
        for trigger in cancelled { scopes.removeValue(forKey: trigger) }
        return cancelled
    }
}
