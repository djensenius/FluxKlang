import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Seeded SplitMix64, private to this file.
private struct TransitionSeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((mixed ^ (mixed >> 31)) % UInt64(bound))
    }
}

#if os(macOS)
@Suite("Patch transitions: sustain, tails and loss", .productionAccessAudit)
#else
@Suite("Patch transitions: sustain, tails and loss")
#endif
struct PatchTransitionSustainTests {
    typealias Fixture = PatchTransitionFixture

    @Test
    func sustainPedalHoldingReleasedNotesKeepsRouteUntilPedalUp() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingA)
        let plan = try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        #expect(plan.tailReservations.map(\.notes) == [1])
        #expect(plan.tailReservations.map(\.pedalHolds) == [1])

        try Fixture.play(Fixture.off(60), on: &ledger, routing: routingB)
        #expect(try tracker.observe(ledger).releasedRoutes.isEmpty)
        #expect(tracker.retainedRoutes == [Fixture.routeA])
        #expect(tracker.tailReservations.map(\.slots) == [2])

        let pedalUp = try Fixture.play(Fixture.pedal(.sustain, down: false), on: &ledger, routing: routingB)
        #expect(pedalUp.contains(MIDIRoutedOutput(
            route: Fixture.routeA, message: .controlChange(channel: 1, controller: 64, value: 0)
        )))
        let drained = try tracker.observe(ledger)
        #expect(drained.releasedRoutes == [Fixture.routeA] && drained.isRetired)
    }

    @Test
    func sostenutoHeldNoteKeepsRouteUntilPedalUp() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), Fixture.pedal(.sostenuto, down: true), on: &ledger, routing: routingA)
        try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        try Fixture.play(Fixture.off(60), on: &ledger, routing: routingB)
        #expect(try tracker.observe(ledger).releasedRoutes.isEmpty)
        try Fixture.play(Fixture.pedal(.sostenuto, down: false), on: &ledger, routing: routingB)
        #expect(try tracker.observe(ledger).releasedRoutes == [Fixture.routeA])
    }

    @Test
    func pedalHoldAloneRetainsTheRoute() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingA)
        let plan = try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        #expect(plan.retainedRoutes == [Fixture.routeA])
        #expect(plan.tailReservations.map(\.notes) == [0])
        #expect(plan.tailReservations.map(\.pedalHolds) == [1])
        try Fixture.play(Fixture.on(60), Fixture.off(60), on: &ledger, routing: routingB)
        #expect(try tracker.observe(ledger).releasedRoutes.isEmpty)
        #expect(tracker.tailReservations.map(\.slots) == [1])
        try Fixture.play(Fixture.pedal(.sustain, down: false), on: &ledger, routing: routingB)
        #expect(try tracker.observe(ledger).releasedRoutes == [Fixture.routeA])
    }

    @Test
    func tailSlotsFollowThePedalReachingARetainedRouteWithoutCuttingIt() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA, tails: 1)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        // A pedal-down reaches every route still holding a key, so the retained route gains a hold.
        try Fixture.play(Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingB)
        let drain = try tracker.observe(ledger)
        #expect(drain.releasedRoutes.isEmpty)
        #expect(tracker.tailReservations.map(\.slots) == [2])
        #expect(tracker.tailReservations.map(\.pedalHolds) == [1])
    }

    @Test
    func releaseMarkersOwnNoRouteAndRetainNothing() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        let routingB = try Fixture.routing(Fixture.routeB)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingA)
        try tracker.recall(to: routingB, recall: nil, ledger: ledger)
        try Fixture.play(Fixture.on(60), on: &ledger, routing: routingB)
        _ = ledger.routeLost(Fixture.routeA)
        #expect(ledger.releaseMarkers.count == 1)
        let drain = try tracker.observe(ledger)
        #expect(drain.releasedRoutes == [Fixture.routeA] && drain.isRetired)
        let plan = try tracker.prepare(to: Fixture.routing(Fixture.routeC), recall: nil, ledger: ledger)
        #expect(plan.retainedRoutes == [Fixture.routeB])
        #expect(plan.tailReservations.map(\.slots) == [1])
    }

    @Test
    func panicDropsRetentionAtOnceAndReadiesDeferredChanges() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), Fixture.pedal(.sustain, down: true), on: &ledger, routing: routingA)
        let recall = Fixture.recall(Fixture.patchA, Fixture.change(Fixture.gain, -6, 0))
        try tracker.recall(to: Fixture.routing(Fixture.routeShared), recall: recall, ledger: ledger)
        #expect(tracker.deferredChanges.map(\.waitingOn) == [[Fixture.routeA]])
        _ = ledger.panic()
        let drain = try tracker.observe(ledger)
        #expect(drain.releasedRoutes == [Fixture.routeA])
        #expect(drain.readyChanges.map(\.change) == [Fixture.change(Fixture.gain, -6, 0)])
        #expect(drain.readyChanges.allSatisfy { !$0.isDeferred })
        #expect(drain.isRetired && tracker.deferredChanges.isEmpty)
    }

    @Test
    func routeLossDropsOnlyThatRoute() throws {
        let routingOld = try Fixture.routing(Fixture.routeA, Fixture.routeA2)
        var tracker = try Fixture.tracker(routingOld)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingOld)
        try tracker.recall(to: Fixture.routing(Fixture.routeB), recall: nil, ledger: ledger)
        _ = ledger.routeLost(Fixture.routeA2)
        let drain = try tracker.observe(ledger)
        #expect(drain.releasedRoutes == [Fixture.routeA2] && !drain.isRetired)
        #expect(tracker.retainedRoutes == [Fixture.routeA])
        _ = ledger.panic(.route(Fixture.routeA))
        #expect(try tracker.observe(ledger).releasedRoutes == [Fixture.routeA])
    }

    @Test
    func observingAnUnchangedLedgerReleasesNothing() throws {
        let routingA = try Fixture.routing(Fixture.routeA)
        var tracker = try Fixture.tracker(routingA)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingA)
        try tracker.recall(to: Fixture.routing(Fixture.routeB), recall: nil, ledger: ledger)
        let before = tracker
        let drain = try tracker.observe(ledger)
        #expect(drain.releasedRoutes.isEmpty && drain.readyChanges.isEmpty && !drain.isRetired)
        #expect(tracker == before)
    }

    /// No intentional gap: across seeded playing with recalls (half of them recalling a variation of a patch the next
    /// routing plays), panics, route loss and recalls before observing, no route a note or pedal sounds on is ever
    /// released or dropped while it sounds, every sounding route is current or retained, and every route the tracker
    /// stops tracking is reported exactly once.
    @Test(arguments: [(UInt64(1), 8), (UInt64(7), 8), (UInt64(42), 1), (UInt64(2026), 2)])
    func continuousPlayingAcrossRecallsLeavesNoGap(seed: UInt64, budgetRoutes: Int) throws {
        var run = try SeededTransitionRun(seed: seed, budgetRoutes: budgetRoutes)
        for _ in 0..<600 {
            try run.step()
        }
        #expect(run.published > 0 && run.recalledVariations > 0 && run.losses > 0 && run.skippedObserves > 0)
        if budgetRoutes == 1 {
            #expect(run.deferred > 0)
        } else {
            #expect(run.droppedTails > 0 && run.deferringRecalls > 0)
        }
    }
}

