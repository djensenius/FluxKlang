//
//  TriggerScheduler.swift
//  FluxKlang
//
//  Sample/ASAP scheduling, musical admission and reserved terminal ownership.
//

enum TriggerSchedulerError: Error, Equatable, Sendable {
    /// Ready musical work with no prepared timeline, no named musical sequence (including
    /// the A2 forwarding signatures), or a ready musical commit awaiting later projection.
    case musicalContextRequired
    /// One timeline per scheduler; a replacement would conceal missing history.
    case musicalAlreadyPrepared
    /// The named sequence or a current musical identity differs from the retained timeline.
    case staleMusicalContext
    /// The stamp's loop pass differs from its covered origin's actual pass.
    case musicalPassMismatch
}

/// Single-owner control-plane composition, not an engine, authorization boundary or
/// render queue. Ledger/readiness arguments are the owner's CURRENT trusted snapshots.
/// Copies may stage transactions; they are not independent live scheduler authorities.
/// The clock alone owns physical baseline/latest/floor; the session alone owns IDs
/// and the terminal queue; the musical state alone owns the optional timeline.
/// No persistence or activation here.
struct TriggerScheduler: Sendable {
    private struct Pending: Sendable {
        let stamp: TriggerStamp
        let handle: TriggerHandle
        let readyEntry: Int?
        let music: SchedulerMusicalAdmission?
        /// Admission order, so batch cancellation is deterministic.
        let order: Int
    }

    private var clock: SchedulerClock
    private var session: TriggerSession
    private var pending: [TriggerID: Pending] = [:]
    private var musical: SchedulerMusicalState
    private var admissions = 0

    var currentToken: TriggerSessionToken { session.currentToken }
    var pendingCount: Int { session.pendingCount }
    var reservedOutcomeCount: Int { session.reservedOutcomeCount }
    var musicalSummary: SchedulerMusicalSummary? { musical.summary }

    /// The pending request's admitted occurrence, or nil when not pending in this session or not musical.
    func pendingMusic(_ handle: TriggerHandle) -> SchedulerPendingMusic? {
        guard handle.session == session.currentToken, let music = pending[handle.trigger]?.music else { return nil }
        return SchedulerPendingMusic(music)
    }

    init(ledger: GenerationLedger, timebase: HostTimebase, outcomeCapacity: Int) throws {
        clock = try SchedulerClock(ledger: ledger, timebase: timebase)
        session = try TriggerSession(outcomeCapacity: outcomeCapacity)
        musical = SchedulerMusicalState(pinLimit: outcomeCapacity)
    }

    func snapshot(ledger: GenerationLedger) throws -> SchedulerClock.Snapshot {
        try clock.snapshot(ledger: ledger)
    }

    /// Physical observation is independent of any irrelevant musical payload.
    mutating func observe(_ anchor: ClockAnchor, nominalRate: Int, timebase: HostTimebase,
                          ledger: GenerationLedger) throws {
        try clock.observe(anchor, nominalRate: nominalRate, timebase: timebase, ledger: ledger)
    }

    /// Construction uses the clock's genuine drift baseline, never requireReady's latest mapping.
    /// A setup anchor newer than the clock's latest is also observed; an older one only has
    /// to agree with the baseline. Neither side publishes on failure.
    mutating func prepareMusical(_ setup: SchedulerMusicalSetup, ledger: GenerationLedger) throws {
        guard musical.summary == nil else { throw TriggerSchedulerError.musicalAlreadyPrepared }
        let (nextClock, baseline) = try anchoredClock(setup.anchor, ledger: ledger)
        var nextMusical = musical
        try nextMusical.prepare(setup, baseline: baseline, ledger: ledger)
        musical = nextMusical
        clock = nextClock
    }

