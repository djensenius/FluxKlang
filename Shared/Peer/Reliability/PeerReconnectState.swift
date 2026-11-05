//
//  PeerReconnectState.swift
//  FluxKlang
//
//  The remote's reconnect state machine (#97), driven by values passed in: a
//  negotiated session, a lost connection, and the current receiver with its
//  `PeerSyncEvent`s or phase. The session always comes from the receiver, never
//  from a caller label. No sockets or timers.
//
//      connected ──snapshot──▶ synced ──resync──▶ resyncing ──snapshot──▶ synced(awaitingResume)
//                                 ▲                                              │ resume()
//                                 └──────────────────────────────────────────────┘
//      any ──lost──▶ disconnected ──reconnect(to: new session)──▶ resyncing ──snapshot──▶ synced
//
//  Input and sending are enabled only in `synced` without a pending resume,
//  i.e. after a snapshot of the current session was applied. An in-session
//  resync keeps the queue (the epochs are unchanged); if intents are held, the
//  snapshot leaves them awaiting an explicit `resume(_:)` from the sync layer,
//  which revalidates them first (#95). Nothing flushes on its own.
//
//  A reconnect is allowed only after `connectionLost(_:)`. It drops the whole
//  queue, never replays it, and returns its discard report exactly once.
//
//  Adoption order (not currency): the host issues connection epochs from one
//  counter per host epoch, and host epochs only advance, so for one `HostID`
//  the pair (host generation, connection generation) strictly increases from
//  one session to the next. A reconnect must strictly increase that pair over
//  the current session, which is the last adopted one; O(1), no history. The
//  current, any older and any reordered session is refused (A→B→A). Another
//  `HostID` is refused by `reconnect(to:)` and adopted only by the explicit
//  `changeHost(to:)`, which restarts the order at that host's session. Whether
//  data is current stays equality-only (M2): an event of any other session, or
//  while disconnected, is ignored and reported, and never changes the phase.
//
//  Latches: every adoption and every current-session resync request (while
//  connected, resyncing, synced or awaiting resume) starts a new
//  `PeerResyncLatch` (a per-session generation, compared by equality only), so
//  every earlier stamp goes stale. If a session's generations run out, the
//  state fails closed (`latchExhausted`) until a reconnect adopts a new session.
//  Delayed signals are bound to the latch or session they were taken under:
//  sync-layer events and receiver phases are stamped with `stamp(_:)` when
//  produced, `resume(_:)` names the latch it revalidated against, and
//  `connectionLost(_:)` / `nextAttemptDelay(after:jitter:)` name the session.
//  Only the snapshot that answers the current latch, observed while the
//  receiver is still synced, clears it; anything else is a typed ignore or
//  refusal that changes nothing.
//

import Foundation

/// Why an event was ignored.
enum PeerReconnectIgnored: Hashable, Sendable {
    /// The event came from, or reported data of, another host or connection epoch.
    case oldSession(StaleDependency)
    /// The connection is gone; nothing is applied until a new session.
    case disconnected
    /// The signal was stamped under an earlier latch; a newer resync is pending or done.
    case staleLatch(expected: PeerResyncLatch, found: PeerResyncLatch)
    /// An `applied` event while the receiver is no longer synced, so it answers no current snapshot.
    case receiverNotSynced(PeerSyncReceiver.Phase)
    /// The session's latch generations are exhausted; only a reconnect recovers.
    case latchExhausted
}

/// One resync latch of one session. Only a `PeerReconnectState` creates latches;
/// they are never reused and compare by equality only.
struct PeerResyncLatch: Hashable, Sendable {
    let session: PeerSyncSession
    let generation: Generation

    fileprivate init(session: PeerSyncSession, generation: Generation) {
        self.session = session
        self.generation = generation
    }
}

/// A sync-layer signal stamped with the latch that was current when it was produced.
struct PeerLatched<Value> {
    let value: Value
    let latch: PeerResyncLatch

