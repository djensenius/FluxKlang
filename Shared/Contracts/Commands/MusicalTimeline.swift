import Foundation

/// Every observation comes from one exhaustive, ordered host control-plane producer.
/// These values grant no authority. Same-frame transitions are ordered by sequence.
enum MusicalObservation: Sendable {
    case primary
    case musical
    case running(Bool)
    case map(MusicalMap)
    case loop(LoopRange?)
    case wrap
}

/// Cannot be constructed outside this file; possession is not an engine lease.
struct MusicalOrigin: Sendable {
    fileprivate let instance: UUID
    fileprivate let epoch: UUID
    fileprivate let record: UUID
    let frame: Int64
    let exactFrame: MusicalFrame
    let clock: MusicalClockMap
    let loop: LoopRange?
    let isRunning: Bool
}

/// A bounded reservation. Release at terminal resolution/cancellation, not outcome drain.
struct MusicalPin: Hashable, Sendable {
    fileprivate let instance: UUID
    fileprivate let epoch: UUID
    fileprivate let id: UUID
    let occurrence: MusicalOccurrence
}

private struct TimelineState: Sendable {
    var primary: ClockAnchor
    var clock: MusicalClockMap
    var loop: LoopRange?
    var running: Bool
}

private struct TimelineRecord: Sendable {
    let id = UUID()
    let state: TimelineState
}

private struct TimelineReservation: Sendable {
    let occurrence: MusicalOccurrence
    var originalTicks: Int64
    var pass: Int128
    var anchor: ClockAnchor?
}

/// Bounded, off-render reference history. Value copies are snapshots of the SAME logical instance:
/// they are not independent producers or shared revocation authorities. The owner must not fork writers.
/// Storage counts are historyLimit records + pinLimit reservations + constant first/current state.
/// There is no implicit time-retention promise and no eager allocation proportional to either limit.
struct MusicalTimeline: Sendable {
    let historyLimit: Int
    let pinLimit: Int
    private(set) var sample: SampleClockMap
    private(set) var firstMusicalAnchor: ClockAnchor
    private(set) var observationSequence: UInt64 = 0
    private var instance = UUID()
    private var epoch = UUID()
    private var state: TimelineState
    private var records: [TimelineRecord]
    private var reservations: [UUID: TimelineReservation] = [:]

    var historyCount: Int { records.count }
    var pinCount: Int { reservations.count }
    var isQuiescent: Bool { reservations.isEmpty }
    var isRunning: Bool { state.running }
    var latestPrimary: ClockAnchor { state.primary }
    var currentClock: MusicalClockMap { state.clock }
    var currentLoop: LoopRange? { state.loop }

    init(sample: SampleClockMap, anchor: ClockAnchor, map: MusicalMap, loop: LoopRange? = nil,
         running: Bool, historyLimit: Int, pinLimit: Int, ledger: GenerationLedger) throws {
        guard historyLimit > 0, pinLimit >= 0 else { throw MusicalTimingError.invalidBudget }
        if case .afterRestart = ledger.resume { throw MusicalTimingError.historyUnavailable }
        let clock = try Self.initialClock(sample: sample, anchor: anchor, map: map, ledger: ledger, restartTicks: nil)
        let initial = TimelineState(primary: anchor, clock: clock, loop: loop, running: running)
        self.sample = sample
        self.firstMusicalAnchor = anchor
        self.historyLimit = historyLimit
        self.pinLimit = pinLimit
        self.state = initial
        self.records = [TimelineRecord(state: initial)]
    }

    /// A failed observation changes no sequence, coverage, history, summaries or pins.
    mutating func observe(_ observation: MusicalObservation, at anchor: ClockAnchor,
                          sequence: UInt64, ledger: GenerationLedger) throws {
        try checkSequence(sequence)
        try checkLedger(ledger, map: state.clock.map, changingMap: observation)
        guard sample.agrees(anchor) else { throw MusicalTimingError.invalidContext }
        guard anchor.sample.frame >= state.primary.sample.frame, anchor.host.ticks >= state.primary.host.ticks else {
            throw MusicalTimingError.timeRegressed
        }
        var candidate = self
        try candidate.apply(observation, anchor: anchor)
        try candidate.refreshReservations()
        candidate.observationSequence = sequence
        candidate.records.append(TimelineRecord(state: candidate.state))
        if candidate.records.count > historyLimit { candidate.records.removeFirst() }
        self = candidate
    }

