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
//  Sends are envelopes (#95): each takes the session's next envelope sequence,
//  from 1, retries included. A result answers exactly one send: its session,
//  command ID and sequence must all match an awaiting envelope, so a delayed
//  duplicate result of an earlier send of a reused ID never answers a later
//  send. An ID may be enqueued again only after its previous send was answered
//  (for example a transient refusal); while it is queued or awaiting, a second
//  copy is a `duplicate`, because the host would only answer it `inFlight`.
//  `PeerCommandResult` carries no session and sequences restart at 1 in every
//  session, so the transport must bind each result to the connection it arrived
//  on and pass that session; the queue cannot tell sessions apart otherwise.
//  Once a session's sequences run out, enqueue and send refuse with
//  `sequenceExhausted` and input is disabled until a reconnect starts again at 1.
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
    /// A result for an awaiting ID but another send of it (e.g. a delayed duplicate
    /// of an earlier, answered send); nothing changes.
    case sequenceMismatch(CommandID, expected: PeerSequence, found: PeerSequence)
    /// This session's envelope sequences are used up; only a reconnect sends again.
    case sequenceExhausted
}

struct PeerOutboundQueue: Sendable {
    static let capacityBounds = 1...4_096
    static let standardCapacity = 256

    private(set) var session: PeerSyncSession
    let capacity: Int
    /// Not yet sent, oldest first.
    private(set) var queued: [CommandIntent] = []
    /// Sent and awaiting the host's result, in send order.
    private(set) var awaitingResult: [PeerCommandEnvelope] = []
    /// The next send's envelope sequence; nil once this session's sequences are
    /// exhausted (2^53 − 1 sends), after which nothing is sent until a reconnect.
    private(set) var nextSequence: PeerSequence?
    private static let firstSequence = try? PeerSequence.origin.next()

    /// `firstSequence` overrides the session's first envelope sequence (default 1):
    /// a restore and test hook (exhaustion is pinned at `PeerSequence.maximumValue`).
    /// A reconnect always restarts at 1.
    init(session: PeerSyncSession, capacity: Int = Self.standardCapacity,
         firstSequence: PeerSequence? = nil) throws(PeerOutboundCapacityError) {
        guard Self.capacityBounds.contains(capacity) else { throw .invalidCapacity(capacity) }
        self.session = session
        self.capacity = capacity
        nextSequence = firstSequence ?? Self.firstSequence
    }

    var count: Int { queued.count + awaitingResult.count }
    var isFull: Bool { count >= capacity }
    var isSequenceExhausted: Bool { nextSequence == nil }

    /// Checks, in order: session freshness, sequence exhaustion, duplicate ID, capacity.
    mutating func enqueue(_ intent: CommandIntent) throws(PeerOutboundRefusal) {
        if let stale = session.staleDependency(host: intent.hostEpoch, connection: intent.connectionEpoch) {
            throw .staleSession(stale)
        }
        guard !isSequenceExhausted else { throw .sequenceExhausted }
        guard !contains(intent.id) else { throw .duplicate(intent.id) }
        guard !isFull else { throw .full(capacity: capacity) }
        queued.append(intent)
    }

    /// Wraps the oldest queued intent in the next envelope, moves it to
    /// `awaitingResult` and returns it for sending; nil when nothing is queued.
    mutating func takeNext() throws(PeerOutboundRefusal) -> PeerCommandEnvelope? {
        guard let sequence = nextSequence else { throw .sequenceExhausted }
        guard !queued.isEmpty else { return nil }
        let envelope = PeerCommandEnvelope(sequence: sequence, intent: queued.removeFirst())
        nextSequence = try? sequence.next()
        awaitingResult.append(envelope)
        return envelope
    }

    /// Records the host's result for the exact send it answers: `origin`'s
    /// epochs, then the command ID, then its envelope sequence must match.
    /// `origin` is the session of the connection the result arrived on, bound by
    /// the transport: the result itself names no session.
    mutating func acknowledge(_ result: PeerCommandResult,
                              session origin: PeerSyncSession) throws(PeerOutboundRefusal) {
        if let stale = session.staleDependency(host: origin.hostEpoch, connection: origin.connectionEpoch) {
            throw .staleSession(stale)
        }
        guard let index = awaitingResult.firstIndex(where: { $0.intent.id == result.command }) else {
            throw .notAwaitingResult(result.command)
        }
        let expected = awaitingResult[index].sequence
        guard result.sequence == expected else {
            throw .sequenceMismatch(result.command, expected: expected, found: result.sequence)
        }
        awaitingResult.remove(at: index)
    }

    /// Drops everything for `next` and reports it once. Nothing is carried over.
    mutating func rebind(to next: PeerSyncSession) -> PeerDiscardReport {
        let report = PeerDiscardReport(previousSession: session, session: next,
                                       discarded: queued.map { $0.id },
                                       unknownOutcome: awaitingResult.map { $0.intent.id })
        queued = []
        awaitingResult = []
        nextSequence = Self.firstSequence
        session = next
        return report
    }

    private func contains(_ command: CommandID) -> Bool {
        queued.contains { $0.id == command } || awaitingResult.contains { $0.intent.id == command }
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
