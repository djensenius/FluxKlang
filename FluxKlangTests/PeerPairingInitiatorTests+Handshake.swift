import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerPairingInitiatorTests {
    private func observerGrants() throws -> PeerGrantSet {
        try PeerGrantSet(role: .observer, commands: [], reads: [.statusRead])
    }

    /// The code an initiator shows for `attempt` with these two nonces.
    private func shownCode(_ attempt: PeerPairingAttemptSpec, own: UInt32, host hostNonce: UInt32) throws
        -> PeerConfirmationCode {
        var initiator = PeerPairingInitiator()
        _ = try initiator.startAttempt(attempt, nonce: Self.nonce(own), now: start)
        try initiator.requestSent(now: start)
        return try initiator.receiveHostNonce(Self.nonce(hostNonce), now: start).code
    }

    // MARK: Against the real host (the only tests that touch `PeerPairingHost`)

    @Test("A real host and the initiator derive the same code, and a host Allow is approved")
    func initiatorAndARealHostDeriveTheSameCodeAndAnAllowIsApproved() throws {
        #expect(PeerPairingInitiator.decisionWindow == .seconds(60) && PeerPairingInitiator.nonceMemory == 256)
        #expect(PeerPairingInitiator.decisionWindow == PeerPairingHost.decisionWindow)
        #expect(PeerPairingInitiator.nonceMemory == PeerPairingHost.nonceMemory)
        var trust = PeerTrustStore()
        var peerHost = PeerPairingHost(identity: host)
        var initiator = PeerPairingInitiator()
        let request = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start)
        let attempt = try peerHost.begin(request, transportIdentity: own, hostNonce: Self.nonce(2), now: start,
                                         trust: trust)
        let shown = try initiator.receiveHostNonce(Self.nonce(2), now: start)
        let code = shown.code
        let revealedNonce = initiator.revealToSend(now: start)
        let revealed = try #require(revealedNonce)
        guard case .awaitingDecision(let prompt) = try peerHost.reveal(revealed, now: start) else {
            Issue.record("the host did not accept the reveal")
            return
        }
        #expect(prompt.code == code && prompt.attempt == attempt)
        try initiator.userConfirmed(codesMatch: true, for: shown.attempt, now: start)
        let outcome = try peerHost.decide(.allow(observerGrants()), for: attempt, now: start, trust: &trust)
        guard case .approved(let record) = outcome else {
            Issue.record("not approved: \(outcome)")
            return
        }
        #expect(record.identity == own && record.label == "Remote C")
        try initiator.hostOutcome(approved: true, now: start)
        #expect(initiator.status == .paired)
    }

    @Test("A real host's Deny arrives as a denied status and trusts nothing")
    func initiatorAndARealHostDenyIsADeniedStatus() throws {
        var trust = PeerTrustStore()
        var peerHost = PeerPairingHost(identity: host)
        var initiator = PeerPairingInitiator()
        let request = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start)
        let attempt = try peerHost.begin(request, transportIdentity: own, hostNonce: Self.nonce(2), now: start,
                                         trust: trust)
        let shown = try initiator.receiveHostNonce(Self.nonce(2), now: start)
        let code = shown.code
        let revealedNonce = initiator.revealToSend(now: start)
        let revealed = try #require(revealedNonce)
        guard case .awaitingDecision(let prompt) = try peerHost.reveal(revealed, now: start) else {
            Issue.record("the host did not accept the reveal")
            return
        }
        #expect(prompt.code == code)
        try initiator.userConfirmed(codesMatch: true, for: shown.attempt, now: start)
        #expect(try peerHost.decide(.deny, for: attempt, now: start, trust: &trust) == .denied(.denied))
        try initiator.hostOutcome(approved: false, now: start)
        #expect(initiator.status == .denied(.hostDenied) && trust.trustedCount == 0)
    }

    @Test("The code changes with the host nonce, our nonce, role, version, either identity and the epoch")
    func initiatorCodeChangesWithEveryTranscriptInput() throws {
        let base = try shownCode(spec(), own: 1, host: 2)
        #expect(try shownCode(spec(), own: 1, host: 2) == base)
        let others = [
            try shownCode(spec(), own: 1, host: 3), try shownCode(spec(), own: 4, host: 2),
            try shownCode(spec(role: .observer), own: 1, host: 2), try shownCode(spec(version: 2), own: 1, host: 2),
            try shownCode(spec(host: Self.identity(101)), own: 1, host: 2),
            try shownCode(spec(identity: Self.identity(2)), own: 1, host: 2),
            try shownCode(PeerPairingAttemptSpec(identity: own, hostIdentity: host, label: "Remote C",
                                                 role: .remoteController,
                                                 session: PeerNegotiatedSession(protocolVersion: 1,
                                                                                hostEpoch: .initial,
                                                                                connectionEpoch: Generation(5),
                                                                                capabilities: .empty)),
                          own: 1, host: 2)
        ]
        #expect(!others.contains(base))
        #expect(Set(others).count == others.count)
    }

    // MARK: Reveal

    @Test("Our nonce is revealed once per value while the code or the host decision is awaited")
    func initiatorRevealReturnsTheNonceOncePerValueInTheTwoRevealStages() throws {
        for stage in [Stage.showing, .awaitingDecision] {
            var initiator = try self.initiator(at: stage)
            #expect(initiator.revealToSend(now: start) == Self.nonce(1), "\(stage)")
            let revealed = initiator
            #expect(initiator.revealToSend(now: start) == nil && initiator.revealToSend(now: start) == nil)
            #expect(initiator == revealed, "a second read changes nothing")
        }
    }

    @Test("A copy taken before the reveal reveals again: once holds per value, not per attempt")
    func initiatorRevealIsOncePerValueSoEachCopyRevealsOnce() throws {
        var original = try initiator(at: .showing)
        var copy = original
        #expect(original.revealToSend(now: start) == Self.nonce(1))
        #expect(original.revealToSend(now: start) == nil)
        #expect(copy.revealToSend(now: start) == Self.nonce(1))
        #expect(copy.revealToSend(now: start) == nil)
    }

    @Test("The nonce is not revealed before the host nonce arrived, or after any end of the attempt")
    func initiatorRevealIsNilInEveryOtherStage() throws {
        for stage in [Stage.idle, .committed, .awaitingHostNonce, .paired, .denied, .timedOut] {
            var initiator = try self.initiator(at: stage)
            let before = initiator
            #expect(initiator.revealToSend(now: start) == nil, "\(stage)")
            #expect(initiator == before, "\(stage)")
        }
    }

    @Test("Answering that the codes differ denies, and the nonce is never revealed afterwards")
    func initiatorFalseCodeAnswerDeniesAndTheNonceIsNeverRevealedAfterwards() throws {
        var unrevealed = try initiator(at: .showing)
        try unrevealed.userConfirmed(codesMatch: false, for: Self.firstAttempt, now: start)
        #expect(unrevealed.status == .denied(.codesDidNotMatch))
        #expect(unrevealed.revealToSend(now: start) == nil)
        var revealed = try initiator(at: .showing)
        #expect(revealed.revealToSend(now: start) == Self.nonce(1))
        try revealed.userConfirmed(codesMatch: false, for: Self.firstAttempt, now: start)
        #expect(revealed.status == .denied(.codesDidNotMatch))
        #expect(revealed.revealToSend(now: start) == nil)
        #expect(refusal(of: .outcome(true), on: &revealed, at: start) == .unexpectedStep)
    }

    @Test("A host approval before our nonce was revealed is refused and changes nothing")
    func initiatorApprovalBeforeTheNonceWasRevealedIsRefusedAndChangesNothing() throws {
        var initiator = try self.initiator(at: .awaitingDecision)
        let before = initiator
        #expect(refusal(of: .outcome(true), on: &initiator, at: start) == .nonceNotRevealed)
        #expect(initiator == before)
        #expect(initiator.revealToSend(now: start) == Self.nonce(1))
        try initiator.hostOutcome(approved: true, now: start)
        #expect(initiator.status == .paired)
        var denied = try self.initiator(at: .awaitingDecision)
        try denied.hostOutcome(approved: false, now: start)
        #expect(denied.status == .denied(.hostDenied))
    }

    // MARK: Replay

    @Test("A host nonce equal to our own nonce ends the attempt as a replay and nothing is revealed")
    func initiatorHostNonceEqualToOurOwnEndsTheAttemptAsNonceReplay() throws {
        var initiator = try self.initiator(at: .awaitingHostNonce)
        #expect(refusal(of: .host(Self.nonce(1)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator.status == .denied(.nonceReplay))
        #expect(initiator.revealToSend(now: start) == nil)
        #expect(refusal(of: .host(Self.nonce(3)), on: &initiator, at: start) == .unexpectedStep)
    }

    @Test("A host nonce from an earlier attempt ends the later attempt as a replay")
    func initiatorHostNonceFromAnEarlierAttemptEndsTheAttemptAsNonceReplay() throws {
        var initiator = try self.initiator(at: .denied)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(3), now: start)
        try initiator.requestSent(now: start)
        #expect(refusal(of: .host(Self.nonce(2)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator.status == .denied(.nonceReplay))
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(4), now: start)
        try initiator.requestSent(now: start)
        let shown = try initiator.receiveHostNonce(Self.nonce(5), now: start).code
        #expect(shown == (try shownCode(spec(), own: 4, host: 5)))
    }

    @Test("Our own nonces are remembered for 256 insertions and the 257th forgets the oldest")
    func initiatorNonceMemoryHolds256OwnNoncesAndForgetsTheOldestOnThe257th() throws {
        var initiator = PeerPairingInitiator()
        for index in 0..<256 {
            _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1_000 + UInt32(index)), now: start)
            expire(&initiator)
        }
        let before = initiator
        #expect(refusal(of: .start(spec(), Self.nonce(1_000)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator == before)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(2_000), now: start)
        expire(&initiator)
        #expect(refusal(of: .start(spec(), Self.nonce(1_001)), on: &initiator, at: start) == .nonceReplay)
        #expect(refusal(of: .start(spec(), Self.nonce(1_000)), on: &initiator, at: start) == nil)
    }

    /// Whether replaying host nonce 500 is refused after `fillers` attempts that each insert one nonce.
    /// Insertions: our nonce 1, host 500, then the fillers, then the probing attempt's own nonce.
    private func replayOfAHostNonce(afterFillers fillers: Int) throws -> PeerInitiatorError? {
        var initiator = try self.initiator(at: .idle)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start)
        _ = try initiator.receiveHostNonce(Self.nonce(500), now: start)
        try initiator.userConfirmed(codesMatch: false, for: Self.firstAttempt, now: start)
        for index in 0..<fillers {
            _ = try initiator.startAttempt(spec(), nonce: Self.nonce(3_000 + UInt32(index)), now: start)
            expire(&initiator)
        }
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(9_000), now: start)
        try initiator.requestSent(now: start)
        return refusal(of: .host(Self.nonce(500)), on: &initiator, at: start)
    }

    @Test("A host nonce is remembered through 254 later insertions and forgotten after the 255th")
    func initiatorNonceMemoryRefusesAHostNonceThroughTheLast256AndForgetsItAfter() throws {
        #expect(try replayOfAHostNonce(afterFillers: 0) == .nonceReplay)
        #expect(try replayOfAHostNonce(afterFillers: 254) == .nonceReplay)
        #expect(try replayOfAHostNonce(afterFillers: 255) == nil)
        #expect(try replayOfAHostNonce(afterFillers: 300) == nil)
    }

    // MARK: Attempt numbers (the person's answer names the prompt it answers)

    private func confirmRefusal(_ initiator: inout PeerPairingInitiator, match: Bool,
                                for attempt: PeerInitiatorAttemptID,
                                at now: ContinuousClock.Instant) -> PeerInitiatorError? {
        do {
            try initiator.userConfirmed(codesMatch: match, for: attempt, now: now)
            return nil
        } catch { return error }
    }

    /// Attempt A (nonces 1 and 2) shows its prompt and times out; attempt B (nonces 3 and 4) starts 61 s after
    /// A's start and shows its prompt, so B's deadline is start + 121 s.
    private struct TwoAttempts {
        var initiator: PeerPairingInitiator
        let first: PeerInitiatorPrompt
        let second: PeerInitiatorPrompt
    }

    private func timedOutAThenShowingB() throws -> TwoAttempts {
        var initiator = PeerPairingInitiator()
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start)
        let first = try initiator.receiveHostNonce(Self.nonce(2), now: start)
        #expect(initiator.tick(now: start + .seconds(60)) == .timedOut)
        let later = start + .seconds(61)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(3), now: later)
        try initiator.requestSent(now: later)
        let second = try initiator.receiveHostNonce(Self.nonce(4), now: later)
        return TwoAttempts(initiator: initiator, first: first, second: second)
    }

    @Test("A late answer to a timed-out attempt cannot confirm or deny the next attempt's code")
    func initiatorStaleConfirmationOfAnEarlierAttemptCannotConfirmOrDenyTheLaterOne() throws {
        let fixture = try timedOutAThenShowingB()
        #expect(fixture.first.attempt.value == 1 && fixture.second.attempt.value == 2)
        #expect(fixture.first.attempt < fixture.second.attempt)
        #expect(fixture.initiator.status == .showingCode(fixture.second))
        for match in [true, false] {
            var initiator = fixture.initiator
            let before = initiator
            let refused = confirmRefusal(&initiator, match: match, for: fixture.first.attempt, at: start + .seconds(62))
            #expect(refused == .staleAttempt, "codesMatch \(match)")
            #expect(initiator == before, "codesMatch \(match)")
            #expect(initiator.status == .showingCode(fixture.second), "codesMatch \(match)")
        }
        var confirmed = fixture.initiator
        #expect(confirmRefusal(&confirmed, match: true, for: fixture.second.attempt, at: start + .seconds(62)) == nil)
        #expect(confirmed.status == .awaitingHostDecision)
        var denied = fixture.initiator
        #expect(confirmRefusal(&denied, match: false, for: fixture.second.attempt, at: start + .seconds(62)) == nil)
        #expect(denied.status == .denied(.codesDidNotMatch))
    }

    @Test("A stale attempt is refused as stale even when the current attempt's deadline has passed")
    func initiatorStaleAttemptOutranksADueTimeout() throws {
        let fixture = try timedOutAThenShowingB()
        var initiator = fixture.initiator
        let before = initiator
        let due = start + .seconds(121)
        #expect(confirmRefusal(&initiator, match: true, for: fixture.first.attempt, at: due) == .staleAttempt)
        #expect(initiator == before)
        #expect(initiator.status == .showingCode(fixture.second))
        #expect(confirmRefusal(&initiator, match: true, for: fixture.second.attempt, at: due) == .timedOut)
        #expect(initiator.status == .timedOut)
    }

    @Test("Attempt numbers grow by exactly one per accepted start and a refused start consumes none")
    func initiatorAttemptNumbersGrowByOnePerAcceptedStartAndRefusedStartsConsumeNone() throws {
        var initiator = PeerPairingInitiator()
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start)
        let first = try initiator.receiveHostNonce(Self.nonce(2), now: start)
        try initiator.userConfirmed(codesMatch: false, for: first.attempt, now: start)
        var before = initiator
        #expect(refusal(of: .start(spec(label: ""), Self.nonce(3)), on: &initiator, at: start) == .invalidLabel)
        #expect(refusal(of: .start(spec(), Self.nonce(1)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator == before)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(3), now: start)
        try initiator.requestSent(now: start)
        let second = try initiator.receiveHostNonce(Self.nonce(4), now: start)
        expire(&initiator)
        before = initiator
        #expect(refusal(of: .start(spec(identity: host), Self.nonce(5)), on: &initiator, at: start) == .sameIdentity)
        #expect(initiator == before)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(5), now: start)
        try initiator.requestSent(now: start)
        let third = try initiator.receiveHostNonce(Self.nonce(6), now: start)
        try initiator.userConfirmed(codesMatch: true, for: third.attempt, now: start)
        #expect(initiator.revealToSend(now: start) == Self.nonce(5))
        try initiator.hostOutcome(approved: true, now: start)
        #expect(initiator.status == .paired)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(7), now: start)
        try initiator.requestSent(now: start)
        let fourth = try initiator.receiveHostNonce(Self.nonce(8), now: start)
        #expect([first.attempt.value, second.attempt.value, third.attempt.value, fourth.attempt.value] == [1, 2, 3, 4])
        #expect(first.attempt < second.attempt && second.attempt < third.attempt && third.attempt < fourth.attempt)
        #expect(second.attempt.value == first.attempt.value + 1 && fourth.attempt.value == third.attempt.value + 1)
        #expect(fourth.attempt.description == "attempt-4")
    }

    @Test("Only the latest issued attempt number is accepted: a forged future number and zero are stale")
    func initiatorForgedFutureAndZeroAttemptNumbersAreRefusedAsStale() throws {
        var initiator = try self.initiator(at: .showing)
        let before = initiator
        let shown = try #require(initiator.status.prompt)
        #expect(shown.attempt.value == 1)
        for forged in [UInt64(2), 0, 3, UInt64.max] {
            let refused = confirmRefusal(&initiator, match: true, for: PeerInitiatorAttemptID(value: forged),
                                         at: start)
            #expect(refused == .staleAttempt, "forged \(forged)")
            #expect(initiator == before, "forged \(forged)")
        }
        #expect(confirmRefusal(&initiator, match: true, for: shown.attempt, at: start) == nil)
    }

    @Test("The right attempt in the wrong state is unexpected, never stale, and an earlier one is stale")
    func initiatorRightAttemptInTheWrongStateIsUnexpectedAndAnEarlierOneIsStale() throws {
        var fixture = try timedOutAThenShowingB()
        let second = fixture.second.attempt
        let later = start + .seconds(62)
        #expect(confirmRefusal(&fixture.initiator, match: true, for: second, at: later) == nil)
        #expect(fixture.initiator.revealToSend(now: later) == Self.nonce(3))
        try fixture.initiator.hostOutcome(approved: true, now: later)
        #expect(fixture.initiator.status == .paired)
        let before = fixture.initiator
        #expect(confirmRefusal(&fixture.initiator, match: true, for: second, at: later) == .unexpectedStep)
        #expect(confirmRefusal(&fixture.initiator, match: false, for: second, at: later) == .unexpectedStep)
        #expect(confirmRefusal(&fixture.initiator, match: true, for: fixture.first.attempt, at: later) == .staleAttempt)
        #expect(fixture.initiator == before)
        #expect(fixture.initiator.status == .paired)
        var idle = PeerPairingInitiator()
        let idleBefore = idle
        #expect(confirmRefusal(&idle, match: true, for: PeerInitiatorAttemptID(value: 0), at: later) == .unexpectedStep)
        #expect(confirmRefusal(&idle, match: true, for: PeerInitiatorAttemptID(value: 1), at: later) == .staleAttempt)
        #expect(idle == idleBefore)
    }

    #if DEBUG
    @Test("At the last number one attempt is numbered, and the next start is refused as exhausted")
    func initiatorStartAtTheLastAttemptNumberIsAcceptedOnceThenExhausted() throws {
        let nearEnd = PeerInitiatorAttemptID(value: UInt64.max - 1)
        var initiator = PeerPairingInitiator(testingLastIssuedAttempt: nearEnd)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start)
        let last = try initiator.receiveHostNonce(Self.nonce(2), now: start)
        #expect(last.attempt.value == UInt64.max)
        try initiator.userConfirmed(codesMatch: false, for: last.attempt, now: start)
        let before = initiator
        #expect(refusal(of: .start(spec(), Self.nonce(3)), on: &initiator, at: start) == .attemptsExhausted)
        #expect(initiator == before)
        #expect(initiator.status == .denied(.codesDidNotMatch))
    }

    @Test("A replayed nonce is refused before an exhausted counter")
    func initiatorStartReplayedNonceOutranksAnExhaustedCounter() throws {
        let nearEnd = PeerInitiatorAttemptID(value: UInt64.max - 1)
        var initiator = PeerPairingInitiator(testingLastIssuedAttempt: nearEnd)
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        expire(&initiator)
        let before = initiator
        #expect(refusal(of: .start(spec(), Self.nonce(1)), on: &initiator, at: start) == .nonceReplay)
        #expect(initiator == before)
        #expect(refusal(of: .start(spec(), Self.nonce(9)), on: &initiator, at: start) == .attemptsExhausted)
        #expect(initiator == before)
    }
    #endif
}
