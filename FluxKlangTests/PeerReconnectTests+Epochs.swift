import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = PeerReconnectFixture

private let remoteC = ConnectionID(validated: "connection.remote-c")
private let remoteD = ConnectionID(validated: "connection.remote-d")
private let remoteE = ConnectionID(validated: "connection.remote-e")

private func issuer(capacity: Int = 4) -> PeerConnectionEpochIssuer {
    do { return try PeerConnectionEpochIssuer(host: Fixture.host, capacity: capacity) } catch {
        preconditionFailure("invalid issuer capacity \(capacity)")
    }
}

private func epoch(_ connection: ConnectionID, _ generation: Int) -> ConnectionEpoch {
    ConnectionEpoch(connection: connection, host: Fixture.host, generation: Fixture.generation(generation))
}

private func milliseconds(_ attempt: Int, _ jitter: Double) throws -> Duration {
    try PeerReconnectBackoff.delay(attempt: attempt, jitterUnit: jitter)
}

@Suite("PeerReconnectTests+Epochs", .productionAccessAudit)
struct PeerReconnectEpochTests {
    @Test func epochsComeFromOneHostWideCounterAndAreNeverReused() throws {
        var issuer = issuer()
        #expect(try issuer.issue(for: remoteC) == epoch(remoteC, 1))
        #expect(try issuer.issue(for: remoteD) == epoch(remoteD, 2))
        #expect(try issuer.issue(for: remoteC) == epoch(remoteC, 3))
        #expect(!issuer.isCurrent(epoch(remoteC, 1)))
        #expect(issuer.isCurrent(epoch(remoteC, 3)))
        #expect(issuer.retire(remoteC) == epoch(remoteC, 3))
        #expect(issuer.current(for: remoteC) == nil)
        #expect(!issuer.isCurrent(epoch(remoteC, 3)))
        #expect(try issuer.issue(for: remoteC) == epoch(remoteC, 4))
        #expect(issuer.lastIssued == Fixture.generation(4))
        #expect(issuer.livePeerCount == 2)
    }

    @Test func currencyIsEqualityOnlyNeverNewerOrOlder() throws {
        var issuer = issuer()
        _ = try issuer.issue(for: remoteC)
        _ = try issuer.issue(for: remoteC)
        #expect(issuer.isCurrent(epoch(remoteC, 2)))
        #expect(!issuer.isCurrent(epoch(remoteC, 1)))
        #expect(!issuer.isCurrent(epoch(remoteC, 3)))
        #expect(!issuer.isCurrent(epoch(remoteC, Generation.maximumValue)))
        #expect(!issuer.isCurrent(epoch(remoteD, 2)))
        let otherHost = ConnectionEpoch(connection: remoteC, host: HostID(validated: "host.other"),
                                        generation: Fixture.generation(2))
        #expect(!issuer.isCurrent(otherHost))
    }

