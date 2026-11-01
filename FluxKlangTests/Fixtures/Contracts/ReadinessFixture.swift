//
//  ReadinessFixture.swift
//  FluxKlangTests
//
//  A generation ledger and action readiness built through the real contract
//  APIs, so each fixture state is reached by legal transitions only.
//

@testable import FluxKlang

/// Why a readiness fixture could not be built.
enum ReadinessFixtureError: Error, Equatable, Sendable {
    case ledger(GenerationLedgerError)
    case readiness(ReadinessError)
    case ids(FixtureIDSequenceError)
}

/// One ledger and one readiness store for the fixed fixture graph.
///
/// The ledger has the primary and musical fixture clocks at 48 kHz and declares
/// the `source` counter of `fx.stream` and the `context` counter of `fx.host`.
/// What `make` leaves for `ContractFixtureIDs.action`:
/// - `available`: `ready` against the current generations, so it is current.
/// - `missing`: never prepared (`unprepared`, no reason).
/// - `stale`: was ready, then `fx.stream` was lost (source generation 2); the
///   readiness was notified, so it is `invalidated` with `sourceChanged`. It is
///   never the ready-but-unnotified case; build that by bumping the ledger alone.
/// - `failed`: `failed` with `preparationFailed`; the ledger is untouched.
/// - `pressured`: `ready` as in `available`, and the store also holds
///   `fx.pressure.1…4095` in `preparing`, so it is at its 4096-action limit and
///   refuses any new action with `capacity`. F5's `readinessAtCapacity` should
///   reuse `make(.pressured)` rather than build a second full store.
struct ReadinessFixture: Sendable {
    /// The action store limit of `ActionReadiness`.
    static var readinessCapacity: Int { 4_096 }
    static var nominalRate: Int { 48_000 }
    static let sourceKey = GenerationKey(.source, ContractFixtureIDs.stream)
    static let contextKey = GenerationKey(.context, ContractFixtureIDs.host)
    static let primaryKey = GenerationKey(.sampleClock, ContractFixtureIDs.primaryClock)
    /// Every fixture action is prepared against these counters, in this order.
    static let dependencyKeys = [primaryKey, sourceKey, contextKey]

    var ledger: GenerationLedger
    var readiness: ActionReadiness

    static func make(_ state: ContractFixtureState) throws(ReadinessFixtureError) -> Self {
        var fixture = try fresh()
        let action = ContractFixtureIDs.action
        switch state {
        case .missing:
            break
        case .available:
            try fixture.prepareReady(action)
        case .stale:
            try fixture.prepareReady(action)
            do { try fixture.ledger.bump(sourceKey, reason: .sourceLost) } catch { throw .ledger(error) }
            fixture.readiness.generationChanged(sourceKey)
        case .failed:
            try fixture.apply { readiness throws(ReadinessError) in
                try readiness.transition(action, to: .preparing)
                try readiness.transition(action, to: .failed, reason: .preparationFailed)
            }
        case .pressured:
            try fixture.prepareReady(action)
            try fixture.fillToCapacity()
        }
        return fixture
    }

    /// The current generation of every dependency key. `action` is accepted only
    /// to match the planned signature: every fixture action shares the same
    /// dependencies. The ledger declares every key, so the result always has
    /// `dependencyKeys.count` entries.
    func requirements(for action: ActionID) -> [GenerationRequirement] {
        Self.dependencyKeys.compactMap { key in
            ledger.generation(key).map { GenerationRequirement(key: key, generation: $0) }
        }
    }

    /// The observable state, for comparing fixtures and proving refusals changed nothing.
    var snapshot: Snapshot {
        Snapshot(
            states: readiness.states,
            reasons: readiness.reasons,
            readyEntries: readiness.states.keys.reduce(into: [:]) { $0[$1] = readiness.readyEntry($1) },
            current: readiness.states.keys.filter { readiness.isCurrent($0, ledger: ledger) },
            generations: ledger.current,
            pendingRestart: ledger.pendingRestart
        )
    }

    struct Snapshot: Hashable, Sendable {
        let states: [ActionID: ReadinessState]
        let reasons: [ActionID: ReadinessReason]
        let readyEntries: [ActionID: Int]
        let current: Set<ActionID>
        let generations: [GenerationKey: Generation]
        let pendingRestart: Generation?

        init(
            states: [ActionID: ReadinessState], reasons: [ActionID: ReadinessReason], readyEntries: [ActionID: Int],
            current: some Sequence<ActionID>, generations: [GenerationKey: Generation], pendingRestart: Generation?
        ) {
            self.states = states
            self.reasons = reasons
            self.readyEntries = readyEntries
            self.current = Set(current)
            self.generations = generations
            self.pendingRestart = pendingRestart
        }
    }

    private static func fresh() throws(ReadinessFixtureError) -> Self {
        do {
            let ledger = try GenerationLedger(
                primaryClock: ContractFixtureIDs.primaryClock, musicalClock: ContractFixtureIDs.musicalClock,
                nominalRate: nominalRate, declaring: [sourceKey, contextKey]
            )
            return Self(ledger: ledger, readiness: ActionReadiness())
        } catch {
            throw .ledger(error)
        }
    }

    private mutating func apply(
        _ change: (inout ActionReadiness) throws(ReadinessError) -> Void
    ) throws(ReadinessFixtureError) {
        do { try change(&readiness) } catch { throw .readiness(error) }
    }

    private mutating func prepareReady(_ action: ActionID) throws(ReadinessFixtureError) {
        let requirements = requirements(for: action)
        let ledger = ledger
        try apply { readiness throws(ReadinessError) in
            try readiness.transition(action, to: .preparing)
            try readiness.markReady(action, preparedAgainst: requirements, ledger: ledger)
        }
    }

    private mutating func fillToCapacity() throws(ReadinessFixtureError) {
        let others = Self.readinessCapacity - readiness.states.count
        guard others > 0 else { return }
        var ids: FixtureIDSequence<ActionTag>
        do { ids = try FixtureIDSequence(prefix: "pressure", limit: others) } catch { throw .ids(error) }
        for _ in 0..<others {
            let id: ActionID
            do { id = try ids.next() } catch { throw .ids(error) }
            try apply { readiness throws(ReadinessError) in try readiness.transition(id, to: .preparing) }
        }
    }
}