    fileprivate init(_ value: Value, latch: PeerResyncLatch) {
        self.value = value
        self.latch = latch
    }
}

extension PeerLatched: Sendable where Value: Sendable {}
extension PeerLatched: Equatable where Value: Equatable {}
extension PeerLatched: Hashable where Value: Hashable {}

enum PeerReconnectOutcome: Hashable, Sendable {
    /// The phase is unchanged. A resync request still starts a new `latch`, or sets `latchExhausted`.
    case unchanged
    /// The phase changed; a resync request may also have set `latchExhausted`.
    case entered(PeerReconnectState.Phase)
    /// Nothing changed: no phase, latch, flag or queue.
    case ignored(PeerReconnectIgnored)
}

enum PeerReconnectError: Error, Hashable, Sendable {
    /// The offered session does not strictly follow the current one; epochs are never re-adopted.
    case staleSession(PeerSyncSession)
    /// `reconnect(to:)` offered another host; only `changeHost(to:)` may adopt it.
    case hostMismatch(expected: HostID, found: HostID)
    /// `changeHost(to:)` offered the current host; use `reconnect(to:)`.
    case sameHost(HostID)
    /// A reconnect needs `connectionLost(_:)` first.
    case notDisconnected
    /// `resume(_:)` needs a snapshot that left held intents awaiting resume.
    case notAwaitingResume
    /// `resume(_:)` named an earlier latch; its revalidation predates the current snapshot.
    case staleLatch(expected: PeerResyncLatch, found: PeerResyncLatch)
    /// A connection signal named another session than the current one.
    case oldSession(StaleDependency)
    case backoff(PeerReconnectBackoffError)
    /// The session's latch generations are exhausted; only a reconnect recovers.
    case latchExhausted
}

struct PeerReconnectState: Sendable {
    enum Phase: Hashable, Sendable {
        /// Negotiated; the first snapshot has not been applied yet.
        case connected(PeerSyncSession)
        /// A snapshot is applied. While `awaitingResume`, held intents wait for `resume(_:)`.
        case synced(PeerSyncSession, awaitingResume: Bool)
        /// Awaiting a snapshot after a reconnect or an in-session resync.
        case resyncing(PeerSyncSession)
        /// The last session's connection was lost; nothing will be sent.
        case disconnected(PeerSyncSession)
    }

    private(set) var phase: Phase
    private(set) var queue: PeerOutboundQueue
    private(set) var attempts = PeerReconnectAttempts()
    /// The current latch; the next applied snapshot of `session` must answer it.
    private(set) var latch: PeerResyncLatch
    /// No further latch exists for this session: every signal is ignored and input stays disabled.
    private(set) var latchExhausted = false

    /// `latchGeneration` is the first latch's generation: a restore and test hook
    /// (exhaustion is pinned at `Generation.maximumValue`). It adds no forging
    /// path, because `stamp(_:)` is already the caller-trusted boundary.
    init(session: PeerSyncSession, queueCapacity: Int = PeerOutboundQueue.standardCapacity,
         latchGeneration: Generation = .initial) throws(PeerOutboundCapacityError) {
        phase = .connected(session)
        queue = try PeerOutboundQueue(session: session, capacity: queueCapacity)
        latch = PeerResyncLatch(session: session, generation: latchGeneration)
    }

    /// Stamps a signal with the current latch; call it when the signal is produced.
    func stamp<Value>(_ value: Value) -> PeerLatched<Value> { PeerLatched(value, latch: latch) }

    var session: PeerSyncSession { queue.session }

    var isInputEnabled: Bool { phase == .synced(session, awaitingResume: false) }

    /// Queues a user intent. Refused unless synced and resumed, then as `PeerOutboundQueue.enqueue`.
    mutating func enqueue(_ intent: CommandIntent) throws(PeerOutboundRefusal) {
        guard isInputEnabled else { throw .inputDisabled }
        try queue.enqueue(intent)
    }

