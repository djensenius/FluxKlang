//
//  PeerRevalidationReport.swift
//  FluxKlang
//
//  The result types of `PeerIntentRevalidator` (#97): what may be offered again as a fresh intent, what was
//  discarded and why, and which sent intents have an unknown outcome. A report holds ids, operations and
//  revisions only. It has no host or connection epoch, so nothing of a dropped session can appear in it as
//  current, and nothing in it is a `CommandIntent`.
//
//  Lists keep input order and are bounded by `PeerRevalidationLimits.maximumListed` each; the counts stay
//  exact and `truncatedCount` says how many entries the three lists omit (always the newest, the tail).
//

/// The five revision axes of `CommandRevisions`, in the fixed order in which differences are listed.
enum PeerRevisionAxis: Hashable, Sendable, CaseIterable {
    case patch, capability, permission, parameter, graph
}

/// Why a held intent was discarded: the FIRST failing condition, in the order of the cases below
/// (class, session, revisions, value presence, finiteness).
enum PeerDiscardReason: Hashable, Sendable {
    /// The operation's retry class is `.never`.
    case neverRetried(CommandOperation)
    /// The intent was made under another host or connection epoch than the current session.
    case staleSession(StaleDependency)
    /// The intent's revisions differ from the current state's on these axes (patch, capability, permission,
    /// parameter, graph order); no axis is relaxed.
    case staleRevisions([PeerRevisionAxis])
    /// The target parameter is not in the current state.
    case valueMissing(ParameterID)
    /// The held value is NaN or infinite.
    case notFinite
}

struct PeerDiscardedIntent: Hashable, Sendable {
    let id: CommandID
    let reason: PeerDiscardReason
}

/// An intent that may be proposed again, as a NEW intent with a NEW command ID built by the caller.
/// `original` is the old ID, for audit only; `basis` is the state revisions it was revalidated against.
struct PeerRetryCandidate: Hashable, Sendable {
    let original: CommandID
    let operation: CommandOperation
    let basis: CommandRevisions
}

enum PeerRevalidationRefusal: Error, Hashable, Sendable {
    /// `maximumListed` is outside `PeerRevalidationLimits.maximumListedBounds`.
    case invalidLimits(maximumListed: Int)
    /// The receiver was stamped under another latch than the one the caller expects.
    case latchMismatch(expected: PeerResyncLatch, found: PeerResyncLatch)
    /// The stamp's latch belongs to another session than the receiver it wraps (the first differing epoch).
    case latchOwnerMismatch(StaleDependency)
    /// `session` is not the receiver's session.
    case sessionMismatch(StaleDependency)
    /// The receiver holds no state: it awaits a snapshot or needs a resync.
    case receiverNotSynced(PeerSyncReceiver.Phase)
    case tooManyHeld(Int)
    case tooManyAwaiting(Int)
    /// A command ID appears twice among the held and awaiting IDs (held first, then awaiting, in order).
    case duplicateCommand(CommandID)
}

/// How many entries of each report list are kept. Built only by `make` (or `standard`); the revalidator
/// checks it again where it is used.
struct PeerRevalidationLimits: Hashable, Sendable {
    static let maximumListedBounds = 1...256
    static let standard = PeerRevalidationLimits(uncheckedMaximumListed: 32)

    let maximumListed: Int

    private init(uncheckedMaximumListed: Int) {
        maximumListed = uncheckedMaximumListed
    }

    static func make(maximumListed: Int) throws(PeerRevalidationRefusal) -> PeerRevalidationLimits {
        try validate(maximumListed: maximumListed)
        return PeerRevalidationLimits(uncheckedMaximumListed: maximumListed)
    }

    static func validate(maximumListed: Int) throws(PeerRevalidationRefusal) {
        guard maximumListedBounds.contains(maximumListed) else { throw .invalidLimits(maximumListed: maximumListed) }
    }

    func validated() throws(PeerRevalidationRefusal) {
        try Self.validate(maximumListed: maximumListed)
    }
}

struct PeerRevalidationReport: Hashable, Sendable {
    /// The first `maximumListed` retry candidates, in held order.
    let retryable: [PeerRetryCandidate]
    /// The first `maximumListed` discarded intents, in held order.
    let discarded: [PeerDiscardedIntent]
    /// The first `maximumListed` sent intents without a result, in awaiting order: outcome unknown.
    let unknownOutcome: [CommandID]
    let retryableCount: Int
    let discardedCount: Int
    let unknownOutcomeCount: Int

    /// Keeps the first `limits.maximumListed` of each list and the exact counts of the full lists.
    init(retryable: [PeerRetryCandidate], discarded: [PeerDiscardedIntent], unknownOutcome: [CommandID],
         limits: PeerRevalidationLimits) {
        let cap = limits.maximumListed
        self.retryable = Array(retryable.prefix(cap))
        self.discarded = Array(discarded.prefix(cap))
        self.unknownOutcome = Array(unknownOutcome.prefix(cap))
        retryableCount = retryable.count
        discardedCount = discarded.count
        unknownOutcomeCount = unknownOutcome.count
    }

    /// The entries the three lists omit, in total.
    var truncatedCount: Int {
        (retryableCount - retryable.count) + (discardedCount - discarded.count)
            + (unknownOutcomeCount - unknownOutcome.count)
    }

    var isEmpty: Bool { retryableCount == 0 && discardedCount == 0 && unknownOutcomeCount == 0 }
}
