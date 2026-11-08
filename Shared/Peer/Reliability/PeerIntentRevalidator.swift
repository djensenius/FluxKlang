//
//  PeerIntentRevalidator.swift
//  FluxKlang
//
//  Decides, for intents the remote still holds when certainty was lost (an in-session resync, or a queue
//  captured before `rebind`), which ones a FRESH replacement may be proposed for (#97). It never replays,
//  relabels or returns a `CommandIntent`, owns no clock or backoff and holds no state: the inputs are values
//  and a refusal returns no report.
//
//  Only never-sent (`held`) intents are examined. Sent intents (`awaitingResultIDs`) are never retryable:
//  their outcome is unknown, not assumed applied, and they are reported as such in order.
//
//  A held `.set` or `.ramp` is retryable only if the receiver's session is the one given, the intent was made
//  under exactly that session, all five revisions equal the receiver state's, its target parameter exists in
//  the state, and its value is finite. Otherwise it is discarded with the first failing reason in the order
//  class, session, revisions, value presence, finiteness. An intent captured before a reconnect carries the
//  old epochs, so it is discarded as a stale session: nothing is relabelled into the new session.
//
//  A call is refused as a whole, in this order: limits, latch, latch owner (the stamp's session is not the
//  receiver's), session, receiver not synced, too many held, too many awaiting, duplicate command ID. Every
//  count check runs before any per-intent work. Not covered: descriptor ranges (`PeerSyncState` has no
//  catalog) and ramp durations (the intent's own validation bounds them).
//

/// A held intent reduced to the fields revalidation reads. Built from a validated `CommandIntent`.
struct PeerHeldIntent: Hashable, Sendable {
    let id: CommandID
    let operation: CommandOperation
    let revisions: CommandRevisions
    let hostEpoch: HostEpoch
    let connectionEpoch: ConnectionEpoch?

    init(id: CommandID, operation: CommandOperation, revisions: CommandRevisions,
         hostEpoch: HostEpoch, connectionEpoch: ConnectionEpoch?) {
        self.id = id
        self.operation = operation
        self.revisions = revisions
        self.hostEpoch = hostEpoch
        self.connectionEpoch = connectionEpoch
    }

    init(_ intent: CommandIntent) {
        self.init(id: intent.id, operation: intent.operation, revisions: intent.revisions,
                  hostEpoch: intent.hostEpoch, connectionEpoch: intent.connectionEpoch)
    }
}

enum PeerIntentRevalidator {
    /// The most held intents, and the most awaiting IDs, one call accepts.
    static let maximumHeld = PeerOutboundQueue.capacityBounds.upperBound

    /// `latched` is the receiver stamped when read (`PeerReconnectState.stamp`); `expecting` is the latch the
    /// caller revalidates under; `session` is the session the fresh intents would be made for.
    static func revalidate( // swiftlint:disable:this function_parameter_count
        held: [CommandIntent], awaitingResultIDs: [CommandID], latched: PeerLatched<PeerSyncReceiver>,
        expecting: PeerResyncLatch, session: PeerSyncSession, limits: PeerRevalidationLimits
    ) throws(PeerRevalidationRefusal) -> PeerRevalidationReport {
        try revalidate(heldIntents: held.lazy.map(PeerHeldIntent.init), awaitingResultIDs: awaitingResultIDs,
                       latched: latched, expecting: expecting, session: session, limits: limits)
    }

    /// The same call on reduced intents; the public entry delegates everything to it. A lazy collection keeps
    /// the count checks ahead of any per-intent work.
    static func revalidate<Held: Collection>( // swiftlint:disable:this function_parameter_count
        heldIntents: Held, awaitingResultIDs: [CommandID], latched: PeerLatched<PeerSyncReceiver>,
        expecting: PeerResyncLatch, session: PeerSyncSession, limits: PeerRevalidationLimits
    ) throws(PeerRevalidationRefusal) -> PeerRevalidationReport where Held.Element == PeerHeldIntent {
        try limits.validated()
        let state = try currentState(latched, expecting: expecting, session: session)
        try requireWithinBounds(heldCount: heldIntents.count, awaitingCount: awaitingResultIDs.count)
        try requireDistinct(heldIntents.map(\.id), awaitingResultIDs)
        return report(heldIntents, awaitingResultIDs: awaitingResultIDs, session: session, state: state,
                      limits: limits)
    }

