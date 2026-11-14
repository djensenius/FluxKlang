import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Fixtures for the peer roster suites (#94 PEER1). Self-contained on purpose.
enum PeerRosterFixture {
    static func generation(_ value: Int) -> Generation {
        do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
    }

    static func identity(_ seed: UInt8) -> PeerIdentityFingerprint {
        guard let identity = PeerIdentityFingerprint((0..<32).map { seed &+ UInt8($0) }) else {
            preconditionFailure("invalid identity")
        }
        return identity
    }

    static func remote() throws -> PeerGrantSet {
        let grant = PeerCommandGrant(controlClass: .live, scope: .parameter(ParameterID(validated: "par.fx.gain")))
        return try PeerGrantSet(role: .remoteController, commands: [grant], reads: [.statusRead])
    }

    static func observer() throws -> PeerGrantSet {
        try PeerGrantSet(role: .observer, commands: [], reads: [.statusRead])
    }

    /// A record made by the real store's `pair`, so label and grant rules are the store's.
    static func record(_ seed: UInt8, _ name: String, role: PeerRole = .remoteController) throws -> PeerTrustRecord {
        var store = PeerTrustStore()
        let grants = role == .remoteController ? try remote() : try observer()
        return try store.pair(identity(seed), label: name, grants: grants, protocolFloor: 1)
    }

    /// `count` records with distinct identities, built directly (a real store holds at most 32).
    static func bulk(_ count: Int) throws -> [PeerTrustRecord] {
        try (0..<count).map { index in
            PeerTrustRecord(identity: identity(UInt8(index)), label: "Peer \(index)", grants: try remote(),
                            protocolFloor: 1, revision: .initial)
        }
    }

    static func session(epoch: Int, hostEpoch hostGeneration: Int = 1) throws -> PeerSyncSession {
        let host = HostID(validated: "host.a")
        let hostEpoch = HostEpoch(host: host, generation: try Generation(hostGeneration))
        let connectionEpoch = ConnectionEpoch(
            connection: ConnectionID(validated: "conn.c"), host: host, generation: try Generation(epoch)
        )
        return try #require(PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: connectionEpoch))
    }

    static func request(label: String, role: PeerRole) throws -> PeerPairingRequest {
        let who = identity(1)
        guard let nonce = PeerNonce((0..<32).map { UInt8($0) }) else { preconditionFailure("bad nonce") }
        return PeerPairingRequest(
            identity: who, label: label, requestedRole: role,
            commitment: PeerPairingCommitment(identity: who, nonce: nonce),
            session: PeerNegotiatedSession(protocolVersion: 1, hostEpoch: generation(7),
                                           connectionEpoch: generation(4), capabilities: .empty)
        )
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    static func utf8(_ rows: [PeerRosterRow]) -> [[UInt8]] { rows.map { Array($0.name.utf8) } }
}

@Suite("Peer roster list", .productionAccessAudit)
struct PeerRosterListTests {
    typealias Fixture = PeerRosterFixture

    @Test("The doc example: Remote C connected at epoch 4")
    func docExample() throws {
        let record = try Fixture.record(1, "Remote C")
        let phase = PeerReconnectState.Phase.connected(try Fixture.session(epoch: 4))
        let list = try PeerRosterList.make(records: [record], connections: [record.identity: phase])
        #expect(list.rows.count == 1)
        let row = try #require(list.rows.first)
        #expect(row.name == "Remote C")
        #expect(row.id == record.identity)
        #expect(row.roleText == "Remote controller")
        #expect(row.statusText == "Connected (epoch 4)")
        #expect(row.isDimmed == false)
        #expect(row.revoke == .revoke(record.identity))
        #expect(row.revoke.title == "Revoke")
        #expect(row.revokeTitle == "Revoke")
        #expect(row.revoke.requiresConfirmation == true)
        #expect(row.accessibilityLabel == "Remote C, Remote controller, connected, epoch 4.")
        #expect(list.emptyText == nil)
    }

    @Test("A disconnected phase reads Disconnected and is dimmed")
    func disconnectedPhase() throws {
        let record = try Fixture.record(1, "Remote C")
        let phase = PeerReconnectState.Phase.disconnected(try Fixture.session(epoch: 4))
        let list = try PeerRosterList.make(records: [record], connections: [record.identity: phase])
        let row = try #require(list.rows.first)
        #expect(row.connection == .disconnected)
        #expect(row.statusText == "Disconnected")
        #expect(row.isDimmed == true)
        #expect(row.accessibilityLabel == "Remote C, Remote controller, disconnected.")
    }

    @Test("An absent entry is disconnected, and an entry with no record adds no row")
    func absentAndUnknownEntries() throws {
        let known = try Fixture.record(1, "Remote C")
        let stranger = Fixture.identity(9)
        let session = try Fixture.session(epoch: 4)
        let absent = try PeerRosterList.make(records: [known])
        #expect(try #require(absent.rows.first).connection == .disconnected)
        let list = try PeerRosterList.make(records: [known], connections: [stranger: .connected(session)])
        #expect(list.rows.count == 1)
        #expect(list.rows.map(\.id) == [known.identity])
        #expect(list.row(for: stranger) == nil)
        #expect(try #require(list.rows.first).connection == .disconnected)
    }

    @Test("Each row takes its own connection and revoke target, in either input order")
    func perRowConnectionAndRevoke() throws {
        let alpha = try Fixture.record(1, "Alpha")
        let bravo = try Fixture.record(2, "Bravo")
        let epochFour = PeerReconnectState.Phase.connected(try Fixture.session(epoch: 4))
        let lost = PeerReconnectState.Phase.disconnected(try Fixture.session(epoch: 7))
        let maps: [[PeerIdentityFingerprint: PeerReconnectState.Phase]] = [
            [alpha.identity: epochFour, bravo.identity: lost],
            [alpha.identity: epochFour]
        ]
        for connections in maps {
            for ordering in [[alpha, bravo], [bravo, alpha]] {
                let rows = try PeerRosterList.make(records: ordering, connections: connections).rows
                #expect(rows.count == 2)
                let first = try #require(rows.first)
                let last = try #require(rows.last)
                #expect(first.id == alpha.identity)
                #expect(first.name == "Alpha")
                #expect(first.connection == .connected(epoch: 4))
                #expect(first.statusText == "Connected (epoch 4)")
                #expect(first.revoke == .revoke(first.id))
                #expect(last.id == bravo.identity)
                #expect(last.name == "Bravo")
                #expect(last.connection == .disconnected)
                #expect(last.statusText == "Disconnected")
                #expect(last.revoke == .revoke(last.id))
            }
        }
    }

    @Test("Connected, synced either way and resyncing show the connection epoch, not the host epoch")
    func connectedPhasesShowConnectionEpoch() throws {
        let record = try Fixture.record(1, "Remote C")
        let session = try Fixture.session(epoch: 4, hostEpoch: 9)
        let phases: [PeerReconnectState.Phase] = [
            .connected(session), .synced(session, awaitingResume: true),
            .synced(session, awaitingResume: false), .resyncing(session)
        ]
        for phase in phases {
            let list = try PeerRosterList.make(records: [record], connections: [record.identity: phase])
            let row = try #require(list.rows.first)
            #expect(row.statusText == "Connected (epoch 4)")
            #expect(row.connection == .connected(epoch: 4))
            #expect(row.isDimmed == false)
        }
    }

    @Test("The epoch never comes from the record revision")
    func epochIsNotRevision() throws {
        var store = PeerTrustStore()
        let identity = Fixture.identity(1)
        let first = try store.pair(identity, label: "Remote C", grants: try Fixture.remote(), protocolFloor: 1)
        let second = try store.updateGrants(identity, to: try Fixture.remote())
        #expect(first.revision != second.revision)
        let phase = PeerReconnectState.Phase.connected(try Fixture.session(epoch: 4))
        let before = try PeerRosterList.make(records: [first], connections: [identity: phase])
        let after = try PeerRosterList.make(records: [second], connections: [identity: phase])
        #expect(try #require(before.rows.first).statusText == "Connected (epoch 4)")
        #expect(try #require(after.rows.first).statusText == "Connected (epoch 4)")
    }

    @Test("An observer reads Observer")
    func observerRole() throws {
        let list = try PeerRosterList.make(records: [try Fixture.record(1, "Remote C", role: .observer)])
        let row = try #require(list.rows.first)
        #expect(row.role == .observer)
        #expect(row.roleText == "Observer")
    }

    @Test("Rows are ordered by UTF-8 bytes of the name")
    func ordersByUTF8Bytes() throws {
        let nfc = "\u{E9}"
        let nfd = "e\u{301}"
        let names = ["f", nfc, "alpha", "Zed", nfd, "Alpha"]
        let records = try names.enumerated().map { try Fixture.record(UInt8($0.offset + 1), $0.element) }
        let expected = ["Alpha", "Zed", "alpha", nfd, "f", nfc].map { Array($0.utf8) }
        for ordering in [records, records.reversed()] {
            let list = try PeerRosterList.make(records: ordering)
            #expect(Fixture.utf8(list.rows) == expected)
        }
    }

    @Test("Equal names are broken by identity bytes")
    func equalNamesBreakByIdentity() throws {
        let two = try Fixture.record(2, "Same")
        let one = try Fixture.record(1, "Same")
        let list = try PeerRosterList.make(records: [two, one])
        #expect(list.rows.map(\.id) == [one.identity, two.identity])
    }

    @Test("Every permutation of four records gives the same rows")
    func permutationInvariant() throws {
        let records = [
            try Fixture.record(1, "Same"), try Fixture.record(2, "Same"),
            try Fixture.record(3, "Alpha"), try Fixture.record(4, "alpha")
        ]
        let expected = try PeerRosterList.make(records: records)
        let all = Fixture.permutations(records)
        #expect(all.count == 24)
        for permutation in all {
            #expect(try PeerRosterList.make(records: permutation) == expected)
        }
    }

    @Test("Duplicate display names are both listed")
    func duplicateNamesListed() throws {
        let list = try PeerRosterList.make(records: [try Fixture.record(1, "Remote C"),
                                                      try Fixture.record(2, "Remote C")])
        #expect(list.rows.count == 2)
    }

    @Test("A revoked peer is not listed")
    func revokedPeerNotListed() throws {
        var store = PeerTrustStore()
        let keep = Fixture.identity(1)
        let gone = Fixture.identity(2)
        try store.pair(keep, label: "Keep", grants: try Fixture.remote(), protocolFloor: 1)
        try store.pair(gone, label: "Gone", grants: try Fixture.remote(), protocolFloor: 1)
        try store.revoke(gone)
        let records = [keep, gone].compactMap { store.record(for: $0) }
        let session = try Fixture.session(epoch: 4)
        let list = try PeerRosterList.make(records: records, connections: [gone: .connected(session)])
        #expect(list.rows.map(\.id) == [keep])
        #expect(list.row(for: gone) == nil)
        #expect(list.emptyText == nil)
    }

    @Test("An empty roster says No paired peers")
    func emptyRoster() throws {
        let list = try PeerRosterList.make(records: [])
        #expect(list.rows.isEmpty)
        #expect(list.emptyText == "No paired peers")
    }

    @Test("row(for:) returns the row or nil")
    func rowLookup() throws {
        let record = try Fixture.record(1, "Remote C")
        let list = try PeerRosterList.make(records: [record])
        #expect(list.row(for: record.identity)?.name == "Remote C")
        #expect(list.row(for: Fixture.identity(2)) == nil)
    }

    @Test("More than 32 records are refused, and 32 are accepted")
    func peerBound() throws {
        #expect(PeerTrustStore.maximumPeers == 32)
        #expect(throws: PeerRosterRefusal.tooManyPeers(33)) {
            try PeerRosterList.make(records: try Fixture.bulk(33))
        }
        #expect(try PeerRosterList.make(records: try Fixture.bulk(32)).rows.count == 32)
    }

    @Test("A repeated identity is refused with the first repeat, after the bound check")
    func duplicateIdentity() throws {
        let one = try Fixture.record(1, "One")
        let two = try Fixture.record(2, "Two")
        #expect(throws: PeerRosterRefusal.duplicateIdentity(one.identity)) {
            try PeerRosterList.make(records: [one, two, one])
        }
        #expect(throws: PeerRosterRefusal.duplicateIdentity(two.identity)) {
            try PeerRosterList.make(records: [one, two, two, one])
        }
        #expect(throws: PeerRosterRefusal.tooManyPeers(33)) {
            try PeerRosterList.make(records: Array(repeating: one, count: 33))
        }
    }

    @Test("No row text carries the identity")
    func identityNeverShown() throws {
        let record = try Fixture.record(1, "Remote C")
        let session = try Fixture.session(epoch: 4)
        for phase in [PeerReconnectState.Phase.connected(session), .disconnected(session)] {
            let list = try PeerRosterList.make(records: [record], connections: [record.identity: phase])
            let row = try #require(list.rows.first)
            let hex = Fixture.hex(record.identity.bytes.prefix(4))
            #expect(hex == "01020304")
            for text in [row.accessibilityLabel, row.statusText, row.revokeAccessibilityLabel, row.roleText] {
                #expect(!text.contains("peer:"))
                #expect(!text.contains(hex))
            }
        }
    }

    @Test("make is deterministic and leaves its input alone")
    func deterministic() throws {
        let records = [try Fixture.record(2, "B"), try Fixture.record(1, "A")]
        let copy = records
        let phase = PeerReconnectState.Phase.connected(try Fixture.session(epoch: 4))
        let connections = [records[0].identity: phase]
        let first = try PeerRosterList.make(records: records, connections: connections)
        let second = try PeerRosterList.make(records: records, connections: connections)
        #expect(first == second)
        #expect(records == copy)
    }

    @Test("The revoke action is labelled with the name")
    func revokeLabel() throws {
        let list = try PeerRosterList.make(records: [try Fixture.record(1, "Remote C")])
        #expect(try #require(list.rows.first).revokeAccessibilityLabel == "Revoke Remote C")
    }
}
