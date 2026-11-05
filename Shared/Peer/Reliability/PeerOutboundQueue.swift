//
//  PeerOutboundQueue.swift
//  FluxKlang
//
//  The remote's bounded queue of outgoing intents for one session (#97). Each
//  intent must carry exactly the session's host and connection epochs, so an
//  intent from any other epoch is refused at enqueue. Order is strict FIFO with
//  no coalescing. The bound covers queued and sent-but-unanswered intents
//  together; a full queue refuses and never evicts.
//
//  On a new session the queue is rebound: everything in it is dropped, never
//  replayed, and returned once as a `PeerDiscardReport`. Intents never sent are
//  *discarded*; intents sent but without a result are *outcome unknown*: never
//  resent and never assumed applied. The UI's "N changes discarded" uses
//  `discardedCount` only and lists unknown outcomes separately. A report can
//  only be made by `rebind`, so each one stands for exactly one dropped queue.
//

import Foundation

/// Thrown only by the queue and reconnect-state initializers.
enum PeerOutboundCapacityError: Error, Hashable, Sendable {
    case invalidCapacity(Int)
}

/// Why the remote refused to queue or acknowledge an intent.
enum PeerOutboundRefusal: Error, Hashable, Sendable {
    /// Input is disabled until a current-session snapshot has been applied.
    case inputDisabled
    /// The intent or result belongs to another host or connection epoch.
    case staleSession(StaleDependency)
    /// The command ID is already queued or awaiting its result in this session.
    case duplicate(CommandID)
    /// The queue holds `capacity` intents; nothing is evicted.
    case full(capacity: Int)
    /// A result for an intent that was not sent in this session or was already answered.
    case notAwaitingResult(CommandID)
}

struct PeerOutboundQueue: Sendable {
    static let capacityBounds = 1...4_096
    static let standardCapacity = 256

    private(set) var session: PeerSyncSession
    let capacity: Int
    /// Not yet sent, oldest first.
    private(set) var queued: [CommandIntent] = []
    /// Sent and awaiting the host's result, in send order.
    private(set) var awaitingResult: [CommandIntent] = []

    init(session: PeerSyncSession, capacity: Int = Self.standardCapacity) throws(PeerOutboundCapacityError) {
        guard Self.capacityBounds.contains(capacity) else { throw .invalidCapacity(capacity) }
        self.session = session
        self.capacity = capacity
    }

    var count: Int { queued.count + awaitingResult.count }
    var isFull: Bool { count >= capacity }

    /// Checks, in order: session freshness, duplicate ID, capacity.
    mutating func enqueue(_ intent: CommandIntent) throws(PeerOutboundRefusal) {
        if let stale = session.staleDependency(host: intent.hostEpoch, connection: intent.connectionEpoch) {
            throw .staleSession(stale)
        }
        guard !contains(intent.id) else { throw .duplicate(intent.id) }
        guard !isFull else { throw .full(capacity: capacity) }
        queued.append(intent)
    }

    /// Moves the oldest queued intent to `awaitingResult` and returns it for sending.
    mutating func takeNext() -> CommandIntent? {
        guard !queued.isEmpty else { return nil }
        let next = queued.removeFirst()
        awaitingResult.append(next)
        return next
    }

    /// Records the host's result for a sent intent of `session`.
    mutating func acknowledge(_ command: CommandID, session result: PeerSyncSession) throws(PeerOutboundRefusal) {
        if let stale = session.staleDependency(host: result.hostEpoch, connection: result.connectionEpoch) {
            throw .staleSession(stale)
        }
        guard let index = awaitingResult.firstIndex(where: { $0.id == command }) else {
            throw .notAwaitingResult(command)
        }
        awaitingResult.remove(at: index)
    }

    /// Drops everything for `next` and reports it once. Nothing is carried over.
    mutating func rebind(to next: PeerSyncSession) -> PeerDiscardReport {
        let report = PeerDiscardReport(previousSession: session, session: next,
                                       discarded: queued.map { $0.id }, unknownOutcome: awaitingResult.map { $0.id })
        queued = []
        awaitingResult = []
        session = next
        return report
    }

    private func contains(_ command: CommandID) -> Bool {
        queued.contains { $0.id == command } || awaitingResult.contains { $0.id == command }
    }
}

/// What one rebind dropped. ID lists are sorted and bounded; the counts are exact.
struct PeerDiscardReport: Hashable, Sendable {
    static let maximumListedIDs = 32

    let previousSession: PeerSyncSession
    let session: PeerSyncSession
    let discardedCount: Int
    let unknownOutcomeCount: Int
    /// The smallest `maximumListedIDs` discarded IDs, ascending.
    let discarded: [CommandID]
    /// The smallest `maximumListedIDs` outcome-unknown IDs, ascending.
    let unknownOutcome: [CommandID]

    fileprivate init(previousSession: PeerSyncSession, session: PeerSyncSession,
                     discarded: [CommandID], unknownOutcome: [CommandID]) {
        self.previousSession = previousSession
        self.session = session
        discardedCount = discarded.count
        unknownOutcomeCount = unknownOutcome.count
        self.discarded = Array(discarded.sorted().prefix(Self.maximumListedIDs))
        self.unknownOutcome = Array(unknownOutcome.sorted().prefix(Self.maximumListedIDs))
    }

    var isEmpty: Bool { discardedCount == 0 && unknownOutcomeCount == 0 }
    var discardedTruncated: Int { discardedCount - discarded.count }
    var unknownOutcomeTruncated: Int { unknownOutcomeCount - unknownOutcome.count }

    /// "N changes discarded", from the discarded count only.
    var headline: String { discardedCount == 1 ? "1 change discarded" : "\(discardedCount) changes discarded" }
}