    /// The next intent to send, oldest first; nil unless synced and resumed.
    mutating func takeNextToSend() -> CommandIntent? {
        guard isInputEnabled else { return nil }
        return queue.takeNext()
    }

    mutating func acknowledge(_ command: CommandID, session result: PeerSyncSession) throws(PeerOutboundRefusal) {
        try queue.acknowledge(command, session: result)
    }

    /// Releases intents held across an in-session resync, after the sync layer
    /// revalidated them against the snapshot that answered `revalidated`.
    mutating func resume(_ revalidated: PeerResyncLatch) throws(PeerReconnectError) {
        guard !latchExhausted else { throw .latchExhausted }
        guard Self.matches(revalidated, latch) else { throw .staleLatch(expected: latch, found: revalidated) }
        guard phase == .synced(session, awaitingResume: true) else { throw .notAwaitingResume }
        phase = .synced(session, awaitingResume: false)
    }

    /// The connection of `lost` is gone; a late loss of an earlier session is ignored.
    mutating func connectionLost(_ lost: PeerSyncSession) -> PeerReconnectOutcome {
        if let stale = session.staleDependency(host: lost.hostEpoch, connection: lost.connectionEpoch) {
            return .ignored(.oldSession(stale))
        }
        if case .disconnected = phase { return .unchanged }
        return enter(.disconnected(session))
    }

    /// The delay before the next attempt to replace `lost`; see `PeerReconnectAttempts`.
    /// Counted only while `lost` is the current, disconnected session.
    mutating func nextAttemptDelay(after lost: PeerSyncSession,
                                   jitter: Double) throws(PeerReconnectError) -> Duration {
        if let stale = session.staleDependency(host: lost.hostEpoch, connection: lost.connectionEpoch) {
            throw .oldSession(stale)
        }
        guard case .disconnected = phase else { throw .notDisconnected }
        do { return try attempts.next(jitter: jitter) } catch { throw .backoff(error) }
    }

    /// Adopts a newly negotiated session of the same host after `connectionLost(_:)`.
    /// The queue is dropped and its report returned; input stays disabled until that
    /// session's snapshot.
    mutating func reconnect(to next: PeerSyncSession) throws(PeerReconnectError) -> PeerDiscardReport {
        guard case .disconnected = phase else { throw .notDisconnected }
        let host = session.hostEpoch.host
        guard next.hostEpoch.host == host else { throw .hostMismatch(expected: host, found: next.hostEpoch.host) }
        guard Self.strictlyFollows(next, session) else { throw .staleSession(next) }
        return adopt(next)
    }

    /// The explicit host-change path: adopts a session of another host after
    /// `connectionLost(_:)`, restarting the adoption order at `next`.
    mutating func changeHost(to next: PeerSyncSession) throws(PeerReconnectError) -> PeerDiscardReport {
        guard case .disconnected = phase else { throw .notDisconnected }
        guard next.hostEpoch.host != session.hostEpoch.host else { throw .sameHost(next.hostEpoch.host) }
        return adopt(next)
    }

    /// Adoption order only, never currency (M2 still governs currency): within
    /// one host, (host generation, connection generation) must strictly increase.
    private static func strictlyFollows(_ next: PeerSyncSession, _ current: PeerSyncSession) -> Bool {
        let nextHost = next.hostEpoch.generation.value, currentHost = current.hostEpoch.generation.value
        let nextConnection = next.connectionEpoch.generation.value
        let currentConnection = current.connectionEpoch.generation.value
        return nextHost > currentHost || (nextHost == currentHost && nextConnection > currentConnection)
    }

    private mutating func adopt(_ next: PeerSyncSession) -> PeerDiscardReport {
        let report = queue.rebind(to: next)
        phase = .resyncing(next)
        latch = PeerResyncLatch(session: next, generation: .initial)
        latchExhausted = false
        return report
    }

