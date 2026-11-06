//
//  PatchTransitionPlan.swift
//  FluxKlang
//
//  A prepared move from one MIDI routing and patch variation to another that cuts no held note. Old routes that
//  still sound are retained until the ledger releases their last note or pedal hold; there is no duration cutoff.
//  A "tail" here is MIDI ownership only: a route's sounding note instances and pedal holds in the ledger. Synth
//  release envelopes after the last release are the engine's responsibility and are not tracked.
//  Only `prepare` builds a plan. Applying parameter changes, crossfades and engine publication are later lanes.
//

/// What the caller should do with a prepared plan. An invalid input is a thrown `PatchTransitionRefusal`, so a
/// refused plan never exists as a value.
enum PatchTransitionDecision: Hashable, Sendable {
    /// Every retained route and tail fits the budget, or the plan adds no retention: publish the plan.
    case publish
    /// The plan adds retention and the budget cannot hold the retained routes or tails. Nothing is cut and nothing in
    /// the plan is actionable (`droppedRoutes` and `parameterChanges` are empty); retry once routes drain.
    case `defer`(PatchTransitionPressure)
}

/// One retained old route and the tail slots it holds: its sounding notes and pedal holds in the ledger snapshot
/// (MIDI ownership only; synth release envelopes are the engine's). Released when the ledger owns nothing on the
/// route.
struct PatchTailReservation: Hashable, Sendable {
    var route: MIDIRouteID { storedRoute }
    /// The patch the route plays; its parameters stay unchanged while the route is retained.
    var target: PatchID { storedTarget }
    var notes: Int { storedNotes }
    var pedalHolds: Int { storedPedalHolds }
    var slots: Int { storedNotes + storedPedalHolds }

    private let storedRoute: MIDIRouteID
    private let storedTarget: PatchID
    private let storedNotes: Int
    private let storedPedalHolds: Int

    fileprivate init(_ occupancy: PatchRouteOccupancy, target: PatchID) {
        storedRoute = occupancy.route
        storedTarget = target
        storedNotes = occupancy.notes
        storedPedalHolds = occupancy.pedalHolds
    }

    /// This reservation updated from a later snapshot, or nil once the route owns nothing there (drained). Reads only
    /// the route's entry in the shared, route-indexed snapshot.
    func observed(in occupancy: PatchLedgerOccupancy) -> Self? {
        occupancy[storedRoute].map { Self($0, target: storedTarget) }
    }
}

/// One parameter change of a recalled patch, applied now or deferred while retained routes share its patch.
struct PatchPlannedChange: Hashable, Sendable {
    var patch: PatchID { storedPatch }
    /// The recalled variation this change leads `patch` to (nil: the baseline). Every deferred change of one patch
    /// leads to the same variation, which the next recall of that patch must start from.
    var variation: PatchVariationID? { storedVariation }
    var change: PatchParameterChange { storedChange }
    /// Retained routes playing `patch`, ascending. Empty: apply now to the patch.
    var waitingOn: [MIDIRouteID] { storedWaitingOn }
    var isDeferred: Bool { !storedWaitingOn.isEmpty }

    private let storedPatch: PatchID
    private let storedVariation: PatchVariationID?
    private let storedChange: PatchParameterChange
    private let storedWaitingOn: [MIDIRouteID]

    fileprivate init(
        patch: PatchID, variation: PatchVariationID?, change: PatchParameterChange, waitingOn: [MIDIRouteID]
    ) {
        storedPatch = patch
        storedVariation = variation
        storedChange = change
        storedWaitingOn = waitingOn
    }

    /// This change still waiting only on the routes in `retained`; with none left it is ready to apply.
    func waiting(onlyOn retained: Set<MIDIRouteID>) -> Self {
        Self(
            patch: storedPatch, variation: storedVariation, change: storedChange,
            waitingOn: storedWaitingOn.filter(retained.contains)
        )
    }
}

struct PatchTransitionPlan: Equatable, Sendable {
    /// Bound on a recall plan's changes and, per patch, on its changes merged with those still deferred. A recall
    /// moves between two variations that each override at most `maximumDeltasPerVariation` parameters, so a plan
    /// `PatchRecallPlanner` produces has at most twice that many changes.
    static let maximumParameterChanges = 2 * PatchVariationLimits.maximumDeltasPerVariation
    /// Owner ruling Q-NT1a.
    static let parameterPolicy = PatchParameterPolicy.newRoutesOnlyDeferWhileTargetRetained

    let previousRouting: MIDIRouting
    /// Applies to new note-ons, pedal-downs and channel messages only; releases follow the ledger.
    let routing: MIDIRouting
    /// Routes not in `routing` that still own a sounding note or pedal hold, ascending and unique.
    let retainedRoutes: [MIDIRouteID]
    /// Routes free at once, ascending: every route the transition stops tracking. With a tracker, these are its
    /// routing's and its retained routes (including a retained route that drained before any `observe`) that are
    /// neither in `routing` nor retained now; without one, `previousRouting`'s. Each route a tracker stops tracking is
    /// reported exactly once, here or in `PatchTransitionDrain.releasedRoutes`. Actionable only on `.publish`: empty
    /// when the decision is `.defer`.
    let droppedRoutes: [MIDIRouteID]
    /// One per retained route, in `retainedRoutes` order. On `.defer`, the retention that does not fit.
    let tailReservations: [PatchTailReservation]
    /// The tracker's deferred changes merged with the recall's, sorted by patch, then parameter. A change no retained
    /// route waits on applies now. Actionable only on `.publish`: empty when the decision is `.defer`.
    let parameterChanges: [PatchPlannedChange]
    let decision: PatchTransitionDecision

