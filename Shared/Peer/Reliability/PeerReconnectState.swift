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
//  snapshot leaves them awaiting an explicit `resume()` from the sync layer,
//  which revalidates them first (#95). Nothing flushes on its own.
//
//  A reconnect is allowed only after `connectionLost()`. It drops the whole
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

import Foundation

/// Why an event was ignored.
enum PeerReconnectIgnored: Hashable, Sendable {
    /// The event came from, or reported data of, another host or connection epoch.
    case oldSession(StaleDependency)
    /// The connection is gone; nothing is applied until a new session.
    case disconnected
}

enum PeerReconnectOutcome: Hashable, Sendable {
    case unchanged
    case entered(PeerReconnectState.Phase)
    case ignored(PeerReconnectIgnored)
}

enum PeerReconnectError: Error, Hashable, Sendable {
    /// The offered session does not strictly follow the current one; epochs are never re-adopted.
    case staleSession(PeerSyncSession)
    /// `reconnect(to:)` offered another host; only `changeHost(to:)` may adopt it.
    case hostMismatch(expected: HostID, found: HostID)
    /// `changeHost(to:)` offered the current host; use `reconnect(to:)`.
    case sameHost(HostID)
    /// A reconnect needs `connectionLost()` first.
    case notDisconnected
    /// `resume()` needs a snapshot that left held intents awaiting resume.
    case notAwaitingResume
}

struct PeerReconnectState: Sendable {
    enum Phase: Hashable, Sendable {
        /// Negotiated; the first snapshot has not been applied yet.
        case connected(PeerSyncSession)
        /// A snapshot is applied. While `awaitingResume`, held intents wait for `resume()`.
        case synced(PeerSyncSession, awaitingResume: Bool)
        /// Awaiting a snapshot after a reconnect or an in-session resync.
        case resyncing(PeerSyncSession)
        /// The last session's connection was lost; nothing will be sent.
        case disconnected(PeerSyncSession)
    }

    private(set) var phase: Phase
    private(set) var queue: PeerOutboundQueue
    private(set) var attempts = PeerReconnectAttempts()

    init(session: PeerSyncSession,
         queueCapacity: Int = PeerOutboundQueue.standardCapacity) throws(PeerOutboundCapacityError) {
        phase = .connected(session)
        queue = try PeerOutboundQueue(session: session, capacity: queueCapacity)
    }

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

    /// Releases intents held across an in-session resync, after the sync layer revalidated them.
    mutating func resume() throws(PeerReconnectError) {
        guard phase == .synced(session, awaitingResume: true) else { throw .notAwaitingResume }
        phase = .synced(session, awaitingResume: false)
    }

    mutating func connectionLost() -> PeerReconnectOutcome {
        if case .disconnected = phase { return .unchanged }
        return enter(.disconnected(session))
    }

    /// The delay before the next connection attempt; see `PeerReconnectAttempts`.
    mutating func nextAttemptDelay(jitter: Double) throws(PeerReconnectBackoffError) -> Duration {
        try attempts.next(jitter: jitter)
    }

    /// Adopts a newly negotiated session of the same host after `connectionLost()`.
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
    /// `connectionLost()`, restarting the adoption order at `next`.
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
        return report
    }

    /// Applies an event that `receiver` produced; its session is `receiver.session`.
    mutating func observe(_ event: PeerSyncEvent, from receiver: PeerSyncReceiver) -> PeerReconnectOutcome {
        if let ignored = ignoredReason(receiver.session) { return .ignored(ignored) }
        switch event {
        case .applied:
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

    /// Follows `receiver`'s phase; its session is `receiver.session`.
    mutating func observe(_ receiver: PeerSyncReceiver) -> PeerReconnectOutcome {
        if let ignored = ignoredReason(receiver.session) { return .ignored(ignored) }
        switch receiver.phase {
        case .awaitingSnapshot: return .unchanged
        case .synced: return snapshotApplied()
        case .resyncRequired: return resyncRequired()
        }
    }

    private func ignoredReason(_ origin: PeerSyncSession) -> PeerReconnectIgnored? {
        if let stale = session.staleDependency(host: origin.hostEpoch, connection: origin.connectionEpoch) {
            return .oldSession(stale)
        }
        if case .disconnected = phase { return .disconnected }
        return nil
    }

    /// A current-session `applied` before synced can only be a snapshot: the
    /// receiver discards deltas while it awaits one. A successful sync resets the attempts.
    private mutating func snapshotApplied() -> PeerReconnectOutcome {
        if case .synced = phase { return .unchanged }
        attempts.reset()
        return enter(.synced(session, awaitingResume: !queue.queued.isEmpty))
    }

    private mutating func resyncRequired() -> PeerReconnectOutcome {
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