    /// A host origin uses the retained primary mapping in effect there, not the newest primary anchor.
    func origin(at host: HostStamp) throws -> MusicalOrigin {
        guard let first = records.first, host.ticks >= first.state.primary.host.ticks,
              host.ticks <= state.primary.host.ticks,
              let record = records.last(where: { $0.state.primary.host.ticks <= host.ticks }) else {
            throw MusicalTimingError.uncoveredOrigin
        }
        let mapping = try SampleClockMap(anchor: record.state.primary, nominalRate: sample.nominalRate,
                                         timebase: sample.timebase)
        return try origin(at: MusicalFrame(host: host, through: mapping))
    }

    /// Only actual recorded coverage is eligible. Future projection is not origin coverage.
    func origin(atFrame frame: Int64) throws -> MusicalOrigin {
        try origin(at: MusicalFrame(frame))
    }

    private func origin(at frame: MusicalFrame) throws -> MusicalOrigin {
        guard let first = records.first, frame >= MusicalFrame(first.state.primary.sample.frame),
              frame <= MusicalFrame(state.primary.sample.frame),
              let record = records.last(where: { MusicalFrame($0.state.primary.sample.frame) <= frame }) else {
            throw MusicalTimingError.uncoveredOrigin
        }
        return try MusicalOrigin(instance: instance, epoch: epoch, record: record.id, frame: frame.rounded(),
                                 exactFrame: frame, clock: record.state.clock, loop: record.state.loop,
                                 isRunning: record.state.running)
    }

    /// Ready absolute and grid targets both require an authenticated, still-covered origin.
    /// The caller checks readiness/freshness first; this component does not validate unrelated sample/ASAP targets.
    mutating func reserve(_ target: MusicalTarget, origin: MusicalOrigin,
                          retroactiveMs: Int = 0) throws -> MusicalPin {
        guard origin.instance == instance, origin.epoch == epoch,
              records.contains(where: { $0.id == origin.record }) else { throw MusicalTimingError.expiredOrigin }
        guard pinCount < pinLimit else { throw MusicalTimingError.pinCapacity }
        guard (0...120).contains(retroactiveMs) else { throw MusicalTimingError.invalidTarget }
        let occurrence = try select(target, origin: origin, retroactiveMs: retroactiveMs)
        let value = try prepare(occurrence)
        let pin = MusicalPin(instance: instance, epoch: epoch, id: UUID(), occurrence: occurrence)
        reservations[pin.id] = value
        return pin
    }

    func project(_ pin: MusicalPin) throws -> MusicalProjection {
        let reservation = try reservation(for: pin)
        guard isRunning else { throw MusicalTimingError.stopped }
        let currentPass = Int128(state.clock.musical.loopIteration)
        let frame = try MusicalTiming.narrow(MusicalTiming.rounded(projectedUnits(reservation)))
        return MusicalProjection(occurrence: pin.occurrence, frame: frame, musicalMap: state.clock.map.revision,
                                 assumesFuture: reservation.pass > currentPass || frame > state.primary.sample.frame)
    }

    /// Stateless late fallback on current running context; no lifecycle or lateness policy is applied here.
    func nextBoundary(at frame: Int64, grid: Int64) throws -> MusicalProjection {
        guard isRunning else { throw MusicalTimingError.stopped }
        guard frame >= state.primary.sample.frame else { throw MusicalTimingError.uncoveredOrigin }
        let occurrence = try MusicalTiming.nextBoundary(at: frame, grid: grid, clock: state.clock, loop: state.loop)
        let pass = try MusicalTiming.projectionPass(occurrence, loop: state.loop,
                                                   anchorTicks: state.clock.musical.ticks)
        let assigned = try MusicalTiming.frame(of: occurrence, from: state.clock, loop: state.loop)
        return MusicalProjection(occurrence: occurrence, frame: assigned, musicalMap: state.clock.map.revision,
                                 assumesFuture: pass > Int128(state.clock.musical.loopIteration)
                                     || assigned > state.primary.sample.frame)
    }

    mutating func release(_ pin: MusicalPin) throws {
        _ = try reservation(for: pin)
        reservations.removeValue(forKey: pin.id)
    }

    /// Explicit quiescent retention boundary. Genuine first anchors survive; old origin tokens do not.
    mutating func rotate() throws {
        guard isQuiescent else { throw MusicalTimingError.pinsOutstanding }
        epoch = UUID()
        records = [TimelineRecord(state: state)]
    }

