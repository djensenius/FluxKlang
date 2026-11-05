import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Support = PeerTrustTestSupport

@Suite("PeerTrustTests+Pairing")
struct PeerTrustPairingTests {
    private let hostIdentity = Support.identity(100)
    private let peer = Support.identity(1)
    private let start = ContinuousClock.now

    private func request(_ identity: PeerIdentityFingerprint? = nil, nonce: PeerNonce = Support.nonce(1),
                         role: PeerRole = .remoteController, version: UInt16 = 1) -> PeerPairingRequest {
        let identity = identity ?? peer
        return PeerPairingRequest(identity: identity, label: "Remote C", requestedRole: role,
                                  commitment: PeerPairingCommitment(identity: identity, nonce: nonce),
                                  session: Support.session(version: version))
    }

    /// A host that has shown the confirmation code for `peer`.
    private func prompted(hostNonce: PeerNonce = Support.nonce(50), peerNonce: PeerNonce = Support.nonce(1),
                          trust: PeerTrustStore = PeerTrustStore()) throws -> (PeerPairingHost, PeerConfirmationCode) {
        var host = PeerPairingHost(identity: hostIdentity)
        try host.begin(request(nonce: peerNonce), transportIdentity: peer, hostNonce: hostNonce, now: start,
                       trust: trust)
        guard case .awaitingDecision(let code) = try host.reveal(peerNonce, now: start) else {
            Issue.record("expected the prompt")
            throw PeerPairingError.unexpectedStep
        }
        return (host, code)
    }

    @Test("Allow trusts exactly the host's explicit role, not the requested one")
    func allowUsesExplicitRole() throws {
        var trust = PeerTrustStore()
        var (host, _) = try prompted(trust: trust)
        let outcome = try host.decide(.allow(Support.observer()), now: start, trust: &trust)
        guard case .approved(let record) = outcome else { Issue.record("not approved: \(outcome)"); return }
        #expect(record.role == .observer && record.identity == peer && record.protocolFloor == 1)
        #expect(trust.record(for: peer) == record)
        #expect(host.phase == .finished(outcome))
    }

    @Test("Nothing is trusted without a decision; Deny and Escape both deny")
    func denyIsDefault() throws {
        var trust = PeerTrustStore()
        var (host, code) = try prompted(trust: trust)
        #expect(host.tick(now: start + .seconds(59)) == .awaitingDecision(code))
        #expect(trust.trustedCount == 0)
        #expect(try host.decide(.deny, now: start, trust: &trust) == .denied(.denied))
        var (escaping, _) = try prompted(hostNonce: Support.nonce(51), peerNonce: Support.nonce(2), trust: trust)
        #expect(try escaping.decide(.escape, now: start, trust: &trust) == .denied(.escaped))
        #expect(trust.trustedCount == 0 && trust.revision == .initial)
    }

