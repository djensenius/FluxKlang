//
//  PeerRosterList.swift
//  FluxKlang
//
//  The host's "Status > Peers" roster as a value (#94 PEER1; host-remote-roles.md
//  lines 42, 82, 89, 90 and 94). It is built from trust records the caller lists
//  (the store has no listing API) and an optional caller-supplied map from
//  identity to reconnect phase, so a view only draws it. Revoked peers have no
//  record and no row. The epoch shown is the session's connection epoch, never a
//  record's store revision. Nothing calls it yet.
//

/// Why a roster or prompt was refused. Nothing is listed on a refusal.
enum PeerRosterRefusal: Error, Hashable, Sendable {
    /// More records than `PeerTrustStore.maximumPeers`; a real store cannot hold them.
    case tooManyPeers(Int)
    /// The first repeated identity in input order; a repeat makes the Revoke target ambiguous.
    case duplicateIdentity(PeerIdentityFingerprint)
    /// The pairing label would be refused by `PeerPairingLabelRule`.
    case invalidLabel
}

/// Whether a paired peer is connected, and under which connection epoch.
enum PeerRosterConnection: Hashable, Sendable {
    case connected(epoch: Int)
    case disconnected
}

/// A row action, carried as a value. The model never revokes anything itself.
enum PeerRosterAction: Hashable, Sendable {
    case revoke(PeerIdentityFingerprint)

    var title: String {
        switch self {
        case .revoke: PeerRosterText.revoke
        }
    }

    /// Revoking asks for confirmation; it is never a drag (host-remote-roles.md line 82).
    var requiresConfirmation: Bool {
        switch self {
        case .revoke: true
        }
    }
}

struct PeerRosterRow: Hashable, Sendable, Identifiable {
    let id: PeerIdentityFingerprint
    /// The record's label, verbatim.
    let name: String
    /// The role the host granted.
    let role: PeerRole
    let connection: PeerRosterConnection
    let revoke: PeerRosterAction

    var roleText: String { PeerRosterText.role(role) }
    var statusText: String { PeerRosterText.status(connection) }

    /// True exactly when disconnected; the text "Disconnected" still carries the meaning.
    var isDimmed: Bool { connection == .disconnected }

    var accessibilityLabel: String {
        PeerRosterText.rowAccessibility(name: name, role: role, connection: connection)
    }

    var revokeTitle: String { revoke.title }
    var revokeAccessibilityLabel: String { PeerRosterText.revokeAccessibility(name: name) }
}

struct PeerRosterList: Hashable, Sendable {
    let rows: [PeerRosterRow]

    private init(rows: [PeerRosterRow]) { self.rows = rows }

    /// `No paired peers` when there are no rows, else nil.
    var emptyText: String? { rows.isEmpty ? PeerRosterText.noPairedPeers : nil }

    func row(for identity: PeerIdentityFingerprint) -> PeerRosterRow? {
        rows.first { $0.id == identity }
    }

    /// Rows are ordered by the UTF-8 bytes of the name, then of the identity, so the order is the
    /// same for every permutation of `records`. A missing `connections` entry means disconnected;
    /// an entry with no record is ignored.
    static func make(
        records: [PeerTrustRecord],
        connections: [PeerIdentityFingerprint: PeerReconnectState.Phase] = [:]
    ) throws(PeerRosterRefusal) -> PeerRosterList {
        guard records.count <= PeerTrustStore.maximumPeers else { throw .tooManyPeers(records.count) }
        var seen: Set<PeerIdentityFingerprint> = []
        for record in records where !seen.insert(record.identity).inserted {
            throw .duplicateIdentity(record.identity)
        }
        let rows = records.map { record in
            PeerRosterRow(
                id: record.identity, name: record.label, role: record.role,
                connection: connection(for: connections[record.identity]),
                revoke: .revoke(record.identity)
            )
        }
        return PeerRosterList(rows: rows.sorted(by: precedes))
    }

    /// A connected, synced or resyncing session shows its connection epoch ("Resyncing" is
    /// unchanged on the host, line 90); a lost one or no known session is disconnected.
    private static func connection(for phase: PeerReconnectState.Phase?) -> PeerRosterConnection {
        switch phase {
        case .connected(let session), .synced(let session, _), .resyncing(let session):
            .connected(epoch: session.connectionEpoch.generation.value)
        case .disconnected, nil:
            .disconnected
        }
    }

    private static func precedes(_ lhs: PeerRosterRow, _ rhs: PeerRosterRow) -> Bool {
        let left = Array(lhs.name.utf8)
        let right = Array(rhs.name.utf8)
        if left != right { return left.lexicographicallyPrecedes(right) }
        return lhs.id.bytes.lexicographicallyPrecedes(rhs.id.bytes)
    }
}
