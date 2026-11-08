import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Controller-side pairing initiator (#94 P2). Time comes only from `start` (one read of the clock, as in
/// `PeerTrustTests+Pairing`) plus durations; nothing sleeps and nothing else reads a clock.
@Suite("PeerPairingInitiatorTests")
struct PeerPairingInitiatorTests {
    let start = ContinuousClock.now
    /// The number of the first attempt every fixture starts from a fresh initiator.
    static let firstAttempt = PeerInitiatorAttemptID(value: 1)
    let own = PeerPairingInitiatorTests.identity(1)
    let host = PeerPairingInitiatorTests.identity(100)

    static func identity(_ seed: UInt8) -> PeerIdentityFingerprint {
        guard let identity = PeerIdentityFingerprint((0..<32).map { seed &+ UInt8($0) }) else {
            preconditionFailure("invalid identity")
        }
        return identity
    }

    /// A distinct 32-byte nonce per `value` (big-endian counter in the first four bytes).
    static func nonce(_ value: UInt32) -> PeerNonce {
        let counter = (0..<4).map { UInt8(truncatingIfNeeded: value >> (UInt32(3 - $0) * 8)) }
        guard let nonce = PeerNonce(counter + [UInt8](repeating: 0x5A, count: 28)) else {
            preconditionFailure("invalid nonce")
        }
        return nonce
    }

    static func session(version: UInt16 = 1) -> PeerNegotiatedSession {
        PeerNegotiatedSession(protocolVersion: version, hostEpoch: .initial, connectionEpoch: .initial,
                              capabilities: .empty)
    }

    func spec(identity: PeerIdentityFingerprint? = nil, host hostIdentity: PeerIdentityFingerprint? = nil,
              label: String = "Remote C", role: PeerRole = .remoteController,
              version: UInt16 = 1) -> PeerPairingAttemptSpec {
        PeerPairingAttemptSpec(identity: identity ?? own, hostIdentity: hostIdentity ?? host, label: label,
                               role: role, session: Self.session(version: version))
    }

    /// Where an initiator is, for the out-of-phase matrix. Own nonce 1, host nonce 2.
    enum Stage: CaseIterable {
        case idle, committed, awaitingHostNonce, showing, awaitingDecision, paired, denied, timedOut
    }

    /// One call on an initiator; `kind` names the method for tables.
    enum Step {
        case sent
        case host(PeerNonce)
        case confirm(Bool)
        case outcome(Bool)
        case start(PeerPairingAttemptSpec, PeerNonce)

        var kind: String {
            switch self {
            case .sent: "sent"
            case .host: "host"
            case .confirm: "confirm"
            case .outcome: "outcome"
            case .start: "start"
            }
        }
    }

    func initiator(at stage: Stage, revealed: Bool = false) throws -> PeerPairingInitiator {
        var value = PeerPairingInitiator()
        if stage == .idle { return value }
        _ = try value.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        switch stage {
        case .idle, .committed: break
        case .timedOut: value.tick(now: start + .seconds(60))
        case .awaitingHostNonce: try value.requestSent(now: start)
        case .showing, .awaitingDecision, .paired, .denied:
            try value.requestSent(now: start)
            _ = try value.receiveHostNonce(Self.nonce(2), now: start)
            try advance(&value, stage: stage, revealed: revealed)
        }
        return value
    }

    private func advance(_ value: inout PeerPairingInitiator, stage: Stage, revealed: Bool) throws {
        switch stage {
        case .awaitingDecision:
            try value.userConfirmed(codesMatch: true, for: Self.firstAttempt, now: start)
            if revealed { _ = value.revealToSend(now: start) }
        case .paired:
            try value.userConfirmed(codesMatch: true, for: Self.firstAttempt, now: start)
            _ = value.revealToSend(now: start)
            try value.hostOutcome(approved: true, now: start)
        case .denied: try value.userConfirmed(codesMatch: false, for: Self.firstAttempt, now: start)
        case .idle, .committed, .awaitingHostNonce, .showing, .timedOut: break
        }
    }

    func apply(_ step: Step, to initiator: inout PeerPairingInitiator,
               at now: ContinuousClock.Instant) throws(PeerInitiatorError) {
        switch step {
        case .sent: try initiator.requestSent(now: now)
        case .host(let nonce): _ = try initiator.receiveHostNonce(nonce, now: now)
        case .confirm(let match):
            try initiator.userConfirmed(codesMatch: match, for: Self.firstAttempt, now: now)
        case .outcome(let approved): try initiator.hostOutcome(approved: approved, now: now)
        case .start(let spec, let nonce): _ = try initiator.startAttempt(spec, nonce: nonce, now: now)
        }
    }

    /// The refusal `step` produces, or nil when it succeeds.
    func refusal(of step: Step, on initiator: inout PeerPairingInitiator,
                 at now: ContinuousClock.Instant) -> PeerInitiatorError? {
        do {
            try apply(step, to: &initiator, at: now)
            return nil
        } catch { return error }
    }

    func allSteps() -> [Step] {
        [.sent, .host(Self.nonce(60)), .confirm(true), .confirm(false), .outcome(true), .outcome(false),
         .start(spec(), Self.nonce(61))]
    }

    /// Ends the current attempt by letting its deadline pass (one nonce inserted into the memory per attempt).
    func expire(_ initiator: inout PeerPairingInitiator) {
        initiator.tick(now: start + PeerPairingInitiator.decisionWindow)
    }

    // MARK: Starting an attempt

    @Test("Begin commits to the nonce and returns the request built from its inputs")
    func initiatorBeginBuildsTheRequestFromItsInputsAndCommitsToTheNonce() throws {
        let attempt = spec(label: "Stage Remote", role: .observer, version: 3)
        let (initiator, request) = try PeerPairingInitiator.begin(attempt, nonce: Self.nonce(9), now: start)
        #expect(request.identity == own && request.label == "Stage Remote" && request.requestedRole == .observer)
        #expect(request.session == Self.session(version: 3))
        #expect(request.commitment == PeerPairingCommitment(identity: own, nonce: Self.nonce(9)))
        #expect(request.commitment != PeerPairingCommitment(identity: own, nonce: Self.nonce(10)))
        #expect(initiator.status == .committed)
    }

    @Test("A label of 64 UTF-8 bytes is accepted and 65 is refused, counted in bytes not characters")
    func initiatorBeginAcceptsLabelsOf64BytesAndRefuses65() throws {
        let euro = "\u{20AC}"
        let accepted = [String(repeating: "a", count: 64), String(repeating: "a", count: 61) + euro,
                        String(repeating: euro, count: 21) + "a", "a"]
        for label in accepted {
            var initiator = PeerPairingInitiator()
            #expect(try initiator.startAttempt(spec(label: label), nonce: Self.nonce(1), now: start).label == label)
        }
        let refused = [String(repeating: "a", count: 65), String(repeating: "a", count: 62) + euro,
                       String(repeating: euro, count: 22), "", String(repeating: euro, count: 100)]
        for label in refused {
            var initiator = PeerPairingInitiator()
            let before = initiator
            #expect(refusal(of: .start(spec(label: label), Self.nonce(1)), on: &initiator, at: start)
                    == .invalidLabel, "label of \(label.utf8.count) bytes")
            #expect(initiator == before)
        }
    }

    @Test("Hidden, whitespace-edged and combining-first labels are refused without a change")
    func initiatorBeginRefusesLabelsThePairingRuleRefuses() {
        let refused = [" ", "\u{200B}", " Remote", "Remote ", "Re\u{0007}mote", "Re\u{202E}mote", "Re\u{200B}mote",
                       "\u{0301}Remote", "Re\u{2028}mote", "Re\u{E000}mote", "\u{3164}"]
        for label in refused {
            var initiator = PeerPairingInitiator()
            let before = initiator
            #expect(refusal(of: .start(spec(label: label), Self.nonce(1)), on: &initiator, at: start)
                    == .invalidLabel, "label \(label.unicodeScalars.map(\.value))")
            #expect(initiator == before)
        }
    }

    @Test("Protocol version 1 and the maximum are accepted and 0 is refused without a change")
    func initiatorBeginRefusesProtocolVersionZeroAndAcceptsOneAndTheMaximum() throws {
        for version in [UInt16(1), 2, UInt16.max] {
            _ = try PeerPairingInitiator.begin(spec(version: version), nonce: Self.nonce(1), now: start)
        }
        var initiator = PeerPairingInitiator()
        let before = initiator
        #expect(refusal(of: .start(spec(version: 0), Self.nonce(1)), on: &initiator, at: start)
                == .protocolVersionInvalid)
        #expect(initiator == before)
    }

    @Test("Our identity equal to the host's is refused by its 32 bytes, and one differing byte is accepted")
    func initiatorBeginRefusesTheSameIdentityByRawBytes() throws {
        var initiator = PeerPairingInitiator()
        let before = initiator
        let twin = Self.identity(1)
        #expect(refusal(of: .start(spec(host: twin), Self.nonce(1)), on: &initiator, at: start) == .sameIdentity)
        #expect(initiator == before)
        var bytes = own.bytes
        bytes[31] ^= 0x01
        let neighbour = try #require(PeerIdentityFingerprint(bytes))
        _ = try PeerPairingInitiator.begin(spec(host: neighbour), nonce: Self.nonce(1), now: start)
    }

    @Test("A same-identity defect outranks an invalid label")
    func initiatorStartAttemptSameIdentityOutranksInvalidLabel() {
        var initiator = PeerPairingInitiator()
        let before = initiator
        let both = spec(host: own, label: " ")
        #expect(refusal(of: .start(both, Self.nonce(1)), on: &initiator, at: start) == .sameIdentity)
        #expect(initiator == before)
        #expect(refusal(of: .start(spec(label: " "), Self.nonce(1)), on: &initiator, at: start) == .invalidLabel)
        #expect(refusal(of: .start(spec(host: own), Self.nonce(1)), on: &initiator, at: start) == .sameIdentity)
    }

    @Test("An invalid label outranks protocol version zero")
    func initiatorStartAttemptInvalidLabelOutranksProtocolVersionZero() {
        var initiator = PeerPairingInitiator()
        let before = initiator
        #expect(refusal(of: .start(spec(label: " ", version: 0), Self.nonce(1)), on: &initiator, at: start)
                == .invalidLabel)
        #expect(initiator == before)
        #expect(refusal(of: .start(spec(version: 0), Self.nonce(1)), on: &initiator, at: start)
                == .protocolVersionInvalid)
        #expect(refusal(of: .start(spec(label: " "), Self.nonce(1)), on: &initiator, at: start) == .invalidLabel)
    }

    @Test("Protocol version zero outranks a replayed own nonce, which is still refused alone")
    func initiatorStartAttemptProtocolVersionZeroOutranksNonceReplay() throws {
        var initiator = try self.initiator(at: .denied)
        let before = initiator
        #expect(refusal(of: .start(spec(version: 0), Self.nonce(1)), on: &initiator, at: start)
                == .protocolVersionInvalid)
        #expect(initiator == before)
        #expect(refusal(of: .start(spec(), Self.nonce(1)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator == before)
        #expect(refusal(of: .start(spec(), Self.nonce(2)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator == before)
    }

    @Test("A running attempt makes every start busy, ahead of every other defect, without a change")
    func initiatorStartAttemptBusyOutranksEveryOtherRefusal() throws {
        let everything = spec(host: own, label: " ", version: 0)
        for stage in [Stage.committed, .awaitingHostNonce, .showing, .awaitingDecision] {
            var initiator = try self.initiator(at: stage)
            let before = initiator
            #expect(refusal(of: .start(everything, Self.nonce(1)), on: &initiator, at: start) == .busy)
            #expect(refusal(of: .start(spec(), Self.nonce(77)), on: &initiator, at: start) == .busy)
            #expect(initiator == before, "\(stage)")
        }
        for stage in [Stage.idle, .paired, .denied, .timedOut] {
            var initiator = try self.initiator(at: stage)
            #expect(refusal(of: .start(spec(), Self.nonce(77)), on: &initiator, at: start) == nil, "\(stage)")
            #expect(initiator.status == .committed)
        }
    }
}
