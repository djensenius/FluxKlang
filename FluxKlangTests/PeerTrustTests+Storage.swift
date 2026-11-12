import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Support = PeerTrustTestSupport

/// Resolved at compile time: the constrained overload wins for any `Encodable`
/// type, so adding a `Codable` conformance to a trust type turns these red.
private func isEncodable<T>(_: T.Type) -> Bool { false }
private func isEncodable<T: Encodable>(_: T.Type) -> Bool { true }
private func isDecodable<T>(_: T.Type) -> Bool { false }
private func isDecodable<T: Decodable>(_: T.Type) -> Bool { true }

private func runtimeCodable(_ type: Any.Type) -> Bool { type is any Encodable.Type || type is any Decodable.Type }

#if os(macOS)
@Suite("PeerTrustTests+Storage", .productionAccessAudit)
#else
@Suite("PeerTrustTests+Storage")
#endif
struct PeerTrustStorageTests {
    private let peer = Support.identity(1)

    // MARK: Storage isolation

    @Test("Trust material has no Codable path into JSON, project files or iCloud")
    func trustTypesAreNotCodable() {
        #expect(isEncodable(HostEpoch.self) && isDecodable(HostEpoch.self) && runtimeCodable(HostEpoch.self))
        let compileTime = [
            isEncodable(PeerIdentityFingerprint.self), isDecodable(PeerIdentityFingerprint.self),
            isEncodable(PeerNonce.self), isDecodable(PeerNonce.self),
            isEncodable(PeerRole.self), isDecodable(PeerRole.self),
            isEncodable(PeerCommandGrant.self), isDecodable(PeerCommandGrant.self),
            isEncodable(PeerReadGrant.self), isDecodable(PeerReadGrant.self),
            isEncodable(PeerGrantSet.self), isDecodable(PeerGrantSet.self),
            isEncodable(PeerTrustRecord.self), isDecodable(PeerTrustRecord.self),
            isEncodable(PeerTrustStore.self), isDecodable(PeerTrustStore.self),
            isEncodable(PeerAuthorizedSession.self), isDecodable(PeerAuthorizedSession.self),
            isEncodable(PeerPairingCommitment.self), isDecodable(PeerPairingCommitment.self),
            isEncodable(PeerPairingRequest.self), isDecodable(PeerPairingRequest.self),
            isEncodable(PeerPairingTranscript.self), isDecodable(PeerPairingTranscript.self),
            isEncodable(PeerConfirmationCode.self), isDecodable(PeerConfirmationCode.self),
            isEncodable(PeerPairingHost.self), isDecodable(PeerPairingHost.self)
        ]
        #expect(!compileTime.contains(true))
        let types: [Any.Type] = [
            PeerIdentityFingerprint.self, PeerNonce.self, PeerRole.self, PeerCommandGrant.self, PeerReadGrant.self,
            PeerGrantSet.self, PeerTrustRecord.self, PeerTrustStore.self, PeerAuthorizedSession.self,
            PeerPairingCommitment.self, PeerPairingRequest.self, PeerPairingTranscript.self,
            PeerConfirmationCode.self, PeerPairingHost.self
        ]
        #expect(!types.contains(where: runtimeCodable))
    }

    @Test("A peer command carries only the opaque fingerprint, never identity or grants")
    func commandJSONHasNoTrustMaterial() throws {
        let store = try Support.store(trusting: peer)
        let session = try store.bind(peer, session: Support.session(), connection: Support.connection,
                                     host: Support.hostEpoch)
        let intent = try Support.intent(Support.set(Support.fxGain), on: session)
        let json = try #require(String(bytes: try JSONEncoder().encode(intent), encoding: .utf8))
        #expect(json.contains(session.permission.rawValue))
        for secret in [PeerTrustDigest.hex(peer.bytes), PeerTrustDigest.hex(peer.bytes.prefix(8)), "Remote C",
                       "remoteController", "status.read", "live|parameter"] {
            #expect(!json.contains(secret), "leaked \(secret)")
        }
        #expect(!String(describing: peer).contains(PeerTrustDigest.hex(peer.bytes)))
    }

    // MARK: Permission fingerprint

