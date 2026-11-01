//
//  ActionReadiness.swift
//  FluxKlang
//
//  Readiness of prepared actions (media-contract.md §7). A `source` (or any
//  dependency) bump invalidates dependent readiness, and only a fresh
//  `preparing → ready` against the current generations restores it (§5.7).
//

import Foundation

enum ReadinessState: String, Codable, Sendable, CaseIterable {
    case unprepared, preparing, ready, invalidated, failed

    /// The allowed transitions of §7.
    var allowedNext: Set<ReadinessState> {
        switch self {
        case .unprepared: [.preparing]
        case .preparing: [.ready, .failed, .unprepared]
        case .ready: [.invalidated, .unprepared]
        case .invalidated, .failed: [.preparing, .unprepared]
        }
    }
}

enum ReadinessError: Error, Equatable, Sendable {
    case illegalTransition(ActionID, from: ReadinessState, to: ReadinessState)
    /// The preparation depends on a generation that is no longer current.
    case stalePreparation(ActionID)
    case timeStretchUnavailable
    case capacity
}

enum ReadinessReason: String, Sendable {
    case sourceChanged, timeStretchUnavailable, preparationFailed, explicitInvalidation
}

struct ActionReadiness: Sendable {
    private(set) var states: [ActionID: ReadinessState] = [:]
    private(set) var reasons: [ActionID: ReadinessReason] = [:]
    private var dependencies: [ActionID: [GenerationRequirement]] = [:]
    /// Counts entries into `ready`, so a trigger can tell whether its action
    /// stayed continuously ready (M7).
    private var readyEntries: [ActionID: Int] = [:]

    func state(_ action: ActionID) -> ReadinessState {
        states[action] ?? .unprepared
    }

    /// The `ready` entry count while `action` is ready, else nil.
    func readyEntry(_ action: ActionID) -> Int? {
        state(action) == .ready ? readyEntries[action, default: 0] : nil
    }

    func isCurrent(_ action: ActionID, ledger: GenerationLedger) -> Bool {
        state(action) == .ready && dependencies[action, default: []].allSatisfy(ledger.isCurrent)
    }

    mutating func transition(_ action: ActionID, to next: ReadinessState,
                             reason: ReadinessReason? = nil) throws(ReadinessError) {
        guard next != .ready else { throw .illegalTransition(action, from: state(action), to: next) }
        try move(action, to: next)
        if next == .failed { reasons[action] = reason ?? .preparationFailed }
        if next == .invalidated { reasons[action] = reason ?? .explicitInvalidation }
    }

    /// `preparing → ready`, prepared against `requirements`, all of which must be current.
    mutating func markReady(_ action: ActionID, preparedAgainst requirements: [GenerationRequirement],
                            ledger: GenerationLedger, policy: ActionPolicy? = nil,
                            supportsTimeStretch: Bool = false) throws(ReadinessError) {
        guard requirements.count <= 8 else { throw .capacity }
        if policy?.timePolicy == .timeStretch, !supportsTimeStretch {
            try move(action, to: .failed)
            reasons[action] = .timeStretchUnavailable
            throw .timeStretchUnavailable
        }
        guard requirements.allSatisfy(ledger.isCurrent) else { throw .stalePreparation(action) }
        guard readyEntries[action, default: 0] < Int.max else { throw .capacity }
        try move(action, to: .ready)
        dependencies[action] = requirements
        readyEntries[action, default: 0] += 1
    }

    /// Invalidates every ready action that depends on `key`; returns them sorted.
    @discardableResult
    mutating func generationChanged(_ key: GenerationKey) -> [ActionID] {
        let affected = states.filter { action, state in
            state == .ready && dependencies[action, default: []].contains { $0.key == key }
        }.keys.sorted()
        for action in affected {
            states[action] = .invalidated
            reasons[action] = .sourceChanged
        }
        return affected
    }

    private mutating func move(_ action: ActionID, to next: ReadinessState) throws(ReadinessError) {
        guard states[action] != nil || states.count < 4096 else { throw .capacity }
        let previous = state(action)
        guard previous.allowedNext.contains(next) else {
            throw .illegalTransition(action, from: previous, to: next)
        }
        states[action] = next
        reasons.removeValue(forKey: action)
    }
}