    /// A discontinuous clock/transport epoch requires terminal cancellation and pin release first.
    /// Restart resume ticks are derived from covered OLD history, never supplied as an unverified hint.
    /// Run state and loop are retained; changing either requires its own ordered observation.
    mutating func reset(sample: SampleClockMap, anchor: ClockAnchor, map: MusicalMap,
                        sequence: UInt64, ledger: GenerationLedger) throws {
        guard isQuiescent else { throw MusicalTimingError.pinsOutstanding }
        try checkSequence(sequence)
        guard sample.anchor.sample.clock == self.sample.anchor.sample.clock, map.clock == state.clock.map.clock else {
            throw MusicalTimingError.invalidContext
        }
        guard sample.anchor.sample.generation != self.sample.anchor.sample.generation
                || anchor.musical?.transport != state.clock.musical.transport else {
            throw MusicalTimingError.invalidTransition
        }
        guard anchor.host.ticks >= state.primary.host.ticks else { throw MusicalTimingError.timeRegressed }
        if sample.anchor.sample.generation == self.sample.anchor.sample.generation {
            guard sample == self.sample else { throw MusicalTimingError.invalidContext }
            guard anchor.sample.frame >= state.primary.sample.frame else { throw MusicalTimingError.timeRegressed }
        }
        var restartTicks: Int64?
        if case .afterRestart(let frame) = ledger.resume {
            let origin = try self.origin(atFrame: frame)
            let oldClock = try MusicalTiming.reanchor(origin.clock.anchor, using: state.clock)
            let ticks = try origin.isRunning ? oldClock.ticks(atFrame: frame) : oldClock.musical.ticks
            restartTicks = origin.loop?.endTicks == ticks ? origin.loop?.startTicks : ticks
        }
        let clock = try Self.initialClock(sample: sample, anchor: anchor, map: map,
                                         ledger: ledger, restartTicks: restartTicks)
        let initial = TimelineState(primary: anchor, clock: clock, loop: state.loop, running: state.running)
        self.sample = sample
        firstMusicalAnchor = anchor
        state = initial
        records = [TimelineRecord(state: initial)]
        epoch = UUID()
        observationSequence = sequence
    }

    private func reservation(for pin: MusicalPin) throws -> TimelineReservation {
        guard pin.instance == instance, pin.epoch == epoch, let value = reservations[pin.id],
              value.occurrence == pin.occurrence else { throw MusicalTimingError.invalidPin }
        return value
    }

    private func runningAnchor(for pass: Int128) -> ClockAnchor? {
        if state.running, Int128(state.clock.musical.loopIteration) == pass { return state.clock.anchor }
        if let record = records.last(where: {
            $0.state.running && Int128($0.state.clock.musical.loopIteration) == pass
        }) { return record.state.clock.anchor }
        return reservations.values.first(where: { $0.pass == pass && $0.anchor != nil })?.anchor
    }

    private func select(_ target: MusicalTarget, origin: MusicalOrigin,
                        retroactiveMs: Int) throws -> MusicalOccurrence {
        // The record selects the actual origin anchor/pass, not an old map revision or a virtual pass.
        let currentOrigin = try MusicalOrigin(
            instance: instance, epoch: epoch, record: origin.record, frame: origin.frame, exactFrame: origin.exactFrame,
            clock: MusicalTiming.reanchor(origin.clock.anchor, using: state.clock),
            loop: state.loop, isRunning: origin.isRunning
        )
        let choices = try MusicalTiming.candidates(for: target, origin: currentOrigin)
        guard retroactiveMs > 0, let prior = choices.previous, case .grid(let grid) = target else {
            return try choices.forward.get()
        }
        let frame = origin.isRunning ? origin.exactFrame : MusicalFrame(origin.clock.anchor.sample.frame)
        guard let previous = try projectedPrevious(prior, at: frame, grid: grid) else {
            return try choices.forward.get()
        }
        if case .success(let forward) = choices.forward, previous.occurrence == forward { return forward }
        return try MusicalTiming.isRetroactive(previous.units, at: frame, milliseconds: retroactiveMs,
                                               rate: sample.nominalRate) ? previous.occurrence : choices.forward.get()
    }

