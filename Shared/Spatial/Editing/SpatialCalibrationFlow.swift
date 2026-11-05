//
//  SpatialCalibrationFlow.swift
//  FluxKlang
//
//  The staged, authorized calibration state machine (#116 PL1, spatial.md
//  "Calibration"). It produces no tone and has no clock: route status,
//  elapsed time and measured results are injected events, so UI frames never
//  clock anything. Results are staged as a pending calibration set, labelled
//  relative and uncalibrated, and are only applied by an explicit commit.
//

/// The flow's phase, without payloads.
enum SpatialCalibrationPhase: Hashable, Sendable, CaseIterable {
    case unavailable
    case planned
    case awaitingAuthorization
    case running
    case results
    case stopped
    case draft
}

/// The kind of an event, without payloads.
enum SpatialCalibrationEventKind: Hashable, Sendable, CaseIterable {
    case routeConfirmed
    case routeLost
    case revise
    case review
    case cancel
    case authorize
    case progress
    case complete
    case stageResults
    case discardResults
    case acknowledgeStop
    case commitDraft
    case discardDraft
}

/// An input to the flow. Each is legal in only some phases; see `SpatialCalibrationFlow`.
enum SpatialCalibrationEvent: Hashable, Sendable {
    /// The device is present and its routes are confirmed; the plan was built
    /// against them. Also restores the routes after a loss while results, a
    /// stop or a draft are shown.
    case routeConfirmed(SpatialCalibrationPlan)
    case routeLost(SpatialCalibrationUnavailableReason)
    /// Replaces the plan before review.
    case revise(SpatialCalibrationPlan)
    /// Opens the authorization sheet for the current plan.
    case review
    /// Escape on the sheet.
    case cancel
    case authorize(SpatialCalibrationAuthorization)
    /// Injected elapsed run time; the model never reads a clock.
    case progress(elapsedSeconds: Double)
    /// Injected measured trims and delays, one per planned output, once the
    /// injected elapsed time has reached the plan's total.
    case complete([SpeakerCalibration])
    case stageResults
    case discardResults
    case acknowledgeStop
    case commitDraft(expected: SpatialCalibrationDraft)
    case discardDraft

    var kind: SpatialCalibrationEventKind {
        switch self {
        case .routeConfirmed: .routeConfirmed
        case .routeLost: .routeLost
        case .revise: .revise
        case .review: .review
        case .cancel: .cancel
        case .authorize: .authorize
        case .progress: .progress
        case .complete: .complete
        case .stageResults: .stageResults
        case .discardResults: .discardResults
        case .acknowledgeStop: .acknowledgeStop
        case .commitDraft: .commitDraft
        case .discardDraft: .discardDraft
        }
    }
}

/// A plan shown on the authorization sheet by one flow, numbered by that
/// flow's review generation so an authorization from an earlier review is stale.
struct SpatialCalibrationReview: Hashable, Sendable {
    let flowID: SpatialCalibrationFlowID
    let plan: SpatialCalibrationPlan
    let generation: UInt64

    fileprivate init(flowID: SpatialCalibrationFlowID, plan: SpatialCalibrationPlan, generation: UInt64) {
        self.flowID = flowID
        self.plan = plan
        self.generation = generation
    }
}

/// An authorized run. `elapsedSeconds` only changes through injected progress.
struct SpatialCalibrationRun: Hashable, Sendable {
    let review: SpatialCalibrationReview
    let elapsedSeconds: Double

    fileprivate init(review: SpatialCalibrationReview, elapsedSeconds: Double) {
        self.review = review
        self.elapsedSeconds = elapsedSeconds
    }

    /// Elapsed time as a fraction `0…1` of the plan's total duration.
    var progress: Double { elapsedSeconds / review.plan.totalSeconds }

    /// The output under test: each takes `secondsPerOutput`, in plan order; the
    /// end of the run belongs to the last output.
    var currentOutput: SpeakerID {
        let outputs = review.plan.outputs
        let index = Int(elapsedSeconds / review.plan.secondsPerOutput)
        return outputs[min(index, outputs.count - 1)]
    }

    /// Refuses a non-finite, earlier or over-long elapsed time.
    fileprivate func advanced(to elapsed: Double) throws(SpatialCalibrationRefusal) -> Self {
        guard elapsed.isFinite else { throw .invalidElapsed }
        guard elapsed >= elapsedSeconds else { throw .elapsedRegressed }
        guard elapsed <= review.plan.totalSeconds else { throw .elapsedBeyondPlan }
        return Self(review: review, elapsedSeconds: elapsed)
    }
}

/// Measured results for a completed run: exactly one entry per planned output,
/// in plan order, always labelled relative and uncalibrated.
struct SpatialCalibrationResults: Hashable, Sendable {
    let review: SpatialCalibrationReview
    let entries: [SpeakerCalibration]

