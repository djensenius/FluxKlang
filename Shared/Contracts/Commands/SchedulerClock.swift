//
//  SchedulerClock.swift
//  FluxKlang
//
//  Inert primary-clock state for future scheduling; no engine or session ownership.
//

/// Other validation failures reuse ClockMapError's sample-generation, rate and timebase errors.
enum SchedulerClockError: Error, Equatable, Sendable {
    case unavailablePrimaryClock
    case primaryClockMismatch
    case declarationChanged
    case restartIncomplete
    case invalidAnchor
    case regressingHorizon
    case notReady
}

/// A single-owner control-plane value with constant retained state. Ledger arguments
/// must be the owner's CURRENT trusted snapshots, not caller-supplied authority proofs.
/// Every throwing mutator publishes only after validation; copies may be staged with
/// a larger transaction. No generation history, synchronization, persistence, musical
/// timing or activation is provided here.
struct SchedulerClock: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let generation: Generation
        let nominalRate: Int
        fileprivate(set) var baseline: SampleClockMap?
        fileprivate(set) var latestAnchor: ClockAnchor?
        fileprivate(set) var horizon: SampleStamp?

        fileprivate mutating func includeFloor(_ stamp: SampleStamp) {
            if let horizon, horizon.frame >= stamp.frame { return }
            horizon = stamp
        }
    }

    let primaryClock: GenerationKey
    /// Process-wide and immutable, including across sample-generation changes.
    let timebase: HostTimebase
    private var state: Snapshot

    init(ledger: GenerationLedger, timebase: HostTimebase) throws {
        guard timebase.numer > 0, timebase.denom > 0 else { throw ClockMapError.invalidTimebase }
        guard ledger.primaryClock.kind == .sampleClock,
              let generation = ledger.generation(ledger.primaryClock) else {
            throw SchedulerClockError.unavailablePrimaryClock
        }
        guard MediaNominalRate.isValid(ledger.nominalRate) else {
            throw ClockMapError.invalidRate(ledger.nominalRate)
        }
        primaryClock = ledger.primaryClock
        self.timebase = timebase
        state = Snapshot(generation: generation, nominalRate: ledger.nominalRate)
    }

    /// A read-only current-generation view; querying never publishes a generation change.
    /// An unseen generation has no baseline, observation or floor. Use requireReady
    /// separately before firing; a floor or matching generation is not re-anchoring.
    func snapshot(ledger: GenerationLedger) throws -> Snapshot {
        guard ledger.primaryClock == primaryClock else { throw SchedulerClockError.primaryClockMismatch }
        guard let generation = ledger.generation(primaryClock) else {
            throw SchedulerClockError.unavailablePrimaryClock
        }
        guard MediaNominalRate.isValid(ledger.nominalRate) else {
            throw ClockMapError.invalidRate(ledger.nominalRate)
        }
        guard generation == state.generation else {
            return Snapshot(generation: generation, nominalRate: ledger.nominalRate)
        }
        guard ledger.nominalRate == state.nominalRate else { throw SchedulerClockError.declarationChanged }
        return state
    }

    /// The latest independently validated physical mapping, only when currently ready.
    /// The snapshot's baseline, not this latest mapping, remains the drift reference.
    func requireReady(ledger: GenerationLedger) throws -> SampleClockMap {
        let current = try snapshot(ledger: ledger)
        guard !ledger.hasRestartObligations else { throw SchedulerClockError.restartIncomplete }
        guard current.baseline != nil, let latest = current.latestAnchor else { throw SchedulerClockError.notReady }
        return try SampleClockMap(anchor: latest, nominalRate: current.nominalRate, timebase: timebase)
    }

    /// Observations need not reach an arrival/commit floor, but cannot regress the
    /// latest actual observation or drift from the genuine first/restart baseline.
    /// Musical payload is neither validated nor retained.
    mutating func observe(_ anchor: ClockAnchor, nominalRate: Int, timebase: HostTimebase,
                          ledger: GenerationLedger) throws {
        var next = try snapshot(ledger: ledger)
        try validate(anchor.sample, in: next)
        try validate(nominalRate, in: next)
        guard timebase.numer > 0, timebase.denom > 0 else { throw ClockMapError.invalidTimebase }
        guard timebase == self.timebase else { throw SchedulerClockError.declarationChanged }
        guard !ledger.hasRestartObligations else { throw SchedulerClockError.restartIncomplete }
        let physical = ClockAnchor(sample: anchor.sample, host: anchor.host)
        if let baseline = next.baseline {
            guard let latest = next.latestAnchor,
                  physical.sample.frame >= latest.sample.frame, physical.host.ticks >= latest.host.ticks,
                  baseline.agrees(physical) else { throw SchedulerClockError.invalidAnchor }
        } else if next.generation == .initial, ledger.pendingRestart == nil {
            next.baseline = try SampleClockMap(anchor: physical, nominalRate: nominalRate, timebase: timebase)
        } else {
            guard ledger.pendingRestart == next.generation, let record = ledger.restartRecord else {
                throw SchedulerClockError.restartIncomplete
            }
            guard ledger.acceptsFirstAnchor(physical, nominalRate: nominalRate, timebase: timebase) else {
                throw SchedulerClockError.invalidAnchor
            }
            let origin = ClockAnchor(sample: record.start, host: record.host)
            next.baseline = try SampleClockMap(anchor: origin, nominalRate: nominalRate, timebase: timebase)
        }
        next.latestAnchor = physical
        next.includeFloor(physical.sample)
        state = next
    }

    /// Records an already accepted current-primary arrival, not trigger admission.
    /// Lower current bounds are harmless; stale stamps throw without changing state.
    /// This is allowed before re-anchoring and never confers readiness.
    mutating func recordArrival(_ arrival: SampleStamp, ledger: GenerationLedger) throws {
        var next = try snapshot(ledger: ledger)
        try validate(arrival, in: next)
        next.includeFloor(arrival)
        state = next
    }

    /// Validates/advances independently of readiness, permitting cancellation checks
    /// during an incomplete restart. Firing must separately requireReady.
    mutating func advanceHorizon(_ horizon: SampleStamp, nominalRate: Int, ledger: GenerationLedger) throws {
        var next = try snapshot(ledger: ledger)
        try validate(horizon, in: next)
        try validate(nominalRate, in: next)
        if let floor = next.horizon, horizon.frame < floor.frame { throw SchedulerClockError.regressingHorizon }
        next.includeFloor(horizon)
        state = next
    }

    private func validate(_ stamp: SampleStamp, in snapshot: Snapshot) throws {
        guard GenerationKey(.sampleClock, stamp.clock) == primaryClock else {
            throw SchedulerClockError.primaryClockMismatch
        }
        guard stamp.generation == snapshot.generation else { throw ClockMapError.staleSampleGeneration }
    }

    private func validate(_ nominalRate: Int, in snapshot: Snapshot) throws {
        guard MediaNominalRate.isValid(nominalRate), nominalRate == snapshot.nominalRate else {
            throw ClockMapError.invalidRate(nominalRate)
        }
    }
}