    private func prepare(_ occurrence: MusicalOccurrence, retaining ticks: Int64? = nil) throws -> TimelineReservation {
        guard state.loop?.admits(ticks: occurrence.ticks) ?? true else { throw MusicalTimingError.outsideLoop }
        let current = Int128(state.clock.musical.loopIteration)
        let originalTicks: Int64
        if let value = runningAnchor(for: occurrence.pass)?.musical?.ticks {
            originalTicks = value
        } else if let ticks {
            originalTicks = ticks
        } else if occurrence.pass == current {
            originalTicks = state.clock.musical.ticks
        } else if occurrence.pass > current, let loop = state.loop, state.clock.musical.ticks <= loop.endTicks {
            originalTicks = loop.startTicks
        } else { throw MusicalTimingError.historyUnavailable }
        let pass = try MusicalTiming.projectionPass(occurrence, loop: state.loop, anchorTicks: originalTicks)
        let anchor = runningAnchor(for: pass)
        guard pass >= current || anchor != nil else { throw MusicalTimingError.historyUnavailable }
        return TimelineReservation(occurrence: occurrence, originalTicks: originalTicks, pass: pass, anchor: anchor)
    }

    private func projectedUnits(_ value: TimelineReservation) throws -> Int128 {
        let clock: MusicalClockMap
        if let anchor = value.anchor {
            clock = try MusicalTiming.reanchor(anchor, using: state.clock)
        } else {
            guard value.pass >= Int128(state.clock.musical.loopIteration) else {
                throw MusicalTimingError.historyUnavailable
            }
            clock = state.clock
        }
        let ticks: Int64? = value.pass == value.occurrence.pass ? value.occurrence.ticks : state.loop?.startTicks
        guard let ticks else { throw MusicalTimingError.invalidContext }
        return try MusicalTiming.projectedUnits(of: MusicalOccurrence(pass: value.pass, ticks: ticks),
                                                from: clock, loop: state.loop)
    }

    private func projectedPrevious(_ initial: MusicalOccurrence, at frame: MusicalFrame, grid: Int64)
        throws -> (occurrence: MusicalOccurrence, units: Int128)? {
        var candidate: MusicalOccurrence? = initial
        // Invert within a pass, then visit only retained pass summaries, never individual grid ticks.
        for _ in 0..<(records.count + reservations.count + 2) {
            guard let previous = candidate else { return nil }
            let value = try prepare(previous)
            let units = try projectedUnits(value)
            if MusicalFrame(units: units) <= frame { return (previous, units) }
            let clock: MusicalClockMap
            if let anchor = runningAnchor(for: previous.pass) {
                clock = try MusicalTiming.reanchor(anchor, using: state.clock)
            } else {
                guard previous.pass == Int128(state.clock.musical.loopIteration) else {
                    throw MusicalTimingError.historyUnavailable
                }
                clock = state.clock
            }
            let bounds = try MusicalTiming.gridBounds(at: frame, grid: grid, clock: clock)
            candidate = MusicalTiming.previousBoundary(pass: previous.pass,
                ticks: min(bounds.previous, Int128(previous.ticks) - 1), grid: grid, loop: state.loop)
        }
        throw MusicalTimingError.historyUnavailable
    }

    private mutating func refreshReservations() throws {
        for (id, old) in reservations {
            reservations[id] = try prepare(old.occurrence, retaining: old.originalTicks)
        }
    }

    private func checkSequence(_ sequence: UInt64) throws {
        let (next, overflow) = observationSequence.addingReportingOverflow(1)
        guard !overflow else { throw MusicalTimingError.overflow }
        guard sequence == next else { throw MusicalTimingError.observationGap }
    }
}