    var label: SpatialCalibrationLabel { .relativeUncalibrated }

    /// Refuses, in entry order, an unplanned or duplicate speaker, then in plan
    /// order the first planned output without a result.
    fileprivate init(review: SpatialCalibrationReview, entries: [SpeakerCalibration])
        throws(SpatialCalibrationRefusal) {
        let planned = Set(review.plan.outputs)
        var bySpeaker: [SpeakerID: SpeakerCalibration] = [:]
        for entry in entries {
            guard planned.contains(entry.speaker) else { throw .unplannedResult(entry.speaker) }
            guard bySpeaker.updateValue(entry, forKey: entry.speaker) == nil else {
                throw .duplicateResult(entry.speaker)
            }
        }
        var ordered: [SpeakerCalibration] = []
        for output in review.plan.outputs {
            guard let entry = bySpeaker[output] else { throw .missingResult(output) }
            ordered.append(entry)
        }
        self.review = review
        self.entries = ordered
    }
}

/// Results staged as the pending calibration set, exactly one generation after
/// the applied set. It changes nothing until committed.
struct SpatialCalibrationDraft: Hashable, Sendable {
    let plan: SpatialCalibrationPlan
    let set: SpatialCalibrationSet

    var label: SpatialCalibrationLabel { .relativeUncalibrated }

    fileprivate init(plan: SpatialCalibrationPlan, set: SpatialCalibrationSet) {
        self.plan = plan
        self.set = set
    }
}

/// What a stop request (Panic, Safe Mute or device loss) found.
enum SpatialCalibrationStopOutcome: Hashable, Sendable {
    /// A run was playing and is now stopped.
    case stoppedRun
    /// Nothing was playing, but a review awaiting authorization was cancelled,
    /// so its authorization can no longer start a run.
    case cancelledReview
    /// Nothing was playing; the flow is unchanged.
    case nothingPlaying
}

/// A route change reported while results, a stop or a draft are shown. They
/// stay on screen, and leaving them lands where the change says.
enum SpatialCalibrationRouteChange: Hashable, Sendable {
    /// The device or a route was lost: leaving lands in unavailable with this reason.
    case lost(SpatialCalibrationUnavailableReason)
    /// The routes were confirmed again after a loss: leaving lands in planned
    /// with this plan, which was built against them.
    case restored(SpatialCalibrationPlan)
}

enum SpatialCalibrationState: Hashable, Sendable {
    case unavailable(SpatialCalibrationUnavailableReason)
    case planned(SpatialCalibrationPlan)
    case awaitingAuthorization(SpatialCalibrationReview)
    case running(SpatialCalibrationRun)
    case results(SpatialCalibrationResults)
    case stopped(SpatialCalibrationPlan, SpatialCalibrationStop)
    case draft(SpatialCalibrationDraft)

    var phase: SpatialCalibrationPhase {
        switch self {
        case .unavailable: .unavailable
        case .planned: .planned
        case .awaitingAuthorization: .awaitingAuthorization
        case .running: .running
        case .results: .results
        case .stopped: .stopped
        case .draft: .draft
        }
    }
}

/// The calibration flow. Legal transitions (every other phase × event pair is
/// refused with `illegalTransition` and changes nothing):
///
/// | Phase | Event | Next |
/// |---|---|---|
/// | unavailable | routeConfirmed | planned |
/// | planned | routeLost / revise / review | unavailable / planned / awaitingAuthorization |
/// | awaitingAuthorization | routeLost / cancel / authorize | unavailable / planned / running |
/// | running | routeLost / progress / complete | stopped / running / results |
/// | results | stageResults / discardResults | draft / planned |
/// | stopped | acknowledgeStop | planned |
/// | draft | commitDraft / discardDraft | planned |
/// | results, stopped, draft | routeLost, or routeConfirmed after a loss | unchanged |
///
/// A route loss while results, a stop or a draft are shown (including the
/// loss that stopped a run) is kept in `routeChange`: leaving lands in
/// unavailable with its reason instead of planned, and a later route
/// confirmation lands in planned with the confirmed plan. Only one
/// confirmation follows a loss: a second `routeConfirmed` is refused with
/// `illegalTransition` until another `routeLost` is recorded.
///
/// Panic, Safe Mute and device loss go to `stop(_:)`, which never throws.
/// Outside running and awaitingAuthorization a device-loss stop records
/// nothing, so hosts must also send `routeLost`.
///
/// Running is reachable only from awaitingAuthorization, with an authorization
/// whose flow ID, plan and generation all match the current review.
struct SpatialCalibrationFlow: Hashable, Sendable {
    let id: SpatialCalibrationFlowID
    private(set) var state: SpatialCalibrationState
    /// Set only while results, a stop or a draft are shown; nil otherwise.
    private(set) var routeChange: SpatialCalibrationRouteChange?
    private var stage: SpatialCalibrationStage
    /// The last review generation issued; the next review gets one more. Every
    /// flow starts at 0, and its ID keeps its reviews apart from other flows'.
    private(set) var lastReviewGeneration: UInt64 = 0

