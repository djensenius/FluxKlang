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

@Suite("Patch transitions: sustain, tails and loss")
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

    /// No intentional gap: across seeded playing with recalls, no route a note or pedal sounds on is ever released
    /// while it sounds, and every sounding route is current or retained.
    @Test(arguments: [(UInt64(1), 8), (UInt64(7), 8), (UInt64(42), 1), (UInt64(2026), 2)])
    func continuousPlayingAcrossRecallsLeavesNoGap(seed: UInt64, budgetRoutes: Int) throws {
        let routings = try [
            Fixture.routing(Fixture.routeA), Fixture.routing(Fixture.routeB), Fixture.routing(Fixture.routeShared),
            Fixture.routing(Fixture.routeA, Fixture.routeC), Fixture.routing(Fixture.routeA2, Fixture.routeB)
        ]
        var generator = TransitionSeededGenerator(seed: seed)
        var tracker = try Fixture.tracker(routings[0], routes: budgetRoutes)
        var ledger = MIDINoteLedger()
        var published = 0
        var deferred = 0
        for _ in 0..<600 {
            let note = UInt8(60 + generator.next(6))
            switch generator.next(10) {
            case 0...2: _ = try? Fixture.play(Fixture.on(note), on: &ledger, routing: tracker.routing)
            case 3...5: _ = try? Fixture.play(Fixture.off(note), on: &ledger, routing: tracker.routing)
            case 6:
                let pedal = generator.next(2) == 0 ? MIDIPedal.sustain : .sostenuto
                let event = Fixture.pedal(pedal, down: generator.next(2) == 0)
                _ = try? Fixture.play(event, on: &ledger, routing: tracker.routing)
            default:
                let plan = try tracker.recall(to: routings[generator.next(routings.count)], recall: nil, ledger: ledger)
                if plan.decision == .publish { published += 1 } else { deferred += 1 }
            }
            let drain = try tracker.observe(ledger)
            let sounding = Set(ledger.notes.map(\.route)).union(ledger.pedalHolds.map(\.route))
            #expect(sounding.isDisjoint(with: drain.releasedRoutes))
            let current = Set(tracker.routing.rules.map(\.route))
            #expect(sounding.isSubset(of: current.union(tracker.retainedRoutes)))
            #expect(current.isDisjoint(with: tracker.retainedRoutes))
            #expect(tracker.retainedRoutes == Array(Set(tracker.retainedRoutes)).sorted())
            #expect(tracker.tailReservations.count <= ledger.notes.count + ledger.pedalHolds.count)
        }
        #expect(published > 0)
        if budgetRoutes == 1 { #expect(deferred > 0) }
    }
}
