//
//  PatchTransitionTracker.swift
//  FluxKlang
//
//  Folds ledger snapshots into the published transition: retained routes are released as the ledger drains them,
//  deferred parameter changes become ready when no retained route shares their patch, and the transition retires
//  when nothing is retained or deferred. Repeated recalls derive retention from the ledger, so a route is retained
//  at most once and a route routed again is current, not retained. A "tail" here is MIDI ownership only (sounding
//  note instances and pedal holds); synth release envelopes after the last release are the engine's responsibility.
//

/// What one observed ledger snapshot released.
struct PatchTransitionDrain: Equatable, Sendable {
    /// Retained routes the ledger no longer sounds on, ascending.
    let releasedRoutes: [MIDIRouteID]
    /// Deferred changes no retained route waits on any more. The engine must apply each one to its patch's state, even
    /// when no current route plays that patch any more (a routing-only recall can unroute it while its tail drains):
    /// nothing on the patch sounds then, and the patch must hold its latest recalled variation the next time it is
    /// routed (coordinator ruling on bhUg).
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
    /// Changes waiting on retained routes, sorted by patch, then parameter. All of one patch's deferred changes lead to
    /// the same recorded variation (`PatchPlannedChange.variation`), which the next recall of that patch must start
    /// from.
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

    /// A tracker for `routing` created while `ledger` may still sound on other routes: each of those routes is
    /// retained as if a recall had just left it, so later recalls and observes accept them. Seeded retention is
    /// existing state that cannot be cut, so it is adopted even over the budget (see `PatchTransitionBudget`). Refuses
    /// the lowest unbound route of `routing` or of the ledger.
    init(
        routing: MIDIRouting, policy: PatchTransitionPolicy, ledger: MIDINoteLedger
    ) throws(PatchTransitionRefusal) {
        try self.init(routing: routing, policy: policy)
        tailReservations = try PatchTransitionPlan.prepare(
            ledger: ledger, from: routing, to: routing, recall: nil, policy: policy
        ).tailReservations
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
    /// changes. Every route the tracker stops tracking is in the plan's `droppedRoutes`. A deferred plan is returned
    /// without being adopted; a refusal throws. Both leave the tracker unchanged.
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
    /// readies deferred changes nothing waits on any more. Reads the ledger once into a route-indexed snapshot and
    /// updates every reservation from it. Refuses a ledger sounding on an untracked route. A retired tracker returns
    /// at once without reading the ledger (the next prepare still refuses untracked routes).
    ///
    /// Control side only, never on the render thread: it allocates and is linear in the ledger, the retained routes
    /// and the deferred changes.
    mutating func observe(_ ledger: MIDINoteLedger) throws(PatchTransitionRefusal) -> PatchTransitionDrain {
        guard !isRetired else { return PatchTransitionDrain(releasedRoutes: [], readyChanges: [], isRetired: true) }
        let occupancy = PatchLedgerOccupancy(ledger)
        let tracked = trackedRoutes
        if let untracked = occupancy.entries.first(where: { !tracked.contains($0.route) }) {
            throw .untrackedRoute(untracked.route)
        }
        var kept: [PatchTailReservation] = []
        var released: [MIDIRouteID] = []
        for reservation in tailReservations {
            if let still = reservation.observed(in: occupancy) {
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
