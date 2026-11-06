//
//  PatchTransitionTracker.swift
//  FluxKlang
//
//  Folds ledger snapshots into the published transition: retained routes are released as the ledger drains them,
//  deferred parameter changes become ready when no retained route shares their patch, and the transition retires
//  when nothing is retained or deferred. Repeated recalls derive retention from the ledger, so a route is retained
//  at most once and a route routed again is current, not retained.
//

/// What one observed ledger snapshot released.
struct PatchTransitionDrain: Equatable, Sendable {
    /// Retained routes the ledger no longer sounds on, ascending.
    let releasedRoutes: [MIDIRouteID]
    /// Deferred changes no retained route waits on any more; the caller applies them to the new routes.
    let readyChanges: [PatchPlannedChange]
    /// Nothing is retained or deferred after this snapshot.
    let isRetired: Bool

    fileprivate init(releasedRoutes: [MIDIRouteID], readyChanges: [PatchPlannedChange], isRetired: Bool) {
        self.releasedRoutes = releasedRoutes
        self.readyChanges = readyChanges
        self.isRetired = isRetired
    }
}

/// The published routing plus everything still retained or deferred. Every refusal leaves it unchanged, and so does
/// a deferred plan. Nothing expires: only a ledger snapshot without a route's notes and holds releases the route, so
/// cutting a retained tail takes a ledger panic or `routeLost` (exceptional loss may silence safely).
struct PatchTransitionTracker: Equatable, Sendable {
    private(set) var routing: MIDIRouting
    let policy: PatchTransitionPolicy
    /// Ascending by route.
    private(set) var tailReservations: [PatchTailReservation] = []
    /// Changes waiting on retained routes, sorted by patch, then parameter.
    private(set) var deferredChanges: [PatchPlannedChange] = []

    var retainedRoutes: [MIDIRouteID] { tailReservations.map(\.route) }
    var isRetired: Bool { tailReservations.isEmpty && deferredChanges.isEmpty }

    /// Refuses the lowest route of `routing` with no patch target.
    init(
        routing: MIDIRouting, policy: PatchTransitionPolicy
    ) throws(PatchTransitionRefusal) {
        try PatchTransitionPlanner.requireBound(PatchTransitionPlanner.routes(of: routing), targets: policy.targets)
        self.routing = routing
        self.policy = policy
    }

    /// Every route the ledger may sound on: the routing's and the retained ones.
    var trackedRoutes: Set<MIDIRouteID> {
        PatchTransitionPlanner.routes(of: routing).union(retainedRoutes)
    }

    /// Plans moving to `next` with `recall` against `ledger` without changing the tracker.
    func prepare(
        to next: MIDIRouting, recall: PatchRecallPlan?, ledger: MIDINoteLedger
    ) throws(PatchTransitionRefusal) -> PatchTransitionPlan {
        try PatchTransitionPlan.prepare(ledger: ledger, to: next, recall: recall, tracker: self)
    }

    /// Prepares and, when the decision is `.publish`, adopts the plan: its routing, its reservations and its deferred
    /// changes. A deferred plan is returned without being adopted; a refusal throws. Both leave the tracker unchanged.
    @discardableResult
    mutating func recall(
        to next: MIDIRouting, recall: PatchRecallPlan?, ledger: MIDINoteLedger
    ) throws(PatchTransitionRefusal) -> PatchTransitionPlan {
        let plan = try prepare(to: next, recall: recall, ledger: ledger)
        guard plan.decision == .publish else { return plan }
        routing = plan.routing
        tailReservations = plan.tailReservations
        deferredChanges = plan.parameterChanges.filter(\.isDeferred)
        return plan
    }

    /// Folds a ledger snapshot taken after an event: releases retained routes the ledger no longer sounds on and
    /// readies deferred changes nothing waits on any more. Refuses a ledger sounding on an untracked route.
    mutating func observe(_ ledger: MIDINoteLedger) throws(PatchTransitionRefusal) -> PatchTransitionDrain {
        let tracked = trackedRoutes
        if let untracked = PatchTransitionPlanner.occupancy(of: ledger).first(where: { !tracked.contains($0.route) }) {
            throw .untrackedRoute(untracked.route)
        }
        var kept: [PatchTailReservation] = []
        var released: [MIDIRouteID] = []
        for reservation in tailReservations {
            if let still = reservation.observed(in: ledger) {
                kept.append(still)
            } else {
                released.append(reservation.route)
            }
        }
        let keptRoutes = Set(kept.map(\.route))
        let changes = deferredChanges.map { $0.waiting(onlyOn: keptRoutes) }
        tailReservations = kept
        deferredChanges = changes.filter(\.isDeferred)
        return PatchTransitionDrain(
            releasedRoutes: released, readyChanges: changes.filter { !$0.isDeferred }, isRetired: isRetired
        )
    }
}
