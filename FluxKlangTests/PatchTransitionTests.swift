import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixture of the patch transition suites. Routes 101, 102 and 301 play patch A, 201 patch B and 401 patch C.
enum PatchTransitionFixture {
    static let keys = MIDIInputID(1)
    static let routeA = MIDIRouteID(101)
    static let routeA2 = MIDIRouteID(102)
    static let routeB = MIDIRouteID(201)
    static let routeShared = MIDIRouteID(301)
    static let routeC = MIDIRouteID(401)
    static let unbound = MIDIRouteID(999)
    static let patchA = PatchID(validated: "patch.a")
    static let patchB = PatchID(validated: "patch.b")
    static let patchC = PatchID(validated: "patch.c")
    static let verse = PatchVariationID(validated: "var.verse")
    static let chorus = PatchVariationID(validated: "var.chorus")
    static let gain = ParameterID(validated: "par.gain")
    static let mix = ParameterID(validated: "par.mix")

    static func targets() throws -> PatchRouteTargets {
        try PatchRouteTargets.make([
            (routeA, patchA), (routeA2, patchA), (routeB, patchB), (routeShared, patchA), (routeC, patchC)
        ])
    }

    static func budget(routes: Int = 8, tails: Int = 64) throws -> PatchTransitionBudget {
        try PatchTransitionBudget.make(retainedRoutes: routes, tailSlots: tails)
    }

    static func routing(_ routes: MIDIRouteID...) throws -> MIDIRouting {
        let rules = try routes.map { route in try #require(MIDIRoutingRule(input: keys, route: route)) }
        return try #require(MIDIRouting(rules: rules))
    }

    static func tracker(
        _ routing: MIDIRouting, routes: Int = 8, tails: Int = 64
    ) throws -> PatchTransitionTracker {
        try PatchTransitionTracker(routing: routing, policy: policy(routes: routes, tails: tails))
    }

    static func policy(routes: Int = 8, tails: Int = 64) throws -> PatchTransitionPolicy {
        try PatchTransitionPolicy(targets: targets(), budget: budget(routes: routes, tails: tails))
    }

    static func change(_ parameter: ParameterID, _ from: Double, _ to: Double) -> PatchParameterChange {
        PatchParameterChange(
            parameter: parameter, from: ParameterValue(value: from, unit: .decibels),
            to: ParameterValue(value: to, unit: .decibels)
        )
    }

    static func recall(
        _ patch: PatchID, from: PatchVariationID? = nil, to: PatchVariationID? = verse,
        _ changes: PatchParameterChange...
    ) -> PatchRecallPlan {
        PatchRecallPlan(patch: patch, from: from, to: to, changes: changes)
    }

    static func on(_ note: UInt8) -> MIDIPerformanceEvent {
        MIDIPerformanceEvent(input: keys, message: .noteOn(channel: 1, note: note, velocity: 100))
    }

    static func off(_ note: UInt8) -> MIDIPerformanceEvent {
        MIDIPerformanceEvent(input: keys, message: .noteOff(channel: 1, note: note, velocity: 64))
    }

    static func pedal(_ pedal: MIDIPedal, down: Bool) -> MIDIPerformanceEvent {
        MIDIPerformanceEvent(
            input: keys, message: .controlChange(channel: 1, controller: pedal.rawValue, value: down ? 127 : 0)
        )
    }

    /// Routes every event in order and returns everything sent.
    @discardableResult
    static func play(
        _ events: MIDIPerformanceEvent..., on ledger: inout MIDINoteLedger, routing: MIDIRouting
    ) throws -> [MIDIRoutedOutput] {
        var outputs: [MIDIRoutedOutput] = []
        for event in events {
            try ledger.route(event, routing: routing, into: &outputs)
        }
        return outputs
    }

    /// Calls `body` and returns its typed refusal, or nil when it succeeds.
    static func refusal<T>(_ body: () throws(PatchTransitionRefusal) -> T) -> PatchTransitionRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }
}

@Suite("Patch transitions")
struct PatchTransitionTests {
    typealias Fixture = PatchTransitionFixture

