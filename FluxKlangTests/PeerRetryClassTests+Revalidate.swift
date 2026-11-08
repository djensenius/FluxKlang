import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private final class HeldReadCounter { var value = 0 }

extension PeerRetryClassTests {
    @Test func aCurrentSetIsRetryableWithItsOriginalIDOperationAndBasis() throws {
        var call = Call()
        call.held = [Fixture.intent("command.set", Fixture.set(0.25, Fixture.pan))]
        let report = try call.run()
        let candidate = PeerRetryCandidate(original: Fixture.id("command.set"),
                                           operation: Fixture.set(0.25, Fixture.pan), basis: Fixture.current)
        #expect(report.retryable == [candidate])
        #expect(report.discarded.isEmpty)
        #expect(report.unknownOutcome.isEmpty)
        #expect(report.retryableCount == 1)
        #expect(report.discardedCount == 0)
        #expect(report.truncatedCount == 0)
    }

    @Test func aCurrentRampIsRetryableWithItsDurationKept() throws {
        var call = Call()
        call.held = [Fixture.intent("command.ramp", Fixture.ramp(0.75))]
        let report = try call.run()
        #expect(report.retryable == [PeerRetryCandidate(original: Fixture.id("command.ramp"),
                                                        operation: Fixture.ramp(0.75), basis: Fixture.current)])
        #expect(report.discarded.isEmpty)
    }

    @Test func everyNeverOperationIsDiscardedAsNeverRetriedWithItsOperation() throws {
        var call = Call()
        let operations = Fixture.neverOperations()
        call.held = operations.enumerated().map { Fixture.intent("command.never.\($0.offset)", $0.element) }
        let report = try call.run()
        let expected = operations.enumerated().map {
            PeerDiscardedIntent(id: Fixture.id("command.never.\($0.offset)"), reason: .neverRetried($0.element))
        }
        #expect(report.discarded == expected)
        #expect(report.retryable.isEmpty)
        #expect(report.discardedCount == 10)
    }

    @Test func aHeldIntentOfAnotherHostIsDiscardedAsAStaleHostEpoch() throws {
        var call = Call()
        call.held = [Fixture.intent("command.generation", session: Fixture.session(host: 2)),
                     Fixture.intent("command.host", session: Fixture.session(hostID: Fixture.otherHost)),
                     Fixture.intent("command.both", session: Fixture.session(host: 2, connection: 2))]
        let report = try call.run()
        #expect(report.discarded.map(\.reason) == Array(repeating: .staleSession(.hostEpoch), count: 3))
        #expect(report.retryable.isEmpty)
    }

    @Test func aHeldIntentOfAnotherConnectionIsDiscardedAsAStaleConnectionEpoch() throws {
        var call = Call()
        call.held = [Fixture.intent("command.generation", session: Fixture.session(connection: 2)),
                     Fixture.intent("command.id", session: Fixture.session(connectionID: Fixture.droppedConnection)),
                     Fixture.intent("command.none", withoutConnection: true)]
        let report = try call.run()
        #expect(report.discarded.map(\.reason) == Array(repeating: .staleSession(.connectionEpoch), count: 3))
        #expect(report.discarded.map(\.id) == ["command.generation", "command.id", "command.none"].map(Fixture.id))
    }

    @Test func eachRevisionAxisAloneMakesTheIntentStaleWhetherAheadOrBehind() throws {
        for axis in PeerRevisionAxis.allCases {
            for delta in [-1, 1] {
                var call = Call()
                call.held = [Fixture.intent("command.axis", revisions: Fixture.moved(axis, by: delta))]
                let report = try call.run()
                #expect(report.discarded == [PeerDiscardedIntent(id: Fixture.id("command.axis"),
                                                                 reason: .staleRevisions([axis]))],
                        "\(axis) \(delta)")
                #expect(report.retryable.isEmpty)
            }
        }
    }

    @Test func severalStaleAxesAreAllListedInTheFixedOrder() throws {
        var call = Call()
        call.held = [Fixture.intent("command.all", revisions: Fixture.revisions(4, 2, 5, 1, 6)),
                     Fixture.intent("command.two", revisions: Fixture.revisions(3, 4, 3, 3, 2)),
                     Fixture.intent("command.low", revisions: Fixture.revisions(2, 3, 2, 3, 3))]
        let report = try call.run()
        #expect(report.discarded.map(\.reason) == [
            .staleRevisions([.patch, .capability, .permission, .parameter, .graph]),
            .staleRevisions([.capability, .graph]),
            .staleRevisions([.patch, .permission])
        ])
    }

    @Test func aTargetMissingFromTheStateIsDiscardedWithItsParameter() throws {
        var call = Call()
        call.use(Fixture.receiver(values: [Fixture.pan: Fixture.value(0.0)]))
        call.held = [Fixture.intent("command.gain", Fixture.set(0.5, Fixture.gain)),
                     Fixture.intent("command.ramp", Fixture.ramp(0.5, Fixture.missing)),
                     Fixture.intent("command.pan", Fixture.set(0.5, Fixture.pan))]
        let report = try call.run()
        #expect(report.discarded == [
            PeerDiscardedIntent(id: Fixture.id("command.gain"), reason: .valueMissing(Fixture.gain)),
            PeerDiscardedIntent(id: Fixture.id("command.ramp"), reason: .valueMissing(Fixture.missing))
        ])
        #expect(report.retryable.map(\.original) == [Fixture.id("command.pan")])
    }

    @Test func aStateWithoutAnyValueDiscardsEveryParameterWriter() throws {
        var call = Call()
        call.use(Fixture.receiver(values: [:]))
        call.held = [Fixture.intent("command.set"), Fixture.intent("command.ramp", Fixture.ramp())]
        let report = try call.run()
        #expect(report.discarded.map(\.reason) == [.valueMissing(Fixture.gain), .valueMissing(Fixture.gain)])
        #expect(report.retryable.isEmpty)
    }

    @Test func aNonFiniteHeldValueIsDiscardedAsNotFinite() throws {
        let call = Call()
        let bad = [Double.nan, Double.infinity, -Double.infinity]
        let core = bad.enumerated().flatMap { index, raw in
            [Fixture.held("command.set.\(index)", Fixture.set(raw)),
             Fixture.held("command.ramp.\(index)", Fixture.ramp(raw))]
        }
        let report = try call.run(core: core)
        #expect(report.discarded.map(\.reason) == Array(repeating: .notFinite, count: 6))
        #expect(report.discarded.map(\.id) == core.map(\.id))
        #expect(report.retryable.isEmpty)
    }

    @Test func everyFiniteHeldValueIsRetryableIncludingBothZerosAndTheExtremes() throws {
        let call = Call()
        let finite = [0.0, -0.0, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                      Double.leastNonzeroMagnitude, Double.leastNormalMagnitude]
        let core = finite.enumerated().map { Fixture.held("command.value.\($0.offset)", Fixture.set($0.element)) }
        let report = try call.run(core: core)
        #expect(report.retryable.map(\.original) == core.map(\.id))
        #expect(report.retryable.map(\.operation) == core.map(\.operation))
        #expect(report.discarded.isEmpty)
        #expect(report.retryable.map { PeerIntentRevalidator.target(of: $0.operation)?.value.value.sign }
                == finite.map { Optional($0.sign) })
    }

    @Test func anEmptyHeldListAndNoAwaitingIDsGiveAnEmptyReport() throws {
        let report = try Call().run()
        #expect(report.isEmpty)
        #expect(report == PeerRevalidationReport(retryable: [], discarded: [], unknownOutcome: [], limits: .standard))
        #expect(report.retryableCount == 0)
        #expect(report.discardedCount == 0)
        #expect(report.unknownOutcomeCount == 0)
        #expect(report.truncatedCount == 0)
    }

    @Test func sentIntentsAreNeverRetryableAndKeepTheirAwaitingOrder() throws {
        var call = Call()
        let awaiting = ["command.zulu", "command.alpha", "command.mike"].map(Fixture.id)
        call.awaiting = awaiting
        call.held = [Fixture.intent("command.fresh")]
        let report = try call.run()
        #expect(report.unknownOutcome == awaiting)
        #expect(report.unknownOutcomeCount == 3)
        #expect(report.retryable.map(\.original) == [Fixture.id("command.fresh")])
        #expect(report.discarded.isEmpty)
        call.held = []
        let onlySent = try call.run()
        #expect(onlySent.unknownOutcome == awaiting)
        #expect(onlySent.retryable.isEmpty)
        #expect(!onlySent.isEmpty)
    }

    @Test func aMixedHeldListKeepsHeldOrderInBothResultLists() throws {
        var call = Call()
        call.held = [Fixture.intent("command.a"), Fixture.intent("command.b", .trigger(Fixture.actionID)),
                     Fixture.intent("command.c", Fixture.ramp()),
                     Fixture.intent("command.d", revisions: Fixture.moved(.graph, by: 1)),
                     Fixture.intent("command.e"), Fixture.intent("command.f", Fixture.set(0.5, Fixture.missing))]
        let report = try call.run()
        #expect(report.retryable.map(\.original) == ["command.a", "command.c", "command.e"].map(Fixture.id))
        #expect(report.discarded == [
            PeerDiscardedIntent(id: Fixture.id("command.b"), reason: .neverRetried(.trigger(Fixture.actionID))),
            PeerDiscardedIntent(id: Fixture.id("command.d"), reason: .staleRevisions([.graph])),
            PeerDiscardedIntent(id: Fixture.id("command.f"), reason: .valueMissing(Fixture.missing))
        ])
    }

    @Test func reversingTheHeldListReversesEachResultListTheSameWay() throws {
        var call = Call()
        call.held = [Fixture.intent("command.a"), Fixture.intent("command.b", .start),
                     Fixture.intent("command.c", Fixture.ramp()), Fixture.intent("command.d", .panic),
                     Fixture.intent("command.e", session: Fixture.session(connection: 2))]
        call.awaiting = ["command.x", "command.y"].map(Fixture.id)
        let forward = try call.run()
        #expect(try call.run() == forward)
        call.held.reverse()
        let backward = try call.run()
        #expect(backward.retryable == forward.retryable.reversed())
        #expect(backward.discarded == forward.discarded.reversed())
        #expect(backward.unknownOutcome == forward.unknownOutcome)
        #expect(forward.retryable.map(\.original) == ["command.a", "command.c"].map(Fixture.id))
        #expect(forward.discarded.map(\.id) == ["command.b", "command.d", "command.e"].map(Fixture.id))
    }

    @Test func noEpochOfTheDroppedSessionAppearsInTheRetryableList() throws {
        let dropped = Fixture.session(connectionID: Fixture.droppedConnection)
        var call = Call()
        call.held = [Fixture.intent("command.old.a", session: dropped), Fixture.intent("command.live.a"),
                     Fixture.intent("command.old.b", Fixture.ramp(), session: dropped),
                     Fixture.intent("command.live.b", Fixture.ramp())]
        let report = try call.run()
        #expect(report.retryable.map(\.original) == ["command.live.a", "command.live.b"].map(Fixture.id))
        #expect(report.discarded.map(\.id) == ["command.old.a", "command.old.b"].map(Fixture.id))
        #expect(report.discarded.allSatisfy { $0.reason == .staleSession(.connectionEpoch) })
        #expect(!String(describing: report.retryable).contains("connection.dropped"))
        for candidate in report.retryable { #expect(candidate.basis == call.receiver.state?.revisions) }
    }

    @Test func aRepeatedIDIsRefusedWithinHeldWithinAwaitingAndAcrossThem() {
        var call = Call()
        call.held = [Fixture.intent("command.a"), Fixture.intent("command.a", .start)]
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.a"))))
        call.held = []
        call.awaiting = ["command.b", "command.c", "command.b"].map(Fixture.id)
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.b"))))
        call.held = [Fixture.intent("command.c", .panic)]
        call.awaiting = ["command.b", "command.c"].map(Fixture.id)
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.c"))))
        call.awaiting = ["command.b", "command.d"].map(Fixture.id)
        #expect(call.outcome() != .refused(.duplicateCommand(Fixture.id("command.c"))))
    }

    @Test func theFirstRepeatInScanOrderIsTheOneNamed() {
        var call = Call()
        call.held = ["command.c", "command.a", "command.c", "command.a"].map { Fixture.intent($0) }
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.c"))))
        call.held = ["command.b", "command.x"].map { Fixture.intent($0) }
        call.awaiting = ["command.a", "command.b", "command.a"].map(Fixture.id)
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.b"))))
        call.held = [Fixture.intent("command.q")]
        call.awaiting = ["command.z", "command.m", "command.m", "command.z"].map(Fixture.id)
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.m"))))
    }

    @Test func aDuplicateRefusesTheWholeCallEvenForIntentsThatWouldBeDiscarded() {
        var call = Call()
        call.held = [Fixture.intent("command.t", .trigger(Fixture.actionID)), Fixture.intent("command.ok"),
                     Fixture.intent("command.t", .trigger(Fixture.actionID))]
        #expect(call.outcome() == .refused(.duplicateCommand(Fixture.id("command.t"))))
    }

    // MARK: bounds and truncation

    @Test func exactlyTheMaximumOfHeldIntentsIsAcceptedAndOneMoreIsRefused() throws {
        var call = Call()
        call.limits = Fixture.limits(256)
        call.held = (0..<4_096).map { Fixture.intent("command.held.\($0)") }
        let report = try call.run()
        #expect(report.retryableCount == 4_096)
        #expect(report.retryable.count == 256)
        #expect(report.truncatedCount == 4_096 - 256)
        call.held.append(Fixture.intent("command.held.4096"))
        #expect(call.outcome() == .refused(.tooManyHeld(4_097)))
        #expect(call.outcome(core: call.reduced()) == .refused(.tooManyHeld(4_097)))
        #expect(call.outcome(core: call.reduced() + call.reduced()) == .refused(.tooManyHeld(8_194)))
    }

    @Test func exactlyTheMaximumOfAwaitingIDsIsAcceptedAndOneMoreIsRefused() throws {
        var call = Call()
        call.awaiting = Fixture.ids("command.sent", count: 4_096)
        let report = try call.run()
        #expect(report.unknownOutcomeCount == 4_096)
        #expect(report.unknownOutcome == Array(call.awaiting.prefix(32)))
        call.awaiting.append(Fixture.id("command.sent.4096"))
        #expect(call.outcome() == .refused(.tooManyAwaiting(4_097)))
    }

    @Test func eachListIsCutAtTheLimitAndItsCountStaysExact() throws {
        for cap in [1, 2, 5] {
            var call = Call()
            call.limits = Fixture.limits(cap)
            let old = Fixture.session(connection: 2)
            call.held = (0..<(cap + 1)).map { Fixture.intent("command.ok.\($0)") }
                + (0..<cap).map { Fixture.intent("command.never.\($0)", .stop) }
                + (0..<(cap - 1)).map { Fixture.intent("command.old.\($0)", session: old) }
            call.awaiting = Fixture.ids("command.sent", count: cap + 2)
            let report = try call.run()
            #expect(report.retryable.map(\.original) == (0..<cap).map { Fixture.id("command.ok.\($0)") })
            #expect(report.retryableCount == cap + 1)
            #expect(report.discarded.count == cap)
            #expect(report.discardedCount == 2 * cap - 1)
            #expect(report.unknownOutcome == Array(call.awaiting.prefix(cap)))
            #expect(report.unknownOutcomeCount == cap + 2)
            #expect(report.truncatedCount == 1 + (cap - 1) + 2)
        }
    }

    @Test func thePublicEntryRefusesMoreThanTheMaximumWithTheFullCount() {
        var call = Call()
        call.held = (0..<8_194).map { Fixture.intent("command.held.\($0)") }
        #expect(call.outcome() == .refused(.tooManyHeld(8_194)))
        call.held = []
        call.awaiting = Fixture.ids("command.sent", count: 8_194)
        #expect(call.outcome() == .refused(.tooManyAwaiting(8_194)))
    }

    /// An array whose element reads are counted; `count` is derived from the indices and reads nothing.
    private struct CountingHeld: RandomAccessCollection {
        let base: [PeerHeldIntent]
        let reads = HeldReadCounter()
        var startIndex: Int { base.startIndex }
        var endIndex: Int { base.endIndex }
        subscript(position: Int) -> PeerHeldIntent {
            reads.value += 1
            return base[position]
        }
    }

    @Test func theInternalEntryReadsNoElementWhenItRefusesMoreThanTheMaximum() {
        let call = Call()
        let counting = CountingHeld(base: Array(repeating: Fixture.held("command.held"), count: 4_097))
        #expect(call.outcome(core: counting) == .refused(.tooManyHeld(4_097)))
        #expect(counting.reads.value == 0)
    }

    @Test func descendingInputIDsKeepTheInputOrderInBothResultLists() throws {
        var call = Call()
        call.held = [Fixture.intent("command.z"), Fixture.intent("command.y", .stop), Fixture.intent("command.x"),
                     Fixture.intent("command.w", .panic), Fixture.intent("command.v")]
        let report = try call.run()
        #expect(report.retryable.map(\.original) == ["command.z", "command.x", "command.v"].map(Fixture.id))
        #expect(report.discarded.map(\.id) == ["command.y", "command.w"].map(Fixture.id))
    }

    @Test func aListExactlyAtTheLimitIsNotTruncated() throws {
        var call = Call()
        call.limits = Fixture.limits(3)
        call.held = (0..<3).map { Fixture.intent("command.ok.\($0)") }
        call.awaiting = Fixture.ids("command.sent", count: 3)
        let report = try call.run()
        #expect(report.retryable.count == 3 && report.retryableCount == 3)
        #expect(report.unknownOutcome.count == 3 && report.unknownOutcomeCount == 3)
        #expect(report.truncatedCount == 0)
    }

    // MARK: with a real reconnect state

    private func syncedReconnect(_ session: PeerSyncSession) throws -> PeerReconnectState {
        var state = Fixture.reconnect(session)
        _ = state.observe(state.stamp(Fixture.receiver(session)))
        if case .synced(_, awaitingResume: true) = state.phase { try state.resume(state.latch) }
        return state
    }

    @Test func intentsHeldAcrossAnInSessionResyncAreRevalidatedAgainstTheSnapshot() throws {
        let session = Fixture.session()
        var state = try syncedReconnect(session)
        let intents = [Fixture.intent("command.a"), Fixture.intent("command.b", Fixture.ramp(0.9, Fixture.pan)),
                       Fixture.intent("command.c", .stop)]
        for intent in intents { try state.enqueue(intent) }
        let sent = try #require(try state.takeNextToSend())
        #expect(sent.intent.id == Fixture.id("command.a"))
        var receiver = Fixture.receiver(session)
        _ = receiver.receive(Fixture.delta(session, sequence: 5))
        _ = state.observe(state.stamp(receiver))
        _ = receiver.receive(Fixture.snapshot(session, sequence: 5))
        _ = state.observe(state.stamp(receiver))
        var call = Call(session: session, receiver: receiver)
        call.reconnect = state
        call.stamped = state.stamp(receiver)
        call.expecting = state.latch
        call.held = state.queue.queued
        call.awaiting = state.queue.awaitingResult.map(\.intent.id)
        let report = try call.run()
        #expect(report.retryable.map(\.original) == [Fixture.id("command.b")])
        #expect(report.discarded == [PeerDiscardedIntent(id: Fixture.id("command.c"), reason: .neverRetried(.stop))])
        #expect(report.unknownOutcome == [Fixture.id("command.a")])
    }

    @Test func intentsCapturedBeforeAReconnectAreAllDiscardedAsStaleAndSentOnesStayUnknown() throws {
        let session = Fixture.session()
        var state = try syncedReconnect(session)
        for index in 0..<3 { try state.enqueue(Fixture.intent("command.i\(index)")) }
        _ = try state.takeNextToSend()
        let held = state.queue.queued
        let awaiting = state.queue.awaitingResult.map(\.intent.id)
        _ = state.connectionLost(session)
        let next = Fixture.session(connection: 2)
        let dropped = try state.reconnect(to: next)
        var call = Call(session: next)
        call.held = held
        call.awaiting = awaiting
        let report = try call.run()
        #expect(report.retryable.isEmpty)
        #expect(report.discarded.map(\.id) == held.map(\.id))
        #expect(report.discarded.allSatisfy { $0.reason == .staleSession(.connectionEpoch) })
        #expect(report.unknownOutcome == awaiting)
        #expect(Set(dropped.unknownOutcome) == Set(report.unknownOutcome))
        #expect(Set(dropped.discarded) == Set(report.discarded.map(\.id)))
        #expect(state.queue.queued.isEmpty)
    }
}