    @Test("The permission fingerprint is opaque, stable and changes with grants, role and re-pair")
    func fingerprintTracksEveryChange() throws {
        var store = try Support.store(trusting: peer)
        let first = try #require(store.record(for: peer)).permissionFingerprint
        #expect(first.isWellFormed && first.rawValue.hasPrefix("pt1.") && first.rawValue.utf8.count == 68)
        #expect(try #require(store.record(for: peer)).permissionFingerprint == first)
        try store.pair(Support.identity(2), label: "Other", grants: Support.remote(), protocolFloor: 1)
        #expect(try #require(store.record(for: peer)).permissionFingerprint == first)
        #expect(try #require(store.record(for: Support.identity(2))).permissionFingerprint != first)

        var seen: Set<PermissionFingerprint> = [first]
        try store.updateGrants(peer, to: Support.remote([Support.fxGain, Support.outGain]))
        #expect(seen.insert(try #require(store.record(for: peer)).permissionFingerprint).inserted)
        try store.updateGrants(peer, to: Support.remote())
        #expect(seen.insert(try #require(store.record(for: peer)).permissionFingerprint).inserted)
        try store.updateGrants(peer, to: Support.observer())
        #expect(seen.insert(try #require(store.record(for: peer)).permissionFingerprint).inserted)
        try store.revoke(peer)
        try store.clearRevocation(peer)
        try store.pair(peer, label: "Remote C", grants: Support.remote(), protocolFloor: 1)
        #expect(seen.insert(try #require(store.record(for: peer)).permissionFingerprint).inserted)
    }

    // MARK: Revocation

