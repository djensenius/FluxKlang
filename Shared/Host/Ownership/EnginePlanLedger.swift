//
//  EnginePlanLedger.swift
//  FluxKlang
//
//  Pure, control-side ownership accounting. No engine operations are performed.
//

/// Opaque process-local identity. Strong retention prevents address reuse while
/// any identity survives; there is no global sequence or persistence format.
struct EngineInstanceID: Hashable, Sendable {
    private final class Identity: Sendable {}
    private let identity: Identity

    fileprivate init() { identity = Identity() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity === rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(identity)) }
}

/// Immutable, copyable reference to one owned plan, not a credential or security
/// capability. Equality includes instance, prepare attempt and prepared ID.
final class PlanBinding: Hashable, Sendable {
    let instance: EngineInstanceID
    let attempt: PrepareAttemptID
    let prepared: PreparedActivationID

    fileprivate init(instance: EngineInstanceID, attempt: PrepareAttemptID, prepared: PreparedActivationID) {
        self.instance = instance
        self.attempt = attempt
        self.prepared = prepared
    }

    static func == (lhs: PlanBinding, rhs: PlanBinding) -> Bool {
        lhs.instance == rhs.instance && lhs.attempt == rhs.attempt && lhs.prepared == rhs.prepared
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(instance)
        hasher.combine(attempt)
        hasher.combine(prepared)
    }
}

/// Ownership status at issue time only, not proof of the currently rendered
/// graph or continuing freshness. An engine port must supply its installed
/// project's exact binding; there is intentionally no raw-ID resident lookup.
struct CommittedResident: Hashable, Sendable {
    let binding: PlanBinding

    fileprivate init(binding: PlanBinding) { self.binding = binding }
}

enum EnginePlanPhase: Hashable, Sendable {
    case held
    /// Accepted ownership, not a statement about what is currently rendering.
    case committed
    case retiring
}

/// Qualified answer without changing the existing engine command vocabulary.
enum EnginePlanCompletion: Hashable, Sendable {
    case held(PlanBinding)
    case retiring(PlanBinding)
    /// Terminal failure attests that NO owned resource remains.
    case failed(instance: EngineInstanceID, attempt: PrepareAttemptID, reason: PrepareFailure)
}

/// Every refusal preserves the entire snapshot.
enum EnginePlanLedgerRefusal: Error, Hashable, Sendable {
    case invalidCapacity
    case unknownInstance
    case notCurrentInstance
    case duplicateAttempt
    case capacityReached
    case unknownAttempt
    case notPending
    case bindingMismatch
    case notHeld
    case notReclaimable
    case notRetiring
    case priorInstanceRetained
    case currentInstance
    case pendingPreparations
}

/// Inert observation, in instance/entry insertion order. Contains only immutable
/// data and identities, never a ledger or resource authority. May become stale.
struct EnginePlanLedgerSnapshot: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case pending(reclaim: Bool)
        case bound(PlanBinding, EnginePlanPhase)
    }

    struct Entry: Hashable, Sendable {
        let attempt: PrepareAttemptID
        let state: State
    }

    struct Record: Hashable, Sendable {
        let instance: EngineInstanceID
        let superseded: Bool
        let quiescent: Bool
        let entries: [Entry]
    }

    let capacity: Int
    let currentInstance: EngineInstanceID
    let records: [Record]
}

/// ONE canonical, deliberately non-Sendable control-side owner spanning a current
/// engine and at most one superseded engine. Reference aliases share state; no
/// cloning, restoration or from-snapshot API. Access must be serialized: Swift 6
/// can allow single-owner region transfers, but not unrestricted concurrent sharing.
///
/// G2 executor premises: lifetime at-most-once prepare dispatch (retired-attempt
/// replay is unsupported), no backend resources before admission, terminal failure
/// only after cleanup, deduplicated safe destruction and truthful retirement and
/// quiescence acknowledgements. This is not unbounded replay history, an executor,
/// a render-safety proof, or a realtime/no-allocation guarantee.
final class EnginePlanLedger {
    private struct Entry {
        let attempt: PrepareAttemptID
        var state: EnginePlanLedgerSnapshot.State
    }