    @Test func livePeersAreBoundedAndAFullIssuerNeverEvicts() throws {
        var issuer = issuer(capacity: 2)
        _ = try issuer.issue(for: remoteC)
        _ = try issuer.issue(for: remoteD)
        #expect(throws: PeerConnectionEpochError.peerLimit(capacity: 2)) { try issuer.issue(for: remoteE) }
        #expect(issuer.isCurrent(epoch(remoteC, 1)))
        #expect(issuer.isCurrent(epoch(remoteD, 2)))
        #expect(issuer.lastIssued == Fixture.generation(2))
        #expect(try issuer.issue(for: remoteD) == epoch(remoteD, 3))
        issuer.retire(remoteC)
        #expect(try issuer.issue(for: remoteE) == epoch(remoteE, 4))

        #expect(throws: PeerConnectionEpochError.invalidCapacity(0)) {
            try PeerConnectionEpochIssuer(host: Fixture.host, capacity: 0)
        }
        #expect(throws: PeerConnectionEpochError.invalidCapacity(1_025)) {
            try PeerConnectionEpochIssuer(host: Fixture.host, capacity: 1_025)
        }
        #expect(try PeerConnectionEpochIssuer(host: Fixture.host, capacity: 1_024).capacity == 1_024)
        #expect(try PeerConnectionEpochIssuer(host: Fixture.host).capacity == 64)
    }

    @Test func anExhaustedCounterRefusesWithoutChangingState() throws {
        let last = Fixture.generation(Generation.maximumValue - 1)
        var issuer = try PeerConnectionEpochIssuer(host: Fixture.host, resumingAfter: last)
        #expect(try issuer.issue(for: remoteC) == epoch(remoteC, Generation.maximumValue))
        #expect(throws: PeerConnectionEpochError.exhausted) { try issuer.issue(for: remoteD) }
        #expect(throws: PeerConnectionEpochError.exhausted) { try issuer.issue(for: remoteC) }
        #expect(issuer.current(for: remoteD) == nil)
        #expect(issuer.isCurrent(epoch(remoteC, Generation.maximumValue)))
    }

    @Test func issuedEpochsDriveTheRemoteAndOldEpochIntentsAreRefused() throws {
        var issuer = issuer()
        let hostEpoch = HostEpoch(host: Fixture.host, generation: Fixture.generation(1))
        let firstEpoch = try issuer.issue(for: Fixture.connection)
        let first = try #require(PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: firstEpoch))
        var state = Fixture.synced(first)
        try state.enqueue(Fixture.intent("command.a", session: first))

        let second = try #require(PeerSyncSession(hostEpoch: hostEpoch,
                                                  connectionEpoch: try issuer.issue(for: Fixture.connection)))
        #expect(!issuer.isCurrent(firstEpoch))
        _ = state.connectionLost(state.session)
        #expect(try state.reconnect(to: second).discarded == [Fixture.id("command.a")])
        var receiver = PeerSyncReceiver(session: second)
        _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(second))), from: receiver)
        #expect(throws: PeerOutboundRefusal.staleSession(.connectionEpoch)) {
            try state.enqueue(Fixture.intent("command.b", session: first))
        }
        try state.enqueue(Fixture.intent("command.b", session: second))
    }

    @Test func eventsForAnOldSessionAreIgnoredAndNeverEnableInput() throws {
        let old = Fixture.session(host: 1, connection: 1)
        let live = Fixture.session(host: 1, connection: 2)
        var state = Fixture.synced(old)
        _ = state.connectionLost(state.session)
        _ = try state.reconnect(to: live)
        var oldReceiver = PeerSyncReceiver(session: old)
        let oldApplied = oldReceiver.receive(Fixture.snapshot(old))
        #expect(state.observe(state.stamp(oldApplied), from: oldReceiver) == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.observe(state.stamp(oldReceiver)) == .ignored(.oldSession(.connectionEpoch)))
        var oldHost = PeerSyncReceiver(session: Fixture.session(host: 2, connection: 2))
        let hostApplied = oldHost.receive(Fixture.snapshot(oldHost.session))
        #expect(state.observe(state.stamp(hostApplied), from: oldHost) == .ignored(.oldSession(.hostEpoch)))
        #expect(state.phase == .resyncing(live))
        #expect(!state.isInputEnabled)

        var receiver = PeerSyncReceiver(session: live)
        let stale = receiver.receive(Fixture.snapshot(old))
        #expect(stale == .stale(.connectionEpoch))
        #expect(state.observe(state.stamp(stale), from: receiver) == .ignored(.oldSession(.connectionEpoch)))
        #expect(!state.isInputEnabled)
        #expect(state.observe(state.stamp(receiver.receive(Fixture.snapshot(live))), from: receiver)
                == .entered(.synced(live, awaitingResume: false)))
    }

    @Test func aLostConnectionDisablesInputAndIgnoresLateEvents() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        try state.enqueue(Fixture.intent("command.a"))
        #expect(state.connectionLost(state.session) == .entered(.disconnected(session)))
        #expect(state.connectionLost(state.session) == .unchanged)
        #expect(!state.isInputEnabled)
        #expect(try state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.b")) }
        var receiver = PeerSyncReceiver(session: session)
        let late = state.stamp(receiver.receive(Fixture.snapshot(session)))
        #expect(state.observe(late, from: receiver) == .ignored(.disconnected))
        #expect(state.observe(state.stamp(receiver)) == .ignored(.disconnected))
        #expect(state.phase == .disconnected(session))
        #expect(state.queue.count == 1)
    }

    @Test func anInSessionResyncHoldsIntentsUntilAnExplicitResume() throws {
        let session = Fixture.session()
        var state = Fixture.state(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(session))), from: receiver)
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume(state.latch) }
        try state.enqueue(Fixture.intent("command.a"))
        let gap = receiver.receive(Fixture.delta(session, sequence: 3))
        #expect(state.observe(state.stamp(gap), from: receiver) == .entered(.resyncing(session)))
        #expect(state.observe(state.stamp(receiver)) == .unchanged)
        #expect(!state.isInputEnabled)
        #expect(try state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.b")) }
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume(state.latch) }
        #expect(state.observe(state.stamp(PeerSyncEvent.refused(.emptyDelta)), from: receiver) == .unchanged)

        _ = receiver.receive(Fixture.snapshot(session, sequence: 3))
        #expect(state.observe(state.stamp(receiver)) == .entered(.synced(session, awaitingResume: true)))
        #expect(state.observe(state.stamp(receiver)) == .unchanged)
        #expect(!state.isInputEnabled)
        #expect(try state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.b")) }
        try state.resume(state.latch)
        #expect(state.phase == .synced(session, awaitingResume: false))
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume(state.latch) }
        #expect(try state.takeNextToSend()?.intent.id == Fixture.id("command.a"))
    }

    @Test func receiverPhasesMapOntoTheReconnectPhases() throws {
        let session = Fixture.session()
        var state = Fixture.state(session)
        var receiver = PeerSyncReceiver(session: session)
        #expect(state.observe(state.stamp(receiver)) == .unchanged)
        let request = PeerResyncRequest(session: session, lastApplied: .origin, reason: .repeated(.origin))
        #expect(state.observe(state.stamp(PeerSyncEvent.resyncRequested(request)), from: receiver) == .unchanged)
        #expect(state.phase == .connected(session))
        _ = receiver.receive(Fixture.snapshot(session))
        #expect(state.observe(state.stamp(receiver)) == .entered(.synced(session, awaitingResume: false)))
        _ = receiver.receive(Fixture.delta(session, sequence: 2))
        #expect(state.observe(state.stamp(receiver)) == .entered(.resyncing(session)))
        let foreign = PeerResyncRequest(session: Fixture.session(connection: 9), lastApplied: .origin,
                                        reason: .repeated(.origin))
        #expect(!state.isInputEnabled)
        let recovered = receiver.receive(Fixture.snapshot(session, sequence: 2))
        #expect(state.observe(state.stamp(recovered), from: receiver)
                == .entered(.synced(session, awaitingResume: false)))
        #expect(state.observe(state.stamp(PeerSyncEvent.resyncRequested(foreign)), from: receiver)
                == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.isInputEnabled)
    }

    @Test func aDelayedAppliedFromAnEarlierLatchNeverClearsTheNewOne() throws {
        let session = Fixture.session()
        var state = Fixture.state(session)
        var receiver = PeerSyncReceiver(session: session)
        let first = state.stamp(receiver.receive(Fixture.snapshot(session)))
        let earlier = state.latch
        #expect(state.observe(first, from: receiver) == .entered(.synced(session, awaitingResume: false)))
        let syncedCopy = state.stamp(receiver)
        try state.enqueue(Fixture.intent("command.a"))
        let gap = state.stamp(receiver.receive(Fixture.delta(session, sequence: 3)))
        #expect(state.observe(gap, from: receiver) == .entered(.resyncing(session)))
        let current = state.latch
        #expect(current != earlier && current.session == session)

        let stale = PeerReconnectIgnored.staleLatch(expected: current, found: earlier)
        #expect(state.observe(first, from: receiver) == .ignored(stale))
        #expect(state.observe(syncedCopy) == .ignored(stale))
        #expect(state.phase == .resyncing(session))
        #expect(!state.isInputEnabled)
        #expect(try state.takeNextToSend() == nil)
        #expect(throws: PeerReconnectError.staleLatch(expected: current, found: earlier)) { try state.resume(earlier) }
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume(current) }

        let recovered = state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 3)))
        #expect(state.observe(recovered, from: receiver) == .entered(.synced(session, awaitingResume: true)))
        #expect(state.latch == current)
        try state.resume(current)
        #expect(state.isInputEnabled)
        #expect(try state.takeNextToSend()?.intent.id == Fixture.id("command.a"))
    }

    @Test func anAppliedDeliveredAfterTheReceiverRelatchedIsIgnored() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = receiver.receive(Fixture.snapshot(session))
        _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: 3))), from: receiver)
        let applied = state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 3)))
        let relatched = state.stamp(receiver.receive(Fixture.delta(session, sequence: 6)))
        #expect(state.observe(applied, from: receiver) == .ignored(.receiverNotSynced(receiver.phase)))
        #expect(state.phase == .resyncing(session))
        #expect(!state.isInputEnabled)
        #expect(state.observe(relatched, from: receiver) == .unchanged)
        let answer = state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 6)))
        #expect(state.observe(answer, from: receiver) == .entered(.synced(session, awaitingResume: false)))
        #expect(state.isInputEnabled)
    }

    @Test func aDelayedSyncedPhaseCopyCannotReopenInputAfterAReLatch() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = receiver.receive(Fixture.snapshot(session))
        _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: 3))), from: receiver)
        let second = state.latch
        _ = receiver.receive(Fixture.snapshot(session, sequence: 3))
        let syncedCopy = state.stamp(receiver)
        let relatch = state.stamp(receiver.receive(Fixture.delta(session, sequence: 6)))
        #expect(state.observe(relatch, from: receiver) == .unchanged)
        let third = state.latch
        #expect(third != second && third.session == session)
        #expect(state.observe(syncedCopy) == .ignored(.staleLatch(expected: third, found: second)))
        #expect(state.phase == .resyncing(session))
        #expect(!state.isInputEnabled)
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume(third) }

        _ = receiver.receive(Fixture.snapshot(session, sequence: 6))
        #expect(state.observe(state.stamp(receiver)) == .entered(.synced(session, awaitingResume: false)))
        #expect(state.isInputEnabled)
    }

    @Test func anAppliedFromBeforeAReLatchIsIgnoredAndRecoveryStillCompletes() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = receiver.receive(Fixture.snapshot(session))
        _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: 3))), from: receiver)
        let second = state.latch
        let early = state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 3)))
        let syncedCopy = state.stamp(receiver)
        _ = receiver.receive(Fixture.delta(session, sequence: 6))
        #expect(state.observe(state.stamp(receiver)) == .unchanged)
        let third = state.latch
        #expect(state.observe(syncedCopy) == .ignored(.staleLatch(expected: third, found: second)))
        let answer = state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 6)))
        #expect(state.observe(early, from: receiver) == .ignored(.staleLatch(expected: third, found: second)))
        #expect(state.phase == .resyncing(session))
        #expect(!state.isInputEnabled)
        #expect(state.observe(answer, from: receiver) == .entered(.synced(session, awaitingResume: false)))
        #expect(state.latch == third)
        #expect(state.isInputEnabled)
    }

    @Test func aDelayedResumeFromAnEarlierLatchIsRefused() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = receiver.receive(Fixture.snapshot(session))
        try state.enqueue(Fixture.intent("command.a"))
        for sequence in [3, 6] {
            _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: sequence))), from: receiver)
            _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(session, sequence: sequence))),
                              from: receiver)
            #expect(state.phase == .synced(session, awaitingResume: true))
            if sequence == 3 {
                let revalidated = state.latch
                _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: 5))), from: receiver)
                #expect(state.phase == .resyncing(session))
                _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 5))),
                                  from: receiver)
                let current = state.latch
                #expect(throws: PeerReconnectError.staleLatch(expected: current, found: revalidated)) {
                    try state.resume(revalidated)
                }
                #expect(state.phase == .synced(session, awaitingResume: true))
                #expect(try state.takeNextToSend() == nil)
            }
        }
        try state.resume(state.latch)
        #expect(try state.takeNextToSend()?.intent.id == Fixture.id("command.a"))
    }

    @Test func lateConnectionSignalsOfAnEarlierSessionChangeNothing() throws {
        let first = Fixture.session(connection: 1)
        let second = Fixture.session(connection: 2)
        var state = Fixture.synced(first)
        try state.enqueue(Fixture.intent("command.a", session: first))
        let taken = try state.takeNextToSend()
        let sent = try #require(taken)
        #expect(throws: PeerReconnectError.notDisconnected) { try state.nextAttemptDelay(after: first, jitter: 0) }
        _ = state.connectionLost(first)
        #expect(throws: PeerReconnectError.backoff(.invalidJitterUnit)) {
            try state.nextAttemptDelay(after: first, jitter: 1)
        }
        _ = try state.nextAttemptDelay(after: first, jitter: 0)
        let report = try state.reconnect(to: second)
        #expect(report.unknownOutcome == [sent.intent.id])
        #expect(state.latch.session == second)

        #expect(state.connectionLost(first) == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.phase == .resyncing(second))
        #expect(throws: PeerReconnectError.oldSession(.connectionEpoch)) {
            try state.nextAttemptDelay(after: first, jitter: 0)
        }
        #expect(throws: PeerOutboundRefusal.staleSession(.connectionEpoch)) {
            try state.acknowledge(Fixture.result(sent), session: first)
        }
        #expect(state.attempts.count == 1)
        _ = state.connectionLost(second)
        #expect(throws: PeerReconnectError.oldSession(.connectionEpoch)) {
            try state.nextAttemptDelay(after: first, jitter: 0)
        }
        #expect(state.attempts.count == 1)
        #expect(try state.nextAttemptDelay(after: second, jitter: 0) == .milliseconds(250))
    }

    @Test func aResultDelayedAcrossAnInSessionResyncIsStillAccepted() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = receiver.receive(Fixture.snapshot(session))
        try state.enqueue(Fixture.intent("command.a"))
        let taken = try state.takeNextToSend()
        let sent = try #require(taken)
        _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: 3))), from: receiver)
        try state.acknowledge(Fixture.result(sent), session: session)
        #expect(state.queue.awaitingResult.isEmpty)
    }

    @Test func sessionsFromPerHostEpochIssuersAreAdoptedInOrder() throws {
        let hostOne = HostEpoch(host: Fixture.host, generation: Fixture.generation(1))
        let hostTwo = HostEpoch(host: Fixture.host, generation: Fixture.generation(2))
        var firstIssuer = issuer()
        var secondIssuer = issuer()
        let sessions = try [
            (hostOne, firstIssuer.issue(for: Fixture.connection)),
            (hostOne, firstIssuer.issue(for: Fixture.connection)),
            (hostTwo, secondIssuer.issue(for: Fixture.connection))
        ].map { try #require(PeerSyncSession(hostEpoch: $0.0, connectionEpoch: $0.1)) }
        #expect(sessions.map { $0.connectionEpoch.generation.value } == [1, 2, 1])
        var state = Fixture.state(sessions[0])
        for next in sessions.dropFirst() {
            _ = state.connectionLost(state.session)
            _ = try state.reconnect(to: next)
        }
        _ = state.connectionLost(state.session)
        for stale in sessions {
            #expect(throws: PeerReconnectError.staleSession(stale)) { try state.reconnect(to: stale) }
        }
    }

    @Test func attemptsSaturateAndResetOnASuccessfulSync() throws {
        var attempts = PeerReconnectAttempts()
        #expect(try attempts.next(jitter: 0) == .milliseconds(125))
        #expect(try attempts.next(jitter: 0) == .milliseconds(250))
        #expect(throws: PeerReconnectBackoffError.invalidJitterUnit) { try attempts.next(jitter: 1) }
        #expect(attempts.count == 2)
        for _ in 2..<32 { _ = try attempts.next(jitter: 0) }
        #expect(attempts.count == 32)
        #expect(try attempts.next(jitter: 0) == .milliseconds(15_000))
        #expect(attempts.count == 32)
        attempts.reset()
        #expect(attempts.count == 0)

        let session = Fixture.session(connection: 1)
        let next = Fixture.session(connection: 2)
        var state = Fixture.synced(session)
        _ = state.connectionLost(state.session)
        #expect(try state.nextAttemptDelay(after: state.session, jitter: 0) == .milliseconds(125))
        #expect(try state.nextAttemptDelay(after: state.session, jitter: 0) == .milliseconds(250))
        _ = try state.reconnect(to: next)
        #expect(state.attempts.count == 2)
        var receiver = PeerSyncReceiver(session: next)
        _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(next))), from: receiver)
        #expect(state.attempts.count == 0)
        _ = state.connectionLost(state.session)
        #expect(try state.nextAttemptDelay(after: state.session, jitter: 0) == .milliseconds(125))
    }

    @Test func backoffIsCappedExponentialWithEqualJitter() throws {
        let ceilings = try (0...8).map { try PeerReconnectBackoff.ceilingMilliseconds(attempt: $0) }
        #expect(ceilings == [250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000])
        #expect(try milliseconds(0, 0) == .milliseconds(125))
        #expect(try milliseconds(0, 0.5) == .milliseconds(187))
        #expect(try milliseconds(6, 0.25) == .milliseconds(10_000))
        #expect(try milliseconds(7, 0) == .milliseconds(15_000))
        #expect(try milliseconds(7, 1.0.nextDown) == .milliseconds(29_999))
        #expect(try milliseconds(64, 0.5) == .milliseconds(22_500))
        #expect(try milliseconds(Int.max, 0) == .milliseconds(15_000))
    }

    @Test func backoffRefusesInvalidInputs() {
        #expect(throws: PeerReconnectBackoffError.negativeAttempt(-1)) { try milliseconds(-1, 0) }
        for jitter in [1.0, -0.1, -Double.ulpOfOne, Double.nan, Double.infinity] {
            #expect(throws: PeerReconnectBackoffError.invalidJitterUnit) { try milliseconds(0, jitter) }
        }
    }
}