/// One seeded playing session of `continuousPlayingAcrossRecallsLeavesNoGap`, checking its invariants every step.
private struct SeededTransitionRun {
    typealias Fixture = PatchTransitionFixture
    static let variations: [PatchVariationID?] = [nil, Fixture.verse, Fixture.chorus, Fixture.bridge]
    static let routes = [Fixture.routeA, Fixture.routeA2, Fixture.routeB, Fixture.routeShared, Fixture.routeC]

    let routings: [MIDIRouting]
    let targets: PatchRouteTargets
    var generator: TransitionSeededGenerator
    var tracker: PatchTransitionTracker
    var ledger = MIDINoteLedger()
    /// The variation each patch's last published recall led to; absent means the baseline.
    var variation: [PatchID: PatchVariationID] = [:]
    var published = 0
    var deferred = 0
    var recalledVariations = 0
    var losses = 0
    var skippedObserves = 0
    /// Published recalls that dropped a route retained before them (drained without an observe in between).
    var droppedTails = 0
    /// Published recalls leaving deferred changes.
    var deferringRecalls = 0

    init(seed: UInt64, budgetRoutes: Int) throws {
        routings = try [
            Fixture.routing(Fixture.routeA), Fixture.routing(Fixture.routeB), Fixture.routing(Fixture.routeShared),
            Fixture.routing(Fixture.routeA, Fixture.routeC), Fixture.routing(Fixture.routeA2, Fixture.routeB)
        ]
        targets = try Fixture.targets()
        generator = TransitionSeededGenerator(seed: seed)
        tracker = try Fixture.tracker(routings[0], routes: budgetRoutes)
    }