    /// Stages the timeline and clock observation together; a rejection publishes neither.
    mutating func observeMusical(_ observation: MusicalObservation, at anchor: ClockAnchor,
                                 sequence: UInt64, ledger: GenerationLedger) throws {
        var nextMusical = musical
        try nextMusical.observe(observation, at: anchor, sequence: sequence, ledger: ledger)
        let (nextClock, _) = try observedClock(anchor, ledger: ledger)
        musical = nextMusical
        clock = nextClock
    }

    /// Delegates to the timeline's quiescent reset with the clock's current genuine baseline.
    /// A restart-start or locate anchor captured before the latest physical observation is valid.
    mutating func resetMusical(_ reset: SchedulerMusicalReset, ledger: GenerationLedger) throws {
        let (nextClock, baseline) = try anchoredClock(reset.anchor, ledger: ledger)
        var nextMusical = musical
        try nextMusical.reset(reset, baseline: baseline, ledger: ledger)
        musical = nextMusical
        clock = nextClock
    }

    /// Read-only current-context query (no state change). Submit and commit do not call it:
    /// they check `musical.current` themselves inside their own staged transactions.
    func requireMusicalContext(_ context: TriggerSchedulerContext) throws -> SchedulerMusicalSummary {
        SchedulerMusicalSummary(try musical.current(context))
    }

    /// Refusals consume nothing. Accepted stale requests immediately complete through
    /// the same session queue and retain their slot until drain. No unreserve is needed.
    mutating func submit(_ stamp: TriggerStamp, session token: TriggerSessionToken,
                         ledger: GenerationLedger, readiness: ActionReadiness) throws -> TriggerHandle {
        try submit(stamp, session: token,
                   context: TriggerSchedulerContext(ledger: ledger, readiness: readiness, musicalSequence: nil))
    }

    mutating func submit(_ stamp: TriggerStamp, session token: TriggerSessionToken,
                         context: TriggerSchedulerContext) throws -> TriggerHandle {
        try admit(stamp, preflight: token, reservation: token, context: context)
    }

    /// Internal test seam for submit: distinct tokens reach the REAL reservation refusal after
    /// musical preparation. Success needs both tokens current, so it grants nothing submit lacks.
    mutating func admit(_ stamp: TriggerStamp, preflight: TriggerSessionToken,
                        reservation: TriggerSessionToken, context: TriggerSchedulerContext) throws -> TriggerHandle {
        let ledger = context.ledger
        let readiness = context.readiness
        try session.preflight(id: stamp.id, session: preflight)
        try stamp.validate(primaryClock: clock.primaryClock, musicalClock: ledger.musicalClock)
        _ = try clock.snapshot(ledger: ledger)
        let stale = stamp.requires.first { !ledger.isCurrent($0) }
        let readyEntry = readiness.isCurrent(stamp.action, ledger: ledger) ? readiness.readyEntry(stamp.action) : nil
        var nextClock = clock
        if let primary = stamp.requires.first(where: { $0.key == clock.primaryClock }), ledger.isCurrent(primary) {
            let arrival = SampleStamp(clock: try ClockID(primary.key.subject.rawValue),
                                      generation: primary.generation, frame: stamp.horizonFrame)
            try nextClock.recordArrival(arrival, ledger: ledger)
        }
        // Covered origin and any pin are staged before reserve; a reservation refusal discards
        // the staged pin. Neither stale nor captured-unready work needs musical resolution.
        var nextMusical = musical
        var music: SchedulerMusicalAdmission?
        if stale == nil, readyEntry != nil, stamp.target.isMusical {
            let latest = try nextClock.snapshot(ledger: ledger).latestAnchor
            music = try nextMusical.admit(stamp, context: context, latestPrimary: latest)
        }
        let rejected = stale.map {
            TriggerOutcome(trigger: stamp.id, result: .rejectedStale, stale: .generation($0.key))
        }
        try rejected?.validateMediaShape()
        var nextSession = session
        let handle = try nextSession.reserve(id: stamp.id, session: reservation)
        if let rejected { try nextSession.complete(handle, outcome: rejected) }
        session = nextSession
        clock = nextClock
        musical = nextMusical
        if rejected == nil {
            admissions += 1
            pending[stamp.id] = Pending(stamp: stamp, handle: handle, readyEntry: readyEntry, music: music,
                                        order: admissions)
        }
        return handle
    }

