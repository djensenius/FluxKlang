//
//  TriggerScheduler.swift
//  FluxKlang
//
//  Inert sample/ASAP scheduling and reserved terminal ownership.
//

enum TriggerSchedulerError: Error, Equatable, Sendable {
    /// Ready musical admission needs covered origin context, supplied by a later slice.
    case musicalContextRequired
}

/// Single-owner control-plane composition, not an engine, authorization boundary or
/// render queue. Ledger/readiness arguments are the owner's CURRENT trusted snapshots.
/// Copies may stage transactions; they are not independent live scheduler authorities.
/// The clock alone owns physical baseline/latest/floor; the session alone owns IDs
/// and the terminal queue. No musical history, pins, persistence or activation here.
struct TriggerScheduler: Sendable {
    private struct Pending: Sendable {
        let stamp: TriggerStamp
        let readyEntry: Int?
    }

    private var clock: SchedulerClock
    private var session: TriggerSession
    private var pending: [TriggerID: Pending] = [:]

    var currentToken: TriggerSessionToken { session.currentToken }
    var pendingCount: Int { session.pendingCount }
    var reservedOutcomeCount: Int { session.reservedOutcomeCount }

    init(ledger: GenerationLedger, timebase: HostTimebase, outcomeCapacity: Int) throws {
        clock = try SchedulerClock(ledger: ledger, timebase: timebase)
        session = try TriggerSession(outcomeCapacity: outcomeCapacity)
    }

    func snapshot(ledger: GenerationLedger) throws -> SchedulerClock.Snapshot {
        try clock.snapshot(ledger: ledger)
    }

    /// Physical observation is independent of any irrelevant musical payload.
    mutating func observe(_ anchor: ClockAnchor, nominalRate: Int, timebase: HostTimebase,
                          ledger: GenerationLedger) throws {
        try clock.observe(anchor, nominalRate: nominalRate, timebase: timebase, ledger: ledger)
    }

    /// Refusals consume nothing. Accepted stale requests immediately complete through
    /// the same session queue and retain their slot until drain. No unreserve is needed.
    mutating func submit(_ stamp: TriggerStamp, session token: TriggerSessionToken,
                         ledger: GenerationLedger, readiness: ActionReadiness) throws -> TriggerHandle {
        try session.preflight(id: stamp.id, session: token)
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
        // B1 must prepare covered origin/provenance and any pin HERE, before reserve.
        // Neither stale nor captured-unready work needs musical resolution.
        if stale == nil, readyEntry != nil, stamp.target.isMusical {
            throw TriggerSchedulerError.musicalContextRequired
        }
        let rejected = stale.map {
            TriggerOutcome(trigger: stamp.id, result: .rejectedStale, stale: .generation($0.key))
        }
        try rejected?.validateMediaShape()
        var nextSession = session
        let handle = try nextSession.reserve(id: stamp.id, session: token)
        if let rejected { try nextSession.complete(handle, outcome: rejected) }
        session = nextSession
        clock = nextClock
        if rejected == nil { pending[stamp.id] = Pending(stamp: stamp, readyEntry: readyEntry) }
        return handle
    }

    /// Enqueues one terminal result, available ONLY through drain. Errors leave the
    /// pending entry, session and clock unchanged, including a staged horizon advance.
    mutating func commit(_ handle: TriggerHandle, at horizon: SampleStamp, nominalRate: Int,
                         ledger: GenerationLedger, readiness: ActionReadiness) throws {
        guard handle.session == session.currentToken else { throw TriggerSessionError.staleSession }
        guard let entry = pending[handle.trigger] else { throw TriggerSessionError.notPending }
        var nextClock = clock
        try nextClock.advanceHorizon(horizon, nominalRate: nominalRate, ledger: ledger)
        let outcome: TriggerOutcome
        if let stale = entry.stamp.requires.first(where: { !ledger.isCurrent($0) }) {
            outcome = TriggerOutcome(trigger: handle.trigger, result: .cancelled, stale: .generation(stale.key))
        } else if entry.readyEntry == nil || !readiness.isCurrent(entry.stamp.action, ledger: ledger)
                    || entry.readyEntry != readiness.readyEntry(entry.stamp.action) {
            outcome = TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady)
        } else {
            _ = try nextClock.requireReady(ledger: ledger)
            outcome = try resolve(entry.stamp, horizon: horizon.frame, nominalRate: nominalRate)
        }
        // Future pin cleanup must also be staged before this enqueue, never published
        // first. Keep both the reservation and all clock/pending state on any failure.
        var nextSession = session
        if outcome.reason == .invalidTiming {
            try nextSession.completeDiagnostic(handle, outcome: outcome)
        } else {
            try nextSession.complete(handle, outcome: outcome)
        }
        session = nextSession
        pending.removeValue(forKey: handle.trigger)
        clock = nextClock
    }

    mutating func drain() -> [SessionOutcome] {
        session.drain()
    }

    /// Explicit quiescence, never automatic recovery from identity exhaustion.
    /// Keep the ENTIRE clock, including its genuine baseline, latest and horizon.
    @discardableResult
    mutating func rotateSession(expected: TriggerSessionToken) throws -> TriggerSessionToken {
        try session.rotateSession(expected: expected)
    }

    private func resolve(_ stamp: TriggerStamp, horizon: Int64, nominalRate: Int) throws -> TriggerOutcome {
        let assigned: Int64
        switch stamp.target {
        case .asap: assigned = horizon
        case .sample(let frame): assigned = frame
        case .grid, .musical:
            // Unreachable for current, continuously-ready A2 admissions; no invented origin.
            throw TriggerSchedulerError.musicalContextRequired
        }
        if assigned >= horizon {
            return TriggerOutcome(trigger: stamp.id, result: .fired, assignedFrame: assigned, frame: assigned)
        }
        let late = TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .late, assignedFrame: assigned)
        switch stamp.latePolicy {
        case .drop: return late
        case .nextBoundary:
            // Actual fallback needs musical context. A2 has none: strict diagnostic,
            // not a fake default grid, stopped transport, assigned frame or map revision.
            return TriggerOutcome(trigger: stamp.id, result: .dropped, reason: .invalidTiming)
        case .fireLate(let maximum), .joinInProgress(let maximum):
            let lateness = Int128(horizon) - Int128(assigned)
            guard lateness * 1_000 <= Int128(nominalRate) * Int128(maximum) else { return late }
            let joined: Bool
            if case .joinInProgress = stamp.latePolicy { joined = true } else { joined = false }
            let offset = joined ? try ExactMath.int64(lateness) : 0
            return TriggerOutcome(trigger: stamp.id, result: joined ? .joined : .firedLate,
                                  assignedFrame: assigned, frame: horizon, startOffsetFrames: offset)
        }
    }
}