    private init(
        previousRouting: MIDIRouting, routing: MIDIRouting, droppedRoutes: [MIDIRouteID],
        tailReservations: [PatchTailReservation], parameterChanges: [PatchPlannedChange],
        decision: PatchTransitionDecision
    ) {
        self.previousRouting = previousRouting
        self.routing = routing
        retainedRoutes = tailReservations.map(\.route)
        self.droppedRoutes = droppedRoutes
        self.tailReservations = tailReservations
        self.parameterChanges = parameterChanges
        self.decision = decision
    }

    /// Plans `previous` → `routing` with `recall`'s changes (nil: routing only) and no tracker: every route the
    /// ledger sounds on outside `routing` is retained, and any retention counts as added. Reads `ledger` only.
    /// Refusals are checked before pressure (see `PatchTransitionRefusal`), so a refused input is never deferred.
    static func prepare(
        ledger: MIDINoteLedger, from previous: MIDIRouting, to routing: MIDIRouting, recall: PatchRecallPlan?,
        policy: PatchTransitionPolicy
    ) throws(PatchTransitionRefusal) -> Self {
        try assemble(PatchTransitionInputs(
            ledger: ledger, previous: previous, routing: routing, recall: recall, policy: policy, deferred: [],
            tracked: nil, wasRetained: []
        ))
    }

    /// Plans `tracker`'s routing → `routing`, merging `recall`'s changes after the tracker's deferred ones, and refuses
    /// a ledger sounding on a route the tracker neither routes to nor retains. Routes the tracker already retains add
    /// no retention, and every tracked route left untracked is dropped.
    static func prepare(
        ledger: MIDINoteLedger, to routing: MIDIRouting, recall: PatchRecallPlan?, tracker: PatchTransitionTracker
    ) throws(PatchTransitionRefusal) -> Self {
        try assemble(PatchTransitionInputs(
            ledger: ledger, previous: tracker.routing, routing: routing, recall: recall, policy: tracker.policy,
            deferred: tracker.deferredChanges, tracked: tracker.trackedRoutes,
            wasRetained: Set(tracker.retainedRoutes)
        ))
    }

    private static func assemble(_ inputs: PatchTransitionInputs) throws(PatchTransitionRefusal) -> Self {
        let targets = inputs.policy.targets
        if let recall = inputs.recall { try PatchTransitionPlanner.validate(recall) }
        let merged = try PatchTransitionPlanner.merge(
            deferred: inputs.deferred.map {
                PatchTransitionPlanner.MergedChange(patch: $0.patch, variation: $0.variation, change: $0.change)
            },
            recall: inputs.recall
        )
        let occupancy = PatchLedgerOccupancy(inputs.ledger).entries
        let current = PatchTransitionPlanner.routes(of: inputs.routing)
        let old = PatchTransitionPlanner.routes(of: inputs.previous)
        try PatchTransitionPlanner.requireBound(
            old.union(current).union(occupancy.map(\.route)), targets: targets
        )
        if let recall = inputs.recall, !current.contains(where: { targets.target(of: $0) == recall.patch }) {
            throw .recallPatchNotRouted(recall.patch)
        }
        if let tracked = inputs.tracked, let untracked = occupancy.first(where: { !tracked.contains($0.route) }) {
            throw .untrackedRoute(untracked.route)
        }
        let reservations = occupancy.compactMap { entry -> PatchTailReservation? in
            guard !current.contains(entry.route), let target = targets.target(of: entry.route) else { return nil }
            return PatchTailReservation(entry, target: target)
        }
        let retained = Set(reservations.map(\.route))
        let changes = merged.map { entry in
            PatchPlannedChange(
                patch: entry.patch, variation: entry.variation, change: entry.change,
                waitingOn: reservations.filter { $0.target == entry.patch }.map(\.route)
            )
        }
        // Only added retention (a route retained that was not retained before) can defer; see PatchTransitionBudget.
        let adds = reservations.contains { !inputs.wasRetained.contains($0.route) }
        let pressure = adds ? inputs.policy.budget.pressure(
            retainedRoutes: reservations.count, tailSlots: reservations.reduce(0) { $0 + $1.slots }
        ) : nil
        let publish = pressure == nil
        let dropped = old.union(inputs.wasRetained).subtracting(current).subtracting(retained).sorted()
        return Self(
            previousRouting: inputs.previous, routing: inputs.routing, droppedRoutes: publish ? dropped : [],
            tailReservations: reservations, parameterChanges: publish ? changes : [],
            decision: pressure.map(PatchTransitionDecision.defer) ?? .publish
        )
    }
}

/// Everything one prepare reads. Without a tracker, `tracked` is nil and `wasRetained` is empty.
private struct PatchTransitionInputs {
    let ledger: MIDINoteLedger
    let previous: MIDIRouting
    let routing: MIDIRouting
    let recall: PatchRecallPlan?
    let policy: PatchTransitionPolicy
    let deferred: [PatchPlannedChange]
    let tracked: Set<MIDIRouteID>?
    /// Routes the tracker retains before this transition.
    let wasRetained: Set<MIDIRouteID>
}
