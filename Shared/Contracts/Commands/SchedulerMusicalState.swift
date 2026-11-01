//
//  SchedulerMusicalState.swift
//  FluxKlang
//
//  Scheduler-owned musical timeline composition; no scheduling arithmetic or clock state.
//

/// The owner's CURRENT trusted snapshots for one scheduler call. `musicalSequence` is the
/// producer's latest observation sequence; nil means no musical context is claimed.
struct TriggerSchedulerContext: Sendable {
    let ledger: GenerationLedger
    let readiness: ActionReadiness
    let musicalSequence: UInt64?
}

/// Control feedback only. Terminal outcomes remain available exclusively through drain.
enum SchedulerCommitDisposition: Sendable {
    case completed
    case waitingForTransport
    case startTransport
}

/// The first musical anchor/state. The physical baseline comes from the scheduler clock.
struct SchedulerMusicalSetup: Sendable {
    let anchor: ClockAnchor
    let map: MusicalMap
    let loop: LoopRange?
    let running: Bool
    let historyLimit: Int

    init(anchor: ClockAnchor, map: MusicalMap, loop: LoopRange? = nil, running: Bool, historyLimit: Int) {
        self.anchor = anchor
        self.map = map
        self.loop = loop
        self.running = running
        self.historyLimit = historyLimit
    }
}

/// A discontinuous transport/clock epoch. Loop and run state are retained by the timeline.
struct SchedulerMusicalReset: Sendable {
    let anchor: ClockAnchor
    let map: MusicalMap
    let sequence: UInt64
}

/// A read-only view. It carries no provenance and cannot reserve or release pins.
struct SchedulerMusicalSummary: Equatable, Sendable {
    let sample: SampleClockMap
    let firstAnchor: ClockAnchor
    let latestPrimary: ClockAnchor
    let clock: MusicalClockMap
    let loop: LoopRange?
    let isRunning: Bool
    let observationSequence: UInt64
    let historyCount: Int
    let historyLimit: Int
    let pinCount: Int
    let pinLimit: Int

    init(_ timeline: MusicalTimeline) {
        sample = timeline.sample
        firstAnchor = timeline.firstMusicalAnchor
        latestPrimary = timeline.latestPrimary
        clock = timeline.currentClock
        loop = timeline.currentLoop
        isRunning = timeline.isRunning
        observationSequence = timeline.observationSequence
        historyCount = timeline.historyCount
        historyLimit = timeline.historyLimit
        pinCount = timeline.pinCount
        pinLimit = timeline.pinLimit
    }
}

/// A pending musical request's admission. The pin is scheduler-private; only its occurrence is shown.
enum SchedulerMusicalAdmission: Sendable {
    case pinned(MusicalPin)
    /// No eligible occurrence in the origin's loop. Pinless; terminal precedence still applies at commit.
    case outsideLoop
}

/// Read-only view of a pending request's musical admission.
enum SchedulerPendingMusic: Equatable, Sendable {
    case pinned(MusicalOccurrence)
    case outsideLoop

    init(_ admission: SchedulerMusicalAdmission) {
        switch admission {
        case .pinned(let pin): self = .pinned(pin.occurrence)
        case .outsideLoop: self = .outsideLoop
        }
    }
}

/// What a ready pending musical request resolves to at commit, before late/stopped policy.
enum SchedulerMusicalResolution: Sendable {
    /// Missing timeline/witness, or a stale sequence/identity: strict invalidTiming, never stopped.
    case missingContext
    /// Pinless outsideLoop diagnosis, naming the current map revision.
    case outsideLoop(Generation)
    /// Valid current context with the transport stopped; only now may the stopped policy apply.
    case stopped
    case projected(MusicalProjection)
}

/// A late `nextBoundary` fallback through the current timeline, before outcome shaping.
enum SchedulerMusicalFallback: Sendable {
    /// Missing timeline/witness, or a stale sequence/identity: strict invalidTiming.
    case missingContext
    /// Valid current context with the transport stopped: the late drop stands.
    case stopped
    /// The next boundary lies outside the loop; names the current map revision.
    case outsideLoop(Generation)
    case projected(MusicalProjection)
}

/// The scheduler's single optional timeline. Copies stage one transaction; they are never
/// independent writers. The pin budget is the outcome capacity: every pin backs a reservation.
struct SchedulerMusicalState: Sendable {
    let pinLimit: Int
    private var timeline: MusicalTimeline?

    var summary: SchedulerMusicalSummary? { timeline.map(SchedulerMusicalSummary.init) }

    init(pinLimit: Int) {
        self.pinLimit = pinLimit
    }

    /// Construction is once per scheduler; replacing a timeline would conceal missing history.
    mutating func prepare(_ setup: SchedulerMusicalSetup, baseline: SampleClockMap,
                          ledger: GenerationLedger) throws {
        guard timeline == nil else { throw TriggerSchedulerError.musicalAlreadyPrepared }
        timeline = try MusicalTimeline(sample: baseline, anchor: setup.anchor, map: setup.map, loop: setup.loop,
                                       running: setup.running, historyLimit: setup.historyLimit,
                                       pinLimit: pinLimit, ledger: ledger)
    }

