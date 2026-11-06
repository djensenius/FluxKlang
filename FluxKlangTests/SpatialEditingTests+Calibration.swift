import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared calibration fixtures for `SpatialCalibrationFlowTests` and
/// `SpatialCalibrationAuthorizationTests`.
extension SpatialEditingFixture {
    static let quadOutputs = ["spk.fl", "spk.fr", "spk.rl", "spk.rr"]
    static let relativeLabel = "relative, uncalibrated"

    static func plan(_ id: String = "cal.quad", outputs: [String] = quadOutputs, level: Double = -20,
                     seconds: Double = 2, routes: Set<RouteID>? = nil,
                     layout chosen: SpatialLayout? = nil) throws -> SpatialCalibrationPlan {
        try SpatialCalibrationPlan(id: SpatialCalibrationPlanID(id), outputs: outputs.map(speaker),
                                   maximumLevelDecibels: level, secondsPerOutput: seconds,
                                   layout: chosen ?? layout(), availableRoutes: routes ?? Self.routes())
    }

    static func entries(_ outputs: [String] = quadOutputs) throws -> [SpeakerCalibration] {
        try outputs.enumerated().map { index, raw in
            try SpeakerCalibration(speaker: speaker(raw), trimDecibels: -Double(index + 1),
                                   delaySeconds: Double(index) / 1_000)
        }
    }

    /// A flow driven through legal events into `phase`. Running is a finished
    /// run (elapsed at the plan's total); `startedRun` is one at elapsed 0.
    static func flow(in phase: SpatialCalibrationPhase, id: String = "flow.a",
                     applied: SpatialCalibrationSet = .empty,
                     plan chosen: SpatialCalibrationPlan? = nil) throws -> SpatialCalibrationFlow {
        let plan = try chosen ?? Self.plan()
        let flowID = try SpatialCalibrationFlowID(id)
        var next: SpatialCalibrationFlow
        switch phase {
        case .unavailable:
            return SpatialCalibrationFlow(id: flowID, applied: applied, unavailable: .deviceMissing)
        case .planned:
            return SpatialCalibrationFlow(id: flowID, applied: applied, plan: plan)
        case .awaitingAuthorization:
            next = try flow(in: .planned, id: id, applied: applied, plan: plan)
            try next.handle(.review)
        case .running:
            next = try startedRun(id: id, applied: applied, plan: plan)
            try next.handle(.progress(elapsedSeconds: plan.totalSeconds))
        case .results:
            next = try flow(in: .running, id: id, applied: applied, plan: plan)
            try next.handle(.complete(entries(plan.outputs.map(\.rawValue))))
        case .stopped:
            next = try flow(in: .running, id: id, applied: applied, plan: plan)
            next.stop(.panic)
        case .draft:
            next = try flow(in: .results, id: id, applied: applied, plan: plan)
            try next.handle(.stageResults)
        }
        return next
    }

