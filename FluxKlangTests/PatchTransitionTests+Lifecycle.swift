import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Patch transitions: route lifecycle, budget and seeding")
struct PatchTransitionLifecycleTests {
    typealias Fixture = PatchTransitionFixture

    /// A retained route that drains with no observe before the next recall is dropped by that recall, once.
    @Test
    func retainedRouteDrainedBeforeTheNextRecallIsDroppedExactlyOnce() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        #expect(try tracker.recall(to: routingB, recall: nil, ledger: ledger).retainedRoutes == [Fixture.routeA])
        try Fixture.play(Fixture.off(48), on: &ledger, routing: routingB)

        let next = try tracker.recall(to: Fixture.routing(Fixture.routeC), recall: nil, ledger: ledger)
        #expect(next.droppedRoutes == [Fixture.routeA, Fixture.routeB])
        #expect(next.retainedRoutes.isEmpty)
        #expect(tracker.isRetired && !tracker.trackedRoutes.contains(Fixture.routeA))
        let drain = try tracker.observe(ledger)
        #expect(drain.releasedRoutes.isEmpty && drain.isRetired)
        #expect(try tracker.recall(to: routingB, recall: nil, ledger: ledger).droppedRoutes == [Fixture.routeC])
    }

    /// Coordinator ruling on bhUg: a change deferred for a patch that a routing-only recall then unroutes becomes
    /// ready when that patch's tail drains, for the engine to apply to the unrouted patch's state.
    @Test
    func changeForAnUnroutedPatchBecomesReadyWhenItsTailDrains() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let recall = try Fixture.planned(Fixture.patchA, from: nil, to: Fixture.verse)
        try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: recall, ledger: ledger)
        #expect(tracker.deferredChanges.map(\.waitingOn) == [[Fixture.routeA], [Fixture.routeA]])

        let away = try tracker.recall(to: Fixture.routing(Fixture.routeB), recall: nil, ledger: ledger)
        #expect(away.droppedRoutes == [Fixture.routeShared])
        #expect(away.retainedRoutes == [Fixture.routeA])
        #expect(away.parameterChanges.allSatisfy { $0.isDeferred })
        let targets = try Fixture.targets()
        let routedPatches = tracker.routing.rules.compactMap { targets.target(of: $0.route) }
        #expect(!routedPatches.contains(Fixture.patchA))

        try Fixture.play(Fixture.off(48), on: &ledger, routing: tracker.routing)
        let drained = try tracker.observe(ledger)
        #expect(drained.releasedRoutes == [Fixture.routeA])
        #expect(drained.readyChanges.map(\.change) == recall.changes)
        #expect(drained.readyChanges.map(\.patch) == [Fixture.patchA, Fixture.patchA])
        #expect(drained.readyChanges.map(\.variation) == [Fixture.verse, Fixture.verse])
        #expect(drained.isRetired)
    }

    @Test
    func trackerSeededFromASoundingLedgerRetainsAndReleasesItsRoutes() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingA)
        let unseeded = try Fixture.tracker(routingB)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try unseeded.prepare(to: routingB, recall: nil, ledger: ledger)
        } == .untrackedRoute(Fixture.routeA))

        var tracker = try PatchTransitionTracker(routing: routingB, policy: Fixture.policy(), ledger: ledger)
        #expect(tracker.routing == routingB)
        #expect(tracker.retainedRoutes == [Fixture.routeA])
        #expect(tracker.tailReservations.map(\.slots) == [2])
        #expect(tracker.deferredChanges.isEmpty && !tracker.isRetired)
        #expect(try tracker.prepare(to: routingB, recall: nil, ledger: ledger).decision == .publish)
        // A route the seeding routing plays is current, not retained.
        let current = try PatchTransitionTracker(routing: routingA, policy: Fixture.policy(), ledger: ledger)
        #expect(current.retainedRoutes.isEmpty && current.isRetired)

        try Fixture.play(Fixture.off(48), on: &ledger, routing: routingB)
        #expect(try tracker.observe(ledger).releasedRoutes.isEmpty)
        try Fixture.play(Fixture.pedal(.sustain, down: false), on: &ledger, routing: routingB)
        let drained = try tracker.observe(ledger)
        #expect(drained.releasedRoutes == [Fixture.routeA] && drained.isRetired)
    }

    @Test
    func seededRetentionIsAdoptedOverTheBudgetAndOnlyAddedRetentionDefers() throws {
        let routingOld = try Fixture.routing(Fixture.routeA, Fixture.routeA2)
        let routingB = try Fixture.routing(Fixture.routeB)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingOld)
        var tracker = try PatchTransitionTracker(
            routing: routingB, policy: Fixture.policy(routes: 0, tails: 0), ledger: ledger
        )
        #expect(tracker.retainedRoutes == [Fixture.routeA, Fixture.routeA2])

        let recall = Fixture.recall(Fixture.patchB, Fixture.change(Fixture.gain, -6, 0))
        let plan = try tracker.recall(to: routingB, recall: recall, ledger: ledger)
        #expect(plan.decision == .publish)
        #expect(plan.parameterChanges.map(\.isDeferred) == [false])

        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingB)
        let before = tracker
        let adding = try tracker.recall(to: Fixture.routing(Fixture.routeC), recall: nil, ledger: ledger)
        #expect(adding.decision == .defer(.retainedRoutes(required: 3, limit: 0)))
        #expect(tracker == before)
    }

    @Test
    func seedingRefusesUnboundRoutes() throws {
        let policy = try Fixture.policy()
        let routingB = try Fixture.routing(Fixture.routeB)
        let stray = try Fixture.routing(Fixture.unbound)
        var sounding = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &sounding, routing: stray)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionTracker(routing: routingB, policy: policy, ledger: sounding)
        } == .unboundRoute(Fixture.unbound))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionTracker(routing: stray, policy: policy, ledger: MIDINoteLedger())
        } == .unboundRoute(Fixture.unbound))
    }

    /// The tail budget gates added retention only: a sustain pedal pressed after adoption may grow the retained
    /// tails over the budget without blocking a recall that adds no retention.
    @Test
    func retentionGrowingAfterAdoptionDoesNotBlockARecallAddingNoRetention() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA, tails: 1)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        #expect(try tracker.recall(to: routingB, recall: nil, ledger: ledger).decision == .publish)
        try Fixture.play(Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingB)
        _ = try tracker.observe(ledger)
        #expect(tracker.tailReservations.map(\.slots) == [2])

        let recall = Fixture.recall(Fixture.patchB, Fixture.change(Fixture.gain, -6, 0))
        let plan = try tracker.recall(to: routingB, recall: recall, ledger: ledger)
        #expect(plan.decision == .publish)
        #expect(plan.tailReservations.map(\.slots) == [2])
        #expect(plan.parameterChanges.map(\.isDeferred) == [false])

        // Retaining another route adds retention, so the whole retention counts again.
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingB)
        let before = tracker
        let away = try tracker.recall(to: routingA, recall: nil, ledger: ledger)
        #expect(away.decision == .defer(.tailSlots(required: 2, limit: 1)))
        #expect(tracker == before)
    }

    /// Dropped routes and changes are actionable only on `.publish`; a deferred plan carries neither.
    @Test
    func deferredPlanCarriesNoDroppedRoutesOrChanges() throws {
        let routingOld = try Fixture.routing(Fixture.routeA, Fixture.routeA2, Fixture.routeC)
        let routingB = try Fixture.routing(Fixture.routeB)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: Fixture.routing(Fixture.routeA, Fixture.routeA2))
        let recall = Fixture.recall(Fixture.patchB, Fixture.change(Fixture.gain, -6, 0))

        var tight = try Fixture.tracker(routingOld, routes: 1)
        let before = tight
        let deferred = try tight.recall(to: routingB, recall: recall, ledger: ledger)
        #expect(deferred.decision == .defer(.retainedRoutes(required: 2, limit: 1)))
        #expect(deferred.droppedRoutes.isEmpty && deferred.parameterChanges.isEmpty)
        #expect(deferred.retainedRoutes == [Fixture.routeA, Fixture.routeA2])
        #expect(tight == before)
        let planned = try PatchTransitionPlanner.plan(
            ledger: ledger, from: routingOld, to: routingB, recall: recall, policy: Fixture.policy(routes: 1)
        )
        #expect(planned == deferred)

        var fits = try Fixture.tracker(routingOld, routes: 2)
        let published = try fits.recall(to: routingB, recall: recall, ledger: ledger)
        #expect(published.decision == .publish)
        #expect(published.droppedRoutes == [Fixture.routeC])
        #expect(published.parameterChanges.map(\.change) == recall.changes)
        #expect(published.parameterChanges.allSatisfy { !$0.isDeferred })
    }

    @Test
    func deferringWhileChangesAreDeferredKeepsThemAndEmptiesThePlan() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA, routes: 1)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        try tracker.recall(
            to: routingShared, recall: Fixture.planned(Fixture.patchA, from: nil, to: Fixture.verse), ledger: ledger
        )
        #expect(tracker.deferredChanges.map(\.waitingOn) == [[Fixture.routeA], [Fixture.routeA]])
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingShared)

        let before = tracker
        let toChorus = try Fixture.planned(Fixture.patchB, from: nil, to: Fixture.chorus)
        let plan = try tracker.recall(to: routingB, recall: toChorus, ledger: ledger)
        #expect(plan.decision == .defer(.retainedRoutes(required: 2, limit: 1)))
        #expect(plan.droppedRoutes.isEmpty && plan.parameterChanges.isEmpty)
        #expect(plan.retainedRoutes == [Fixture.routeA, Fixture.routeShared])
        #expect(tracker == before)

        // Once the first tail drains, unobserved, the same recall publishes and drops it.
        try Fixture.play(Fixture.off(48), on: &ledger, routing: routingShared)
        let published = try tracker.recall(to: routingB, recall: toChorus, ledger: ledger)
        #expect(published.decision == .publish)
        #expect(published.droppedRoutes == [Fixture.routeA])
        #expect(published.retainedRoutes == [Fixture.routeShared])
        #expect(published.parameterChanges.map(\.patch) == [
            Fixture.patchA, Fixture.patchA, Fixture.patchB, Fixture.patchB
        ])
        #expect(published.parameterChanges.map(\.isDeferred) == [true, true, false, false])
        #expect(published.parameterChanges.map(\.waitingOn).first == [Fixture.routeShared])
    }
}