    static func sounding(_ ledger: MIDINoteLedger) -> Set<MIDIRouteID> {
        Set(ledger.notes.map(\.route)).union(ledger.pedalHolds.map(\.route))
    }

    mutating func step() throws {
        let note = UInt8(60 + generator.next(6))
        switch generator.next(11) {
        case 0...2: play(Fixture.on(note))
        case 3...5: play(Fixture.off(note))
        case 6:
            let pedal = generator.next(2) == 0 ? MIDIPedal.sustain : .sostenuto
            play(Fixture.pedal(pedal, down: generator.next(2) == 0))
        case 7: lose()
        default: try recall()
        }
        // Sometimes the next event, or the next recall, comes before the tracker sees this snapshot.
        if generator.next(4) == 0 {
            skippedObserves += 1
        } else {
            try observe()
        }
        checkInvariants()
    }

    mutating func play(_ event: MIDIPerformanceEvent) {
        _ = try? Fixture.play(event, on: &ledger, routing: tracker.routing)
    }

    mutating func lose() {
        losses += 1
        let route = Self.routes[generator.next(Self.routes.count)]
        switch generator.next(4) {
        case 0: _ = ledger.panic()
        case 1: _ = ledger.panic(.route(route))
        default: _ = ledger.routeLost(route)
        }
    }

    mutating func recall() throws {
        let next = routings[generator.next(routings.count)]
        let recall = try nextRecall(playedBy: next)
        let before = tracker
        let plan = try tracker.recall(to: next, recall: recall, ledger: ledger)
        #expect(Self.sounding(ledger).isDisjoint(with: plan.droppedRoutes))
        guard plan.decision == .publish else {
            deferred += 1
            #expect(plan.droppedRoutes.isEmpty && plan.parameterChanges.isEmpty)
            #expect(tracker == before)
            return
        }
        published += 1
        #expect(Set(plan.droppedRoutes) == before.trackedRoutes.subtracting(tracker.trackedRoutes))
        #expect(plan.droppedRoutes == Array(Set(plan.droppedRoutes)).sorted())
        if !Set(plan.droppedRoutes).isDisjoint(with: before.retainedRoutes) { droppedTails += 1 }
        if !tracker.deferredChanges.isEmpty { deferringRecalls += 1 }
        if let recall { variation[recall.patch] = recall.to }
    }

    /// Half the time nil; otherwise `PatchRecallPlanner`'s plan from the patch's current variation to a random one,
    /// for a patch `routing` plays.
    mutating func nextRecall(playedBy routing: MIDIRouting) throws -> PatchRecallPlan? {
        guard generator.next(2) == 0 else { return nil }
        recalledVariations += 1
        let patches = Set(routing.rules.compactMap { targets.target(of: $0.route) }).sorted()
        let patch = patches[generator.next(patches.count)]
        let target = Self.variations[generator.next(Self.variations.count)]
        return try Fixture.planned(patch, from: variation[patch], to: target)
    }

    mutating func observe() throws {
        let before = tracker.trackedRoutes
        let drain = try tracker.observe(ledger)
        let sounding = Self.sounding(ledger)
        #expect(sounding.isDisjoint(with: drain.releasedRoutes))
        #expect(Set(drain.releasedRoutes) == before.subtracting(tracker.trackedRoutes))
        #expect(drain.readyChanges.allSatisfy { $0.variation == variation[$0.patch] && !$0.isDeferred })
        #expect(tracker.tailReservations.count <= ledger.notes.count + ledger.pedalHolds.count)
        #expect(tracker.tailReservations.allSatisfy { sounding.contains($0.route) })
    }

    func checkInvariants() {
        let current = PatchTransitionPlanner.routes(of: tracker.routing)
        #expect(Self.sounding(ledger).isSubset(of: current.union(tracker.retainedRoutes)))
        #expect(current.isDisjoint(with: tracker.retainedRoutes))
        #expect(tracker.retainedRoutes == Array(Set(tracker.retainedRoutes)).sorted())
        #expect(tracker.deferredChanges.allSatisfy { $0.variation == variation[$0.patch] && $0.isDeferred })
    }
}
