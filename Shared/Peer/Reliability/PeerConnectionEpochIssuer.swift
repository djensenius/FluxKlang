//
//  PeerConnectionEpochIssuer.swift
//  FluxKlang
//
//  Host-side issuer of connection epochs (#97). One issuer lives for one host
//  epoch. Every issue takes the next `Generation` from a single host-wide
//  counter, so no epoch is ever issued twice, even to another peer or after a
//  retire. A reconnect replaces the peer's live epoch. Epochs are compared by
//  equality only (rule M2): a newer-looking generation is not current.
//
//  The live map is bounded and refuses a new peer when full; it never evicts.
//  Retiring a peer frees its slot but never makes its epoch reusable.
//

import Foundation

enum PeerConnectionEpochError: Error, Hashable, Sendable {
    case invalidCapacity(Int)
    /// A new peer would exceed the live-peer capacity. Nothing is evicted.
    case peerLimit(capacity: Int)
    /// The host-wide counter reached `Generation.maximumValue`; a new host epoch is needed.
    case exhausted
}

struct PeerConnectionEpochIssuer: Sendable {
    static let capacityBounds = 1...1_024
    static let standardCapacity = 64

    let host: HostID
    let capacity: Int
    private(set) var lastIssued: Generation?
    private var live: [ConnectionID: ConnectionEpoch] = [:]

    init(host: HostID, capacity: Int = Self.standardCapacity) throws(PeerConnectionEpochError) {
        guard Self.capacityBounds.contains(capacity) else { throw .invalidCapacity(capacity) }
        self.host = host
        self.capacity = capacity
    }

    /// Resumes after `lastIssued`, e.g. from a persisted counter in the same host epoch.
    init(host: HostID, resumingAfter lastIssued: Generation,
         capacity: Int = Self.standardCapacity) throws(PeerConnectionEpochError) {
        try self.init(host: host, capacity: capacity)
        self.lastIssued = lastIssued
    }

    var livePeerCount: Int { live.count }

    /// Issues a fresh epoch for `connection`, replacing any live one (a reconnect).
    mutating func issue(for connection: ConnectionID) throws(PeerConnectionEpochError) -> ConnectionEpoch {
        guard live[connection] != nil || live.count < capacity else { throw .peerLimit(capacity: capacity) }
        let generation: Generation
        if let lastIssued {
            do { generation = try lastIssued.next() } catch { throw .exhausted }
        } else {
            generation = .initial
        }
        let epoch = ConnectionEpoch(connection: connection, host: host, generation: generation)
        lastIssued = generation
        live[connection] = epoch
        return epoch
    }

    /// Ends the peer's live epoch. Returns the retired epoch, if any.
    @discardableResult
    mutating func retire(_ connection: ConnectionID) -> ConnectionEpoch? {
        live.removeValue(forKey: connection)
    }

    func current(for connection: ConnectionID) -> ConnectionEpoch? { live[connection] }

    /// True only when `epoch` equals the peer's live epoch.
    func isCurrent(_ epoch: ConnectionEpoch) -> Bool { live[epoch.connection] == epoch }
}
