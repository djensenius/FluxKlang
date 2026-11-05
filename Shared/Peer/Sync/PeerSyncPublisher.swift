//
//  PeerSyncPublisher.swift
//  FluxKlang
//
//  Host-side source of one session's snapshot/delta stream (#95). Each delta
//  takes the next sequence; nothing wraps, and a step that would break a bound
//  is refused before any state changes. A new session needs a new publisher.
//

import Foundation

struct PeerSyncPublisher: Sendable {
    let session: PeerSyncSession
    let limits: PeerSyncLimits
    private(set) var state: PeerSyncState

    init(session: PeerSyncSession, revisions: CommandRevisions, values: [ParameterID: ParameterValue],
         limits: PeerSyncLimits = .standard) throws(PeerSyncError) {
        let snapshot = PeerSyncSnapshot(session: session, sequence: .origin, revisions: revisions, values: values)
        try snapshot.validate(limits)
        self.session = session
        self.limits = limits
        state = PeerSyncState(snapshot)
    }

    /// The full current state, for a new or resyncing controller.
    func snapshot() -> PeerSyncSnapshot {
        PeerSyncSnapshot(session: session, sequence: state.sequence, revisions: state.revisions, values: state.values)
    }

    /// Advances the stream by one delta, or throws and leaves it unchanged.
    mutating func publish(revisions: CommandRevisions, updates: [ParameterID: ParameterValue] = [:],
                          removals: Set<ParameterID> = []) throws(PeerSyncError) -> PeerSyncDelta {
        let sequence: PeerSequence
        do { sequence = try state.sequence.next() } catch { throw .sequenceExhausted }
        let delta = PeerSyncDelta(session: session, sequence: sequence, revisions: revisions,
                                  updates: updates, removals: removals)
        state = try state.applying(delta, limits: limits)
        return delta
    }
}
