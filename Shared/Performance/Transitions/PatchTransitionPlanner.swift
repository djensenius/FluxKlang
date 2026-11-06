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

/// One ledger snapshot's sounding ownership, read once and indexed by route, so updating every reservation from a
/// snapshot never rescans the ledger per route. Only `init(_:)` builds one, from a ledger.
struct PatchLedgerOccupancy: Sendable {
    /// One entry per route owning a sounding note or a pedal hold, ascending by route, so a route with many notes
    /// appears once.
    let entries: [PatchRouteOccupancy]
    private let index: [MIDIRouteID: PatchRouteOccupancy]

    init(_ ledger: MIDINoteLedger) {
        var notes: [MIDIRouteID: Int] = [:]
        var holds: [MIDIRouteID: Int] = [:]
        for instance in ledger.notes {
            notes[instance.route, default: 0] += 1
        }
        for hold in ledger.pedalHolds {
            holds[hold.route, default: 0] += 1
        }
        entries = Set(notes.keys).union(holds.keys).sorted().map { route in
            PatchRouteOccupancy(route: route, notes: notes[route] ?? 0, pedalHolds: holds[route] ?? 0)
        }
        index = Dictionary(uniqueKeysWithValues: entries.map { ($0.route, $0) })
    }

    /// The route's entry, or nil when it owns nothing in the snapshot.
    subscript(route: MIDIRouteID) -> PatchRouteOccupancy? {
        index[route]
    }
}

enum PatchTransitionPlanner {
    /// A deferred or recalled change while merging: its patch, the recalled variation it leads to (nil: the
    /// baseline) and the change.
    struct MergedChange {
        let patch: PatchID
        var variation: PatchVariationID?
        var change: PatchParameterChange
    }

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

    /// The deferred changes followed by `recall`'s, merged per (patch, parameter), sorted by patch, then parameter.
    /// - The recalled patch's deferred changes must lead to `recall.from` (else `.discontinuousVariation`), so a stale
    ///   recall is refused even when it touches none of their parameters. Afterwards they all lead to `recall.to`.
    /// - A change continuing a deferred one must start at its `to` (else `.discontinuous`). The merge keeps the
    ///   deferred `from` and takes the new `to`, and a merge back to the starting value drops out.
    /// - The recalled patch's merged changes are bounded by `maximumParameterChanges` (`.tooManyMergedChanges`).
    ///   Every other patch's deferred changes were bounded when their recall merged.
    static func merge(
        deferred: [MergedChange], recall: PatchRecallPlan?
    ) throws(PatchTransitionRefusal) -> [MergedChange] {
        var merged = deferred
        if let recall {
            var indices: [ParameterID: Int] = [:]
            for index in merged.indices where merged[index].patch == recall.patch {
                guard merged[index].variation == recall.from else {
                    throw .invalidRecallPlan(.discontinuousVariation(recall.patch, expected: merged[index].variation))
                }
                merged[index].variation = recall.to
                indices[merged[index].change.parameter] = index
            }
            for change in recall.changes {
                guard let index = indices[change.parameter] else {
                    merged.append(MergedChange(patch: recall.patch, variation: recall.to, change: change))
                    continue
                }
                let earlier = merged[index].change
                guard earlier.to == change.from else { throw .invalidRecallPlan(.discontinuous(change.parameter)) }
                merged[index].change = PatchParameterChange(
                    parameter: change.parameter, from: earlier.from, to: change.to
                )
            }
            merged.removeAll { $0.change.from == $0.change.to }
            let count = merged.count(where: { $0.patch == recall.patch })
            let maximum = PatchTransitionPlan.maximumParameterChanges
            guard count <= maximum else {
                throw .tooManyMergedChanges(recall.patch, count: count, maximum: maximum)
            }
        }
        return merged.sorted { lhs, rhs in
            lhs.patch == rhs.patch ? lhs.change.parameter < rhs.change.parameter : lhs.patch < rhs.patch
        }
    }
}
