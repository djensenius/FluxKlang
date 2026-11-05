//
//  PeerSyncReceiver.swift
//  FluxKlang
//
//  Controller-side mirror of one session's snapshot/delta stream (#95). A delta
//  applies only at exactly the next sequence. A gap, repeat, regression or
//  unappliable delta latches a resync request; later deltas are reported as
//  discarded, never skipped silently, until a current-session snapshot arrives.
//  Anything from another host or connection epoch is stale and changes nothing.
//
//  Two guards survive a resync latch within the session. The revision floor is
//  the last accepted state's revisions; a snapshot that lowers any of them is
//  refused and (re)latches the resync. The high-water mark is the highest
//  current-session sequence seen, including discarded and refused deltas; a
//  snapshot below it is refused, so a stale recovery snapshot cannot clear the
//  latch. Both are O(1) and reset only with a new receiver, i.e. a new session.
//  A current-session delta with a far-future sequence raises the mark for the
//  rest of the session, so no older snapshot can recover it. That fails closed;
//  the escape is a reconnect, which negotiates a new session and a new receiver.
//

import Foundation

enum PeerResyncReason: Hashable, Sendable {
    case gap(expected: PeerSequence, found: PeerSequence)
    case repeated(PeerSequence)
    case unappliable(PeerSyncError)
    /// A current-session snapshot was refused while (or by) latching the resync.
    case snapshotRefused(PeerSyncError)
}

/// Asks the host for a fresh snapshot of `session`.
struct PeerResyncRequest: Hashable, Sendable {
    let session: PeerSyncSession
    let lastApplied: PeerSequence
    let reason: PeerResyncReason
}

enum PeerSyncEvent: Hashable, Sendable {
    case applied(PeerSequence)
    case stale(StaleDependency)
    case resyncRequested(PeerResyncRequest)
    /// A delta that arrived while no snapshot is current. It is not applied.
    case discardedAwaitingSnapshot(PeerSequence)
    case refused(PeerSyncError)
}

struct PeerSyncReceiver: Sendable {
    enum Phase: Hashable, Sendable {
        case awaitingSnapshot
        case synced(PeerSyncState)
        case resyncRequired(PeerResyncRequest)
    }

    let session: PeerSyncSession
    let limits: PeerSyncLimits
    private(set) var phase: Phase = .awaitingSnapshot
    /// The revisions of the last accepted state; snapshots may not lower them.
    private(set) var revisionFloor: CommandRevisions?
    /// The highest current-session sequence observed; snapshots may not be below it.
    private(set) var highWaterMark: PeerSequence?

    init(session: PeerSyncSession, limits: PeerSyncLimits = .standard) {
        self.session = session
        self.limits = limits
    }

    /// The mirrored state, or nil while awaiting a snapshot or resync.
    var state: PeerSyncState? {
        if case .synced(let state) = phase { return state }
        return nil
    }

    /// Accepts a current-session snapshot at or above the high-water mark whose
    /// revisions do not lower the floor. A snapshot below the mark is refused and,
    /// while resyncing, re-emits the request. A snapshot that lowers the floor is
    /// never applied: the host is inconsistent, so even a synced receiver drops its
    /// mirror and latches `resyncRequired` to ask for a fresh snapshot.
    mutating func receive(_ snapshot: PeerSyncSnapshot) -> PeerSyncEvent {
        if let stale = session.staleDependency(host: snapshot.session.hostEpoch,
                                                connection: snapshot.session.connectionEpoch) {
            return .stale(stale)
        }
        do { try snapshot.validate(limits) } catch { return .refused(error) }
        if let error = behindMark(snapshot.sequence) {
            guard case .resyncRequired(let request) = phase else { return .refused(error) }
            return relatch(lastApplied: request.lastApplied, reason: .snapshotRefused(error))
        }
        if let floor = revisionFloor, snapshot.revisions.regresses(from: floor) {
            switch phase {
            case .awaitingSnapshot: return .refused(.revisionRegressed)
            case .synced(let state):
                return relatch(lastApplied: state.sequence, reason: .snapshotRefused(.revisionRegressed))
            case .resyncRequired(let request):
                return relatch(lastApplied: request.lastApplied, reason: .snapshotRefused(.revisionRegressed))
            }
        }
        accept(PeerSyncState(snapshot))
        return .applied(snapshot.sequence)
    }

    mutating func receive(_ delta: PeerSyncDelta) -> PeerSyncEvent {
        if let stale = session.staleDependency(host: delta.session.hostEpoch,
                                                connection: delta.session.connectionEpoch) {
            return .stale(stale)
        }
        observe(delta.sequence)
        guard case .synced(let current) = phase else { return .discardedAwaitingSnapshot(delta.sequence) }
        let expected: PeerSequence
        do { expected = try current.sequence.next() } catch {
            return requestResync(after: current, reason: .unappliable(.sequenceExhausted))
        }
        guard delta.sequence == expected else {
            let reason: PeerResyncReason = delta.sequence < expected
                ? .repeated(delta.sequence) : .gap(expected: expected, found: delta.sequence)
            return requestResync(after: current, reason: reason)
        }
        do {
            accept(try current.applying(delta, limits: limits))
            return .applied(delta.sequence)
        } catch {
            return requestResync(after: current, reason: .unappliable(error))
        }
    }

    private mutating func requestResync(after current: PeerSyncState, reason: PeerResyncReason) -> PeerSyncEvent {
        relatch(lastApplied: current.sequence, reason: reason)
    }

    /// Latches (or keeps) the resync and emits the request. The floor and mark are kept.
    private mutating func relatch(lastApplied: PeerSequence, reason: PeerResyncReason) -> PeerSyncEvent {
        let request = PeerResyncRequest(session: session, lastApplied: lastApplied, reason: reason)
        phase = .resyncRequired(request)
        return .resyncRequested(request)
    }

    private mutating func accept(_ state: PeerSyncState) {
        phase = .synced(state)
        revisionFloor = state.revisions
        observe(state.sequence)
    }

    private func behindMark(_ sequence: PeerSequence) -> PeerSyncError? {
        guard let mark = highWaterMark else { return nil }
        return sequence >= mark ? nil : .snapshotBehind(current: mark, found: sequence)
    }

    private mutating func observe(_ sequence: PeerSequence) {
        highWaterMark = max(highWaterMark ?? sequence, sequence)
    }
}