private extension MusicalTimeline {
    static func initialClock(sample: SampleClockMap, anchor: ClockAnchor, map: MusicalMap,
                             ledger: GenerationLedger, restartTicks: Int64?) throws -> MusicalClockMap {
        guard !ledger.hasRestartObligations, ledger.nominalRate == sample.nominalRate,
              GenerationKey(.sampleClock, sample.anchor.sample.clock) == ledger.primaryClock,
              sample.anchor.sample.generation == ledger.generation(ledger.primaryClock),
              map.clock == ledger.musicalClock,
              map.revision == ledger.generation(GenerationKey(.musicalMap, map.clock)),
              sample.agrees(anchor), let position = anchor.musical, position.ticks >= 0,
              position.loopIteration == 0,
              position.musicalMap == map.revision,
              position.transport == ledger.generation(GenerationKey(.transport, map.clock)) else {
            throw MusicalTimingError.invalidContext
        }
        if ledger.pendingRestart != nil,
           !ledger.acceptsFirstAnchor(sample.anchor, nominalRate: sample.nominalRate, timebase: sample.timebase) {
            throw MusicalTimingError.invalidContext
        }
        if case .locate(let ticks) = ledger.resume, position.ticks != ticks {
            throw MusicalTimingError.invalidContext
        }
        if case .afterRestart = ledger.resume, restartTicks != position.ticks {
            throw MusicalTimingError.invalidContext
        }
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: sample.nominalRate,
                                   currentSample: sample.anchor.sample.generation, currentTransport: position.transport)
    }

    func checkLedger(_ ledger: GenerationLedger, map: MusicalMap, changingMap event: MusicalObservation) throws {
        let revision: Generation
        if case .map(let replacement) = event { revision = replacement.revision } else { revision = map.revision }
        guard !ledger.hasRestartObligations, ledger.nominalRate == sample.nominalRate,
              ledger.primaryClock == GenerationKey(.sampleClock, sample.anchor.sample.clock),
              ledger.generation(ledger.primaryClock) == sample.anchor.sample.generation,
              ledger.musicalClock == map.clock,
              ledger.generation(GenerationKey(.transport, map.clock)) == state.clock.musical.transport,
              ledger.generation(GenerationKey(.musicalMap, map.clock)) == revision else {
            throw MusicalTimingError.invalidContext
        }
    }

    mutating func apply(_ event: MusicalObservation, anchor: ClockAnchor) throws {
        let wrapping: Bool = if case .wrap = event { true } else { false }
        if !wrapping { try checkCoverage(to: anchor.sample.frame) }
        try checkAnchor(anchor, for: event)
        switch event {
        case .primary:
            break
        case .musical:
            state.clock = try MusicalTiming.reanchor(anchor, using: state.clock)
        case .running(let running):
            guard running != state.running else { throw MusicalTimingError.invalidTransition }
            state.clock = try MusicalTiming.reanchor(anchor, using: state.clock)
            state.running = running
        case .wrap:
            state.clock = try MusicalTiming.reanchor(anchor, using: state.clock)
        case .map(let map):
            try replaceMap(map)
        case .loop(let loop):
            state.loop = loop
        }
        state.primary = anchor
        if !wrapping { try checkCoverage(to: anchor.sample.frame) }
    }

    func checkCoverage(to frame: Int64) throws {
        if state.running, let loop = state.loop, state.clock.musical.ticks <= loop.endTicks,
           try Int128(frame) >= MusicalTiming.wrapFrame(state.clock, loop: loop) {
            throw MusicalTimingError.missingWrap
        }
    }

    mutating func replaceMap(_ map: MusicalMap) throws {
        guard map.clock == state.clock.map.clock, map.revision == (try state.clock.map.revision.next()) else {
            throw MusicalTimingError.invalidTransition
        }
        state.clock = try MusicalClockMap(anchor: state.clock.anchor, map: map, nominalRate: sample.nominalRate,
                                          currentSample: sample.anchor.sample.generation,
                                          currentTransport: state.clock.musical.transport)
    }

    func checkAnchor(_ anchor: ClockAnchor, for event: MusicalObservation) throws {
        switch event {
        case .primary:
            guard anchor.musical == nil else { throw MusicalTimingError.invalidTransition }
            guard anchor.sample.frame > state.primary.sample.frame, anchor.host.ticks > state.primary.host.ticks else {
                throw MusicalTimingError.timeRegressed
            }
        case .map, .loop:
            guard anchor.musical == nil else { throw MusicalTimingError.invalidTransition }
        case .musical, .running:
            try checkPosition(anchor, wrapping: false)
        case .wrap:
            try checkPosition(anchor, wrapping: true)
        }
    }

    func checkPosition(_ anchor: ClockAnchor, wrapping: Bool) throws {
        guard let position = anchor.musical, position.ticks >= 0,
              position.musicalMap == state.clock.map.revision,
              position.transport == state.clock.musical.transport else { throw MusicalTimingError.invalidContext }
        if wrapping {
            guard state.running, let loop = state.loop,
                  state.clock.musical.ticks <= loop.endTicks,
                  Int128(position.loopIteration) == Int128(state.clock.musical.loopIteration) + 1,
                  position.ticks == loop.startTicks,
                  try Int128(anchor.sample.frame) == MusicalTiming.wrapFrame(state.clock, loop: loop) else {
                throw MusicalTimingError.invalidTransition
            }
        } else {
            guard position.loopIteration == state.clock.musical.loopIteration else {
                throw MusicalTimingError.invalidTransition
            }
            if state.running {
                let expected = state.clock.exactTicks(atFrame: anchor.sample.frame)
                let error = Int128(position.ticks) * expected.denominator - expected.numerator
                guard error.magnitude <= expected.denominator.magnitude else {
                    throw MusicalTimingError.invalidTransition
                }
            } else if position.ticks != state.clock.musical.ticks {
                throw MusicalTimingError.invalidTransition
            }
        }
    }
}