    mutating func observe(_ observation: MusicalObservation, at anchor: ClockAnchor,
                          sequence: UInt64, ledger: GenerationLedger) throws {
        guard var next = timeline else { throw TriggerSchedulerError.musicalContextRequired }
        try next.observe(observation, at: anchor, sequence: sequence, ledger: ledger)
        timeline = next
    }

    /// Delegates restart/locate derivation to the timeline, which keeps its old history until then.
    mutating func reset(_ reset: SchedulerMusicalReset, baseline: SampleClockMap,
                        ledger: GenerationLedger) throws {
        guard var next = timeline else { throw TriggerSchedulerError.musicalContextRequired }
        try next.reset(sample: baseline, anchor: reset.anchor, map: reset.map,
                       sequence: reset.sequence, ledger: ledger)
        timeline = next
    }

    /// Freshness the timeline's projection does not check: the producer's sequence and every
    /// current sample/transport/map identity, generation and rate. Never falls back to older state.
    func current(_ context: TriggerSchedulerContext) throws -> MusicalTimeline {
        guard let timeline, let sequence = context.musicalSequence else {
            throw TriggerSchedulerError.musicalContextRequired
        }
        let ledger = context.ledger
        let sample = timeline.sample.anchor.sample
        let clock = timeline.currentClock
        guard sequence == timeline.observationSequence, !ledger.hasRestartObligations,
              ledger.nominalRate == timeline.sample.nominalRate,
              ledger.primaryClock == GenerationKey(.sampleClock, sample.clock),
              ledger.generation(ledger.primaryClock) == sample.generation,
              ledger.musicalClock == clock.map.clock,
              ledger.generation(GenerationKey(.transport, clock.map.clock)) == clock.musical.transport,
              ledger.generation(GenerationKey(.musicalMap, clock.map.clock)) == clock.map.revision else {
            throw TriggerSchedulerError.staleMusicalContext
        }
        return timeline
    }

    /// Origin conversion uses the scheduler clock's latest PHYSICAL anchor; coverage stays the
    /// timeline's own recorded history. Every refusal, including uncovered origins and missing
    /// history, is atomic; only an empty loop admits pinlessly.
    mutating func admit(_ stamp: TriggerStamp, context: TriggerSchedulerContext,
                        latestPrimary: ClockAnchor?) throws -> SchedulerMusicalAdmission {
        var next = try current(context)
        guard let latestPrimary else { throw SchedulerClockError.notReady }
        let origin = try next.origin(at: stamp.originHost, latestPrimary: latestPrimary)
        // The named pass is checked before any loop extrapolation; a mismatch is never re-based.
        guard origin.clock.musical.loopIteration == stamp.loopIteration else {
            throw TriggerSchedulerError.musicalPassMismatch
        }
        let target: MusicalTarget
        switch stamp.target {
        case .grid(let ticks): target = .grid(ticks)
        case .musical(let ticks): target = .absolute(ticks)
        case .sample, .asap: throw TriggerSchedulerError.musicalContextRequired
        }
        do {
            let pin = try next.reserve(target, origin: origin, retroactiveMs: stamp.retroactiveMs)
            timeline = next
            return .pinned(pin)
        } catch MusicalTimingError.outsideLoop {
            return .outsideLoop
        }
    }

    /// Projects through the timeline only after the current-context check; never re-quantizes.
    /// Projection errors propagate non-consumingly; the caller publishes nothing on a throw.
    func resolve(_ admission: SchedulerMusicalAdmission?,
                 context: TriggerSchedulerContext) throws -> SchedulerMusicalResolution {
        let timeline: MusicalTimeline
        do {
            timeline = try current(context)
        } catch TriggerSchedulerError.musicalContextRequired, TriggerSchedulerError.staleMusicalContext {
            return .missingContext
        }
        switch admission {
        case nil:
            // Unreachable: captured-ready musical work is always admitted. Fail closed.
            return .missingContext
        case .outsideLoop:
            return .outsideLoop(timeline.currentClock.map.revision)
        case .pinned(let pin):
            guard timeline.isRunning else { return .stopped }
            return .projected(try timeline.project(pin))
        }
    }

    /// Stateless boundary selection is the timeline's (`nextBoundary(at:grid:)`); only the
    /// current-context check is added here. Other timeline refusals propagate non-consumingly.
    func fallback(at frame: Int64, grid: Int64,
                  context: TriggerSchedulerContext) throws -> SchedulerMusicalFallback {
        let timeline: MusicalTimeline
        do {
            timeline = try current(context)
        } catch TriggerSchedulerError.musicalContextRequired, TriggerSchedulerError.staleMusicalContext {
            return .missingContext
        }
        guard timeline.isRunning else { return .stopped }
        do {
            return .projected(try timeline.nextBoundary(at: frame, grid: grid))
        } catch MusicalTimingError.outsideLoop {
            return .outsideLoop(timeline.currentClock.map.revision)
        }
    }

    /// Releases a pending admission's pin, if any, IN PLACE on this staged copy (no per-pin timeline
    /// copy); the timeline validates the pin before its only mutation, and callers discard the copy on throw.
    mutating func release(_ admission: SchedulerMusicalAdmission?) throws {
        guard case .pinned(let pin) = admission else { return }
        guard timeline != nil else { throw MusicalTimingError.invalidPin }
        try timeline?.release(pin)
    }
}