    @Test("A revoked identity is denied, cannot bind and its in-flight command is denied")
    func revokedIdentityRejects() throws {
        var store = try Support.store(trusting: peer)
        let session = try store.bind(peer, session: Support.session(), connection: Support.connection,
                                     host: Support.hostEpoch)
        let intent = try Support.intent(Support.set(Support.fxGain), on: session)
        try store.revoke(peer)
        #expect(store.availability(for: peer) == .denied && store.record(for: peer) == nil)
        #expect(throws: PeerTrustError.revoked) {
            try store.bind(peer, session: Support.session(), connection: Support.connection, host: Support.hostEpoch)
        }
        #expect(try Support.admit(intent, from: session, trust: store) == .refused(.rejected(.permissionDenied)))
        #expect(throws: PeerTrustError.revoked) { try store.revoke(peer) }
        #expect(throws: PeerTrustError.revoked) { try store.updateGrants(peer, to: Support.remote()) }
        #expect(throws: PeerTrustError.unknownIdentity) { try store.revoke(Support.identity(9)) }
    }

    @Test("A grant change turns an in-flight command into permissionChanged")
    func grantChangeInvalidatesInFlight() throws {
        var store = try Support.store(trusting: peer)
        let session = try store.bind(peer, session: Support.session(), connection: Support.connection,
                                     host: Support.hostEpoch)
        let intent = try Support.intent(Support.set(Support.fxGain), on: session)
        try store.updateGrants(peer, to: Support.remote([Support.fxGain, Support.outGain]))
        #expect(try Support.admit(intent, from: session, trust: store) == .refused(.rejected(.permissionChanged)))
        let rebound = try store.bind(peer, session: Support.session(), connection: Support.connection,
                                     host: Support.hostEpoch)
        let fresh = try Support.intent(Support.set(Support.outGain), on: rebound)
        #expect(try Support.admit(fresh, from: rebound, trust: store) == .admitted)
    }

    @Test("Revocation is final until the host explicitly clears it")
    func revokedIsFinal() throws {
        var store = try Support.store(trusting: peer)
        try store.revoke(peer)
        #expect(throws: PeerTrustError.revoked) { try store.checkPairable(peer) }
        #expect(throws: PeerTrustError.revoked) {
            try store.pair(peer, label: "Remote C", grants: Support.remote(), protocolFloor: 1)
        }
        let before = store.revision
        try store.clearRevocation(peer)
        #expect(store.revision != before && !store.isRevoked(peer))
        #expect(throws: PeerTrustError.notRevoked) { try store.clearRevocation(peer) }
        try store.pair(peer, label: "Remote C", grants: Support.remote(), protocolFloor: 1)
        #expect(store.availability(for: peer) == .available)
    }

    // MARK: Bounds

    @Test("A full revocation list refuses pairing and never evicts a revocation")
    func revocationListFullFailsClosed() throws {
        var store = PeerTrustStore()
        for seed in 0..<UInt8(PeerTrustStore.maximumRecords) {
            try store.pair(Support.identity(seed), label: "Peer", grants: Support.observer(), protocolFloor: 1)
            try store.revoke(Support.identity(seed))
        }
        #expect(store.revokedCount == PeerTrustStore.maximumRecords && store.trustedCount == 0)
        #expect(throws: PeerTrustError.revocationListFull) {
            try store.pair(Support.identity(200), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        #expect((0..<UInt8(PeerTrustStore.maximumRecords)).allSatisfy { store.isRevoked(Support.identity($0)) })
        try store.clearRevocation(Support.identity(0))
        try store.pair(Support.identity(200), label: "Peer", grants: Support.observer(), protocolFloor: 1)
    }

    @Test("Trusted peers reserve room for their own revocation")
    func trustedPeersReserveRevocations() throws {
        var store = PeerTrustStore()
        for seed in 0..<UInt8(PeerTrustStore.maximumPeers) {
            try store.pair(Support.identity(seed), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        #expect(throws: PeerTrustError.capacityExceeded) {
            try store.pair(Support.identity(200), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        for seed in 0..<UInt8(PeerTrustStore.maximumPeers) { try store.revoke(Support.identity(seed)) }
        for seed in 32..<UInt8(PeerTrustStore.maximumRecords) {
            try store.pair(Support.identity(seed), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        #expect(store.trustedCount == 32 && store.revokedCount == 32)
        #expect(throws: PeerTrustError.capacityExceeded) {
            try store.pair(Support.identity(200), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        try store.revoke(Support.identity(32))
        #expect(store.revokedCount == 33)
        #expect(throws: PeerTrustError.combinedRecordCapacityFull) {
            try store.pair(Support.identity(200), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        for seed in 33..<UInt8(PeerTrustStore.maximumRecords) { try store.revoke(Support.identity(seed)) }
        #expect(store.revokedCount == PeerTrustStore.maximumRecords)
    }

    @Test("Labels that look blank, break lines or hide scalars are refused, never trimmed")
    func labelsMustBeVisible() throws {
        let unassigned = "\u{0378}"
        let refused = [
            "Stage\u{2028}Left", "Stage\u{2029}Left", " ", "\u{00A0}", "\u{3164}", "\u{0301}", "\u{0301}Keys",
            "Keys\u{E000}", "Keys" + unassigned, " Keys", "Keys ", "Keys\u{00A0}", "\u{115F}\u{1160}\u{FFA0}",
            "Ke\u{034F}ys", "Keys\u{3164}",
            // Format (Cf) scalars that are not default-ignorable, so only the Cf rule refuses them.
            "\u{0600}12", "Keys\u{FFF9}"
        ]
        #expect(Unicode.Scalar(0x0378)?.properties.generalCategory == .unassigned)
        var store = PeerTrustStore()
        for label in refused {
            #expect(throws: PeerTrustError.invalidLabel, "\(label.unicodeScalars.map(\.value))") {
                try store.pair(peer, label: label, grants: Support.observer(), protocolFloor: 1)
            }
        }
        #expect(store.trustedCount == 0)
        let accepted = ["Dave's iPad", "Stage Left 2", "Keys \u{2764}\u{FE0F}", "Пульт", "e\u{0301}"]
        for (seed, label) in accepted.enumerated() {
            let identity = Support.identity(UInt8(seed) &+ 10)
            let record = try store.pair(identity, label: label, grants: Support.observer(), protocolFloor: 1)
            #expect(record.label == label)
        }
    }

    @Test("Labels refuse control and format (bidi, zero-width) scalars; protocol floors are bounded")
    func recordBounds() throws {
        var store = PeerTrustStore()
        let formatScalars = ["\u{202E}", "\u{200B}", "\u{200D}", "\u{2066}", "\u{FEFF}"]
        let invalid = ["", String(repeating: "a", count: 65), "Remote\nC", "Remote\u{0}"]
            + formatScalars.map { "Remote" + $0 + "C" }
        for label in invalid {
            #expect(throws: PeerTrustError.invalidLabel) {
                try store.pair(peer, label: label, grants: Support.observer(), protocolFloor: 1)
            }
        }
        #expect(store.trustedCount == 0)
        #expect(throws: PeerTrustError.invalidProtocolVersion) {
            try store.pair(peer, label: "Remote C", grants: Support.observer(), protocolFloor: 0)
        }
        try store.pair(peer, label: String(repeating: "a", count: 64), grants: Support.observer(), protocolFloor: 1)
        #expect(throws: PeerTrustError.alreadyTrusted) {
            try store.pair(peer, label: "Again", grants: Support.observer(), protocolFloor: 1)
        }
        #expect(store.revision == Support.generation(2))
    }
}