    private struct Record {
        let instance: EngineInstanceID
        var superseded = false
        var quiescent = false
        var entries: [Entry] = []
    }

    private struct BoundLocation {
        let record: Int
        let entry: Int
        let phase: EnginePlanPhase
    }

    let capacity: Int
    private(set) var currentInstance: EngineInstanceID
    private var records: [Record]

    /// Storage grows lazily; every entry in every phase across both records counts.
    init(capacity: Int) throws(EnginePlanLedgerRefusal) {
        guard capacity > 0 else { throw .invalidCapacity }
        self.capacity = capacity
        currentInstance = EngineInstanceID()
        records = [Record(instance: currentInstance)]
    }

    var count: Int { records.reduce(0) { $0 + $1.entries.count } }

    func snapshot() -> EnginePlanLedgerSnapshot {
        EnginePlanLedgerSnapshot(capacity: capacity, currentInstance: currentInstance, records: records.map { record in
            EnginePlanLedgerSnapshot.Record(
                instance: record.instance, superseded: record.superseded, quiescent: record.quiescent,
                entries: record.entries.map { .init(attempt: $0.attempt, state: $0.state) }
            )
        })
    }

    /// Only admission consumes a slot. The backend MUST NOT create resources
    /// before this succeeds. Live duplicates are refused, not replayed.
    func dispatch(instance: EngineInstanceID, attempt: PrepareAttemptID) throws(EnginePlanLedgerRefusal) {
        let record = try recordIndex(instance)
        guard instance == currentInstance else { throw .notCurrentInstance }
        guard !records[record].entries.contains(where: { $0.attempt == attempt }) else { throw .duplicateAttempt }
        guard count < capacity else { throw .capacityReached }
        records[record].entries.append(Entry(attempt: attempt, state: .pending(reclaim: false)))
    }

    /// Routes exactly the named record, including a superseded instance.
    /// The backend MUST NOT call `complete` with `.failure` until cleanup finishes
    /// (G2 obligation): an accepted failure immediately removes the pending entry;
    /// the ledger does not wait for cleanup. Failure has no ID. If a resource
    /// remains, report success with its actual ID and reclaim/retire it.
    func complete(
        instance: EngineInstanceID, attempt: PrepareAttemptID, result: Result<PreparedActivationID, PrepareFailure>
    ) throws(EnginePlanLedgerRefusal) -> EnginePlanCompletion {
        let (record, entry) = try entryIndex(instance: instance, attempt: attempt)
        guard case .pending(let reclaim) = records[record].entries[entry].state else { throw .notPending }
        switch result {
        case .success(let prepared):
            let binding = PlanBinding(instance: instance, attempt: attempt, prepared: prepared)
            let retiring = reclaim || records[record].superseded
            records[record].entries[entry].state = .bound(binding, retiring ? .retiring : .held)
            return retiring ? .retiring(binding) : .held(binding)
        case .failure(let reason):
            records[record].entries.remove(at: entry)
            releaseQuiescentPrior()
            return .failed(instance: instance, attempt: attempt, reason: reason)
        }
    }

    /// Abandoned preparation only, never implicit current-instance routing.
    /// Repeating pending-reclaim or retiring reclaim is an idempotent no-op.
    /// Committed ownership requires authorized release, not abandoned reclaim.
    func reclaim(instance: EngineInstanceID, attempt: PrepareAttemptID) throws(EnginePlanLedgerRefusal) {
        let (record, entry) = try entryIndex(instance: instance, attempt: attempt)
        switch records[record].entries[entry].state {
        case .pending:
            records[record].entries[entry].state = .pending(reclaim: true)
        case .bound(_, .committed):
            throw .notReclaimable
        case .bound(let binding, .held):
            records[record].entries[entry].state = .bound(binding, .retiring)
        case .bound(_, .retiring):
            break
        }
    }

    /// Success OR partial commit accepts ownership; failure leaves the plan held.
    /// G2, not this ledger, determines the actual installed/rendered graph.
    func committed(_ binding: PlanBinding, outcome: ActivationCommitOutcome) throws(EnginePlanLedgerRefusal) {
        let location = try boundIndex(binding)
        guard location.phase == .held else { throw .notHeld }
        if outcome != .failed {
            records[location.record].entries[location.entry].state = .bound(binding, .committed)
        }
    }

