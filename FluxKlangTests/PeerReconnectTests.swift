import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum PeerReconnectFixture {
    static let host = HostID(validated: "host.reconnect")
    static let connection = ConnectionID(validated: "connection.reconnect")
    static let gain = ParameterID(validated: "parameter.gain")
    static let permission = PermissionFingerprint(rawValue: "permissions.reconnect")

    static func generation(_ value: Int) -> Generation {
        do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
    }

    static func sequence(_ value: Int) -> PeerSequence {
        do { return try PeerSequence(value) } catch { preconditionFailure("invalid sequence \(value)") }
    }

    static func session(host hostGeneration: Int = 1, connection connectionGeneration: Int = 1) -> PeerSyncSession {
        let hostEpoch = HostEpoch(host: host, generation: generation(hostGeneration))
        let connectionEpoch = ConnectionEpoch(connection: connection, host: host,
                                              generation: generation(connectionGeneration))
        guard let session = PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: connectionEpoch) else {
            preconditionFailure("invalid session")
        }
        return session
    }

    static func revisions() -> CommandRevisions { CommandRevisions(patch: .initial, parameter: .initial) }

    static func id(_ raw: String) -> CommandID {
        guard let id = CommandID(rawValue: raw) else { preconditionFailure("invalid command ID \(raw)") }
        return id
    }

    static func intent(_ raw: String, session: PeerSyncSession = session(), value: Double = 0.5,
                       connectionEpoch: ConnectionEpoch?? = nil) -> CommandIntent {
        do {
            return try CommandIntent(.init(
                id: id(raw), commandClass: .live, origin: .controller, hostEpoch: session.hostEpoch,
                connectionEpoch: connectionEpoch ?? session.connectionEpoch, revisions: revisions(),
                operation: .set(gain, ParameterValue(value: value, unit: .normalized)), permission: permission
            ))
        } catch { preconditionFailure("invalid intent \(raw): \(error)") }
    }

    static func snapshot(_ session: PeerSyncSession, sequence: Int = 0) -> PeerSyncSnapshot {
        PeerSyncSnapshot(session: session, sequence: self.sequence(sequence), revisions: revisions(),
                         values: [gain: ParameterValue(value: 0.5, unit: .normalized)])
    }

    static func delta(_ session: PeerSyncSession, sequence: Int) -> PeerSyncDelta {
        PeerSyncDelta(session: session, sequence: self.sequence(sequence), revisions: revisions(),
                      updates: [gain: ParameterValue(value: 0.25, unit: .normalized)], removals: [])
    }

    static func result(_ raw: String, sequence: Int,
                       outcome: PeerCommandOutcome = .admitted) -> PeerCommandResult {
        PeerCommandResult(sequence: self.sequence(sequence), command: id(raw), outcome: outcome)
    }

    static func result(_ sent: PeerCommandEnvelope, outcome: PeerCommandOutcome = .admitted) -> PeerCommandResult {
        PeerCommandResult(sequence: sent.sequence, command: sent.intent.id, outcome: outcome)
    }

    static func state(_ session: PeerSyncSession = session(), capacity: Int = 8) -> PeerReconnectState {
        do { return try PeerReconnectState(session: session, queueCapacity: capacity) } catch {
            preconditionFailure("invalid capacity \(capacity)")
        }
    }

    /// A state for `session` whose first snapshot was applied through a real receiver.
    static func synced(_ session: PeerSyncSession = session(), capacity: Int = 8) -> PeerReconnectState {
        var state = state(session, capacity: capacity)
        var receiver = PeerSyncReceiver(session: session)
        _ = state.observe(state.stamp(receiver.receive(snapshot(session))), from: receiver)
        return state
    }
}

private typealias Fixture = PeerReconnectFixture

private func ids(_ raws: [String]) -> [CommandID] { raws.map(Fixture.id) }

