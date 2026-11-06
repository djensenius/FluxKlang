import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Patch transitions: change bounds")
struct PatchTransitionBoundsTests {
    typealias Fixture = PatchTransitionFixture

    /// `count` ascending changes `par.p00000`, `par.p00001`, …, each `from` → `to` dB.
    private static func manyChanges(_ count: Int, from: Double = -6, to: Double = 0) throws -> [PatchParameterChange] {
        try (0..<count).map { index in
            let digits = String(index)
            let parameter = try ParameterID("par.p" + String(repeating: "0", count: 5 - digits.count) + digits)
            return Fixture.change(parameter, from, to)
        }
    }

    @Test
    func boundIsTwiceTheDeltasOfOneVariation() {
        #expect(PatchTransitionPlan.maximumParameterChanges == 2 * PatchVariationLimits.maximumDeltasPerVariation)
        #expect(PatchTransitionPlan.maximumParameterChanges == 8192)
    }

    @Test
    func recallChangeCountIsBounded() throws {
        let maximum = PatchTransitionPlan.maximumParameterChanges
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
    func mergedChangesArePerPatchBounded() throws {
        let maximum = PatchTransitionPlan.maximumParameterChanges
        let routingOld = try Fixture.routing(Fixture.routeA, Fixture.routeB)
        var tracker = try Fixture.tracker(routingOld)
        var ledger = MIDINoteLedger()
        try Fixture.play(Fixture.on(48), on: &ledger, routing: routingOld)
        let routingNext = try Fixture.routing(Fixture.routeShared, Fixture.routeC)
        let many = PatchRecallPlan(
            patch: Fixture.patchA, from: nil, to: Fixture.verse, changes: try Self.manyChanges(maximum)
        )
        try tracker.recall(to: routingNext, recall: many, ledger: ledger)
        #expect(tracker.deferredChanges.count == maximum)

        // Another patch has its own bound.
        let other = Fixture.recall(Fixture.patchC, Fixture.change(Fixture.gain, -6, 0))
        let both = try tracker.prepare(to: routingNext, recall: other, ledger: ledger)
        #expect(both.parameterChanges.count == maximum + 1)

        // At the limit: one deferred change cancels and one new parameter joins.
        let first = try ParameterID("par.p00000")
        let late = try ParameterID("par.q")
        let swap = PatchRecallPlan(
            patch: Fixture.patchA, from: Fixture.verse, to: Fixture.chorus,
            changes: [Fixture.change(first, 0, -6), Fixture.change(late, -6, 0)]
        )
        let atLimit = try tracker.prepare(to: routingNext, recall: swap, ledger: ledger)
        #expect(atLimit.parameterChanges.count == maximum)
        #expect(atLimit.parameterChanges.allSatisfy { $0.variation == Fixture.chorus })

        let before = tracker
        let added = PatchRecallPlan(
            patch: Fixture.patchA, from: Fixture.verse, to: Fixture.chorus, changes: [Fixture.change(late, -6, 0)]
        )
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingNext, recall: added, ledger: ledger)
        } == .tooManyMergedChanges(Fixture.patchA, count: maximum + 1, maximum: maximum))
        #expect(tracker == before)

        // The recall itself is bounded before merging, even when all of it would cancel deferred changes.
        let cancelling = PatchRecallPlan(
            patch: Fixture.patchA, from: Fixture.verse, to: nil,
            changes: try Self.manyChanges(maximum + 1, from: 0, to: -6)
        )
        #expect(Fixture.refusal { () throws(PatchTransitionRefusal) in
            try tracker.recall(to: routingNext, recall: cancelling, ledger: ledger)
        } == .tooManyParameterChanges(count: maximum + 1, maximum: maximum))
        #expect(tracker == before)
    }
}
