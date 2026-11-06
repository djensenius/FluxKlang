//
//  PatchTransitionPlanner.swift
//  FluxKlang
//
//  Pure checks and derivations behind `PatchTransitionPlan.prepare`. The planner reads a ledger snapshot and never
//  changes it: the ledger already sends every release to the route that received the note-on, so retaining a route
//  only means keeping its destination reserved until the ledger owns nothing there.
//

/// Sounding ownership of one route in a ledger snapshot. Release markers own no route and are not counted.
struct PatchRouteOccupancy: Hashable, Sendable {
    let route: MIDIRouteID
    /// Note instances still sounding on the route (key down, sustained or held by sostenuto).
    let notes: Int
    let pedalHolds: Int
}

enum PatchTransitionPlanner {
    /// Plans moving from `previous` to `routing` with `recall`'s parameter changes; see `PatchTransitionPlan.prepare`.
    static func plan(
        ledger: MIDINoteLedger, from previous: MIDIRouting, to routing: MIDIRouting, recall: PatchRecallPlan?,
        policy: PatchTransitionPolicy
    ) throws(PatchTransitionRefusal) -> PatchTransitionPlan {
        try PatchTransitionPlan.prepare(ledger: ledger, from: previous, to: routing, recall: recall, policy: policy)
    }

    /// The distinct routes of `routing`'s rules.
    static func routes(of routing: MIDIRouting) -> Set<MIDIRouteID> {
        Set(routing.rules.map(\.route))
    }

    /// One entry per route owning a sounding note or a pedal hold, ascending by route, so a route with many notes
    /// appears once.
    static func occupancy(of ledger: MIDINoteLedger) -> [PatchRouteOccupancy] {
        var notes: [MIDIRouteID: Int] = [:]
        var holds: [MIDIRouteID: Int] = [:]
        for instance in ledger.notes {
            notes[instance.route, default: 0] += 1
        }
        for hold in ledger.pedalHolds {
            holds[hold.route, default: 0] += 1
        }
        return Set(notes.keys).union(holds.keys).sorted().map { route in
            PatchRouteOccupancy(route: route, notes: notes[route] ?? 0, pedalHolds: holds[route] ?? 0)
        }
    }

    /// Refuses a plan `PatchRecallPlanner` could not have produced: changes with no variation change, more than
    /// `maximumParameterChanges`, then per change in order: unsorted or duplicate, non-finite, unit mismatch,
    /// unchanged.
    static func validate(_ recall: PatchRecallPlan) throws(PatchTransitionRefusal) {
        guard recall.from != recall.to || recall.changes.isEmpty else {
            throw .invalidRecallPlan(.changesWithoutVariationChange)
        }
        let maximum = PatchTransitionPlan.maximumParameterChanges
        guard recall.changes.count <= maximum else {
            throw .tooManyParameterChanges(count: recall.changes.count, maximum: maximum)
        }
        var previous: ParameterID?
        for change in recall.changes {
            let parameter = change.parameter
            if let previous, !(previous < parameter) { throw .invalidRecallPlan(.unsorted(parameter)) }
            previous = parameter
            guard change.from.value.isFinite, change.to.value.isFinite else {
                throw .invalidRecallPlan(.nonFinite(parameter))
            }
            guard change.from.unit == change.to.unit else { throw .invalidRecallPlan(.unitMismatch(parameter)) }
            guard change.from != change.to else { throw .invalidRecallPlan(.unchanged(parameter)) }
        }
    }

    /// Refuses the lowest route of either routing or of the ledger that has no patch target.
    static func requireBound(
        _ routes: Set<MIDIRouteID>, targets: PatchRouteTargets
    ) throws(PatchTransitionRefusal) {
        if let unbound = routes.filter({ targets.target(of: $0) == nil }).min() {
            throw .unboundRoute(unbound)
        }
    }

    /// The deferred changes followed by `recall`'s, merged per (patch, parameter): a change continuing a deferred one
    /// keeps the deferred `from` and takes the new `to`, and a merge back to the starting value drops out. Sorted by
    /// patch, then parameter.
    static func merge(
        deferred: [(patch: PatchID, change: PatchParameterChange)], recall: PatchRecallPlan?
    ) throws(PatchTransitionRefusal) -> [(patch: PatchID, change: PatchParameterChange)] {
        var merged = deferred
        if let recall {
            let indices = Dictionary(
                merged.indices.filter { merged[$0].patch == recall.patch }.map { (merged[$0].change.parameter, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for change in recall.changes {
                guard let index = indices[change.parameter] else {
                    merged.append((recall.patch, change))
                    continue
                }
                let earlier = merged[index].change
                guard earlier.to == change.from else { throw .invalidRecallPlan(.discontinuous(change.parameter)) }
                merged[index].change = PatchParameterChange(
                    parameter: change.parameter, from: earlier.from, to: change.to
                )
            }
        }
        merged.removeAll { $0.change.from == $0.change.to }
        let maximum = PatchTransitionPlan.maximumParameterChanges
        guard merged.count <= maximum else { throw .tooManyParameterChanges(count: merged.count, maximum: maximum) }
        return merged.sorted { lhs, rhs in
            lhs.patch == rhs.patch ? lhs.change.parameter < rhs.change.parameter : lhs.patch < rhs.patch
        }
    }
}