    @Test("The decision deadline denies, and a late Allow is refused")
    func timeoutDenies() throws {
        var trust = PeerTrustStore()
        var (host, _) = try prompted(trust: trust)
        #expect(host.tick(now: start + PeerPairingHost.decisionWindow) == .finished(.denied(.timedOut)))
        #expect(throws: PeerPairingError.unexpectedStep) {
            try host.decide(.allow(Support.remote()), now: start, trust: &trust)
        }
        var (late, _) = try prompted(hostNonce: Support.nonce(51), peerNonce: Support.nonce(2), trust: trust)
        #expect(throws: PeerPairingError.unexpectedStep) {
            try late.decide(.allow(Support.remote()), now: start + .seconds(61), trust: &trust)
        }
        #expect(late.phase == .finished(.denied(.timedOut)))
        #expect(trust.trustedCount == 0)
    }

    @Test("Finished attempts are terminal")
    func terminalStatesIgnoreInput() throws {
        var trust = PeerTrustStore()
        var (host, _) = try prompted(trust: trust)
        _ = try host.decide(.deny, now: start, trust: &trust)
        #expect(throws: PeerPairingError.unexpectedStep) { try host.reveal(Support.nonce(1), now: start) }
        #expect(throws: PeerPairingError.unexpectedStep) {
            try host.decide(.allow(Support.remote()), now: start, trust: &trust)
        }
        #expect(host.phase == .finished(.denied(.denied)) && trust.trustedCount == 0)
        var idle = PeerPairingHost(identity: hostIdentity)
        #expect(throws: PeerPairingError.unexpectedStep) { try idle.reveal(Support.nonce(1), now: start) }
    }

    @Test("Reused host or peer nonces are refused")
    func replayedNonceRejects() throws {
        var trust = PeerTrustStore()
        var (host, _) = try prompted(trust: trust)
        _ = try host.decide(.deny, now: start, trust: &trust)
        #expect(throws: PeerPairingError.nonceReplay) {
            try host.begin(request(nonce: Support.nonce(2)), transportIdentity: peer, hostNonce: Support.nonce(50),
                           now: start, trust: trust)
        }
        // The peer replays its earlier commitment and reveal against a fresh host nonce.
        try host.begin(request(), transportIdentity: peer, hostNonce: Support.nonce(51), now: start, trust: trust)
        #expect(try host.reveal(Support.nonce(1), now: start) == .finished(.denied(.nonceReplay)))
        // A peer that reflects the host's own nonce.
        try host.begin(request(nonce: Support.nonce(52)), transportIdentity: peer, hostNonce: Support.nonce(52),
                       now: start, trust: trust)
        #expect(try host.reveal(Support.nonce(52), now: start) == .finished(.denied(.nonceReplay)))
        #expect(trust.trustedCount == 0)
    }

    @Test("A reveal that does not open the commitment denies")
    func commitmentMismatchRejects() throws {
        var host = PeerPairingHost(identity: hostIdentity)
        try host.begin(request(nonce: Support.nonce(1)), transportIdentity: peer, hostNonce: Support.nonce(50),
                       now: start, trust: PeerTrustStore())
        #expect(try host.reveal(Support.nonce(9), now: start) == .finished(.denied(.commitmentMismatch)))
        // A commitment to another identity's key does not open for this peer.
        let other = PeerPairingRequest(
            identity: peer, label: "Remote C", requestedRole: .observer,
            commitment: PeerPairingCommitment(identity: Support.identity(2), nonce: Support.nonce(3)),
            session: Support.session()
        )
        try host.begin(other, transportIdentity: peer, hostNonce: Support.nonce(51), now: start,
                       trust: PeerTrustStore())
        #expect(try host.reveal(Support.nonce(3), now: start) == .finished(.denied(.commitmentMismatch)))
    }

    @Test("The claimed identity must be the transport identity")
    func identityMismatchRejects() throws {
        var host = PeerPairingHost(identity: hostIdentity)
        #expect(throws: PeerPairingError.identityMismatch) {
            try host.begin(request(), transportIdentity: Support.identity(2), hostNonce: Support.nonce(50),
                           now: start, trust: PeerTrustStore())
        }
        #expect(throws: PeerPairingError.identityMismatch) {
            try host.begin(request(hostIdentity), transportIdentity: hostIdentity, hostNonce: Support.nonce(50),
                           now: start, trust: PeerTrustStore())
        }
        #expect(host.phase == .idle)
    }

    @Test("One prompt at a time; a second request is busy until the first ends")
    func secondRequestBusy() throws {
        var trust = PeerTrustStore()
        var (host, code) = try prompted(trust: trust)
        #expect(throws: PeerPairingError.busy) {
            try host.begin(request(Support.identity(2), nonce: Support.nonce(4)),
                           transportIdentity: Support.identity(2), hostNonce: Support.nonce(53), now: start,
                           trust: trust)
        }
        #expect(host.phase == .awaitingDecision(code))
        _ = try host.decide(.deny, now: start, trust: &trust)
        try host.begin(request(Support.identity(2), nonce: Support.nonce(4)), transportIdentity: Support.identity(2),
                       hostNonce: Support.nonce(53), now: start, trust: trust)
        #expect(host.phase == .awaitingReveal)
    }

    @Test("The last 256 nonces are refused; remembering a 257th forgets only the oldest")
    func nonceMemoryEdge() throws {
        func indexed(_ index: Int) throws -> PeerNonce {
            try #require(PeerNonce([UInt8(index >> 8), UInt8(index & 0xFF)] + Array(repeating: 0xA5, count: 30)))
        }
        let trust = PeerTrustStore()
        var host = PeerPairingHost(identity: hostIdentity)
        let unopened = request(nonce: Support.nonce(9))
        for attempt in 0..<128 { // 256 nonces: one host and one peer nonce per attempt
            try host.begin(unopened, transportIdentity: peer, hostNonce: indexed(2 * attempt), now: start, trust: trust)
            #expect(try host.reveal(indexed(2 * attempt + 1), now: start) == .finished(.denied(.commitmentMismatch)))
        }
        #expect(throws: PeerPairingError.nonceReplay) {
            try host.begin(unopened, transportIdentity: peer, hostNonce: indexed(0), now: start, trust: trust)
        }
        try host.begin(request(nonce: indexed(0)), transportIdentity: peer, hostNonce: indexed(256), now: start,
                       trust: trust)
        var probe = host
        probe.tick(now: start + PeerPairingHost.decisionWindow)
        #expect(throws: PeerPairingError.nonceReplay) {
            try probe.begin(unopened, transportIdentity: peer, hostNonce: indexed(1), now: start, trust: trust)
        }
        guard case .awaitingDecision = try host.reveal(indexed(0), now: start) else {
            Issue.record("the 257th nonce should have evicted the oldest"); return
        }
    }

    @Test("Revoked, already trusted and full stores refuse to start pairing")
    func trustPreconditions() throws {
        var trust = try Support.store(trusting: peer)
        var host = PeerPairingHost(identity: hostIdentity)
        #expect(throws: PeerPairingError.trust(.alreadyTrusted)) {
            try host.begin(request(), transportIdentity: peer, hostNonce: Support.nonce(50), now: start, trust: trust)
        }
        try trust.revoke(peer)
        #expect(throws: PeerPairingError.trust(.revoked)) {
            try host.begin(request(), transportIdentity: peer, hostNonce: Support.nonce(50), now: start, trust: trust)
        }
    }

    @Test("A store that fills while the prompt is up refuses the Allow")
    func approvalRechecksTrust() throws {
        var trust = PeerTrustStore()
        var (host, _) = try prompted(trust: trust)
        for seed in 0..<UInt8(PeerTrustStore.maximumPeers) {
            try trust.pair(Support.identity(seed &+ 120), label: "Peer", grants: Support.observer(), protocolFloor: 1)
        }
        let outcome = try host.decide(.allow(Support.remote()), now: start, trust: &trust)
        #expect(outcome == .denied(.trustRefused(.capacityExceeded)) && trust.record(for: peer) == nil)
    }

    @Test("The confirmation code is six digits from the whole transcript, not the identity")
    func confirmationCodeIsTranscriptBound() throws {
        let (_, code) = try prompted()
        let isDecimal = code.digits.utf8.allSatisfy { (0x30...0x39).contains($0) }
        #expect(code.digits.count == PeerConfirmationCode.digitCount && isDecimal)
        let (_, again) = try prompted()
        #expect(again == code)
        let base = request()
        func digits(_ request: PeerPairingRequest, host: PeerIdentityFingerprint = hostIdentity,
                    hostNonce: PeerNonce = Support.nonce(50), peerNonce: PeerNonce = Support.nonce(1)) -> String {
            PeerConfirmationCode(PeerPairingTranscript(host: host, request: request, hostNonce: hostNonce,
                                                       peerNonce: peerNonce)).digits
        }
        #expect(digits(base) == again.digits)
        let variants = [
            digits(base, hostNonce: Support.nonce(51)), digits(base, peerNonce: Support.nonce(2)),
            digits(base, host: Support.identity(101)), digits(request(role: .observer)), digits(request(version: 2)),
            digits(request(Support.identity(2)))
        ]
        #expect(variants.allSatisfy { $0 != digits(base) })
        let transcript = PeerPairingTranscript(host: hostIdentity, request: base, hostNonce: Support.nonce(50),
                                               peerNonce: Support.nonce(1))
        #expect(transcript.digest.count == 32 && transcript.digest != peer.bytes)
    }
}