    /// Applies an event that `receiver` produced, stamped when it was produced.
    /// Its session is `receiver.session`. An `applied` clears a latch only if
    /// it answers the current one and `receiver` is still synced. A current
    /// `resyncRequested` starts a new latch (see the phase overload's contract).
    mutating func observe(_ stamped: PeerLatched<PeerSyncEvent>,
                          from receiver: PeerSyncReceiver) -> PeerReconnectOutcome {
        if let ignored = ignoredReason(receiver.session, stamped.latch) { return .ignored(ignored) }
        switch stamped.value {
        case .applied:
            guard case .synced = receiver.phase else { return .ignored(.receiverNotSynced(receiver.phase)) }
            return snapshotApplied()
        case .resyncRequested(let request):
            if let stale = session.staleDependency(host: request.session.hostEpoch,
                                                   connection: request.session.connectionEpoch) {
                return .ignored(.oldSession(stale))
            }
            return resyncRequired()
        case .stale(let stale):
            return .ignored(.oldSession(stale))
        case .discardedAwaitingSnapshot, .refused:
            return .unchanged
        }
    }

    /// Follows the phase of a receiver stamped when it was read; its session is `receiver.session`.
    ///
    /// Caller contract: every observed current `.resyncRequired` phase (a poll
    /// included) starts a new latch, so any signal stamped before that
    /// observation, an `.applied` included, is ignored as `.staleLatch`.
    /// Recovery then completes on the next `.synced` phase read or `.applied`
    /// stamped after the last observed request.
    mutating func observe(_ stamped: PeerLatched<PeerSyncReceiver>) -> PeerReconnectOutcome {
        let receiver = stamped.value
        if let ignored = ignoredReason(receiver.session, stamped.latch) { return .ignored(ignored) }
        switch receiver.phase {
        case .awaitingSnapshot: return .unchanged
        case .synced: return snapshotApplied()
        case .resyncRequired: return resyncRequired()
        }
    }

    private func ignoredReason(_ origin: PeerSyncSession, _ stamped: PeerResyncLatch) -> PeerReconnectIgnored? {
        if let stale = session.staleDependency(host: origin.hostEpoch, connection: origin.connectionEpoch) {
            return .oldSession(stale)
        }
        if case .disconnected = phase { return .disconnected }
        if latchExhausted { return .latchExhausted }
        guard Self.matches(stamped, latch) else { return .staleLatch(expected: latch, found: stamped) }
        return nil
    }

    /// Equality only: a latch is current or it is not; latches are never ordered.
    private static func matches(_ found: PeerResyncLatch, _ expected: PeerResyncLatch) -> Bool {
        found == expected
    }

    /// Starts the next latch of this session; fails closed once generations run out.
    private mutating func raiseLatch() {
        do {
            latch = PeerResyncLatch(session: session, generation: try latch.generation.next())
        } catch {
            latchExhausted = true
        }
    }

    /// A current-session `applied` before synced can only be a snapshot: the
    /// receiver discards deltas while it awaits one. A successful sync resets the attempts.
    private mutating func snapshotApplied() -> PeerReconnectOutcome {
        if case .synced = phase { return .unchanged }
        attempts.reset()
        return enter(.synced(session, awaitingResume: !queue.queued.isEmpty))
    }

    /// Every current-session request starts a new latch, even while already
    /// resyncing, so no signal stamped before it can clear the new one.
    private mutating func resyncRequired() -> PeerReconnectOutcome {
        if case .disconnected = phase { return .unchanged }
        raiseLatch()
        switch phase {
        case .synced: return enter(.resyncing(session))
        case .connected, .resyncing, .disconnected: return .unchanged
        }
    }

    private mutating func enter(_ next: Phase) -> PeerReconnectOutcome {
        phase = next
        return .entered(next)
    }
}