    static func startedRun(id: String = "flow.a", applied: SpatialCalibrationSet = .empty,
                           plan: SpatialCalibrationPlan? = nil) throws -> SpatialCalibrationFlow {
        var next = try flow(in: .awaitingAuthorization, id: id, applied: applied, plan: plan)
        try next.handle(.authorize(SpatialCalibrationAuthorization(authorizing: #require(review(of: next)))))
        return next
    }

    static func review(of flow: SpatialCalibrationFlow) -> SpatialCalibrationReview? {
        if case let .awaitingAuthorization(review) = flow.state { return review }
        return nil
    }

    static func run(of flow: SpatialCalibrationFlow) -> SpatialCalibrationRun? {
        if case let .running(run) = flow.state { return run }
        return nil
    }

    static func results(of flow: SpatialCalibrationFlow) -> SpatialCalibrationResults? {
        if case let .results(results) = flow.state { return results }
        return nil
    }

    static func draft(of flow: SpatialCalibrationFlow) -> SpatialCalibrationDraft? {
        if case let .draft(draft) = flow.state { return draft }
        return nil
    }

    /// Handles `event`, requires the typed refusal and that nothing changed.
    static func expectRefusal(_ flow: inout SpatialCalibrationFlow, _ event: SpatialCalibrationEvent,
                              _ expected: SpatialCalibrationRefusal,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let before = flow
        do {
            try flow.handle(event)
            Issue.record("\(event.kind) in \(before.phase) was not refused", sourceLocation: sourceLocation)
        } catch {
            #expect(error == expected, sourceLocation: sourceLocation)
        }
        #expect(flow == before, sourceLocation: sourceLocation)
    }
}

@Suite("Spatial calibration flow phases, runs and staging")
struct SpatialCalibrationFlowTests {
    private typealias Fixture = SpatialEditingFixture
    private typealias Phase = SpatialCalibrationPhase
    private typealias Kind = SpatialCalibrationEventKind

    /// Every legal phase × event pair and the phase it leads to; all others are refused.
    private static let legal: [Phase: [Kind: Phase]] = [
        .unavailable: [.routeConfirmed: .planned],
        .planned: [.routeLost: .unavailable, .revise: .planned, .review: .awaitingAuthorization],
        .awaitingAuthorization: [.routeLost: .unavailable, .cancel: .planned, .authorize: .running],
        .running: [.routeLost: .stopped, .progress: .running, .complete: .results],
        .results: [.routeLost: .results, .stageResults: .draft, .discardResults: .planned],
        .stopped: [.routeLost: .stopped, .acknowledgeStop: .planned],
        .draft: [.routeLost: .draft, .commitDraft: .planned, .discardDraft: .planned]
    ]

    /// A well-formed event of `kind`: authorize and commit carry this flow's own
    /// review or draft when it has one, else one from a matching helper flow.
    private static func event(_ kind: Kind, for flow: SpatialCalibrationFlow) throws -> SpatialCalibrationEvent {
        switch kind {
        case .authorize:
            let source = try Fixture.review(of: flow)
                ?? #require(Fixture.review(of: Fixture.flow(in: .awaitingAuthorization)))
            return .authorize(SpatialCalibrationAuthorization(authorizing: source))
        case .commitDraft:
            let source = try Fixture.draft(of: flow) ?? #require(Fixture.draft(of: Fixture.flow(in: .draft)))
            return .commitDraft(expected: source)
        default:
            let plain: [SpatialCalibrationEvent] = [
                .routeConfirmed(try Fixture.plan()), .routeLost(.routeUnconfirmed),
                .revise(try Fixture.plan(level: -30)), .review, .cancel, .progress(elapsedSeconds: 8),
                .complete(try Fixture.entries()), .stageResults, .discardResults, .acknowledgeStop, .discardDraft
            ]
            return try #require(plain.first { $0.kind == kind })
        }
    }

    @Test func everyIllegalPhaseEventPairIsRefusedAndChangesNothing() throws {
        var legalCount = 0
        var illegalCount = 0
        for phase in Phase.allCases {
            for kind in Kind.allCases {
                var flow = try Fixture.flow(in: phase)
                #expect(flow.phase == phase)
                let event = try Self.event(kind, for: flow)
                #expect(event.kind == kind)
                if let next = Self.legal[phase]?[kind] {
                    legalCount += 1
                    try flow.handle(event)
                    #expect(flow.phase == next, "\(phase) × \(kind)")
                } else {
                    illegalCount += 1
                    Fixture.expectRefusal(&flow, event, .illegalTransition(from: phase, event: kind))
                }
            }
        }
        #expect(legalCount == 18 && illegalCount == 73)
        #expect(Self.legal[.planned]?[.authorize] == nil)
    }

    @Test func authorizedRunStagesRelativeResultsOneGenerationAhead() throws {
        let applied = try SpatialCalibrationSet(generation: 3, entries: [
            SpeakerCalibration(speaker: Fixture.speaker("spk.fl"), trimDecibels: -9)
        ])
        let plan = try Fixture.plan()
        var flow = SpatialCalibrationFlow(id: try SpatialCalibrationFlowID("flow.a"), applied: applied,
                                          unavailable: .routeUnconfirmed)
        try flow.handle(.routeConfirmed(plan))
        try flow.handle(.review)
        let review = try #require(Fixture.review(of: flow))
        #expect(review.plan == plan && review.generation == 1 && review.flowID == flow.id)
        try flow.handle(.authorize(SpatialCalibrationAuthorization(authorizing: review)))
        try flow.handle(.progress(elapsedSeconds: plan.totalSeconds))
        let measured = try Fixture.entries()
        try flow.handle(.complete(measured))
        let results = try #require(Fixture.results(of: flow))
        #expect(results.entries == measured && results.label.text == Fixture.relativeLabel)
        #expect(flow.applied == applied && flow.pending == nil)
        try flow.handle(.stageResults)
        let draft = try #require(Fixture.draft(of: flow))
        #expect(draft.set == (try SpatialCalibrationSet(generation: 4, entries: measured)))
        #expect(draft.plan == plan && draft.label == .relativeUncalibrated && draft.label.text == Fixture.relativeLabel)
        #expect(flow.pending == draft.set && flow.applied == applied)
        try flow.handle(.commitDraft(expected: draft))
        #expect(flow.state == .planned(plan) && flow.applied == draft.set && flow.pending == nil)
    }

    @Test func commitNeedsThisFlowsDraftAndDiscardKeepsTheAppliedSet() throws {
        var flow = try Fixture.flow(in: .draft)
        let draft = try #require(Fixture.draft(of: flow))
        let other = try Fixture.flow(in: .draft, applied: SpatialCalibrationSet(generation: 5))
        let foreign = try #require(Fixture.draft(of: other))
        Fixture.expectRefusal(&flow, .commitDraft(expected: foreign), .draftMismatch)
        var discarded = flow
        try discarded.handle(.discardDraft)
        #expect(discarded.state == .planned(draft.plan) && discarded.pending == nil && discarded.applied == .empty)
        try flow.handle(.commitDraft(expected: draft))
        #expect(flow.applied == draft.set && flow.applied.generation == 1 && flow.pending == nil)
    }

    @Test func stagingRefusesWhenTheAppliedGenerationCannotAdvance() throws {
        var flow = try Fixture.flow(in: .results, applied: SpatialCalibrationSet(generation: Int.max))
        Fixture.expectRefusal(&flow, .stageResults, .calibration(.invalidGeneration(Int.max)))
        var below = try Fixture.flow(in: .results, applied: SpatialCalibrationSet(generation: Int.max - 1))
        try below.handle(.stageResults)
        #expect(below.pending?.generation == Int.max)
    }

    /// Calibrating some speakers changes only those (Copilot r2): every other
    /// applied entry, including one for a speaker no plan can test, is staged
    /// and committed exactly, never reset to 0 dB and no delay or dropped.
    @Test func stagingKeepsEveryUntestedSpeakersTrimAndDelay() throws {
        func entry(_ raw: String, _ trim: Double, _ delay: Double) throws -> SpeakerCalibration {
            try SpeakerCalibration(speaker: Fixture.speaker(raw), trimDecibels: trim, delaySeconds: delay)
        }
        let untested = try [entry("spk.rr", -3.5, 0.0125), entry("spk.c", -6, 0.002)]
        let applied = try SpatialCalibrationSet(generation: 2, entries: [entry("spk.fl", -9, 0.004)] + untested)
        var flow = try Fixture.flow(in: .results, applied: applied, plan: Fixture.plan(outputs: ["spk.fr", "spk.fl"]))
        let measured = try #require(Fixture.results(of: flow)).entries
        try flow.handle(.stageResults)
        let draft = try #require(Fixture.draft(of: flow))
        #expect(draft.set == (try SpatialCalibrationSet(generation: 3, entries: measured + untested)))
        try flow.handle(.commitDraft(expected: draft))
        #expect(flow.applied == draft.set)
        for kept in untested { #expect(flow.applied.entry(for: kept.speaker) == kept, "\(kept.speaker)") }
        // A full plan replaces every planned entry; only the speaker no plan can test is carried.
        let full = try Fixture.flow(in: .draft, applied: flow.applied)
        #expect(full.pending == (try SpatialCalibrationSet(generation: 4, entries: Fixture.entries() + [untested[1]])))
        // Nothing is dropped to fit: a merged set over 64 entries is refused and changes nothing.
        let others = try (0..<61).map { try entry("spk.n" + String($0), -1, 0) }
        var crowded = try Fixture.flow(in: .results, applied: SpatialCalibrationSet(entries: others))
        Fixture.expectRefusal(&crowded, .stageResults, .calibration(.tooManyCalibrationEntries(65)))
        var fits = try Fixture.flow(in: .results, applied: SpatialCalibrationSet(entries: Array(others.dropLast())))
        try fits.handle(.stageResults)
        #expect(fits.pending?.entries.count == 64)
    }

    @Test func resultsMustCoverExactlyThePlannedOutputs() throws {
        let plan = try Fixture.plan(outputs: ["spk.rr", "spk.fl", "spk.rl", "spk.fr"])
        var flow = try Fixture.flow(in: .running, plan: plan)
        let measured = try Fixture.entries(["spk.fr", "spk.rl", "spk.fl", "spk.rr"])
        let unplanned = try SpeakerCalibration(speaker: Fixture.speaker("spk.c"))
        Fixture.expectRefusal(&flow, .complete(measured + [unplanned]), .unplannedResult(unplanned.speaker))
        Fixture.expectRefusal(&flow, .complete([measured[1]] + measured), .duplicateResult(measured[1].speaker))
        Fixture.expectRefusal(&flow, .complete(Array(measured.dropLast())),
                              .missingResult(try Fixture.speaker("spk.rr")))
        Fixture.expectRefusal(&flow, .complete(Array(measured.dropFirst())),
                              .missingResult(try Fixture.speaker("spk.fr")))
        Fixture.expectRefusal(&flow, .complete([]), .missingResult(try Fixture.speaker("spk.rr")))
        try flow.handle(.complete(measured))
        let results = try #require(Fixture.results(of: flow))
        #expect(results.entries.map(\.speaker) == plan.outputs)
        #expect(results.entries.allSatisfy { measured.contains($0) })
    }

    @Test func resultRefusalsFollowTheDocumentedOrder() throws {
        var flow = try Fixture.flow(in: .running)
        let measured = try Fixture.entries()
        let unplanned = try SpeakerCalibration(speaker: Fixture.speaker("spk.c"))
        Fixture.expectRefusal(&flow, .complete(Array(measured.dropLast()) + [unplanned]),
                              .unplannedResult(unplanned.speaker))
        Fixture.expectRefusal(&flow, .complete([measured[2]] + measured.dropLast()),
                              .duplicateResult(measured[2].speaker))
    }

    @Test func earlyCompletionIsRefusedBeforeItsEntriesAreChecked() throws {
        var flow = try Fixture.startedRun()
        let unplanned = try SpeakerCalibration(speaker: Fixture.speaker("spk.c"))
        Fixture.expectRefusal(&flow, .complete([unplanned]), .runIncomplete(elapsedSeconds: 0, totalSeconds: 8))
        try flow.handle(.progress(elapsedSeconds: 8))
        Fixture.expectRefusal(&flow, .complete([unplanned]), .unplannedResult(unplanned.speaker))
    }

    @Test func completeNeedsTheWholeRun() throws {
        var flow = try Fixture.startedRun()
        let measured = try Fixture.entries()
        Fixture.expectRefusal(&flow, .complete(measured), .runIncomplete(elapsedSeconds: 0, totalSeconds: 8))
        try flow.handle(.progress(elapsedSeconds: (8.0).nextDown))
        Fixture.expectRefusal(&flow, .complete(measured),
                              .runIncomplete(elapsedSeconds: (8.0).nextDown, totalSeconds: 8))
        try flow.handle(.progress(elapsedSeconds: 8))
        try flow.handle(.complete(measured))
        #expect(Fixture.results(of: flow)?.entries == measured)
    }

    @Test func progressIsInjectedMonotonicAndBoundedByThePlan() throws {
        var flow = try Fixture.startedRun()
        let outputs = try Fixture.plan().outputs
        func run() throws -> SpatialCalibrationRun { try #require(Fixture.run(of: flow)) }
        #expect(try run().elapsedSeconds == 0 && run().progress == 0 && run().currentOutput == outputs[0])
        try flow.handle(.progress(elapsedSeconds: (2.0).nextDown))
        #expect(try run().currentOutput == outputs[0])
        try flow.handle(.progress(elapsedSeconds: 2))
        #expect(try run().currentOutput == outputs[1] && run().progress == 0.25)
        try flow.handle(.progress(elapsedSeconds: 2))
        Fixture.expectRefusal(&flow, .progress(elapsedSeconds: (2.0).nextDown), .elapsedRegressed)
        for bad in [Double.nan, .infinity, -.infinity] {
            Fixture.expectRefusal(&flow, .progress(elapsedSeconds: bad), .invalidElapsed)
        }
        Fixture.expectRefusal(&flow, .progress(elapsedSeconds: (8.0).nextUp), .elapsedBeyondPlan)
        try flow.handle(.progress(elapsedSeconds: 7.0))
        #expect(try run().currentOutput == outputs[3])
        try flow.handle(.progress(elapsedSeconds: 8))
        #expect(try run().currentOutput == outputs[3] && run().progress == 1)
    }

    /// 3 × 0.7 / 0.7 is 2.9999999999999996, so a truncated quotient would name
    /// the third speaker at the fourth's planned start (Copilot 4485408153).
    @Test func theOutputUnderTestChangesExactlyAtEachPlannedBoundary() throws {
        var copilot = try Fixture.startedRun(plan: Fixture.plan(seconds: 0.7))
        let fourth = try Fixture.speaker("spk.rr")
        #expect(3 * 0.7 / 0.7 < 3)
        try copilot.handle(.progress(elapsedSeconds: 3 * 0.7))
        #expect(Fixture.run(of: copilot)?.currentOutput == fourth)
        // Each output starts exactly at its boundary, and the value just before belongs to the previous output.
        for seconds in [0.7, 1.0 / 3, 0.3, 0.65, 9.9, 0.25, 10] {
            let plan = try Fixture.plan(seconds: seconds)
            var flow = try Fixture.startedRun(plan: plan)
            for (index, output) in plan.outputs.enumerated() {
                let start = seconds * Double(index)
                if index > 0 {
                    try flow.handle(.progress(elapsedSeconds: start.nextDown))
                    #expect(Fixture.run(of: flow)?.currentOutput == plan.outputs[index - 1], "\(seconds) × \(index)⁻")
                }
                try flow.handle(.progress(elapsedSeconds: start))
                #expect(Fixture.run(of: flow)?.currentOutput == output, "\(seconds) × \(index)")
            }
            #expect(plan.totalSeconds.bitPattern == (seconds * 4).bitPattern)
            try flow.handle(.progress(elapsedSeconds: plan.totalSeconds))
            #expect(Fixture.run(of: flow)?.currentOutput == plan.outputs.last, "\(seconds) at the end")
        }
    }

    @Test func stopsAndRouteLossEndTheRunAndAcknowledgeTruthfully() throws {
        let plan = try Fixture.plan()
        let cases: [(SpatialCalibrationStop, SpatialCalibrationState)] = [
            (.panic, .planned(plan)),
            (.safeMute, .planned(plan)),
            (.deviceLost(.deviceMissing), .unavailable(.deviceMissing))
        ]
        for (stop, after) in cases {
            var flow = try Fixture.startedRun()
            #expect(flow.stop(stop) == .stoppedRun)
            #expect(flow.state == .stopped(plan, stop))
            let stopped = flow
            #expect(flow.stop(.panic) == .nothingPlaying && flow == stopped)
            try flow.handle(.acknowledgeStop)
            #expect(flow.state == after && flow.pending == nil)
        }
        var lost = try Fixture.startedRun()
        try lost.handle(.routeLost(.routeUnconfirmed))
        #expect(lost.state == .stopped(plan, .deviceLost(.routeUnconfirmed)))
        try lost.handle(.acknowledgeStop)
        #expect(lost.state == .unavailable(.routeUnconfirmed))
    }

    @Test func stopsOutsideARunOrReviewAreNoOpsThatNeverThrow() throws {
        let stops: [SpatialCalibrationStop] = [.panic, .safeMute, .deviceLost(.deviceMissing)]
        var checked = 0
        for phase in Phase.allCases where phase != .running && phase != .awaitingAuthorization {
            for stop in stops {
                var flow = try Fixture.flow(in: phase)
                let before = flow
                #expect(flow.stop(stop) == .nothingPlaying, "\(phase) × \(stop)")
                #expect(flow.stop(stop) == .nothingPlaying && flow == before, "\(phase) × \(stop)")
                checked += 1
            }
        }
        #expect(checked == 15)
    }

    @Test func routeLossAfterAPanicStopLeavesToUnavailable() throws {
        let plan = try Fixture.plan()
        var flow = try Fixture.flow(in: .stopped)
        #expect(flow.state == .stopped(plan, .panic) && flow.routeChange == nil)
        try flow.handle(.routeLost(.routeUnconfirmed))
        try flow.handle(.routeLost(.deviceMissing))
        #expect(flow.state == .stopped(plan, .panic) && flow.routeChange == .lost(.deviceMissing))
        #expect(flow.stop(.deviceLost(.routeUnconfirmed)) == .nothingPlaying)
        #expect(flow.routeChange == .lost(.deviceMissing))
        try flow.handle(.acknowledgeStop)
        #expect(flow.state == .unavailable(.deviceMissing) && flow.routeChange == nil)
    }

    @Test func routeLossWhileResultsAreShownKeepsThemAndLeavesToUnavailable() throws {
        var flow = try Fixture.flow(in: .results)
        let shown = flow.state
        try flow.handle(.routeLost(.routeUnconfirmed))
        #expect(flow.state == shown && flow.routeChange == .lost(.routeUnconfirmed))
        try flow.handle(.discardResults)
        #expect(flow.state == .unavailable(.routeUnconfirmed) && flow.routeChange == nil && flow.pending == nil)
    }

    @Test func routeLossDuringADraftStillCommitsAndLeavesToUnavailable() throws {
        var staged = try Fixture.flow(in: .results)
        try staged.handle(.routeLost(.deviceMissing))
        try staged.handle(.stageResults)
        let draft = try #require(Fixture.draft(of: staged))
        #expect(staged.routeChange == .lost(.deviceMissing) && staged.pending == draft.set)
        try staged.handle(.discardDraft)
        #expect(staged.state == .unavailable(.deviceMissing) && staged.pending == nil && staged.applied == .empty)
        var flow = try Fixture.flow(in: .draft)
        try flow.handle(.routeLost(.routeUnconfirmed))
        #expect(Fixture.draft(of: flow) == draft && flow.pending == draft.set)
        try flow.handle(.commitDraft(expected: draft))
        #expect(flow.state == .unavailable(.routeUnconfirmed) && flow.applied == draft.set && flow.pending == nil)
        #expect(flow.routeChange == nil)
    }

    @Test func confirmedRoutesAfterALossLeaveToTheConfirmedPlan() throws {
        let confirmed = try Fixture.plan(level: -30)
        let exits: [(Phase, SpatialCalibrationEvent)] = [
            (.results, .discardResults), (.stopped, .acknowledgeStop), (.draft, .discardDraft)
        ]
        for (phase, exit) in exits {
            var flow = try Fixture.flow(in: phase)
            let unexpected = SpatialCalibrationRefusal.illegalTransition(from: phase, event: .routeConfirmed)
            Fixture.expectRefusal(&flow, .routeConfirmed(confirmed), unexpected)
            try flow.handle(.routeLost(.deviceMissing))
            let shown = flow.state
            try flow.handle(.routeConfirmed(confirmed))
            #expect(flow.state == shown && flow.routeChange == .restored(confirmed))
            Fixture.expectRefusal(&flow, .routeConfirmed(confirmed), unexpected)
            var relost = flow
            try relost.handle(.routeLost(.routeUnconfirmed))
            try relost.handle(exit)
            #expect(relost.state == .unavailable(.routeUnconfirmed))
            try flow.handle(exit)
            #expect(flow.state == .planned(confirmed) && flow.routeChange == nil, "\(phase)")
        }
        var lost = try Fixture.startedRun()
        try lost.handle(.routeLost(.deviceMissing))
        #expect(lost.routeChange == .lost(.deviceMissing))
        try lost.handle(.routeConfirmed(confirmed))
        try lost.handle(.acknowledgeStop)
        #expect(lost.state == .planned(confirmed) && lost.routeChange == nil)
    }

    @Test func reviseCancelAndDiscardKeepThePlanAndTheAppliedSet() throws {
        let plan = try Fixture.plan()
        let revised = try Fixture.plan(level: -30)
        var flow = try Fixture.flow(in: .unavailable)
        try flow.handle(.routeConfirmed(plan))
        #expect(flow.state == .planned(plan))
        try flow.handle(.revise(revised))
        try flow.handle(.review)
        #expect(Fixture.review(of: flow)?.plan == revised)
        try flow.handle(.cancel)
        #expect(flow.state == .planned(revised))
        try flow.handle(.routeLost(.routeUnconfirmed))
        #expect(flow.state == .unavailable(.routeUnconfirmed))
        var awaiting = try Fixture.flow(in: .awaitingAuthorization)
        try awaiting.handle(.routeLost(.deviceMissing))
        #expect(awaiting.state == .unavailable(.deviceMissing))
        var results = try Fixture.flow(in: .results)
        try results.handle(.discardResults)
        #expect(results.state == .planned(plan) && results.pending == nil && results.applied == .empty)
    }
}