    /// Starts unavailable (the Calibrate button is disabled with `reason`).
    /// `id` must be unique to this flow instance; see `SpatialCalibrationFlowID`.
    init(id: SpatialCalibrationFlowID, applied: SpatialCalibrationSet = .empty,
         unavailable reason: SpatialCalibrationUnavailableReason) {
        self.id = id
        state = .unavailable(reason)
        stage = SpatialCalibrationStage(applied: applied)
    }

    /// Starts planned, for a device that is already present with confirmed
    /// routes. `id` must be unique to this flow instance.
    init(id: SpatialCalibrationFlowID, applied: SpatialCalibrationSet = .empty, plan: SpatialCalibrationPlan) {
        self.id = id
        state = .planned(plan)
        stage = SpatialCalibrationStage(applied: applied)
    }

    /// The generation after `last`; refuses rather than wrapping.
    static func reviewGeneration(after last: UInt64) throws(SpatialCalibrationRefusal) -> UInt64 {
        let (generation, overflow) = last.addingReportingOverflow(1)
        guard !overflow else { throw .reviewGenerationExhausted }
        return generation
    }

    var phase: SpatialCalibrationPhase { state.phase }
    /// The calibration renders use; only `commitDraft` changes it.
    var applied: SpatialCalibrationSet { stage.applied }
    /// The staged set, present only in the draft phase.
    var pending: SpatialCalibrationSet? { stage.pending }

    /// Applies `event`, or throws and changes nothing.
    mutating func handle(_ event: SpatialCalibrationEvent) throws(SpatialCalibrationRefusal) {
        var next = self
        switch state {
        case .unavailable: try next.fromUnavailable(event)
        case let .planned(plan): try next.fromPlanned(plan, event)
        case let .awaitingAuthorization(review): try next.fromAwaitingAuthorization(review, event)
        case let .running(run): try next.fromRunning(run, event)
        case let .results(results): try next.fromResults(results, event)
        case let .stopped(plan, _): try next.fromStopped(plan, event)
        case let .draft(draft): try next.fromDraft(draft, event)
        }
        self = next
    }

    /// Panic, Safe Mute or device loss. It never throws, so a broadcast needs no
    /// error handling. A running calibration stops. A review awaiting
    /// authorization is cancelled to planned (unavailable after a device loss),
    /// and the next review gets a new generation. In any other phase nothing is
    /// playing, so the flow is unchanged; repeating a stop is harmless. Route
    /// status still arrives as `routeLost`: in results, stopped or draft a
    /// device-loss stop does not record the loss (and in planned it does not
    /// leave), so hosts must also send `routeLost` for the loss to count.
    @discardableResult
    mutating func stop(_ reason: SpatialCalibrationStop) -> SpatialCalibrationStopOutcome {
        switch state {
        case let .running(run):
            halt(run, reason)
            return .stoppedRun
        case let .awaitingAuthorization(review):
            if case let .deviceLost(lost) = reason {
                state = .unavailable(lost)
            } else {
                state = .planned(review.plan)
            }
            return .cancelledReview
        default:
            return .nothingPlaying
        }
    }

    private mutating func halt(_ run: SpatialCalibrationRun, _ reason: SpatialCalibrationStop) {
        state = .stopped(run.review.plan, reason)
        if case let .deviceLost(lost) = reason { routeChange = .lost(lost) }
    }

    /// Records a route loss (the latest wins), or a confirmation after one,
    /// while results, a stop or a draft are shown. A confirmation without a
    /// loss, or a second one after a restore, is illegal.
    private mutating func noteRoute(_ event: SpatialCalibrationEvent) throws(SpatialCalibrationRefusal) {
        switch (event, routeChange) {
        case let (.routeLost(reason), _):
            routeChange = .lost(reason)
        case let (.routeConfirmed(plan), .lost?):
            routeChange = .restored(plan)
        default:
            throw illegal(event)
        }
    }

    /// Leaves results, a stop or a draft: to planned with `plan`, unless the
    /// route changed meanwhile.
    private mutating func leave(toPlanned plan: SpatialCalibrationPlan) {
        switch routeChange {
        case let .lost(reason): state = .unavailable(reason)
        case let .restored(confirmed): state = .planned(confirmed)
        case nil: state = .planned(plan)
        }
        routeChange = nil
    }

