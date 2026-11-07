//
//  PerformCellState.swift
//  FluxKlang
//
//  The ten perform cell states of perform.md and the deterministic input result of a cell (#102 P1).
//

/// The ten states of perform.md "States", in the document's order. `meterUnavailable` is a meter facet: it never
/// changes the input result, so ten states give nine exclusive input outcomes.
enum PerformCellState: CaseIterable, Hashable, Sendable {
    case engaged
    case staleController
    case waitingForPickup
    case hazardous
    case pendingRemoval
    case noTarget
    case notPermittedHere
    case resyncing
    case missingPlugin
    case meterUnavailable
}

enum PerformDisabledReason: Equatable, Sendable {
    /// The target was removed from the active graph.
    case noTarget
}

/// What an edit of the cell does. Decided by the first holding state in the priority order of `PerformCellEvaluation`.
enum PerformInputResult: Equatable, Sendable {
    /// Applies; the parameter revision moves.
    case accepted
    /// A new epoch is resyncing: queued nowhere, the stale intent is dropped.
    case droppedStaleIntent
    case rejectedPermission
    case disabled(PerformDisabledReason)
    /// The edit is stored but nothing is rendered (the plugin is missing).
    case storedNotRendered
    /// The controller is stale: no device input. Host UI edits are still accepted.
    case noDeviceInput
    case needsAuthorization
    case heldForPickup
}

/// What the cell knows about its target, binding and session. Plain values; the host fills them in.
struct PerformCellFacts: Equatable, Sendable {
    /// A new epoch is resyncing.
    var resyncing = false
    /// The remote may edit this target (`false`: "Not in your permissions").
    var permitted = true
    /// The target exists in the active graph (`false`: "No target").
    var targetExists = true
    var pluginMissing = false
    var controllerStale = false
    /// The binding's runtime pickup state; nil when the cell has no binding.
    var pickup: PickupState?
    /// The target is removed only in a draft; the cell is still live.
    var pendingRemoval = false
    /// Edit mode is on; a cell that takes input and is not hazardous then offers "Learn control...".
    var editMode = false
}

/// The states that hold, in the fixed priority order, and the input result of the first one that has a result.
struct PerformCellEvaluation: Equatable, Sendable {
    let states: [PerformCellState]
    let inputResult: PerformInputResult

    private struct Rule {
        let state: PerformCellState
        let holds: Bool
        /// Nil for a facet that does not decide the input result.
        let result: PerformInputResult?
    }

    init(facts: PerformCellFacts, controlClass: ControlClass, signalUnavailable: Bool) {
        var waiting = false
        var engaged = false
        switch facts.pickup {
        case .waiting: waiting = true
        case .engaged: engaged = true
        case .unavailable, nil: break
        }
        let rules = [
            Rule(state: .resyncing, holds: facts.resyncing, result: .droppedStaleIntent),
            Rule(state: .notPermittedHere, holds: !facts.permitted, result: .rejectedPermission),
            Rule(state: .noTarget, holds: !facts.targetExists, result: .disabled(.noTarget)),
            Rule(state: .missingPlugin, holds: facts.pluginMissing, result: .storedNotRendered),
            Rule(state: .staleController, holds: facts.controllerStale, result: .noDeviceInput),
            Rule(state: .hazardous, holds: controlClass == .hazardous, result: .needsAuthorization),
            Rule(state: .waitingForPickup, holds: waiting, result: .heldForPickup),
            Rule(state: .pendingRemoval, holds: facts.pendingRemoval, result: .accepted),
            Rule(state: .engaged, holds: engaged, result: .accepted),
            Rule(state: .meterUnavailable, holds: signalUnavailable, result: nil)
        ]
        let holding = rules.filter(\.holds)
        states = holding.map(\.state)
        inputResult = holding.lazy.compactMap(\.result).first ?? .accepted
    }
}