    /// Authorized discard/release of exact held or committed ownership. No raw-ID
    /// fallback. Already retiring is an idempotent no-op; nothing is removed.
    func release(_ binding: PlanBinding) throws(EnginePlanLedgerRefusal) {
        let location = try boundIndex(binding)
        records[location.record].entries[location.entry].state = .bound(binding, .retiring)
    }

    /// Stable retryable intents, in instance/dispatch insertion order. No handed-
    /// off flag: failed handoff returns the same list. G2 must deduplicate actual
    /// execution and prove safe destruction; returning an array proves neither.
    func pendingRetirements() -> [PlanBinding] {
        records.flatMap { record in
            record.entries.compactMap { entry in
                if case .bound(let binding, .retiring) = entry.state { return binding }
                return nil
            }
        }
    }

    /// Only a true executor acknowledgement frees a bound entry's slot. Unknown,
    /// early or duplicate acknowledgements refuse without changing any record.
    func acknowledgeRetired(_ binding: PlanBinding) throws(EnginePlanLedgerRefusal) {
        let location = try boundIndex(binding)
        guard location.phase == .retiring else { throw .notRetiring }
        records[location.record].entries.remove(at: location.entry)
        releaseQuiescentPrior()
    }

    /// Refuses before minting or mutation while ANY prior record remains, even
    /// an empty, unquiesced one. Superseding never attests quiescence.
    @discardableResult
    func supersede() throws(EnginePlanLedgerRefusal) -> EngineInstanceID {
        guard records.count == 1 else { throw .priorInstanceRetained }
        records[0].superseded = true
        for entry in records[0].entries.indices {
            switch records[0].entries[entry].state {
            case .pending:
                records[0].entries[entry].state = .pending(reclaim: true)
            case .bound(let binding, _):
                records[0].entries[entry].state = .bound(binding, .retiring)
            }
        }
        currentInstance = EngineInstanceID()
        records.append(Record(instance: currentInstance))
        return currentInstance
    }

    /// Backend-attested quiescence (G2), superseded instances only. Pending work
    /// forbids acknowledgement. Repeated acknowledgement while retained is a no-op.
    /// Release the old record only after BOTH quiescence and zero entries.
    func acknowledgeQuiescent(_ instance: EngineInstanceID) throws(EnginePlanLedgerRefusal) {
        let record = try recordIndex(instance)
        guard records[record].superseded else { throw .currentInstance }
        guard !records[record].entries.contains(where: {
            if case .pending = $0.state { return true }
            return false
        }) else { throw .pendingPreparations }
        records[record].quiescent = true
        releaseQuiescentPrior()
    }

    func attestCommitted(_ binding: PlanBinding) -> CommittedResident? {
        guard binding.instance == currentInstance,
              let location = try? boundIndex(binding), location.phase == .committed else { return nil }
        return CommittedResident(binding: binding)
    }

    private func recordIndex(_ instance: EngineInstanceID) throws(EnginePlanLedgerRefusal) -> Int {
        guard let index = records.firstIndex(where: { $0.instance == instance }) else { throw .unknownInstance }
        return index
    }

    private func entryIndex(
        instance: EngineInstanceID, attempt: PrepareAttemptID
    ) throws(EnginePlanLedgerRefusal) -> (Int, Int) {
        let record = try recordIndex(instance)
        guard let entry = records[record].entries.firstIndex(where: { $0.attempt == attempt }) else {
            throw .unknownAttempt
        }
        return (record, entry)
    }

    private func boundIndex(_ binding: PlanBinding) throws(EnginePlanLedgerRefusal) -> BoundLocation {
        let (record, entry) = try entryIndex(instance: binding.instance, attempt: binding.attempt)
        guard case .bound(let actual, let phase) = records[record].entries[entry].state,
              actual == binding else { throw .bindingMismatch }
        return BoundLocation(record: record, entry: entry, phase: phase)
    }

    private func releaseQuiescentPrior() {
        if records.count == 2, records[0].quiescent, records[0].entries.isEmpty {
            records.removeFirst()
        }
    }
}
