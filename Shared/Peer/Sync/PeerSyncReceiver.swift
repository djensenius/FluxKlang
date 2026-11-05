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

import Foundation

enum PeerResyncReason: Hashable, Sendable {
    case gap(expected: PeerSequence, found: PeerSequence)
    case repeated(PeerSequence)
    case unappliable(PeerSyncError)
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

    init(session: PeerSyncSession, limits: PeerSyncLimits = .standard) {
        self.session = session
        self.limits = limits
    }

    /// The mirrored state, or nil while awaiting a snapshot or resync.
    var state: PeerSyncState? {
        if case .synced(let state) = phase { return state }
        return nil
    }

    private var lastApplied: PeerSequence? {
        switch phase {
        case .awaitingSnapshot: nil
        case .synced(let state): state.sequence
        case .resyncRequired(let request): request.lastApplied
        }
    }

    mutating func receive(_ snapshot: PeerSyncSnapshot) -> PeerSyncEvent {
        if let stale = session.staleDependency(host: snapshot.session.hostEpoch,
                                                connection: snapshot.session.connectionEpoch) {
            return .stale(stale)
        }
        do { try snapshot.validate(limits) } catch { return .refused(error) }
        if let floor = lastApplied, snapshot.sequence < floor {
            return .refused(.snapshotBehind(current: floor, found: snapshot.sequence))
        }
        phase = .synced(PeerSyncState(snapshot))
        return .applied(snapshot.sequence)
    }

    mutating func receive(_ delta: PeerSyncDelta) -> PeerSyncEvent {
        if let stale = session.staleDependency(host: delta.session.hostEpoch,
                                                connection: delta.session.connectionEpoch) {
            return .stale(stale)
        }
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
            phase = .synced(try current.applying(delta, limits: limits))
            return .applied(delta.sequence)
        } catch {
            return requestResync(after: current, reason: .unappliable(error))
        }
    }

    private mutating func requestResync(after current: PeerSyncState, reason: PeerResyncReason) -> PeerSyncEvent {
        let request = PeerResyncRequest(session: session, lastApplied: current.sequence, reason: reason)
        phase = .resyncRequired(request)
        return .resyncRequested(request)
    }
}