    /// Enqueues one terminal result, available ONLY through drain. Errors leave the
    /// pending entry, session and clock unchanged, including a staged horizon advance.
    /// Names no musical sequence: ready musical work resolves to strict invalidTiming, so
    /// discarding the disposition can never hide a `.startTransport`.
    mutating func commit(_ handle: TriggerHandle, at horizon: SampleStamp, nominalRate: Int,
                         ledger: GenerationLedger, readiness: ActionReadiness) throws {
        try commit(handle, at: horizon, nominalRate: nominalRate,
                   context: TriggerSchedulerContext(ledger: ledger, readiness: readiness, musicalSequence: nil))
    }

    /// Precedence after the session/handle checks and the staged horizon advance (whose refusals consume
    /// nothing): a stale requirement (`.cancelled`), then readiness (`notReady`), then clock readiness
    /// (throws); for musical work, a missing/stale witness (`invalidTiming`, no frame or map), then the
    /// pinless `outsideLoop` (current map), then the stopped policy, then projection and the late policy.
    /// M12: a refused resume leaves the request waiting; it ends with `invalidTiming` at the next commit
    /// naming the refused sequence, or `.cancelled` if a requirement goes stale first.
    @discardableResult
    mutating func commit(_ handle: TriggerHandle, at horizon: SampleStamp, nominalRate: Int,
                         context: TriggerSchedulerContext) throws -> SchedulerCommitDisposition {
        let ledger = context.ledger
        let readiness = context.readiness
        guard handle.session == session.currentToken else { throw TriggerSessionError.staleSession }
        guard let entry = pending[handle.trigger] else { throw TriggerSessionError.notPending }
        var nextClock = clock
        try nextClock.advanceHorizon(horizon, nominalRate: nominalRate, ledger: ledger)
        let outcome: TriggerOutcome
        var disposition = SchedulerCommitDisposition.completed
        let point = CommitPoint(horizon: horizon.frame, nominalRate: nominalRate, context: context)
        if let stale = entry.stamp.requires.first(where: { !ledger.isCurrent($0) }) {
            outcome = TriggerOutcome(trigger: handle.trigger, result: .cancelled, stale: .generation(stale.key))
        } else if entry.readyEntry == nil || !readiness.isCurrent(entry.stamp.action, ledger: ledger)
                    || entry.readyEntry != readiness.readyEntry(entry.stamp.action) {
            outcome = TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady)
        } else {
            _ = try nextClock.requireReady(ledger: ledger)
            if entry.stamp.target.isMusical {
                let music = try musical.resolve(entry.music, context: context)
                guard let resolved = try musicalOutcome(entry.stamp, music, at: point) else {
                    // Waiting keeps the pin and pending entry; the observed horizon is still a floor.
                    clock = nextClock
                    return .waitingForTransport
                }
                (outcome, disposition) = resolved
            } else {
                outcome = try resolve(entry.stamp, at: point)
            }
        }
        try publishTerminals([(handle, outcome)], clock: nextClock)
        return disposition
    }

    /// Horizon-independent: cancels every pending request with a stale requirement, in admission
    /// order, without clock readiness (usable during an incomplete restart). All-or-nothing: every
    /// pin release and enqueue is staged first; the clock is never touched. A partial-batch failure
    /// is unreachable: a cancelled outcome is always well-formed and every pending pin is releasable.
    @discardableResult
    mutating func cancelStale(ledger: GenerationLedger) throws -> [TriggerHandle] {
        let batch = pending.values.sorted { $0.order < $1.order }.compactMap { entry in
            entry.stamp.requires.first { !ledger.isCurrent($0) }.map {
                (entry.handle, TriggerOutcome(trigger: entry.handle.trigger, result: .cancelled,
                                              stale: .generation($0.key)))
            }
        }
        guard !batch.isEmpty else { return [] }
        try publishTerminals(batch, clock: clock)
        return batch.map(\.0)
    }

    #if DEBUG
    /// DEBUG-only test seam for the shared terminal transaction: prepared (possibly malformed)
    /// outcomes meet the REAL session validator. Never called from production.
    mutating func completeForTesting(_ batch: [(TriggerHandle, TriggerOutcome)]) throws {
        try publishTerminals(batch, clock: clock)
    }
    #endif

    /// The shared terminal transaction for one commit or a cancellation batch: each enqueue is staged
    /// on ONE session copy first (so stale/duplicate handle identity errors win), then its pin release
    /// in place on ONE musical copy (O(n) copying per batch: argued, not timing-tested). Publication
    /// follows only if every stage succeeds; any failure keeps every pin, queued outcome and clock/pending state.
    private mutating func publishTerminals(_ batch: [(TriggerHandle, TriggerOutcome)],
                                           clock nextClock: SchedulerClock) throws {
        var nextSession = session
        var nextMusical = musical
        for (handle, outcome) in batch {
            if outcome.reason == .invalidTiming || outcome.reason == .outsideLoop {
                try nextSession.completeDiagnostic(handle, outcome: outcome)
            } else {
                try nextSession.complete(handle, outcome: outcome)
            }
            try nextMusical.release(pending[handle.trigger]?.music)
        }
        session = nextSession
        for (handle, _) in batch { pending.removeValue(forKey: handle.trigger) }
        clock = nextClock
        musical = nextMusical
    }

    mutating func drain() -> [SessionOutcome] {
        session.drain()
    }

    /// Explicit quiescence, never automatic recovery from identity exhaustion. Checks the token,
    /// then zero pins, then delegates. Keeps the ENTIRE clock (baseline, latest, horizon) and the
    /// same timeline with its history and sequence; never calls `timeline.rotate()`.
    @discardableResult
    mutating func rotateSession(expected: TriggerSessionToken) throws -> TriggerSessionToken {
        guard expected == session.currentToken else { throw TriggerSessionError.staleSession }
        guard (musical.summary?.pinCount ?? 0) == 0 else { throw MusicalTimingError.pinsOutstanding }
        return try session.rotateSession(expected: expected)
    }

    /// Setup/reset staging: observe only an anchor the clock has not covered (no baseline yet, or
    /// newer than its latest); otherwise leave the clock untouched. Either way the timeline's
    /// latest primary stays at or before the clock's latest anchor, as origin conversion requires.
    private func anchoredClock(_ anchor: ClockAnchor,
                               ledger: GenerationLedger) throws -> (SchedulerClock, SampleClockMap) {
        let current = try clock.snapshot(ledger: ledger)
        if let baseline = current.baseline, let latest = current.latestAnchor,
           anchor.sample.frame <= latest.sample.frame, anchor.host.ticks <= latest.host.ticks {
            return (clock, baseline)
        }
        return try observedClock(anchor, ledger: ledger)
    }

    /// A staged physical observation and the resulting generation's genuine baseline.
    private func observedClock(_ anchor: ClockAnchor,
                               ledger: GenerationLedger) throws -> (SchedulerClock, SampleClockMap) {
        var next = clock
        try next.observe(anchor, nominalRate: ledger.nominalRate, timebase: clock.timebase, ledger: ledger)
        guard let baseline = try next.snapshot(ledger: ledger).baseline else { throw SchedulerClockError.notReady }
        return (next, baseline)
    }

    /// nil means wait for the transport. Missing context is never treated as stopped.
    private func musicalOutcome(_ stamp: TriggerStamp, _ music: SchedulerMusicalResolution,
                                at point: CommitPoint) throws -> (TriggerOutcome, SchedulerCommitDisposition)? {
        let horizon = point.horizon
        switch music {
        case .missingContext:
            return (TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .invalidTiming), .completed)
        case .outsideLoop(let map):
            return (TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .outsideLoop, musicalMap: map),
                    .completed)
        case .stopped:
            let fired = TriggerOutcome(trigger: stamp.id, result: .fired, assignedFrame: horizon, frame: horizon)
            switch stamp.stoppedPolicy {
            case .wait: return nil
            case .immediate: return (fired, .completed)
            case .startTransport: return (fired, .startTransport)
            }
        case .projected(let projection):
            return (try lateOutcome(stamp, assigned: projection.frame, musicalMap: projection.musicalMap,
                                    at: point), .completed)
        }
    }

    private func resolve(_ stamp: TriggerStamp, at point: CommitPoint) throws -> TriggerOutcome {
        let assigned: Int64
        switch stamp.target {
        case .asap: assigned = point.horizon
        case .sample(let frame): assigned = frame
        case .grid, .musical:
            // Unreachable: commit routes every musical target through musicalOutcome.
            throw TriggerSchedulerError.musicalContextRequired
        }
        return try lateOutcome(stamp, assigned: assigned, musicalMap: nil, at: point)
    }

    /// Sample and projected musical frames share one exact lateness policy; musicalMap names
    /// the revision a musical target was projected through.
    private func lateOutcome(_ stamp: TriggerStamp, assigned: Int64, musicalMap: Generation?,
                             at point: CommitPoint) throws -> TriggerOutcome {
        let horizon = point.horizon
        if assigned >= horizon {
            return TriggerOutcome(trigger: stamp.id, result: .fired, assignedFrame: assigned, frame: assigned,
                                  musicalMap: musicalMap)
        }
        let late = TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .late, assignedFrame: assigned,
                                  musicalMap: musicalMap)
        switch stamp.latePolicy {
        case .drop: return late
        case .nextBoundary:
            return try boundaryOutcome(stamp, late: late, at: point)
        case .fireLate(let maximum), .joinInProgress(let maximum):
            let lateness = Int128(horizon) - Int128(assigned)
            guard lateness * 1_000 <= Int128(point.nominalRate) * Int128(maximum) else { return late }
            let joined: Bool
            if case .joinInProgress = stamp.latePolicy { joined = true } else { joined = false }
            let offset = joined ? try ExactMath.int64(lateness) : 0
            return TriggerOutcome(trigger: stamp.id, result: joined ? .joined : .firedLate,
                                  assignedFrame: assigned, frame: horizon, startOffsetFrames: offset,
                                  musicalMap: musicalMap)
        }
    }

    /// Late fallback for sample and musical targets alike. Missing context is a strict diagnostic
    /// (no default grid, frame or map); a valid stopped context keeps the late drop; outsideLoop keeps
    /// the original assigned reference and names the current map.
    private func boundaryOutcome(_ stamp: TriggerStamp, late: TriggerOutcome,
                                 at point: CommitPoint) throws -> TriggerOutcome {
        let missing = TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .invalidTiming)
        guard let grid = stamp.fallbackGrid else { return missing } // Unreachable: validated at submit.
        switch try musical.fallback(at: point.horizon, grid: grid, context: point.context) {
        case .missingContext: return missing
        case .stopped: return late
        case .outsideLoop(let map):
            return TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .outsideLoop,
                                  assignedFrame: late.assignedFrame, musicalMap: map)
        case .projected(let projection):
            return TriggerOutcome(trigger: stamp.id, result: .fired, assignedFrame: projection.frame,
                                  frame: projection.frame, musicalMap: projection.musicalMap)
        }
    }
}

/// One commit's staged horizon, rate and musical witness.
private struct CommitPoint {
    let horizon: Int64
    let nominalRate: Int
    let context: TriggerSchedulerContext
}
