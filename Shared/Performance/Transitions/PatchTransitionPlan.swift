//
//  PatchTransitionPlan.swift
//  FluxKlang
//
//  A prepared move from one MIDI routing and patch variation to another that cuts no held note. Old routes that
//  still sound are retained until the ledger releases their last note or pedal hold; there is no duration cutoff.
//  Only `prepare` builds a plan. Applying parameter changes, crossfades and engine publication are later lanes.
//

/// What the caller should do with a prepared plan. An invalid input is a thrown `PatchTransitionRefusal`, so a
/// refused plan never exists as a value.
enum PatchTransitionDecision: Hashable, Sendable {
    /// Every retained route and tail fits the budget: publish the plan.
    case publish
    /// The budget cannot hold the retained routes or tails. Nothing is cut; retry once routes drain.
    case `defer`(PatchTransitionPressure)
}

/// One retained old route and the tail slots it holds: its sounding notes and pedal holds in the ledger snapshot.
/// Released when the ledger owns nothing on the route.
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

    /// This reservation against a later ledger snapshot, or nil once the route owns nothing there (drained).
    func observed(in ledger: MIDINoteLedger) -> Self? {
        let notes = ledger.notes.count(where: { $0.route == storedRoute })
        let holds = ledger.pedalHolds.count(where: { $0.route == storedRoute })
        guard notes + holds > 0 else { return nil }
        return Self(PatchRouteOccupancy(route: storedRoute, notes: notes, pedalHolds: holds), target: storedTarget)
    }
}

/// One parameter change of the recalled patch, applied now or deferred while retained routes share its patch.
struct PatchPlannedChange: Hashable, Sendable {
    var patch: PatchID { storedPatch }
    var change: PatchParameterChange { storedChange }
    /// Retained routes playing `patch`, ascending. Empty: apply now to the new routes.
    var waitingOn: [MIDIRouteID] { storedWaitingOn }
    var isDeferred: Bool { !storedWaitingOn.isEmpty }

    private let storedPatch: PatchID
    private let storedChange: PatchParameterChange
    private let storedWaitingOn: [MIDIRouteID]

    fileprivate init(patch: PatchID, change: PatchParameterChange, waitingOn: [MIDIRouteID]) {
        storedPatch = patch
        storedChange = change
        storedWaitingOn = waitingOn
    }

    /// This change still waiting only on the routes in `retained`; with none left it is ready to apply.
    func waiting(onlyOn retained: Set<MIDIRouteID>) -> Self {
        Self(patch: storedPatch, change: storedChange, waitingOn: storedWaitingOn.filter(retained.contains))
    }
}

struct PatchTransitionPlan: Equatable, Sendable {
    /// Bound on a recall plan's changes and on the changes it merges with those still deferred.
    static let maximumParameterChanges = PatchVariationLimits.maximumDeltasPerVariation
    /// Owner ruling Q-NT1a.
    static let parameterPolicy = PatchParameterPolicy.newRoutesOnlyDeferWhileTargetRetained

    let previousRouting: MIDIRouting
    /// Applies to new note-ons, pedal-downs and channel messages only; releases follow the ledger.
    let routing: MIDIRouting
    /// Routes not in `routing` that still own a sounding note or pedal hold, ascending and unique.
    let retainedRoutes: [MIDIRouteID]
    /// Routes of `previousRouting` that are neither in `routing` nor retained, ascending: free at once.
    let droppedRoutes: [MIDIRouteID]
    /// One per retained route, in `retainedRoutes` order.
    let tailReservations: [PatchTailReservation]
    /// Sorted by patch, then parameter.
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
    /// ledger sounds on outside `routing` is retained. Reads `ledger` only. Refusals are checked before pressure (see
    /// `PatchTransitionRefusal`), so a refused input is never deferred.
    static func prepare(
        ledger: MIDINoteLedger, from previous: MIDIRouting, to routing: MIDIRouting, recall: PatchRecallPlan?,
        policy: PatchTransitionPolicy
    ) throws(PatchTransitionRefusal) -> Self {
        try assemble(PatchTransitionInputs(
            ledger: ledger, previous: previous, routing: routing, recall: recall, policy: policy, deferred: [],
            tracked: nil
        ))
    }

    /// Plans `tracker`'s routing → `routing`, merging `recall`'s changes after the tracker's deferred ones, and refuses
    /// a ledger sounding on a route the tracker neither routes to nor retains.
    static func prepare(
        ledger: MIDINoteLedger, to routing: MIDIRouting, recall: PatchRecallPlan?, tracker: PatchTransitionTracker
    ) throws(PatchTransitionRefusal) -> Self {
        try assemble(PatchTransitionInputs(
            ledger: ledger, previous: tracker.routing, routing: routing, recall: recall, policy: tracker.policy,
            deferred: tracker.deferredChanges, tracked: tracker.trackedRoutes
        ))
    }

    private static func assemble(_ inputs: PatchTransitionInputs) throws(PatchTransitionRefusal) -> Self {
        let targets = inputs.policy.targets
        if let recall = inputs.recall { try PatchTransitionPlanner.validate(recall) }
        let merged = try PatchTransitionPlanner.merge(
            deferred: inputs.deferred.map { ($0.patch, $0.change) }, recall: inputs.recall
        )
        let occupancy = PatchTransitionPlanner.occupancy(of: inputs.ledger)
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
        let changes = merged.map { patch, change in
            PatchPlannedChange(
                patch: patch, change: change,
                waitingOn: reservations.filter { $0.target == patch }.map(\.route)
            )
        }
        let pressure = inputs.policy.budget.pressure(
            retainedRoutes: reservations.count, tailSlots: reservations.reduce(0) { $0 + $1.slots }
        )
        return Self(
            previousRouting: inputs.previous, routing: inputs.routing,
            droppedRoutes: old.subtracting(current).subtracting(retained).sorted(),
            tailReservations: reservations, parameterChanges: changes,
            decision: pressure.map(PatchTransitionDecision.defer) ?? .publish
        )
    }
}

/// Everything one prepare reads. `tracked` is nil without a tracker.
private struct PatchTransitionInputs {
    let ledger: MIDINoteLedger
    let previous: MIDIRouting
    let routing: MIDIRouting
    let recall: PatchRecallPlan?
    let policy: PatchTransitionPolicy
    let deferred: [PatchPlannedChange]
    let tracked: Set<MIDIRouteID>?
}
