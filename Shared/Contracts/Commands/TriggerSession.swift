//
//  TriggerSession.swift
//  FluxKlang
//
//  Control-plane identity and terminal-outcome ownership, independent of timing.
//

/// Opaque process-local correlation boundary, not an authorization credential.
/// Retaining the instance identity prevents address reuse while any token survives.
struct TriggerSessionToken: Hashable, Sendable {
    fileprivate final class Identity: Sendable {}
    fileprivate let instance: Identity
    fileprivate let counter: Generation

    fileprivate init(instance: Identity = Identity(), counter: Generation = .initial) {
        self.instance = instance
        self.counter = counter
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instance === rhs.instance && lhs.counter == rhs.counter
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(instance))
        hasher.combine(counter)
    }
}

struct TriggerHandle: Hashable, Sendable {
    let session: TriggerSessionToken
    let trigger: TriggerID

    fileprivate init(session: TriggerSessionToken, trigger: TriggerID) {
        self.session = session
        self.trigger = trigger
    }
}

struct SessionOutcome: Hashable, Sendable {
    let handle: TriggerHandle
    let outcome: TriggerOutcome

    fileprivate init(handle: TriggerHandle, outcome: TriggerOutcome) {
        self.handle = handle
        self.outcome = outcome
    }
}

/// Every refusal leaves the session unchanged.
enum TriggerSessionError: Error, Equatable, Sendable {
    case invalidOutcomeCapacity
    case staleSession
    case duplicateID
    case outcomeCapacity
    case sessionExhausted
    case notPending
    case mismatchedCompletion
    case invalidCompletion
    case notQuiescent
    case overflow
}

/// One single-owner control-plane value. Copies represent the same logical
/// session, not independent live authorities. Sendable does not provide synchronization.
/// No persistence, cross-process replay, allocation-free or activation guarantees.
struct TriggerSession: Sendable {
    private static let identityBudget = 65_536
    private let outcomeCapacity: Int
    private(set) var currentToken = TriggerSessionToken()
    private var seen: Set<TriggerID> = []
    private var pending: Set<TriggerID> = []
    private var terminal: [SessionOutcome] = []

    var pendingCount: Int { pending.count }
    /// Pending and queued outcomes each own one slot; completion does not free it.
    var reservedOutcomeCount: Int { pending.count + terminal.count }

    init(outcomeCapacity: Int) throws(TriggerSessionError) {
        guard (1...Self.identityBudget).contains(outcomeCapacity) else { throw .invalidOutcomeCapacity }
        self.outcomeCapacity = outcomeCapacity
    }

    /// Advisory only; reserve rechecks everything before mutating.
    func preflight(id: TriggerID, session: TriggerSessionToken) throws(TriggerSessionError) {
        guard session == currentToken else { throw .staleSession }
        guard !seen.contains(id) else { throw .duplicateID }
        guard seen.count < Self.identityBudget else { throw .sessionExhausted }
        guard reservedOutcomeCount < outcomeCapacity else { throw .outcomeCapacity }
    }

    /// Accepts an identity and reserves exactly one future terminal-outcome slot.
    /// It does not validate/admit a command or schedule musical work.
    mutating func reserve(id: TriggerID, session: TriggerSessionToken) throws(TriggerSessionError) -> TriggerHandle {
        try preflight(id: id, session: session)
        seen.insert(id)
        pending.insert(id)
        return TriggerHandle(session: currentToken, trigger: id)
    }

    /// Transfers the pending reservation to the queue exactly once. Shape validation
    /// is canonical B validation, not proof of freshness or correct musical timing.
    mutating func complete(_ handle: TriggerHandle, outcome: TriggerOutcome) throws(TriggerSessionError) {
        guard handle.session == currentToken else { throw .staleSession }
        guard pending.contains(handle.trigger) else { throw .notPending }
        guard outcome.trigger == handle.trigger else { throw .mismatchedCompletion }
        do { try outcome.validateMediaShape() } catch { throw .invalidCompletion }
        pending.remove(handle.trigger)
        terminal.append(SessionOutcome(handle: handle, outcome: outcome))
    }

    /// Transfers all queued outcomes, in completion order, to the consumer.
    /// Slots are released, but seen IDs remain until explicit quiescent rotation.
    mutating func drain() -> [SessionOutcome] {
        let outcomes = terminal
        terminal = []
        return outcomes
    }

    /// Only this operation clears seen IDs. Counter advancement is checked before
    /// any mutation. A future scheduler must additionally require zero timeline pins
    /// and preserve its own clocks/history/horizon; this component owns none of them.
    @discardableResult
    mutating func rotateSession(expected: TriggerSessionToken) throws(TriggerSessionError) -> TriggerSessionToken {
        guard expected == currentToken else { throw .staleSession }
        guard pending.isEmpty, terminal.isEmpty else { throw .notQuiescent }
        let next: Generation
        do { next = try currentToken.counter.next() } catch { throw .overflow }
        currentToken = TriggerSessionToken(instance: currentToken.instance, counter: next)
        seen.removeAll(keepingCapacity: true)
        return currentToken
    }
}
