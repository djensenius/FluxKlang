import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Support = PeerTrustTestSupport

/// Fixed vectors for the derivations both peers must compute identically (#94 P1).
/// Computed independently with Python `hashlib` from the documented byte layouts.
#if os(macOS)
@Suite("PeerTrustTests+Vectors", .productionAccessAudit)
#else
@Suite("PeerTrustTests+Vectors")
#endif
struct PeerTrustVectorTests {
    private let hostIdentity = Support.identity(100)
    private let peer = Support.identity(1)

    private func transcript(hostNonce: PeerNonce) -> PeerPairingTranscript {
        let request = PeerPairingRequest(identity: peer, label: "Remote C", requestedRole: .remoteController,
                                         commitment: PeerPairingCommitment(identity: peer, nonce: Support.nonce(1)),
                                         session: Support.session())
        return PeerPairingTranscript(host: hostIdentity, request: request, hostNonce: hostNonce,
                                     peerNonce: Support.nonce(1))
    }

    @Test("The length-prefixed, domain-separated digest matches its fixed vector")
    func digestVector() {
        let digest = PeerTrustDigest.sha256(domain: "d", [[1, 2], [3]])
        #expect(PeerTrustDigest.hex(digest) == "1d5f5b925b07eea3681d9ea6c74b36e5df51f5e785fa6358381261c97de4dc5c")
    }

    @Test("Commitment, transcript and confirmation code match their fixed vectors")
    func pairingVectors() {
        let commitment = PeerPairingCommitment(identity: peer, nonce: Support.nonce(1))
        #expect(PeerTrustDigest.hex(commitment.bytes)
            == "b0bcc08afb1b4176927deefa141f903122dbaf39b3ff3489610f2a5c429432d0")
        let transcript = transcript(hostNonce: Support.nonce(50))
        #expect(PeerTrustDigest.hex(transcript.digest)
            == "f1bb95b91089e81281e12b297967279308fb4ed90f7e0aaf541b6a47897267bb")
        #expect(PeerConfirmationCode(transcript).digits == "486930")
    }

    @Test("A code with a leading zero still renders as six digits")
    func leadingZeroCode() {
        let transcript = transcript(hostNonce: Support.nonce(6))
        #expect(PeerTrustDigest.hex(transcript.digest)
            == "38bd17a8a9dc5f5cc68e06064151f0928518fa8e7ab8f04b516b808720f19b16")
        let code = PeerConfirmationCode(transcript)
        #expect(code.digits == "014812" && code.description == "014812")
        #expect(code.digits.utf8.count == PeerConfirmationCode.digitCount)
    }

    @Test("The permission fingerprint matches its fixed vector")
    func permissionFingerprintVector() throws {
        let store = try Support.store()
        let record = try #require(store.record(for: peer))
        #expect(record.revision == Support.generation(2))
        #expect(record.permissionFingerprint.rawValue
            == "pt1.cfa1cb41683e6b6d2f90cb89a9a9481bf80239fe78eb954e2362b6306343b322")
    }

    @Test("Nonces and commitments are exactly 32 bytes", arguments: [31, 32, 33])
    func lengthsArePinned(count: Int) {
        let bytes = [UInt8](repeating: 7, count: count)
        #expect((PeerNonce(bytes) != nil) == (count == 32))
        #expect((PeerPairingCommitment(bytes) != nil) == (count == 32))
        #expect((PeerIdentityFingerprint(bytes) != nil) == (count == 32))
    }
}