    private func illegal(_ event: SpatialCalibrationEvent) -> SpatialCalibrationRefusal {
        .illegalTransition(from: phase, event: event.kind)
    }

    private mutating func fromUnavailable(_ event: SpatialCalibrationEvent) throws(SpatialCalibrationRefusal) {
        guard case let .routeConfirmed(plan) = event else { throw illegal(event) }
        state = .planned(plan)
    }

    private mutating func fromPlanned(_ plan: SpatialCalibrationPlan, _ event: SpatialCalibrationEvent)
        throws(SpatialCalibrationRefusal) {
        switch event {
        case let .routeLost(reason):
            state = .unavailable(reason)
        case let .revise(revised):
            state = .planned(revised)
        case .review:
            let generation = try Self.reviewGeneration(after: lastReviewGeneration)
            lastReviewGeneration = generation
            state = .awaitingAuthorization(SpatialCalibrationReview(flowID: id, plan: plan, generation: generation))
        default:
            throw illegal(event)
        }
    }

    private mutating func fromAwaitingAuthorization(
        _ review: SpatialCalibrationReview, _ event: SpatialCalibrationEvent
    ) throws(SpatialCalibrationRefusal) {
        switch event {
        case let .routeLost(reason):
            state = .unavailable(reason)
        case .cancel:
            state = .planned(review.plan)
        case let .authorize(authorization):
            if let defect = Self.defect(of: authorization, for: review) { throw .authorizationMismatch(defect) }
            state = .running(SpatialCalibrationRun(review: review, elapsedSeconds: 0))
        default:
            throw illegal(event)
        }
    }

    /// The first binding that does not match: flow ID, plan ID, the rest of the
    /// plan (reported as `.digest`), then generation. The whole plan is compared,
    /// so a digest collision cannot pass.
    private static func defect(of authorization: SpatialCalibrationAuthorization,
                               for review: SpatialCalibrationReview) -> SpatialCalibrationAuthorizationDefect? {
        if authorization.flowID != review.flowID { return .flowID }
        if authorization.planID != review.plan.id { return .planID }
        if authorization.plan != review.plan { return .digest }
        if authorization.generation != review.generation { return .generation }
        return nil
    }

    private mutating func fromRunning(_ run: SpatialCalibrationRun, _ event: SpatialCalibrationEvent)
        throws(SpatialCalibrationRefusal) {
        switch event {
        case let .routeLost(reason):
            halt(run, .deviceLost(reason))
        case let .progress(elapsed):
            state = .running(try run.advanced(to: elapsed))
        case let .complete(entries):
            // An early completion is refused before its entries are checked.
            let total = run.review.plan.totalSeconds
            guard run.elapsedSeconds == total else {
                throw .runIncomplete(elapsedSeconds: run.elapsedSeconds, totalSeconds: total)
            }
            state = .results(try SpatialCalibrationResults(review: run.review, entries: entries))
        default:
            throw illegal(event)
        }
    }

    private mutating func fromResults(_ results: SpatialCalibrationResults, _ event: SpatialCalibrationEvent)
        throws(SpatialCalibrationRefusal) {
        switch event {
        case .routeLost, .routeConfirmed:
            try noteRoute(event)
        case .stageResults:
            let current = stage.applied.generation
            let (generation, overflow) = current.addingReportingOverflow(1)
            guard !overflow else { throw .calibration(.invalidGeneration(current)) }
            let set: SpatialCalibrationSet
            do {
                set = try SpatialCalibrationSet(generation: generation, entries: results.entries)
                try stage.stage(set)
            } catch {
                throw .calibration(error)
            }
            state = .draft(SpatialCalibrationDraft(plan: results.review.plan, set: set))
        case .discardResults:
            leave(toPlanned: results.review.plan)
        default:
            throw illegal(event)
        }
    }

    private mutating func fromStopped(_ plan: SpatialCalibrationPlan, _ event: SpatialCalibrationEvent)
        throws(SpatialCalibrationRefusal) {
        switch event {
        case .routeLost, .routeConfirmed:
            try noteRoute(event)
        case .acknowledgeStop:
            leave(toPlanned: plan)
        default:
            throw illegal(event)
        }
    }

    private mutating func fromDraft(_ draft: SpatialCalibrationDraft, _ event: SpatialCalibrationEvent)
        throws(SpatialCalibrationRefusal) {
        switch event {
        case .routeLost, .routeConfirmed:
            try noteRoute(event)
        case let .commitDraft(expected):
            guard expected == draft else { throw .draftMismatch }
            do {
                try stage.promote(expected: draft.set)
            } catch {
                throw .calibration(error)
            }
            leave(toPlanned: draft.plan)
        case .discardDraft:
            stage.discard()
            leave(toPlanned: draft.plan)
        default:
            throw illegal(event)
        }
    }
}
