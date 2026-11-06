//
//  PatchTransitionPolicy.swift
//  FluxKlang
//
//  Budgets, pressure and route-to-patch targets for patch transitions. There is no duration, timer or deadline
//  anywhere in a transition: a retained route is held until the ledger shows its last release, however long. A
//  "tail" here is MIDI ownership only (sounding note instances and pedal holds); synth release envelopes are the
//  engine's responsibility.
//

/// How a transition treats the recall plan's parameter changes (owner ruling Q-NT1a, as confirmed by coordinator
/// ruling M3).
enum PatchParameterPolicy: Hashable, Sendable {
    /// Deferral protects only retained routes, so a retained tail never changes: while any retained route plays the
    /// recalled patch (shares its parameter target), that patch's changes are deferred until every such route drains.
    /// A route that stays in, or becomes part of, the new routing is current, and its patch takes the changes at once,
    /// including on notes the route already holds: the patch instance is shared, as on any synth. Per-note protection
    /// is out of scope.
    case newRoutesOnlyDeferWhileTargetRetained
}

/// Why a transition must wait. Pressure never cuts a note: the plan is not published and the caller retries later.
enum PatchTransitionPressure: Hashable, Sendable {
    /// Retained routes after the transition, against the budget.
    case retainedRoutes(required: Int, limit: Int)
    /// Tail slots (sounding note instances plus pedal holds on retained routes) against the budget.
    case tailSlots(required: Int, limit: Int)
}

/// The caller's capacity for retained old routes and their tails. Only the throwing factory builds one.
///
/// The budget gates only a transition that adds retention, that is, one that retains a route not already retained.
/// Retention already adopted can grow past the budget afterwards (a pedal pressed later adds a hold to a retained
/// route, and a seeded tracker adopts whatever the ledger already sounds on). That growth is never cut, and it does
/// not block a transition that adds no retention. It only defers a later transition that adds some.
struct PatchTransitionBudget: Hashable, Sendable {
    /// At most one retained route per ledger entry.
    static let retainedRouteBounds = 0...(
        MIDINoteLedgerPolicy.noteCapacityBounds.upperBound + MIDINoteLedgerPolicy.pedalCapacityBounds.upperBound
    )
    /// A tail slot is one note instance or one pedal hold, so the ledger's largest capacity bounds it.
    static let tailSlotBounds = retainedRouteBounds

    var retainedRoutes: Int { storedRetainedRoutes }
    var tailSlots: Int { storedTailSlots }

    private let storedRetainedRoutes: Int
    private let storedTailSlots: Int

    /// Refuses either capacity outside its bounds.
    static func make(retainedRoutes: Int, tailSlots: Int) throws(PatchTransitionRefusal) -> Self {
        guard retainedRouteBounds.contains(retainedRoutes), tailSlotBounds.contains(tailSlots) else {
            throw .invalidBudget(retainedRoutes: retainedRoutes, tailSlots: tailSlots)
        }
        return Self(retainedRoutes: retainedRoutes, tailSlots: tailSlots)
    }

    private init(retainedRoutes: Int, tailSlots: Int) {
        storedRetainedRoutes = retainedRoutes
        storedTailSlots = tailSlots
    }

    /// The first exceeded capacity (routes, then tail slots), or nil when both fit. Exactly at capacity fits.
    func pressure(retainedRoutes: Int, tailSlots: Int) -> PatchTransitionPressure? {
        if retainedRoutes > storedRetainedRoutes {
            return .retainedRoutes(required: retainedRoutes, limit: storedRetainedRoutes)
        }
        if tailSlots > storedTailSlots {
            return .tailSlots(required: tailSlots, limit: storedTailSlots)
        }
        return nil
    }
}

/// Which patch each MIDI route plays: the parameter target of the route. Two routes with the same patch share a
/// target, so a change to that patch would reach both. Only the throwing factory builds one.
struct PatchRouteTargets: Equatable, Sendable {
    static let maximumBindings = 1024

    /// Bound routes, ascending.
    var routes: [MIDIRouteID] { storedBindings.keys.sorted() }

    private let storedBindings: [MIDIRouteID: PatchID]

    /// Refuses more than `maximumBindings` pairs (checked first) and a route bound twice (the first repeat in order).
    static func make(_ pairs: [(route: MIDIRouteID, patch: PatchID)]) throws(PatchTransitionRefusal) -> Self {
        guard pairs.count <= maximumBindings else {
            throw .tooManyBindings(count: pairs.count, maximum: maximumBindings)
        }
        var bindings: [MIDIRouteID: PatchID] = [:]
        for pair in pairs {
            guard bindings.updateValue(pair.patch, forKey: pair.route) == nil else {
                throw .duplicateBinding(pair.route)
            }
        }
        return Self(bindings: bindings)
    }

    private init(bindings: [MIDIRouteID: PatchID]) {
        storedBindings = bindings
    }

    func target(of route: MIDIRouteID) -> PatchID? {
        storedBindings[route]
    }
}

/// The caller's route targets and budget, both already validated, which every prepare of one tracker shares.
struct PatchTransitionPolicy: Equatable, Sendable {
    let targets: PatchRouteTargets
    let budget: PatchTransitionBudget
}