    /// The first failing reason for one held intent, or nil when a fresh intent may replace it.
    static func discardReason(for held: PeerHeldIntent, session: PeerSyncSession,
                              state: PeerSyncState) -> PeerDiscardReason? {
        guard PeerRetryPolicy.classify(held.operation) == .freshIntentOnly,
              let target = target(of: held.operation) else { return .neverRetried(held.operation) }
        if let stale = session.staleDependency(host: held.hostEpoch, connection: held.connectionEpoch) {
            return .staleSession(stale)
        }
        let axes = differingAxes(held.revisions, state.revisions)
        if !axes.isEmpty { return .staleRevisions(axes) }
        guard state.values[target.parameter] != nil else { return .valueMissing(target.parameter) }
        guard target.value.value.isFinite else { return .notFinite }
        return nil
    }

    /// The parameter and value a parameter writer sets; nil for every other operation.
    static func target(of operation: CommandOperation) -> (parameter: ParameterID, value: ParameterValue)? {
        switch operation {
        case .set(let parameter, let value), .ramp(let parameter, let value, _):
            (parameter, value)
        case .bind, .recall, .trigger, .start, .stop, .locate, .panic, .safeMute, .propose, .editDraft:
            nil
        }
    }

    private static func currentState(_ latched: PeerLatched<PeerSyncReceiver>, expecting: PeerResyncLatch,
                                     session: PeerSyncSession) throws(PeerRevalidationRefusal) -> PeerSyncState {
        guard latched.latch == expecting else { throw .latchMismatch(expected: expecting, found: latched.latch) }
        try requireLatchOwner(latched)
        let receiver = latched.value
        if let stale = session.staleDependency(host: receiver.session.hostEpoch,
                                               connection: receiver.session.connectionEpoch) {
            throw .sessionMismatch(stale)
        }
        guard let state = receiver.state else { throw .receiverNotSynced(receiver.phase) }
        return state
    }

    /// The stamp must come from the session of the receiver it wraps, as `PeerReconnectState.observe` requires.
    private static func requireLatchOwner(_ latched: PeerLatched<PeerSyncReceiver>) throws(PeerRevalidationRefusal) {
        let received = latched.value.session
        if let stale = latched.latch.session.staleDependency(host: received.hostEpoch,
                                                             connection: received.connectionEpoch) {
            throw .latchOwnerMismatch(stale)
        }
    }

    private static func requireWithinBounds(heldCount: Int, awaitingCount: Int) throws(PeerRevalidationRefusal) {
        guard heldCount <= maximumHeld else { throw .tooManyHeld(heldCount) }
        guard awaitingCount <= maximumHeld else { throw .tooManyAwaiting(awaitingCount) }
    }

    /// Scans held IDs then awaiting IDs in order and names the first one seen before.
    private static func requireDistinct(_ held: [CommandID],
                                        _ awaiting: [CommandID]) throws(PeerRevalidationRefusal) {
        var seen = Set<CommandID>()
        for id in held + awaiting where !seen.insert(id).inserted { throw .duplicateCommand(id) }
    }

    private static func differingAxes(_ held: CommandRevisions, _ current: CommandRevisions) -> [PeerRevisionAxis] {
        var axes: [PeerRevisionAxis] = []
        if held.patch != current.patch { axes.append(.patch) }
        if held.capability != current.capability { axes.append(.capability) }
        if held.permission != current.permission { axes.append(.permission) }
        if held.parameter != current.parameter { axes.append(.parameter) }
        if held.graph != current.graph { axes.append(.graph) }
        return axes
    }

    private static func report<Held: Sequence>(
        _ held: Held, awaitingResultIDs: [CommandID], session: PeerSyncSession, state: PeerSyncState,
        limits: PeerRevalidationLimits
    ) -> PeerRevalidationReport where Held.Element == PeerHeldIntent {
        var retryable: [PeerRetryCandidate] = []
        var discarded: [PeerDiscardedIntent] = []
        for intent in held {
            if let reason = discardReason(for: intent, session: session, state: state) {
                discarded.append(PeerDiscardedIntent(id: intent.id, reason: reason))
            } else {
                retryable.append(PeerRetryCandidate(original: intent.id, operation: intent.operation,
                                                    basis: state.revisions))
            }
        }
        return PeerRevalidationReport(retryable: retryable, discarded: discarded,
                                      unknownOutcome: awaitingResultIDs, limits: limits)
    }
}