@Suite("PeerReconnectTests")
struct PeerReconnectTests {
    @Test func inputStaysDisabledUntilACurrentSnapshotIsApplied() throws {
        let session = Fixture.session()
        var state = Fixture.state(session)
        var receiver = PeerSyncReceiver(session: session)
        #expect(state.phase == .connected(session))
        #expect(!state.isInputEnabled)
        #expect(throws: PeerOutboundRefusal.inputDisabled) { try state.enqueue(Fixture.intent("command.a")) }

        let early = receiver.receive(Fixture.delta(session, sequence: 1))
        #expect(early == .discardedAwaitingSnapshot(Fixture.sequence(1)))
        #expect(state.observe(state.stamp(early), from: receiver) == .unchanged)
        #expect(state.observe(state.stamp(receiver)) == .unchanged)
        #expect(!state.isInputEnabled)

        let applied = receiver.receive(Fixture.snapshot(session, sequence: 1))
        #expect(state.observe(state.stamp(applied), from: receiver)
                == .entered(.synced(session, awaitingResume: false)))
        #expect(state.isInputEnabled)
        try state.enqueue(Fixture.intent("command.a"))
        #expect(try state.takeNextToSend()?.intent.id == Fixture.id("command.a"))
    }

    @Test func intentsLeaveInStrictOrderWithoutCoalescing() throws {
        var state = Fixture.synced()
        for (raw, value) in [("command.c", 0.1), ("command.a", 0.2), ("command.b", 0.3)] {
            try state.enqueue(Fixture.intent(raw, value: value))
        }
        var sent: [CommandIntent] = []
        while let next = try state.takeNextToSend() { sent.append(next.intent) }
        #expect(sent.map { $0.id } == ids(["command.c", "command.a", "command.b"]))
        #expect(sent.map { $0.operation } == [0.1, 0.2, 0.3].map {
            CommandOperation.set(Fixture.gain, ParameterValue(value: $0, unit: .normalized))
        })
        #expect(state.queue.awaitingResult.count == 3)
    }

    @Test func aFullQueueRefusesAtCapacityPlusOneAndNeverEvicts() throws {
        var state = Fixture.synced(capacity: 3)
        try state.enqueue(Fixture.intent("command.1"))
        _ = try state.takeNextToSend()
        try state.enqueue(Fixture.intent("command.2"))
        try state.enqueue(Fixture.intent("command.3"))
        #expect(state.queue.isFull)
        #expect(throws: PeerOutboundRefusal.full(capacity: 3)) { try state.enqueue(Fixture.intent("command.4")) }
        #expect(state.queue.awaitingResult.map { $0.intent.id } == ids(["command.1"]))
        #expect(state.queue.queued.map { $0.id } == ids(["command.2", "command.3"]))

        try state.acknowledge(Fixture.result("command.1", sequence: 1), session: state.session)
        try state.enqueue(Fixture.intent("command.4"))
        #expect(state.queue.count == 3)
    }

    @Test func standardCapacityIs256AndCapacityBoundsArePinned() throws {
        var queue = try PeerOutboundQueue(session: Fixture.session())
        for index in 0..<256 { try queue.enqueue(Fixture.intent("command.\(index)")) }
        #expect(throws: PeerOutboundRefusal.full(capacity: 256)) { try queue.enqueue(Fixture.intent("command.256")) }
        #expect(queue.count == 256)
        #expect(throws: PeerOutboundCapacityError.invalidCapacity(0)) {
            try PeerOutboundQueue(session: Fixture.session(), capacity: 0)
        }
        #expect(throws: PeerOutboundCapacityError.invalidCapacity(4_097)) {
            try PeerOutboundQueue(session: Fixture.session(), capacity: 4_097)
        }
        #expect(try PeerOutboundQueue(session: Fixture.session(), capacity: 1).capacity == 1)
        #expect(try PeerOutboundQueue(session: Fixture.session(), capacity: 4_096).capacity == 4_096)
    }

    @Test func intentsFromAnyOtherEpochAreRefusedAtEnqueue() throws {
        let live = Fixture.session(host: 2, connection: 5)
        var state = Fixture.synced(live)
        let cases: [(CommandIntent, StaleDependency)] = [
            (Fixture.intent("command.old", session: Fixture.session(host: 2, connection: 4)), .connectionEpoch),
            (Fixture.intent("command.newer", session: Fixture.session(host: 2, connection: 6)), .connectionEpoch),
            (Fixture.intent("command.host", session: Fixture.session(host: 1, connection: 5)), .hostEpoch),
            (Fixture.intent("command.none", session: live, connectionEpoch: .some(nil)), .connectionEpoch)
        ]
        for (intent, dependency) in cases {
            #expect(throws: PeerOutboundRefusal.staleSession(dependency)) { try state.enqueue(intent) }
        }
        #expect(state.queue.count == 0)
    }

    @Test func aDuplicateIDIsRefusedWhileQueuedOrAwaitingItsResult() throws {
        var state = Fixture.synced()
        try state.enqueue(Fixture.intent("command.a"))
        #expect(throws: PeerOutboundRefusal.duplicate(Fixture.id("command.a"))) {
            try state.enqueue(Fixture.intent("command.a", value: 0.9))
        }
        _ = try state.takeNextToSend()
        #expect(throws: PeerOutboundRefusal.duplicate(Fixture.id("command.a"))) {
            try state.enqueue(Fixture.intent("command.a"))
        }
        try state.acknowledge(Fixture.result("command.a", sequence: 1), session: state.session)
        try state.enqueue(Fixture.intent("command.a"))
        #expect(state.queue.queued.count == 1)
    }

    @Test func resultsAreAcceptedOnlyOnceAndOnlyForTheCurrentSession() throws {
        var state = Fixture.synced()
        try state.enqueue(Fixture.intent("command.a"))
        try state.enqueue(Fixture.intent("command.b"))
        #expect(throws: PeerOutboundRefusal.notAwaitingResult(Fixture.id("command.a"))) {
            try state.acknowledge(Fixture.result("command.a", sequence: 1), session: state.session)
        }
        _ = try state.takeNextToSend()
        #expect(throws: PeerOutboundRefusal.staleSession(.connectionEpoch)) {
            try state.acknowledge(Fixture.result("command.a", sequence: 1), session: Fixture.session(connection: 2))
        }
        try state.acknowledge(Fixture.result("command.a", sequence: 1), session: state.session)
        #expect(throws: PeerOutboundRefusal.notAwaitingResult(Fixture.id("command.a"))) {
            try state.acknowledge(Fixture.result("command.a", sequence: 1), session: state.session)
        }
        #expect(state.queue.queued.map { $0.id } == ids(["command.b"]))
        #expect(state.queue.awaitingResult.isEmpty)
    }

    @Test func aDelayedDuplicateResultOfAReusedIDNeverAnswersTheLaterSend() throws {
        for first in [PeerCommandOutcome.admitted, .refused(.ledgerFull(capacity: 4))] {
            var state = Fixture.synced()
            try state.enqueue(Fixture.intent("command.x"))
            let taken = try state.takeNextToSend()
            let original = try #require(taken)
            try state.acknowledge(Fixture.result(original, outcome: first), session: state.session)
            try state.enqueue(Fixture.intent("command.x"))
            let retaken = try state.takeNextToSend()
            let resent = try #require(retaken)
            #expect(original.sequence == Fixture.sequence(1) && resent.sequence == Fixture.sequence(2))

            let expected = PeerOutboundRefusal.sequenceMismatch(Fixture.id("command.x"), expected: resent.sequence,
                                                                 found: original.sequence)
            #expect(throws: expected) {
                try state.acknowledge(Fixture.result(original, outcome: first), session: state.session)
            }
            #expect(state.queue.awaitingResult == [resent])
            _ = state.connectionLost(state.session)
            let report = try state.reconnect(to: Fixture.session(connection: 2))
            #expect(report.unknownOutcome == [Fixture.id("command.x")])
            #expect(report.discarded.isEmpty)
        }
    }

    @Test func theMatchingResultOfTheResendIsAcceptedAndSequencesRestartPerSession() throws {
        var state = Fixture.synced()
        try state.enqueue(Fixture.intent("command.x"))
        _ = try state.takeNextToSend()
        try state.acknowledge(Fixture.result("command.x", sequence: 1, outcome: .refused(.ledgerFull(capacity: 4))),
                              session: state.session)
        try state.enqueue(Fixture.intent("command.x"))
        try state.enqueue(Fixture.intent("command.y"))
        #expect(try state.takeNextToSend()?.sequence == Fixture.sequence(2))
        #expect(try state.takeNextToSend()?.sequence == Fixture.sequence(3))
        let later = PeerOutboundRefusal.sequenceMismatch(Fixture.id("command.x"), expected: Fixture.sequence(2),
                                                          found: Fixture.sequence(3))
        #expect(throws: later) {
            try state.acknowledge(Fixture.result("command.x", sequence: 3), session: state.session)
        }
        #expect(state.queue.awaitingResult.map { $0.sequence } == [Fixture.sequence(2), Fixture.sequence(3)])
        try state.acknowledge(Fixture.result("command.x", sequence: 2), session: state.session)
        #expect(state.queue.awaitingResult.map { $0.intent.id } == ids(["command.y"]))
        #expect(state.queue.nextSequence == Fixture.sequence(4))

        let second = Fixture.session(connection: 2)
        _ = state.connectionLost(state.session)
        let report = try state.reconnect(to: second)
        #expect(report.unknownOutcome == ids(["command.y"]))
        #expect(state.queue.nextSequence == Fixture.sequence(1))
    }

    @Test func exhaustedSequencesRefuseWithATypedErrorUntilAReconnect() throws {
        let first = Fixture.session()
        let last = Fixture.sequence(PeerSequence.maximumValue)
        var state = try PeerReconnectState(session: first, firstSequence: last)
        var receiver = PeerSyncReceiver(session: first)
        _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(first))), from: receiver)
        try state.enqueue(Fixture.intent("command.a"))
        try state.enqueue(Fixture.intent("command.b"))
        #expect(try state.takeNextToSend()?.sequence == last)
        #expect(state.queue.isSequenceExhausted && !state.isInputEnabled)
        #expect(throws: PeerOutboundRefusal.sequenceExhausted) { _ = try state.takeNextToSend() }
        #expect(throws: PeerOutboundRefusal.sequenceExhausted) { try state.enqueue(Fixture.intent("command.c")) }
        #expect(state.queue.queued.map { $0.id } == ids(["command.b"]))
        #expect(state.queue.awaitingResult.map { $0.sequence } == [last])

        let second = Fixture.session(connection: 2)
        _ = state.connectionLost(first)
        let report = try state.reconnect(to: second)
        #expect(report.discarded == ids(["command.b"]) && report.unknownOutcome == ids(["command.a"]))
        receiver = PeerSyncReceiver(session: second)
        _ = state.observe(state.stamp(receiver.receive(Fixture.snapshot(second))), from: receiver)
        #expect(state.isInputEnabled)
        try state.enqueue(Fixture.intent("command.c", session: second))
        #expect(try state.takeNextToSend()?.sequence == Fixture.sequence(1))
    }

    @Test func reconnectDropsEverythingAndReportsDiscardedAndUnknownSeparately() throws {
        let first = Fixture.session(connection: 3)
        let second = Fixture.session(connection: 4)
        var state = Fixture.synced(first)
        for raw in ["command.d", "command.b", "command.c", "command.a"] {
            try state.enqueue(Fixture.intent(raw, session: first))
        }
        _ = try state.takeNextToSend()
        _ = try state.takeNextToSend()
        try state.acknowledge(Fixture.result("command.d", sequence: 1), session: first)
        #expect(state.connectionLost(state.session) == .entered(.disconnected(first)))

        let report = try state.reconnect(to: second)
        #expect(report.previousSession == first)
        #expect(report.session == second)
        #expect(report.discarded == ids(["command.a", "command.c"]))
        #expect(report.unknownOutcome == ids(["command.b"]))
        #expect(report.discardedCount == 2)
        #expect(report.unknownOutcomeCount == 1)
        #expect(report.headline == "2 changes discarded")
        #expect(state.phase == .resyncing(second))
        #expect(!state.isInputEnabled)
        #expect(state.queue.count == 0)
        #expect(state.session == second)

        var receiver = PeerSyncReceiver(session: second)
        #expect(state.observe(state.stamp(receiver.receive(Fixture.snapshot(second))), from: receiver)
                == .entered(.synced(second, awaitingResume: false)))
        #expect(try state.takeNextToSend() == nil)
        #expect(throws: PeerOutboundRefusal.notAwaitingResult(Fixture.id("command.b"))) {
            try state.acknowledge(Fixture.result("command.b", sequence: 2), session: second)
        }
    }

    @Test func theReportIsEmittedOnceAndNeverRepeatedByLaterReconnects() throws {
        let first = Fixture.session(connection: 1)
        var state = Fixture.synced(first)
        try state.enqueue(Fixture.intent("command.a", session: first))
        try state.enqueue(Fixture.intent("command.b", session: first))
        _ = try state.takeNextToSend()
        _ = state.connectionLost(state.session)
        let report = try state.reconnect(to: Fixture.session(connection: 2))
        #expect(report.discarded == [Fixture.id("command.b")])
        #expect(report.unknownOutcome == [Fixture.id("command.a")])
        #expect(report.headline == "1 change discarded")
        _ = state.connectionLost(state.session)
        let again = try state.reconnect(to: Fixture.session(connection: 3))
        #expect(again.isEmpty)
        #expect(again.discarded.isEmpty && again.unknownOutcome.isEmpty)
        #expect(again.headline == "0 changes discarded")
        #expect(again.previousSession == Fixture.session(connection: 2))
    }

    @Test func reportIDListsAreSortedAndBoundedAt32WithATruncationCount() throws {
        for total in [32, 33] {
            var state = Fixture.synced(capacity: 80)
            for index in (0..<total).reversed() { try state.enqueue(Fixture.intent("command.q\(1_000 + index)")) }
            for index in (0..<total).reversed() { try state.enqueue(Fixture.intent("command.s\(1_000 + index)")) }
            for _ in 0..<total { _ = try state.takeNextToSend() }
            _ = state.connectionLost(state.session)
            let report = try state.reconnect(to: Fixture.session(connection: 2))
            let expectedQueued = (0..<min(total, 32)).map { Fixture.id("command.s\(1_000 + $0)") }
            let expectedSent = (0..<min(total, 32)).map { Fixture.id("command.q\(1_000 + $0)") }
            #expect(report.discardedCount == total)
            #expect(report.unknownOutcomeCount == total)
            #expect(report.discarded == expectedQueued)
            #expect(report.unknownOutcome == expectedSent)
            #expect(report.discardedTruncated == total - 32)
            #expect(report.unknownOutcomeTruncated == total - 32)
        }
    }

    @Test func aReconnectNeedsALostConnectionFirst() throws {
        let session = Fixture.session()
        let next = Fixture.session(connection: 2)
        var state = Fixture.synced(session)
        try state.enqueue(Fixture.intent("command.a"))
        #expect(throws: PeerReconnectError.notDisconnected) { try state.reconnect(to: next) }
        #expect(state.phase == .synced(session, awaitingResume: false))
        #expect(state.queue.count == 1)
        _ = state.connectionLost(state.session)
        _ = try state.reconnect(to: next)
        #expect(throws: PeerReconnectError.notDisconnected) { try state.reconnect(to: Fixture.session(connection: 3)) }
        #expect(state.phase == .resyncing(next))
    }

    @Test func aToBToANeverReadoptsTheEarlierSession() throws {
        let sessionA = Fixture.session(connection: 1)
        let sessionB = Fixture.session(connection: 2)
        var state = Fixture.synced(sessionA)
        try state.enqueue(Fixture.intent("command.a", session: sessionA))
        _ = state.connectionLost(state.session)
        #expect(throws: PeerReconnectError.staleSession(sessionA)) { try state.reconnect(to: sessionA) }
        #expect(state.queue.count == 1)
        _ = try state.reconnect(to: sessionB)
        _ = state.connectionLost(state.session)
        #expect(throws: PeerReconnectError.staleSession(sessionA)) { try state.reconnect(to: sessionA) }
        #expect(state.phase == .disconnected(sessionB))

        var oldReceiver = PeerSyncReceiver(session: sessionA)
        let applied = oldReceiver.receive(Fixture.snapshot(sessionA))
        #expect(state.observe(state.stamp(applied), from: oldReceiver) == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.observe(state.stamp(oldReceiver)) == .ignored(.oldSession(.connectionEpoch)))
        #expect(state.phase == .disconnected(sessionB))
        #expect(try state.reconnect(to: Fixture.session(host: 2, connection: 1)).isEmpty)
    }

    @Test func manyReconnectsNeverReadoptTheOldestOrAnEqualPair() throws {
        let sessionA = Fixture.session(connection: 1)
        var state = Fixture.state(sessionA)
        for connection in 2...20 {
            _ = state.connectionLost(state.session)
            _ = try state.reconnect(to: Fixture.session(connection: connection))
        }
        _ = state.connectionLost(state.session)
        for stale in [sessionA, Fixture.session(connection: 19), Fixture.session(connection: 20)] {
            #expect(throws: PeerReconnectError.staleSession(stale)) { try state.reconnect(to: stale) }
        }
        #expect(state.phase == .disconnected(Fixture.session(connection: 20)))
        _ = try state.reconnect(to: Fixture.session(connection: 21))
    }

    @Test func theHostGenerationOrdersBeforeTheConnectionGeneration() throws {
        var state = Fixture.state(Fixture.session(host: 2, connection: 5))
        _ = state.connectionLost(state.session)
        let older = [Fixture.session(host: 1, connection: 9), Fixture.session(host: 2, connection: 4),
                     Fixture.session(host: 1, connection: 6)]
        for stale in older {
            #expect(throws: PeerReconnectError.staleSession(stale)) { try state.reconnect(to: stale) }
        }
        _ = try state.reconnect(to: Fixture.session(host: 3, connection: 1))
        _ = state.connectionLost(state.session)
        #expect(throws: PeerReconnectError.staleSession(Fixture.session(host: 2, connection: 6))) {
            try state.reconnect(to: Fixture.session(host: 2, connection: 6))
        }
        _ = try state.reconnect(to: Fixture.session(host: 3, connection: 2))
        #expect(state.session == Fixture.session(host: 3, connection: 2))
    }

    @Test func anotherHostIsAdoptedOnlyThroughTheExplicitHostChange() throws {
        let otherHost = HostID(validated: "host.other")
        let other = ConnectionEpoch(connection: Fixture.connection, host: otherHost, generation: Fixture.generation(1))
        let foreign = try #require(PeerSyncSession(
            hostEpoch: HostEpoch(host: otherHost, generation: Fixture.generation(1)), connectionEpoch: other))
        let home = Fixture.session(host: 5, connection: 5)
        var state = Fixture.synced(home)
        try state.enqueue(Fixture.intent("command.a", session: home))
        #expect(throws: PeerReconnectError.notDisconnected) { try state.changeHost(to: foreign) }
        _ = state.connectionLost(state.session)
        #expect(throws: PeerReconnectError.hostMismatch(expected: Fixture.host, found: otherHost)) {
            try state.reconnect(to: foreign)
        }
        #expect(throws: PeerReconnectError.sameHost(Fixture.host)) {
            try state.changeHost(to: Fixture.session(host: 6, connection: 1))
        }
        #expect(state.queue.count == 1)
        #expect(try state.changeHost(to: foreign).discarded == [Fixture.id("command.a")])
        #expect(state.phase == .resyncing(foreign))
        _ = state.connectionLost(state.session)
        #expect(throws: PeerReconnectError.staleSession(foreign)) { try state.reconnect(to: foreign) }
        _ = try state.changeHost(to: Fixture.session(host: 1, connection: 1))
        #expect(state.session == Fixture.session(host: 1, connection: 1))
    }

    @Test func exhaustedLatchesFailClosedUntilAReconnect() throws {
        let first = Fixture.session(connection: 1)
        let second = Fixture.session(connection: 2)
        let last = Fixture.generation(Generation.maximumValue)
        var state = try PeerReconnectState(session: first, queueCapacity: 8, latchGeneration: last)
        var receiver = PeerSyncReceiver(session: first)
        #expect(state.observe(state.stamp(receiver.receive(Fixture.snapshot(first))), from: receiver)
                == .entered(.synced(first, awaitingResume: false)))
        let gap = state.stamp(receiver.receive(Fixture.delta(first, sequence: 3)))
        #expect(state.observe(gap, from: receiver) == .entered(.resyncing(first)))
        #expect(state.latchExhausted && state.latch.generation == last)
        #expect(state.phase == .resyncing(first))
        let recovered = state.stamp(receiver.receive(Fixture.snapshot(first, sequence: 3)))
        #expect(state.observe(recovered, from: receiver) == .ignored(.latchExhausted))
        #expect(state.observe(state.stamp(receiver)) == .ignored(.latchExhausted))
        #expect(throws: PeerReconnectError.latchExhausted) { try state.resume(state.latch) }
        #expect(!state.isInputEnabled)

        _ = state.connectionLost(first)
        _ = try state.reconnect(to: second)
        #expect(!state.latchExhausted && state.latch.generation == .initial && state.latch.session == second)
        var next = PeerSyncReceiver(session: second)
        #expect(state.observe(state.stamp(next.receive(Fixture.snapshot(second))), from: next)
                == .entered(.synced(second, awaitingResume: false)))
    }

    @Test func eachObservedResyncPhaseStartsALatchAndRecoveryNeedsALaterRead() throws {
        let session = Fixture.session()
        var state = Fixture.synced(session)
        var receiver = PeerSyncReceiver(session: session)
        _ = receiver.receive(Fixture.snapshot(session))
        _ = state.observe(state.stamp(receiver.receive(Fixture.delta(session, sequence: 3))), from: receiver)
        let poll = state.stamp(receiver)
        let applied = state.stamp(receiver.receive(Fixture.snapshot(session, sequence: 3)))
        #expect(poll.latch == applied.latch)
        #expect(state.observe(poll) == .unchanged)
        #expect(state.latch != poll.latch)
        let stale = PeerReconnectIgnored.staleLatch(expected: state.latch, found: applied.latch)
        #expect(state.observe(applied, from: receiver) == .ignored(stale))
        #expect(!state.isInputEnabled)
        #expect(state.observe(state.stamp(receiver)) == .entered(.synced(session, awaitingResume: false)))
        #expect(state.isInputEnabled)
    }
}
