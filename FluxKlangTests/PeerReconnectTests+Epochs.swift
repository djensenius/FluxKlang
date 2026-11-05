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

@Suite("PeerReconnectTests+Epochs")
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
        _ = state.connectionLost()
        #expect(try state.reconnect(to: second).discarded == [Fixture.id("command.a")])
        var receiver = PeerSyncReceiver(session: second)
        _ = state.observe(receiver.receive(Fixture.snapshot(second)), from: receiver)
        #expect(throws: PeerOutboundRefusal.staleSession(.connectionEpoch)) {
            try state.enqueue(Fixture.intent("command.b", session: first))
        }
        try state.enqueue(Fixture.intent("command.b", session: second))
    }

    @Test func eventsForAnOldSessionAreIgnoredAndNeverEnableInput() throws {
        let old = Fixture.session(host: 1, connection: 1)
        let live = Fixture.session(host: 1, connection: 2)
        var state = Fixture.synced(old)
        _ = state.connectionLost()
        _ = try state.reconnect(to: live)
        var oldReceiver = PeerSyncReceiver(session: old)
        let oldApplied = oldReceiver.receive(Fixture.snapshot(old))
        #expect(state.observe(oldApplied, from: oldReceiver) == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.observe(oldReceiver) == .ignored(.oldSession(.connectionEpoch)))
        var oldHost = PeerSyncReceiver(session: Fixture.session(host: 2, connection: 2))
        let hostApplied = oldHost.receive(Fixture.snapshot(oldHost.session))
        #expect(state.observe(hostApplied, from: oldHost) == .ignored(.oldSession(.hostEpoch)))
        #expect(state.phase == .resyncing(live))
        #expect(!state.isInputEnabled)

        var receiver = PeerSyncReceiver(session: live)
        let stale = receiver.receive(Fixture.snapshot(old))
        #expect(stale == .stale(.connectionEpoch))
        #expect(state.observe(stale, from: receiver) == .ignored(.oldSession(.connectionEpoch)))
        #expect(!state.isInputEnabled)
        #expect(state.observe(receiver.receive(Fixture.snapshot(live)), from: receiver)
                == .entered(.synced(live, awaitingResume: false)))
    }

    @Test func aLostConnectionDisablesInputAndIgnoresLateEvents() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        try state.enqueue(Fixture.intent("command.a"))
        #expect(state.connectionLost() == .entered(.disconnected(session)))
        #expect(state.connectionLost() == .unchanged)
        #expect(!state.isInputEnabled)
        #expect(state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.b")) }
        var receiver = PeerSyncReceiver(session: session)
        #expect(state.observe(receiver.receive(Fixture.snapshot(session)), from: receiver) == .ignored(.disconnected))
        #expect(state.observe(receiver) == .ignored(.disconnected))
        #expect(state.phase == .disconnected(session))
        #expect(state.queue.count == 1)
    }

    @Test func anInSessionResyncHoldsIntentsUntilAnExplicitResume() throws {
        let session = Fixture.session()
        var state = Fixture.state(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = state.observe(receiver.receive(Fixture.snapshot(session)), from: receiver)
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume() }
        try state.enqueue(Fixture.intent("command.a"))
        let gap = receiver.receive(Fixture.delta(session, sequence: 3))
        #expect(state.observe(gap, from: receiver) == .entered(.resyncing(session)))
        #expect(state.observe(receiver) == .unchanged)
        #expect(!state.isInputEnabled)
        #expect(state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.b")) }
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume() }
        #expect(state.observe(.refused(.emptyDelta), from: receiver) == .unchanged)

        _ = receiver.receive(Fixture.snapshot(session, sequence: 3))
        #expect(state.observe(receiver) == .entered(.synced(session, awaitingResume: true)))
        #expect(state.observe(receiver) == .unchanged)
        #expect(!state.isInputEnabled)
        #expect(state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.b")) }
        try state.resume()
        #expect(state.phase == .synced(session, awaitingResume: false))
        #expect(throws: PeerReconnectError.notAwaitingResume) { try state.resume() }
        #expect(state.takeNextToSend()?.id == Fixture.id("command.a"))
    }

    @Test func receiverPhasesMapOntoTheReconnectPhases() throws {
        let session = Fixture.session()
        var state = Fixture.state(session)
        var receiver = PeerSyncReceiver(session: session)
        #expect(state.observe(receiver) == .unchanged)
        let request = PeerResyncRequest(session: session, lastApplied: .origin, reason: .repeated(.origin))
        #expect(state.observe(.resyncRequested(request), from: receiver) == .unchanged)
        #expect(state.phase == .connected(session))
        _ = receiver.receive(Fixture.snapshot(session))
        #expect(state.observe(receiver) == .entered(.synced(session, awaitingResume: false)))
        _ = receiver.receive(Fixture.delta(session, sequence: 2))
        #expect(state.observe(receiver) == .entered(.resyncing(session)))
        let foreign = PeerResyncRequest(session: Fixture.session(connection: 9), lastApplied: .origin,
                                        reason: .repeated(.origin))
        _ = state.observe(.applied(.origin), from: receiver)
        #expect(state.observe(.resyncRequested(foreign), from: receiver) == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.isInputEnabled)
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
            _ = state.connectionLost()
            _ = try state.reconnect(to: next)
        }
        _ = state.connectionLost()
        for stale in sessions {
            #expect(throws: PeerReconnectError.staleSession(stale)) { try state.reconnect(to: stale) }
        }
    }

    @Test func attemptsSaturateAndResetOnASuccessfulSync() throws {
        #if false
        // Must not compile: the count is only ever 0 at creation.
        _ = PeerReconnectAttempts(count: 99)
        #endif
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
        _ = state.connectionLost()
        #expect(try state.nextAttemptDelay(jitter: 0) == .milliseconds(125))
        #expect(try state.nextAttemptDelay(jitter: 0) == .milliseconds(250))
        _ = try state.reconnect(to: next)
        #expect(state.attempts.count == 2)
        var receiver = PeerSyncReceiver(session: next)
        _ = state.observe(receiver.receive(Fixture.snapshot(next)), from: receiver)
        #expect(state.attempts.count == 0)
        _ = state.connectionLost()
        #expect(try state.nextAttemptDelay(jitter: 0) == .milliseconds(125))
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
