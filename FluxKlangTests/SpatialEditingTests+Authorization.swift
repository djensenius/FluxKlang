import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Spatial calibration plans, digests and authorization bindings")
struct SpatialCalibrationAuthorizationTests {
    private typealias Fixture = SpatialEditingFixture

    /// One flow reviewing `first`, and a value copy of it (same flow ID and
    /// review generation) that revised to `second` before its review.
    private static func reviewedPair(_ first: SpatialCalibrationPlan, _ second: SpatialCalibrationPlan) throws
        -> (ours: SpatialCalibrationFlow, theirs: SpatialCalibrationAuthorization) {
        var ours = try Fixture.flow(in: .planned, plan: first)
        var copy = ours
        try copy.handle(.revise(second))
        try copy.handle(.review)
        try ours.handle(.review)
        return (ours, SpatialCalibrationAuthorization(authorizing: try #require(Fixture.review(of: copy))))
    }

    private static func reroutedPlan() throws -> SpatialCalibrationPlan {
        try Fixture.plan(routes: Fixture.routes().union([RouteID("rte.alt")]),
                         layout: Fixture.layout(reroutes: ["spk.rr": "rte.alt"]))
    }

    @Test func authorizationFromAnotherFlowIsRefused() throws {
        var flowA = try Fixture.flow(in: .awaitingAuthorization, id: "flow.a")
        var flowB = try Fixture.flow(in: .awaitingAuthorization, id: "flow.b")
        let reviewA = try #require(Fixture.review(of: flowA))
        let reviewB = try #require(Fixture.review(of: flowB))
        let fromA = SpatialCalibrationAuthorization(authorizing: reviewA)
        #expect(reviewA.plan == reviewB.plan && reviewA.generation == reviewB.generation)
        #expect(fromA.flowID == flowA.id && fromA.flowID != reviewB.flowID && reviewB.flowID == flowB.id)
        Fixture.expectRefusal(&flowB, .authorize(fromA), .authorizationMismatch(.flowID))
        try flowA.handle(.authorize(fromA))
        #expect(Fixture.run(of: flowA)?.review == reviewA)
    }

    @Test func authorizationForAnotherPlanIDIsRefused() throws {
        var (flow, foreign) = try Self.reviewedPair(Fixture.plan("cal.a"), Fixture.plan("cal.b"))
        let ours = try #require(Fixture.review(of: flow))
        #expect(foreign.flowID == ours.flowID && foreign.generation == ours.generation)
        #expect(foreign.planID != ours.plan.id)
        Fixture.expectRefusal(&flow, .authorize(foreign), .authorizationMismatch(.planID))
    }

    @Test func authorizationForAnotherDigestIsRefused() throws {
        var (flow, foreign) = try Self.reviewedPair(Fixture.plan(), Fixture.plan(level: -30))
        let ours = try #require(Fixture.review(of: flow))
        #expect(foreign.flowID == ours.flowID && foreign.planID == ours.plan.id)
        #expect(foreign.generation == ours.generation && foreign.digest != ours.plan.digest)
        Fixture.expectRefusal(&flow, .authorize(foreign), .authorizationMismatch(.digest))
    }

    @Test func authorizationFromAnEarlierReviewIsRefused() throws {
        var flow = try Fixture.flow(in: .awaitingAuthorization)
        let first = try #require(Fixture.review(of: flow))
        let stale = SpatialCalibrationAuthorization(authorizing: first)
        try flow.handle(.cancel)
        try flow.handle(.review)
        let second = try #require(Fixture.review(of: flow))
        #expect(first.generation == 1 && second.generation == 2 && flow.lastReviewGeneration == 2)
        #expect(stale.flowID == second.flowID && stale.planID == second.plan.id && stale.digest == second.plan.digest)
        Fixture.expectRefusal(&flow, .authorize(stale), .authorizationMismatch(.generation))
        try flow.handle(.authorize(SpatialCalibrationAuthorization(authorizing: second)))
        #expect(Fixture.run(of: flow)?.review == second)
    }

    @Test func authorizationDefectsAreReportedInTheDocumentedOrder() throws {
        let other = try Fixture.flow(in: .awaitingAuthorization, id: "flow.b", plan: Fixture.plan("cal.b"))
        let foreign = SpatialCalibrationAuthorization(authorizing: try #require(Fixture.review(of: other)))
        var flow = try Fixture.flow(in: .awaitingAuthorization)
        Fixture.expectRefusal(&flow, .authorize(foreign), .authorizationMismatch(.flowID))

        let stale = SpatialCalibrationAuthorization(authorizing: try #require(Fixture.review(of: flow)))
        try flow.handle(.cancel)
        try flow.handle(.revise(Fixture.plan(level: -30)))
        try flow.handle(.review)
        let current = try #require(Fixture.review(of: flow))
        #expect(stale.planID == current.plan.id)
        #expect(stale.digest != current.plan.digest && stale.generation != current.generation)
        Fixture.expectRefusal(&flow, .authorize(stale), .authorizationMismatch(.digest))

        try flow.handle(.cancel)
        try flow.handle(.revise(Fixture.plan("cal.c")))
        try flow.handle(.review)
        Fixture.expectRefusal(&flow, .authorize(stale), .authorizationMismatch(.planID))
    }

    @Test func stopsCancelAPendingReviewAndStaleItsAuthorization() throws {
        let plan = try Fixture.plan()
        let cases: [(SpatialCalibrationStop, SpatialCalibrationState)] = [
            (.panic, .planned(plan)), (.safeMute, .planned(plan)),
            (.deviceLost(.deviceMissing), .unavailable(.deviceMissing))
        ]
        for (stop, after) in cases {
            var flow = try Fixture.flow(in: .awaitingAuthorization)
            let stale = SpatialCalibrationAuthorization(authorizing: try #require(Fixture.review(of: flow)))
            #expect(flow.stop(stop) == .cancelledReview, "\(stop)")
            #expect(flow.state == after && flow.lastReviewGeneration == 1, "\(stop)")
            let cancelled = flow
            #expect(flow.stop(stop) == .nothingPlaying && flow == cancelled)
            Fixture.expectRefusal(&flow, .authorize(stale), .illegalTransition(from: after.phase, event: .authorize))
            if after.phase == .unavailable { try flow.handle(.routeConfirmed(plan)) }
            try flow.handle(.review)
            #expect(Fixture.review(of: flow)?.generation == 2)
            Fixture.expectRefusal(&flow, .authorize(stale), .authorizationMismatch(.generation))
        }
    }

    @Test func reviewGenerationsAdvanceWithoutWrapping() throws {
        #expect(try SpatialCalibrationFlow.reviewGeneration(after: 0) == 1)
        #expect(try SpatialCalibrationFlow.reviewGeneration(after: .max - 1) == .max)
        #expect(throws: SpatialCalibrationRefusal.reviewGenerationExhausted) {
            try SpatialCalibrationFlow.reviewGeneration(after: .max)
        }
        var flow = try Fixture.flow(in: .planned)
        #expect(flow.lastReviewGeneration == 0)
        for expected in UInt64(1)...3 {
            try flow.handle(.review)
            #expect(Fixture.review(of: flow)?.generation == expected && flow.lastReviewGeneration == expected)
            try flow.handle(.cancel)
        }
    }

    @Test func reroutingASpeakerMakesANewPlanAndStalesItsAuthorization() throws {
        let base = try Fixture.plan()
        let rerouted = try Self.reroutedPlan()
        #expect(base.routes == (try ["rte.fl", "rte.fr", "rte.rl", "rte.rr"].map { try RouteID($0) }))
        #expect(rerouted.routes == (try ["rte.fl", "rte.fr", "rte.rl", "rte.alt"].map { try RouteID($0) }))
        #expect(rerouted.id == base.id && rerouted.outputs == base.outputs)
        #expect(rerouted != base && rerouted.digest != base.digest)
        let ordered = try Fixture.plan(outputs: ["spk.rr", "spk.fl"])
        #expect(ordered.routes == (try ["rte.rr", "rte.fl"].map { try RouteID($0) }))

        var (flow, old) = try Self.reviewedPair(rerouted, base)
        let current = try #require(Fixture.review(of: flow))
        #expect(old.flowID == current.flowID && old.planID == current.plan.id && old.generation == current.generation)
        Fixture.expectRefusal(&flow, .authorize(old), .authorizationMismatch(.digest))
    }

    @Test func plansRefuseBadOutputsInOrder() throws {
        #expect(throws: SpatialCalibrationRefusal.noOutputs) { try Fixture.plan(outputs: []) }
        let front = try Fixture.speaker("spk.fl")
        #expect(throws: SpatialCalibrationRefusal.duplicateOutput(front)) {
            try Fixture.plan(outputs: ["spk.fl", "spk.fr", "spk.fl"])
        }
        #expect(throws: SpatialCalibrationRefusal.unknownOutput(try Fixture.speaker("spk.zz"))) {
            try Fixture.plan(outputs: ["spk.fl", "spk.zz", "spk.c"])
        }
        #expect(throws: SpatialCalibrationRefusal.unroutedOutput(try Fixture.speaker("spk.c"))) {
            try Fixture.plan(outputs: ["spk.fl", "spk.c"])
        }
        let hostRoutes = try Fixture.routes().subtracting([RouteID("rte.rr")])
        #expect(throws: SpatialCalibrationRefusal.unroutedOutput(try Fixture.speaker("spk.rr"))) {
            try Fixture.plan(routes: hostRoutes)
        }
        #expect(throws: SpatialCalibrationRefusal.duplicateOutput(front)) {
            try Fixture.plan(outputs: ["spk.fl", "spk.fl"], level: 0, seconds: 0)
        }
        #expect(throws: SpatialCalibrationRefusal.invalidMaximumLevel) { try Fixture.plan(level: 0, seconds: 0) }
        let routed = try Fixture.plan(outputs: ["spk.rr", "spk.fl"], seconds: 0.5)
        #expect(routed.outputs == [try Fixture.speaker("spk.rr"), front] && routed.totalSeconds == 1)
    }

    @Test func planOutputCountIsBoundedBySixtyFourSpeakers() throws {
        let raws = (0..<64).map { "spk.n" + String($0) }
        let ids = try raws.map(Fixture.speaker)
        let routes = try raws.map { try RouteID("rte." + $0.dropFirst(4)) }
        let layout = try SpatialLayout(speakers: zip(ids, routes).map { id, route in
            try SpatialSpeaker(id: id, position: Fixture.point(0, 0), route: route)
        })
        func plan(_ outputs: [SpeakerID]) throws -> SpatialCalibrationPlan {
            try SpatialCalibrationPlan(id: SpatialCalibrationPlanID("cal.big"), outputs: outputs,
                                       maximumLevelDecibels: -20, secondsPerOutput: 0.25,
                                       layout: layout, availableRoutes: Set(routes))
        }
        let full = try plan(ids)
        #expect(full.outputs == ids && full.routes == routes && full.totalSeconds == 16)
        #expect(SpatialCalibrationPlan.maximumOutputs == 64)
        #expect(throws: SpatialCalibrationRefusal.tooManyOutputs(65)) {
            try plan(ids + [Fixture.speaker("spk.extra")])
        }
    }

    /// Every boundary, for durations whose quotients drift either way, starts
    /// its own output; the value just before it belongs to the previous one.
    @Test func eachPlannedBoundaryStartsItsOwnOutput() {
        typealias Plan = SpatialCalibrationPlan
        let count = Plan.maximumOutputs
        func index(_ elapsed: Double, _ seconds: Double, count: Int = SpatialCalibrationPlan.maximumOutputs) -> Int {
            Plan.outputIndex(at: elapsed, secondsPerOutput: seconds, count: count)
        }
        for seconds in [0.1, 0.7, 1.0 / 3, 0.3, 1e-3, 0.25, 9.9, 10, 1e9, 1e300] {
            for output in 0..<count {
                let start = Plan.boundarySeconds(output, secondsPerOutput: seconds)
                #expect(start.bitPattern == (seconds * Double(output)).bitPattern)
                #expect(index(start, seconds) == output, "\(seconds) × \(output)")
                if output > 0 { #expect(index(start.nextDown, seconds) == output - 1, "\(seconds) × \(output)⁻") }
            }
            let end = Plan.boundarySeconds(count, secondsPerOutput: seconds)
            for elapsed in [end.nextDown, end, end.nextUp, .greatestFiniteMagnitude, .infinity] {
                #expect(index(elapsed, seconds) == count - 1, "\(seconds) at \(elapsed)")
            }
            for elapsed in [-0.0, -seconds, -.greatestFiniteMagnitude, -.infinity, .nan] {
                #expect(index(elapsed, seconds) == 0, "\(seconds) at \(elapsed)")
            }
            #expect(index(seconds * 5, seconds, count: 1) == 0 && index(seconds, seconds, count: 2) == 1)
        }
        // Durations a plan refuses still give an index in range, never a trap.
        for seconds in [0.0, -1, .nan, .infinity, -.infinity, .leastNonzeroMagnitude] {
            for elapsed in [-1.0, 0, 1, .nan, .infinity, -.infinity] {
                #expect((0..<count).contains(index(elapsed, seconds)) && index(elapsed, seconds, count: 1) == 0)
            }
        }
    }

    @Test func levelAndDurationEdgesAreInclusive() throws {
        for level in [-60.0, -6] {
            #expect(try Fixture.plan(level: level).maximumLevelDecibels == level)
        }
        for level in [(-60.0).nextDown, (-6.0).nextUp, .nan, .infinity, -.infinity] {
            #expect(throws: SpatialCalibrationRefusal.invalidMaximumLevel) { try Fixture.plan(level: level) }
        }
        for seconds in [0.25, 10] {
            #expect(try Fixture.plan(seconds: seconds).secondsPerOutput == seconds)
        }
        for seconds in [(0.25).nextDown, (10.0).nextUp, .nan, .infinity] {
            #expect(throws: SpatialCalibrationRefusal.invalidDuration) { try Fixture.plan(seconds: seconds) }
        }
    }

    @Test func digestIsDeterministicPinnedAndCoversEveryReviewedField() throws {
        let base = try Fixture.plan()
        #expect(base.digest == (try Fixture.plan()).digest)
        #expect(base.digest.value == 0x6e62_a2a9_b556_2c7c)
        let variants = try [
            Fixture.plan("cal.other"),
            Fixture.plan(outputs: ["spk.fr", "spk.fl", "spk.rl", "spk.rr"]),
            Fixture.plan(outputs: ["spk.fl", "spk.fr", "spk.rl"]),
            Fixture.plan(level: -21),
            Fixture.plan(seconds: 3),
            Self.reroutedPlan()
        ]
        let distinct = Set(variants.map(\.digest.value) + [base.digest.value])
        #expect(distinct.count == 7)
    }
}
