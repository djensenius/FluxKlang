import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Patch transitions: repeated recall and parameter changes")
struct PatchTransitionRepeatedTests {
    typealias Fixture = PatchTransitionFixture

    /// `count` ascending gain changes of `patch`, each -6 → 0 dB.
    private static func manyChanges(_ count: Int) throws -> [PatchParameterChange] {
        try (0..<count).map { index in
            let digits = String(index)
            let parameter = try ParameterID("par.p" + String(repeating: "0", count: 5 - digits.count) + digits)
            return Fixture.change(parameter, -6, 0)
        }
    }

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

    @Test
    func recallingBackCancelsAStillDeferredChange() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingShared = try Fixture.routing(Fixture.routeShared)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let toChorus = Fixture.recall(
            Fixture.patchA, from: Fixture.verse, to: Fixture.chorus,
            Fixture.change(Fixture.gain, -6, 0), Fixture.change(Fixture.mix, 1, 2)
        )
        try tracker.recall(to: routingShared, recall: toChorus, ledger: ledger)
        #expect(tracker.deferredChanges.count == 2)
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingShared)

        let toVerse = Fixture.recall(
            Fixture.patchA, from: Fixture.chorus, to: Fixture.verse, Fixture.change(Fixture.gain, 0, -6)
        )
        let back = try tracker.recall(to: routingA, recall: toVerse, ledger: ledger)
        #expect(back.retainedRoutes == [Fixture.routeShared])
        #expect(back.parameterChanges.map(\.change) == [Fixture.change(Fixture.mix, 1, 2)])
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
        let stale = Fixture.recall(Fixture.patchA, Fixture.change(Fixture.gain, -3, 0))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingA, recall: stale, ledger: ledger)
        } == .invalidRecallPlan(.discontinuous(Fixture.gain)))
        #expect(tracker == before)
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
    func recallChangeCountIsBounded() throws {
        let maximum = PatchTransitionPlan.maximumParameterChanges
        #expect(maximum == 4096)
        let changes = try Self.manyChanges(maximum + 1)
        let tracker = try Fixture.tracker(Fixture.routing(Fixture.routeA))
        let full = PatchRecallPlan(
            patch: Fixture.patchA, from: nil, to: Fixture.verse, changes: Array(changes.prefix(maximum))
        )
        let plan = try tracker.prepare(to: tracker.routing, recall: full, ledger: MIDINoteLedger())
        #expect(plan.parameterChanges.count == maximum)
        let over = PatchRecallPlan(patch: Fixture.patchA, from: nil, to: Fixture.verse, changes: changes)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.prepare(to: tracker.routing, recall: over, ledger: MIDINoteLedger())
        } == .tooManyParameterChanges(count: maximum + 1, maximum: maximum))
    }

    @Test
    func mergedChangeCountIsBounded() throws {
        let maximum = PatchTransitionPlan.maximumParameterChanges
        let routingA = try Fixture.routing(Fixture.routeA, Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        let many = PatchRecallPlan(
            patch: Fixture.patchA, from: nil, to: Fixture.verse, changes: try Self.manyChanges(maximum - 1)
        )
        let routingNext = try Fixture.routing(Fixture.routeShared, Fixture.routeC)
        try tracker.recall(to: routingNext, recall: many, ledger: ledger)
        #expect(tracker.deferredChanges.count == maximum - 1)

        let one = Fixture.recall(Fixture.patchC, Fixture.change(Fixture.gain, -6, 0))
        #expect(try tracker.prepare(to: routingNext, recall: one, ledger: ledger).parameterChanges.count == maximum)
        let two = Fixture.recall(
            Fixture.patchC, Fixture.change(Fixture.gain, -6, 0), Fixture.change(Fixture.mix, -6, 0)
        )
        let before = tracker
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingNext, recall: two, ledger: ledger)
        } == .tooManyParameterChanges(count: maximum + 1, maximum: maximum))
        #expect(tracker == before)

        // The recall itself is bounded before merging, even when most of it cancels deferred changes.
        let back = try Self.manyChanges(maximum + 1).map {
            PatchParameterChange(parameter: $0.parameter, from: $0.to, to: $0.from)
        }
        let cancelling = PatchRecallPlan(patch: Fixture.patchA, from: nil, to: Fixture.verse, changes: back)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingNext, recall: cancelling, ledger: ledger)
        } == .tooManyParameterChanges(count: maximum + 1, maximum: maximum))
        #expect(tracker == before)
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