extension PeerReconnectEpochTests {
    @Test func theFirstSequenceHookRefusesOriginAndAcceptsOneThroughTheMaximum() throws {
        let session = Fixture.session()
        #expect(throws: PeerOutboundCapacityError.invalidFirstSequence(.origin)) {
            try PeerOutboundQueue(session: session, firstSequence: .origin)
        }
        #expect(throws: PeerOutboundCapacityError.invalidFirstSequence(.origin)) {
            try PeerReconnectState(session: session, firstSequence: .origin)
        }
        #expect(throws: PeerOutboundCapacityError.invalidCapacity(0)) {
            try PeerOutboundQueue(session: session, capacity: 0, firstSequence: .origin)
        }
        var queue = try PeerOutboundQueue(session: session, firstSequence: Fixture.sequence(1))
        try queue.enqueue(Fixture.intent("command.a"))
        #expect(try queue.takeNext()?.sequence == Fixture.sequence(1))
        var state = try PeerReconnectState(session: session, firstSequence: Fixture.sequence(1))
        var receiver = PeerSyncReceiver(session: session)
        _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(session))), from: receiver)
        try state.enqueue(Fixture.intent("command.b"))
        #expect(try state.takeNextToSend()?.sequence == Fixture.sequence(1))
        let last = Fixture.sequence(PeerSequence.maximumValue)
        let restored = try PeerOutboundQueue(session: session, firstSequence: last)
        #expect(restored.nextSequence == last && !restored.isSequenceExhausted)
    }
}
