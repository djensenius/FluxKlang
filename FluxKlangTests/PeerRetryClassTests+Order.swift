import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerRetryClassTests {
    /// The same expectation through the public entry (`CommandIntent`) and the reduced one (`PeerHeldIntent`).
    fileprivate func expectBothPaths(_ call: Call, _ expected: Outcome,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(call.outcome() == expected, sourceLocation: sourceLocation)
        #expect(call.outcome(core: call.reduced()) == expected, sourceLocation: sourceLocation)
    }

    fileprivate func discarded(_ id: String, _ reason: PeerDiscardReason) -> Outcome {
        .report(PeerRevalidationReport(
            retryable: [], discarded: [PeerDiscardedIntent(id: Fixture.id(id), reason: reason)],
            unknownOutcome: [], limits: .standard
        ))
    }

    private var otherLatch: PeerResyncLatch { Fixture.reconnect(Fixture.session(), latchGeneration: 2).latch }

    // MARK: whole-call refusal order

    @Test func aLatchMismatchIsReportedBeforeASessionMismatch() {
        var call = Call()
        call.expecting = otherLatch
        call.session = Fixture.session(connection: 2)
        call.held = [Fixture.intent("command.a")]
        expectBothPaths(call, .refused(.latchMismatch(expected: otherLatch, found: call.stamped.latch)))
    }

    @Test func aSessionMismatchIsReportedBeforeAnUnsyncedReceiver() {
        var call = Call()
        call.use(Fixture.unsynced())
        call.session = Fixture.session(connection: 2)
        call.held = [Fixture.intent("command.a")]
        expectBothPaths(call, .refused(.sessionMismatch(.connectionEpoch)))
    }

    @Test func anUnsyncedReceiverIsReportedBeforeTooManyHeldIntents() {
        var call = Call()
        call.use(Fixture.unsynced())
        call.held = (0..<4_097).map { Fixture.intent("command.held.\($0)") }
        expectBothPaths(call, .refused(.receiverNotSynced(.awaitingSnapshot)))
    }

    @Test func tooManyHeldIntentsAreReportedBeforeTooManyAwaitingIDs() {
        var call = Call()
        call.held = (0..<4_097).map { Fixture.intent("command.held.\($0)") }
        call.awaiting = Fixture.ids("command.sent", count: 4_097)
        expectBothPaths(call, .refused(.tooManyHeld(4_097)))
    }

    @Test func tooManyAwaitingIDsAreReportedBeforeADuplicateCommand() {
        var call = Call()
        call.held = [Fixture.intent("command.a")]
        call.awaiting = Fixture.ids("command.sent", count: 4_096) + [Fixture.id("command.a")]
        expectBothPaths(call, .refused(.tooManyAwaiting(4_097)))
        call.awaiting = Array(repeating: Fixture.id("command.same"), count: 4_097)
        expectBothPaths(call, .refused(.tooManyAwaiting(4_097)))
    }

    @Test func tooManyHeldIntentsAreReportedBeforeADuplicateCommand() {
        var call = Call()
        call.held = (0..<4_097).map { Fixture.intent("command.held.\($0 % 4_096)") }
        expectBothPaths(call, .refused(.tooManyHeld(4_097)))
    }

    @Test func aLatchMismatchIsReportedBeforeNotSyncedCountAndDuplicateRefusals() {
        var call = Call()
        call.use(Fixture.resyncing())
        call.expecting = otherLatch
        call.held = (0..<4_097).map { Fixture.intent("command.held.\($0 % 4_096)") }
        call.awaiting = Fixture.ids("command.sent", count: 4_097)
        expectBothPaths(call, .refused(.latchMismatch(expected: otherLatch, found: call.stamped.latch)))
    }

    // MARK: discard reason order

    @Test func aNeverClassIsReportedBeforeAStaleSessionAndStaleRevisions() throws {
        var call = Call()
        let old = Fixture.session(connection: 2)
        call.held = [Fixture.intent("command.t", .trigger(Fixture.actionID), session: old,
                                    revisions: Fixture.moved(.patch, by: 1))]
        expectBothPaths(call, discarded("command.t", .neverRetried(.trigger(Fixture.actionID))))
    }

    @Test func aStaleSessionIsReportedBeforeStaleRevisionsAndAMissingValue() throws {
        var call = Call()
        call.held = [Fixture.intent("command.s", Fixture.set(0.5, Fixture.missing),
                                    session: Fixture.session(host: 2), revisions: Fixture.moved(.graph, by: -1))]
        expectBothPaths(call, discarded("command.s", .staleSession(.hostEpoch)))
    }

    @Test func staleRevisionsAreReportedBeforeAMissingValue() throws {
        var call = Call()
        call.held = [Fixture.intent("command.r", Fixture.ramp(0.5, Fixture.missing),
                                    revisions: Fixture.moved(.permission, by: 1))]
        expectBothPaths(call, discarded("command.r", .staleRevisions([.permission])))
    }

    @Test func aMissingValueIsReportedBeforeANonFiniteValue() throws {
        let call = Call()
        let nan = Fixture.held("command.v", Fixture.set(Double.nan, Fixture.missing))
        #expect(call.outcome(core: [nan]) == discarded("command.v", .valueMissing(Fixture.missing)))
        let infinite = Fixture.held("command.w", Fixture.ramp(-Double.infinity, Fixture.missing))
        #expect(call.outcome(core: [infinite]) == discarded("command.w", .valueMissing(Fixture.missing)))
    }

    @Test func aNonFiniteValueIsReportedAfterEveryOtherDiscardReason() throws {
        let call = Call()
        let old = Fixture.session(connection: 2)
        let session = Fixture.held("command.s", Fixture.set(Double.nan), session: old)
        #expect(call.outcome(core: [session]) == discarded("command.s", .staleSession(.connectionEpoch)))
        let stale = Fixture.held("command.r", Fixture.ramp(Double.infinity),
                                 revisions: Fixture.moved(.parameter, by: 1))
        #expect(call.outcome(core: [stale]) == discarded("command.r", .staleRevisions([.parameter])))
        let alone = Fixture.held("command.n", Fixture.set(Double.nan))
        #expect(call.outcome(core: [alone]) == discarded("command.n", .notFinite))
    }

    @Test func theFirstFailingReasonOfEachIntentDoesNotDependOnItsNeighbours() throws {
        var call = Call()
        let old = Fixture.session(connection: 2)
        let intents = [Fixture.intent("command.a", .stop, session: old),
                       Fixture.intent("command.b", session: old),
                       Fixture.intent("command.c", revisions: Fixture.moved(.patch, by: 1)),
                       Fixture.intent("command.d", Fixture.set(0.5, Fixture.missing))]
        let expected = [PeerDiscardReason.neverRetried(.stop), .staleSession(.connectionEpoch),
                        .staleRevisions([.patch]), .valueMissing(Fixture.missing)]
        for order in [intents, intents.reversed()] {
            call.held = order
            let report = try call.run()
            #expect(report.discarded.map(\.id) == order.map(\.id))
            for item in report.discarded {
                let index = try #require(intents.firstIndex { $0.id == item.id })
                #expect(item.reason == expected[index])
            }
        }
    }

    // MARK: refusal payloads and unchanged state

    @Test func aLatchMismatchNamesTheExpectedLatchAndTheStampItFound() throws {
        var call = Call()
        let anotherSession = Fixture.reconnect(Fixture.session(connection: 2)).latch
        for expecting in [otherLatch, anotherSession] {
            call.expecting = expecting
            #expect(call.outcome() == .refused(.latchMismatch(expected: expecting, found: call.stamped.latch)))
            #expect(expecting != call.stamped.latch)
        }
        let later = Fixture.reconnect(Fixture.session(), latchGeneration: 2)
        call.stamped = later.stamp(call.receiver)
        call.expecting = Fixture.reconnect(Fixture.session()).latch
        #expect(call.outcome() == .refused(.latchMismatch(expected: call.expecting, found: later.latch)))
        call.held = []
        #expect(call.outcome(core: []) == .refused(.latchMismatch(expected: call.expecting, found: later.latch)))
    }

    @Test func aSessionMismatchNamesTheFirstDifferingEpochOfTheReceiver() {
        var call = Call()
        call.session = Fixture.session(connection: 2)
        #expect(call.outcome() == .refused(.sessionMismatch(.connectionEpoch)))
        call.session = Fixture.session(host: 2)
        #expect(call.outcome() == .refused(.sessionMismatch(.hostEpoch)))
        call.session = Fixture.session(host: 2, connection: 2)
        #expect(call.outcome() == .refused(.sessionMismatch(.hostEpoch)))
        call.session = Fixture.session(connectionID: Fixture.droppedConnection)
        #expect(call.outcome() == .refused(.sessionMismatch(.connectionEpoch)))
    }

    @Test func anUnsyncedReceiverReportsItsExactPhase() throws {
        var call = Call()
        let waiting = Fixture.unsynced()
        call.use(waiting)
        #expect(call.outcome() == .refused(.receiverNotSynced(.awaitingSnapshot)))
        let resyncing = Fixture.resyncing()
        call.use(resyncing)
        guard case .resyncRequired(let request) = resyncing.phase else {
            Issue.record("the fixture receiver should need a resync")
            return
        }
        #expect(request.lastApplied == .origin)
        #expect(call.outcome() == .refused(.receiverNotSynced(resyncing.phase)))
        #expect(call.outcome() != .refused(.receiverNotSynced(.awaitingSnapshot)))
    }

    // MARK: latch owner

    /// A stamp made by one session's reconnect state around another session's receiver.
    private func foreignStamp(receiver sessionOfReceiver: PeerSyncSession) -> Call {
        var call = Call()
        call.receiver = Fixture.receiver(sessionOfReceiver)
        call.stamped = call.reconnect.stamp(call.receiver)
        call.session = sessionOfReceiver
        return call
    }

    @Test func aStampOfAnotherSessionsLatchIsRefusedWithTheFirstDifferingEpoch() {
        var call = foreignStamp(receiver: Fixture.session(connection: 2))
        call.held = [Fixture.intent("command.a")]
        expectBothPaths(call, .refused(.latchOwnerMismatch(.connectionEpoch)))
        call = foreignStamp(receiver: Fixture.session(host: 2, connection: 2))
        expectBothPaths(call, .refused(.latchOwnerMismatch(.hostEpoch)))
        call = foreignStamp(receiver: Fixture.session(connectionID: Fixture.droppedConnection))
        expectBothPaths(call, .refused(.latchOwnerMismatch(.connectionEpoch)))
    }

    @Test func aLatchMismatchIsReportedBeforeALatchOwnerMismatch() {
        var call = foreignStamp(receiver: Fixture.session(connection: 2))
        call.expecting = otherLatch
        expectBothPaths(call, .refused(.latchMismatch(expected: otherLatch, found: call.stamped.latch)))
    }

    @Test func aLatchOwnerMismatchIsReportedBeforeASessionMismatch() {
        var call = foreignStamp(receiver: Fixture.session(host: 2, connection: 2))
        call.session = Fixture.session(host: 2, connection: 3)
        expectBothPaths(call, .refused(.latchOwnerMismatch(.hostEpoch)))
    }

    @Test func aLatchOwnerMismatchIsReportedBeforeAnUnsyncedReceiver() {
        var call = foreignStamp(receiver: Fixture.session(connection: 2))
        call.use(Fixture.unsynced(Fixture.session(connection: 2)))
        call.held = (0..<4_097).map { Fixture.intent("command.held.\($0)") }
        expectBothPaths(call, .refused(.latchOwnerMismatch(.connectionEpoch)))
    }

    // MARK: limits forged through unsafeBitCast (test only; the real initialiser is private)

    private func forgedLimits(_ raw: Int) throws -> PeerRevalidationLimits {
        try #require(MemoryLayout<PeerRevalidationLimits>.size == MemoryLayout<Int>.size,
                     "PeerRevalidationLimits no longer is one Int; the unsafeBitCast forgery must be reworked")
        return unsafeBitCast(raw, to: PeerRevalidationLimits.self)
    }

    @Test func limitsForgedThroughUnsafeBitCastAreRefusedAtThePointOfUse() throws {
        var call = Call()
        call.held = [Fixture.intent("command.a")]
        #expect(try forgedLimits(32).maximumListed == 32)
        for raw in [0, -1, 257, Int.max, Int.min] {
            call.limits = try forgedLimits(raw)
            expectBothPaths(call, .refused(.invalidLimits(maximumListed: raw)))
        }
        for raw in [1, 256] {
            call.limits = try forgedLimits(raw)
            #expect(call.outcome() == .report(PeerRevalidationReport(
                retryable: [PeerRetryCandidate(original: Fixture.id("command.a"), operation: Fixture.set(),
                                               basis: Fixture.current)],
                discarded: [], unknownOutcome: [], limits: call.limits)))
        }
    }

    @Test func forgedInvalidLimitsAreReportedBeforeLatchSessionNotSyncedAndCountRefusals() throws {
        var call = Call()
        call.expecting = otherLatch
        call.session = Fixture.session(connection: 2)
        call.use(Fixture.unsynced())
        call.held = (0..<4_097).map { Fixture.intent("command.held.\($0 % 4_096)") }
        call.awaiting = Fixture.ids("command.sent", count: 4_097)
        call.limits = try forgedLimits(0)
        expectBothPaths(call, .refused(.invalidLimits(maximumListed: 0)))
        call.limits = try forgedLimits(257)
        expectBothPaths(call, .refused(.invalidLimits(maximumListed: 257)))
    }
}