    @Test
    func droneHeldAcrossRecallKeepsItsOldRouteUntilItsNoteOff() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)

        let plan = try tracker.recall(to: routingB, recall: Fixture.recall(Fixture.patchB), ledger: ledger)
        #expect(plan.decision == .publish)
        #expect(plan.retainedRoutes == [Fixture.routeA])
        #expect(plan.droppedRoutes.isEmpty)
        #expect(plan.tailReservations.map(\.slots) == [1])
        #expect(plan.tailReservations.map(\.target) == [Fixture.patchA])
        #expect(tracker.routing == routingB)

        try Fixture.play(Fixture.on(60), Fixture.off(60), on: &ledger, routing: routingB)
        let held = try tracker.observe(ledger)
        #expect(held.releasedRoutes.isEmpty && !held.isRetired)
        #expect(tracker.retainedRoutes == [Fixture.routeA])

        let release = try Fixture.play(Fixture.off(48), on: &ledger, routing: routingB)
        #expect(release == [
            MIDIRoutedOutput(route: Fixture.routeA, message: .noteOff(channel: 1, note: 48, velocity: 64))
        ])
        let drained = try tracker.observe(ledger)
        #expect(drained.releasedRoutes == [Fixture.routeA])
        #expect(drained.isRetired && tracker.isRetired)
        #expect(tracker.retainedRoutes.isEmpty)
    }

    @Test
    func silentOldRouteIsDroppedNotRetained() throws {
        var tracker = try Fixture.tracker(Fixture.routing(Fixture.routeA, Fixture.routeA2))
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), Fixture.off(60), on: &ledger, routing: tracker.routing)
        let plan = try tracker.recall(
            to: Fixture.routing(Fixture.routeB), recall: Fixture.recall(Fixture.patchB), ledger: ledger
        )
        #expect(plan.retainedRoutes.isEmpty && plan.tailReservations.isEmpty)
        #expect(plan.droppedRoutes == [Fixture.routeA, Fixture.routeA2])
        #expect(tracker.isRetired)
    }

    @Test
    func soundingRouteKeptInTheNewRoutingIsCurrentNotRetained() throws {
        var tracker = try Fixture.tracker(Fixture.routing(Fixture.routeA, Fixture.routeA2))
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: tracker.routing)
        let plan = try tracker.recall(
            to: Fixture.routing(Fixture.routeA), recall: Fixture.recall(Fixture.patchA), ledger: ledger
        )
        #expect(plan.retainedRoutes == [Fixture.routeA2])
        #expect(plan.droppedRoutes.isEmpty)
    }

    @Test
    func pressureAtTheRouteBudgetPublishesAndOneMoreDefersWithoutChange() throws {
        let routingOld = try Fixture.routing(Fixture.routeA, Fixture.routeA2)
        let routingB = try Fixture.routing(Fixture.routeB)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingOld)

        var fits = try Fixture.tracker(routingOld, routes: 2)
        #expect(try fits.recall(to: routingB, recall: nil, ledger: ledger).decision == .publish)

        var tight = try Fixture.tracker(routingOld, routes: 1)
        let before = tight
        let plan = try tight.recall(to: routingB, recall: nil, ledger: ledger)
        #expect(plan.decision == .defer(.retainedRoutes(required: 2, limit: 1)))
        #expect(plan.retainedRoutes == [Fixture.routeA, Fixture.routeA2])
        #expect(tight == before)
        #expect(ledger.notes.count == 2)

        try Fixture.play(Fixture.off(60), on: &ledger, routing: routingOld)
        #expect(try tight.recall(to: routingB, recall: nil, ledger: ledger).decision == .publish)
    }

    @Test
    func pressureAtTheTailBudgetPublishesAndOneMoreDefers() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var ledger = MIDINoteLedger()
        try Fixture.play(
            Fixture.on(60), Fixture.on(62), Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingA
        )

        var fits = try Fixture.tracker(routingA, tails: 3)
        #expect(try fits.recall(to: routingB, recall: nil, ledger: ledger).decision == .publish)
        var tight = try Fixture.tracker(routingA, tails: 2)
        let before = tight
        let plan = try tight.recall(to: routingB, recall: nil, ledger: ledger)
        #expect(plan.decision == .defer(.tailSlots(required: 3, limit: 2)))
        #expect(tight == before)
    }

    @Test
    func routePressureIsReportedBeforeTailPressure() throws {
        let routingOld = try Fixture.routing(Fixture.routeA, Fixture.routeA2)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingOld)
        let tracker = try Fixture.tracker(routingOld, routes: 1, tails: 1)
        let plan = try tracker.prepare(to: Fixture.routing(Fixture.routeB), recall: nil, ledger: ledger)
        #expect(plan.decision == .defer(.retainedRoutes(required: 2, limit: 1)))
    }

    @Test
    func budgetBoundsAreInclusive() throws {
        let upper = PatchTransitionBudget.retainedRouteBounds.upperBound
        #expect(upper == 5120)
        #expect(try PatchTransitionBudget.make(retainedRoutes: 0, tailSlots: 0).tailSlots == 0)
        let top = try PatchTransitionBudget.make(retainedRoutes: upper, tailSlots: upper)
        #expect(top.retainedRoutes == upper && top.tailSlots == upper)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionBudget.make(retainedRoutes: -1, tailSlots: 0)
        } == .invalidBudget(retainedRoutes: -1, tailSlots: 0))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionBudget.make(retainedRoutes: 0, tailSlots: upper + 1)
        } == .invalidBudget(retainedRoutes: 0, tailSlots: upper + 1))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionBudget.make(retainedRoutes: upper + 1, tailSlots: 0)
        } == .invalidBudget(retainedRoutes: upper + 1, tailSlots: 0))
    }

    @Test
    func targetBindingsAreBoundedAndUnique() throws {
        let maximum = PatchRouteTargets.maximumBindings
        let pairs = (0..<UInt32(maximum + 1)).map { (route: MIDIRouteID($0), patch: Fixture.patchA) }
        let full = try PatchRouteTargets.make(Array(pairs.prefix(maximum)))
        #expect(full.routes.count == maximum)
        #expect(full.target(of: MIDIRouteID(UInt32(maximum - 1))) == Fixture.patchA)
        #expect(full.target(of: MIDIRouteID(UInt32(maximum))) == nil)
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in try PatchRouteTargets.make(pairs) }
            == .tooManyBindings(count: maximum + 1, maximum: maximum))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchRouteTargets.make([(Fixture.routeB, Fixture.patchB), (Fixture.routeA, Fixture.patchA),
                                        (Fixture.routeB, Fixture.patchB)])
        } == .duplicateBinding(Fixture.routeB))
    }

    @Test
    func unboundRoutesAreRefusedLowestFirst() throws {
        let policy = try Fixture.policy()
        let routingA = try Fixture.routing(Fixture.routeA)
        let stray = try Fixture.routing(Fixture.unbound, MIDIRouteID(998))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionTracker(routing: stray, policy: policy)
        } == .unboundRoute(MIDIRouteID(998)))

        let tracker = try Fixture.tracker(routingA)
        let ledger = MIDINoteLedger()
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.prepare(to: stray, recall: nil, ledger: ledger)
        } == .unboundRoute(MIDIRouteID(998)))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionPlanner.plan(
                ledger: ledger, from: stray, to: routingA, recall: nil, policy: policy
            )
        } == .unboundRoute(MIDIRouteID(998)))

        var sounding = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &sounding, routing: try Fixture.routing(Fixture.unbound))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try PatchTransitionPlanner.plan(
                ledger: sounding, from: routingA, to: routingA, recall: nil, policy: policy
            )
        } == .unboundRoute(Fixture.unbound))
    }

    @Test
    func recallOfAPatchTheNewRoutingDoesNotPlayIsRefused() throws {
        var tracker = try Fixture.tracker(Fixture.routing(Fixture.routeA))
        let routingB = try Fixture.routing(Fixture.routeB)
        let before = tracker
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingB, recall: Fixture.recall(Fixture.patchC), ledger: MIDINoteLedger())
        } == .recallPatchNotRouted(Fixture.patchC))
        #expect(tracker == before)
    }

    @Test
    func ledgerSoundingOnAnUntrackedRouteIsRefused() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: try Fixture.routing(Fixture.routeC))
        let before = tracker
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingA, recall: nil, ledger: ledger)
        } == .untrackedRoute(Fixture.routeC))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in try tracker.observe(ledger) }
            == .untrackedRoute(Fixture.routeC))
        #expect(tracker == before)
        // The static planner has no tracking; the route is simply retained.
        let plan = try PatchTransitionPlanner.plan(
            ledger: ledger, from: routingA, to: routingA, recall: nil, policy: Fixture.policy()
        )
        #expect(plan.retainedRoutes == [Fixture.routeC])
    }

    @Test
    func refusalTakesPrecedenceOverPressure() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingA)
        let tracker = try Fixture.tracker(routingA, routes: 0, tails: 0)
        let routingB = try Fixture.routing(Fixture.routeB)
        let stray = try Fixture.routing(Fixture.unbound)
        #expect(try tracker.prepare(to: routingB, recall: nil, ledger: ledger).decision
            == .defer(.retainedRoutes(required: 1, limit: 0)))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.prepare(to: stray, recall: nil, ledger: ledger)
        } == .unboundRoute(Fixture.unbound))
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.prepare(to: routingB, recall: Fixture.recall(Fixture.patchC), ledger: ledger)
        } == .recallPatchNotRouted(Fixture.patchC))
    }

    @Test
    func staticPlannerMatchesTrackerPrepare() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingA)
        let recall = Fixture.recall(Fixture.patchB, Fixture.change(Fixture.gain, -6, 0))
        let tracked = try Fixture.tracker(routingA).prepare(to: routingB, recall: recall, ledger: ledger)
        let planned = try PatchTransitionPlanner.plan(
            ledger: ledger, from: routingA, to: routingB, recall: recall, policy: Fixture.policy()
        )
        #expect(tracked == planned)
        #expect(planned.previousRouting == routingA && planned.routing == routingB)
    }

    @Test
    func noTransitionValueCarriesATimerOrDuration() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingA)
        var tracker = try Fixture.tracker(routingA)
        let recall = Fixture.recall(Fixture.patchA, Fixture.change(Fixture.gain, -6, 0))
        let plan = try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: recall, ledger: ledger)
        let drain = try tracker.observe(ledger)
        let values: [Any] = [plan, tracker, try Fixture.policy(), try Fixture.budget(), try Fixture.targets(), drain]
            + plan.tailReservations + plan.parameterChanges
        let banned = ["time", "duration", "deadline", "timeout", "expir", "seconds", "cutoff"]
        for value in values {
            for label in Mirror(reflecting: value).children.compactMap(\.label) {
                #expect(!banned.contains { label.lowercased().contains($0) }, "\(label)")
            }
        }
        #expect(PatchTransitionPlan.parameterPolicy == .newRoutesOnlyDeferWhileTargetRetained)
    }
}
