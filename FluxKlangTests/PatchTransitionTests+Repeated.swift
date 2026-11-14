import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Patch transitions: repeated recall and parameter changes", .productionAccessAudit)
struct PatchTransitionRepeatedTests {
    typealias Fixture = PatchTransitionFixture

    @Test
    func recallBackToARouteHoldingNotesMakesItCurrentAgainNotRetained() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        #expect(try tracker.recall(to: routingB, recall: nil, ledger: ledger).retainedRoutes == [Fixture.routeA])
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingB)

        let back = try tracker.recall(to: routingA, recall: nil, ledger: ledger)
        #expect(back.retainedRoutes == [Fixture.routeB])
        #expect(tracker.retainedRoutes == [Fixture.routeB])
        #expect(tracker.routing == routingA)

        let release = try Fixture.play(Fixture.off(48), on: &ledger, routing: routingA)
        #expect(release.map(\.route) == [Fixture.routeA])
        #expect(try tracker.observe(ledger).releasedRoutes.isEmpty)
        try Fixture.play(Fixture.off(60), on: &ledger, routing: routingA)
        let drained = try tracker.observe(ledger)
        #expect(drained.releasedRoutes == [Fixture.routeB] && drained.isRetired)
    }

    @Test
    func repeatedRecallsRetainEachRouteOnce() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        let routingC = try Fixture.routing(Fixture.routeC)
        var tracker = try Fixture.tracker(routingA, routes: 2)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), Fixture.on(50), Fixture.on(52), on: &ledger, routing: routingA)
        let first = try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        #expect(first.retainedRoutes == [Fixture.routeA])
        #expect(first.tailReservations.map(\.notes) == [3])
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingB)
        let second = try tracker.recall(to: routingC, recall: nil, ledger: ledger)
        #expect(second.decision == .publish)
        #expect(second.retainedRoutes == [Fixture.routeA, Fixture.routeB])
        #expect(second.tailReservations.map(\.notes) == [3, 1])
        let third = try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        #expect(third.retainedRoutes == [Fixture.routeA])
        #expect(third.droppedRoutes == [Fixture.routeC])
    }

    @Test
    func repeatingTheSameRecallRetainsNothing() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let plan = try tracker.recall(to: routingA, recall: Fixture.recall(Fixture.patchA), ledger: ledger)
        #expect(plan.retainedRoutes.isEmpty && plan.droppedRoutes.isEmpty && tracker.isRetired)
    }

    @Test
    func changesToAnotherPatchApplyAtOnceAndRetainedTailsKeepTheirValues() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let recall = Fixture.recall(
            Fixture.patchB, Fixture.change(Fixture.gain, -6, 0), Fixture.change(Fixture.mix, 1, 2)
        )
        let plan = try tracker.recall(to: Fixture.routing(Fixture.routeB), recall: recall, ledger: ledger)
        #expect(plan.parameterChanges.map(\.patch) == [Fixture.patchB, Fixture.patchB])
        #expect(plan.parameterChanges.allSatisfy { !$0.isDeferred })
        #expect(plan.tailReservations.map(\.target) == [Fixture.patchA])
        #expect(tracker.deferredChanges.isEmpty)
    }

    @Test
    func changesSharingATargetWithARetainedRouteWaitUntilItDrains() throws {
        let routingA = try Fixture.routing(Fixture.routeA, Fixture.routeA2)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let recall = Fixture.recall(Fixture.patchA, Fixture.change(Fixture.gain, -6, 0))
        let plan = try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: recall, ledger: ledger)
        #expect(plan.parameterChanges.map(\.waitingOn) == [[Fixture.routeA, Fixture.routeA2]])
        #expect(tracker.deferredChanges == plan.parameterChanges)

        _ = ledger.routeLost(Fixture.routeA)
        let partial = try tracker.observe(ledger)
        #expect(partial.readyChanges.isEmpty)
        #expect(tracker.deferredChanges.map(\.waitingOn) == [[Fixture.routeA2]])
        try Fixture.play(Fixture.off(48), on: &ledger, routing: tracker.routing)
        let drained = try tracker.observe(ledger)
        #expect(drained.readyChanges.map(\.change) == [Fixture.change(Fixture.gain, -6, 0)])
        #expect(drained.readyChanges.map(\.patch) == [Fixture.patchA])
        #expect(drained.isRetired)
    }

    /// A large multi-patch wait set stays patch-specific, and an unchanged observation updates no tracker state or
    /// readies changes when no retained route drains.
    @Test
    func indexedWaitsAndUnchangedObservationPreservePatchSpecificResultsAtScale() throws {
        let routesPerPatch = 32
        let changesPerPatch = 512
        let routesA = (0..<routesPerPatch).map { MIDIRouteID(UInt32(1_000 + $0)) }
        let routesB = (0..<routesPerPatch).map { MIDIRouteID(UInt32(2_000 + $0)) }
        let currentRouting = try Fixture.routing(Fixture.routeShared, Fixture.routeB)
        let previousRoutes = routesA + routesB
        let previousRules = try previousRoutes.map { route in
            try #require(MIDIRoutingRule(input: Fixture.keys, route: route))
        }
        let previousRouting = try #require(MIDIRouting(rules: previousRules))
        let bindings = routesA.map { ($0, Fixture.patchA) } + routesB.map { ($0, Fixture.patchB) } + [
            (Fixture.routeShared, Fixture.patchA), (Fixture.routeB, Fixture.patchB)
        ]
        let targets = try PatchRouteTargets.make(bindings)
        let budget = try Fixture.budget(routes: previousRoutes.count, tails: previousRoutes.count)
        let policy = PatchTransitionPolicy(targets: targets, budget: budget)
        var tracker = try PatchTransitionTracker(routing: previousRouting, policy: policy)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: previousRouting)

        func changes() throws -> [PatchParameterChange] {
            try (0..<changesPerPatch).map { index in
                Fixture.change(try ParameterID("par.\(100_000 + index)"), -12, -6)
            }
        }
        let recallA = PatchRecallPlan(
            patch: Fixture.patchA, from: nil, to: Fixture.verse, changes: try changes()
        )
        let recallB = PatchRecallPlan(
            patch: Fixture.patchB, from: nil, to: Fixture.verse, changes: try changes()
        )

        let first = try tracker.recall(to: currentRouting, recall: recallA, ledger: ledger)
        #expect(first.parameterChanges.count == changesPerPatch)
        #expect(first.parameterChanges.allSatisfy { $0.waitingOn == routesA })
        let second = try tracker.recall(to: currentRouting, recall: recallB, ledger: ledger)
        #expect(second.parameterChanges.count == 2 * changesPerPatch)
        #expect(second.parameterChanges.prefix(changesPerPatch).allSatisfy { $0.waitingOn == routesA })
        #expect(second.parameterChanges.suffix(changesPerPatch).allSatisfy { $0.waitingOn == routesB })

        let before = tracker
        let unchanged = try tracker.observe(ledger)
        #expect(unchanged.releasedRoutes.isEmpty && unchanged.readyChanges.isEmpty && !unchanged.isRetired)
        #expect(tracker == before)
    }

    @Test
    func recallingBackCancelsAStillDeferredChange() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let toChorus = try Fixture.planned(Fixture.patchA, from: Fixture.verse, to: Fixture.chorus)
        #expect(toChorus.changes == [Fixture.change(Fixture.gain, -6, 0), Fixture.change(Fixture.mix, 1, 2)])
        try tracker.recall(to: routingShared, recall: toChorus, ledger: ledger)
        #expect(tracker.deferredChanges.count == 2)
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingShared)

        // Chorus → bridge moves gain back to -6 dB and keeps mix: the deferred gain change cancels.
        let toBridge = try Fixture.planned(Fixture.patchA, from: Fixture.chorus, to: Fixture.bridge)
        #expect(toBridge.changes == [Fixture.change(Fixture.gain, 0, -6)])
        let back = try tracker.recall(to: routingA, recall: toBridge, ledger: ledger)
        #expect(back.retainedRoutes == [Fixture.routeShared])
        #expect(back.parameterChanges.map(\.change) == [Fixture.change(Fixture.mix, 1, 2)])
        #expect(back.parameterChanges.map(\.variation) == [Fixture.bridge])
        #expect(back.parameterChanges.map(\.waitingOn) == [[Fixture.routeShared]])
        #expect(tracker.deferredChanges == back.parameterChanges)
    }

    @Test
    func routingOnlyRecallReevaluatesDeferredChanges() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let recall = Fixture.recall(Fixture.patchA, Fixture.change(Fixture.gain, -6, 0))
        try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: recall, ledger: ledger)
        let back = try tracker.recall(to: routingA, recall: nil, ledger: ledger)
        #expect(back.retainedRoutes.isEmpty)
        #expect(back.parameterChanges.map(\.change) == [Fixture.change(Fixture.gain, -6, 0)])
        #expect(back.parameterChanges.allSatisfy { !$0.isDeferred })
        #expect(tracker.isRetired)
    }

    @Test
    func discontinuousRecallIsRefusedAndTheTrackerIsUnchanged() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let recall = Fixture.recall(Fixture.patchA, Fixture.change(Fixture.gain, -6, 0))
        try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: recall, ledger: ledger)
        let before = tracker
        let stale = Fixture.recall(
            Fixture.patchA, from: Fixture.verse, to: Fixture.chorus, Fixture.change(Fixture.gain, -3, 0)
        )
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingA, recall: stale, ledger: ledger)
        } == .invalidRecallPlan(.discontinuous(Fixture.gain)))
        #expect(tracker == before)
    }

    /// The deferred changes record the variation they lead to, so a recall from another variation is refused even
    /// when it changes none of the deferred parameters.
    @Test
    func recallNotStartingWhereDeferredChangesLeadIsRefusedWithoutSharedParameters() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let toChorus = Fixture.recall(
            Fixture.patchA, from: nil, to: Fixture.chorus, Fixture.change(Fixture.gain, -6, 0)
        )
        try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: toChorus, ledger: ledger)
        #expect(tracker.deferredChanges.map(\.variation) == [Fixture.chorus])
        let before = tracker
        let stale = Fixture.recall(Fixture.patchA, from: nil, to: Fixture.verse, Fixture.change(Fixture.mix, 1, 2))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingA, recall: stale, ledger: ledger)
        } == .invalidRecallPlan(.discontinuousVariation(Fixture.patchA, expected: Fixture.chorus)))
        #expect(tracker == before)

        let onward = Fixture.recall(
            Fixture.patchA, from: Fixture.chorus, to: Fixture.verse, Fixture.change(Fixture.mix, 1, 2)
        )
        let plan = try tracker.prepare(to: routingA, recall: onward, ledger: ledger)
        #expect(plan.parameterChanges.map(\.change) == [
            Fixture.change(Fixture.gain, -6, 0), Fixture.change(Fixture.mix, 1, 2)
        ])
        #expect(plan.parameterChanges.map(\.variation) == [Fixture.verse, Fixture.verse])
    }

    /// nil → verse defers gain -12 → -6 and verse → chorus moves it back, so the change cancels. The tracker still
    /// records chorus while the retained route plays the patch, so a stale verse → bridge recall is refused.
    @Test
    func staleRecallAfterEveryDeferredChangeCancelledIsRefused() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let toVerse = Fixture.recall(
            Fixture.patchA, from: nil, to: Fixture.verse, Fixture.change(Fixture.gain, -12, -6)
        )
        try tracker.recall(to: routingShared, recall: toVerse, ledger: ledger)
        let toChorus = Fixture.recall(
            Fixture.patchA, from: Fixture.verse, to: Fixture.chorus, Fixture.change(Fixture.gain, -6, -12)
        )
        let cancelled = try tracker.recall(to: routingShared, recall: toChorus, ledger: ledger)
        #expect(cancelled.parameterChanges.isEmpty && tracker.deferredChanges.isEmpty)
        #expect(tracker.retainedRoutes == [Fixture.routeA])
        #expect(tracker.deferredVariations == [Fixture.patchA: Fixture.chorus])

        let before = tracker
        let stale = Fixture.recall(
            Fixture.patchA, from: Fixture.verse, to: Fixture.bridge, Fixture.change(Fixture.mix, 1, 2)
        )
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingShared, recall: stale, ledger: ledger)
        } == .invalidRecallPlan(.discontinuousVariation(Fixture.patchA, expected: Fixture.chorus)))
        #expect(tracker == before)

        let onward = Fixture.recall(
            Fixture.patchA, from: Fixture.chorus, to: Fixture.bridge, Fixture.change(Fixture.mix, 1, 2)
        )
        let plan = try tracker.recall(to: routingShared, recall: onward, ledger: ledger)
        #expect(plan.parameterChanges.map(\.change) == [Fixture.change(Fixture.mix, 1, 2)])
        #expect(plan.parameterChanges.map(\.variation) == [Fixture.bridge])
        #expect(plan.parameterChanges.map(\.waitingOn) == [[Fixture.routeA]])
        #expect(tracker.deferredVariations == [Fixture.patchA: Fixture.bridge])
    }

    /// A recall back to the baseline is recorded as the baseline, not as no record.
    @Test
    func staleRecallAfterCancellingBackToTheBaselineIsRefused() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        try tracker.recall(
            to: routingShared, recall: Fixture.planned(Fixture.patchA, from: nil, to: Fixture.verse), ledger: ledger
        )
        try tracker.recall(
            to: routingShared, recall: Fixture.planned(Fixture.patchA, from: Fixture.verse, to: nil), ledger: ledger
        )
        #expect(tracker.deferredChanges.isEmpty)
        #expect(tracker.deferredVariations == [Fixture.patchA: PatchVariationID?.none])
        let before = tracker
        let stale = try Fixture.planned(Fixture.patchA, from: Fixture.verse, to: Fixture.chorus)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingShared, recall: stale, ledger: ledger)
        } == .invalidRecallPlan(.discontinuousVariation(Fixture.patchA, expected: nil)))
        #expect(tracker == before)
    }

    /// The record lives only while a retained route plays the patch: once the last one drains, or becomes current
    /// again, the next recall may start from any variation.
    @Test
    func variationRecordClearsWhenThePatchHasNoRetainedRouteLeft() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let toChorus = Fixture.recall(
            Fixture.patchA, from: nil, to: Fixture.chorus, Fixture.change(Fixture.gain, -12, 0)
        )
        let elsewhere = Fixture.recall(
            Fixture.patchA, from: Fixture.bridge, to: Fixture.verse, Fixture.change(Fixture.mix, 2, 1)
        )

        var drained = try Fixture.tracker(routingA)
        try drained.recall(to: routingShared, recall: toChorus, ledger: ledger)
        #expect(drained.deferredVariations == [Fixture.patchA: Fixture.chorus])
        var released = ledger
        try Fixture.play(Fixture.off(48), on: &released, routing: routingShared)
        #expect(try drained.observe(released).isRetired)
        #expect(drained.deferredVariations.isEmpty)
        let afterDrain = try drained.recall(to: routingShared, recall: elsewhere, ledger: released)
        #expect(afterDrain.parameterChanges.map(\.isDeferred) == [false])
        #expect(drained.deferredVariations.isEmpty)

        var current = try Fixture.tracker(routingA)
        try current.recall(to: routingShared, recall: toChorus, ledger: ledger)
        try current.recall(to: routingA, recall: nil, ledger: ledger)
        #expect(current.retainedRoutes.isEmpty && current.deferredVariations.isEmpty)
        #expect(try current.prepare(to: routingA, recall: elsewhere, ledger: ledger).decision == .publish)
    }

    @Test(arguments: [
        (PatchTransitionFixture.recall(PatchTransitionFixture.patchA, from: nil, to: nil,
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, -6, 0)),
         PatchRecallDefect.changesWithoutVariationChange),
        (PatchTransitionFixture.recall(PatchTransitionFixture.patchA,
                                       PatchTransitionFixture.change(PatchTransitionFixture.mix, -6, 0),
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, -6, 0)),
         .unsorted(PatchTransitionFixture.gain)),
        (PatchTransitionFixture.recall(PatchTransitionFixture.patchA,
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, -6, 0),
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, 0, 1)),
         .unsorted(PatchTransitionFixture.gain)),
        (PatchTransitionFixture.recall(PatchTransitionFixture.patchA,
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, -6, -6)),
         .unchanged(PatchTransitionFixture.gain)),
        (PatchTransitionFixture.recall(PatchTransitionFixture.patchA,
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, .nan, 0)),
         .nonFinite(PatchTransitionFixture.gain)),
        (PatchTransitionFixture.recall(PatchTransitionFixture.patchA,
                                       PatchTransitionFixture.change(PatchTransitionFixture.gain, 0, .infinity)),
         .nonFinite(PatchTransitionFixture.gain)),
        (PatchRecallPlan(patch: PatchTransitionFixture.patchA, from: nil, to: PatchTransitionFixture.verse, changes: [
            PatchParameterChange(
                parameter: PatchTransitionFixture.gain, from: ParameterValue(value: 0, unit: .decibels),
                to: ParameterValue(value: 0, unit: .normalized)
            )
        ]), .unitMismatch(PatchTransitionFixture.gain))
    ])
    func invalidRecallPlanIsRefusedBeforePressureAndLeavesTheTrackerUnchanged(
        recall: PatchRecallPlan, defect: PatchRecallDefect
    ) throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        var tracker = try Fixture.tracker(routingA, routes: 0, tails: 0)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        let before = tracker
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingShared, recall: recall, ledger: ledger)
        } == .invalidRecallPlan(defect))
        #expect(tracker == before)
    }

    @Test
    func sameVariationWithoutChangesIsAccepted() throws {
        let tracker = try Fixture.tracker(Fixture.routing(Fixture.routeA))
        let plan = try tracker.prepare(
            to: Fixture.routing(Fixture.routeA), recall: Fixture.recall(Fixture.patchA, from: nil, to: nil),
            ledger: MIDINoteLedger()
        )
        #expect(plan.decision == .publish && plan.parameterChanges.isEmpty)
    }

    @Test
    func plannedChangesAreSortedByPatchThenParameter() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let routingNext = try Fixture.routing(Fixture.routeShared, Fixture.routeB)
        try tracker.recall(
            to: routingNext, recall: Fixture.recall(Fixture.patchA, Fixture.change(Fixture.mix, -6, 0)), ledger: ledger
        )
        let plan = try tracker.prepare(
            to: routingNext,
            recall: Fixture.recall(
                Fixture.patchB, Fixture.change(Fixture.gain, -6, 0), Fixture.change(Fixture.mix, -6, 0)
            ),
            ledger: ledger
        )
        #expect(plan.parameterChanges.map(\.patch) == [Fixture.patchA, Fixture.patchB, Fixture.patchB])
        #expect(plan.parameterChanges.map(\.change.parameter) == [Fixture.mix, Fixture.gain, Fixture.mix])
        #expect(plan.parameterChanges.map(\.isDeferred) == [true, false, false])
    }
}
