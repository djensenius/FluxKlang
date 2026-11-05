import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = PeerSyncFixture

private let other = PermissionFingerprint(rawValue: "permissions.changed")

private func context(_ session: PeerSyncSession = Fixture.session(), revisions: CommandRevisions = Fixture.revisions(),
                     permission: PermissionFingerprint? = Fixture.permission) throws -> AdmissionContext {
    let descriptor = try ParameterDescriptor(.init(
        id: Fixture.gain, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: nil, curve: .linear,
        ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 0, maximumMilliseconds: 100)),
        controlClass: .live, verification: .reported
    ))
    return AdmissionContext(
        hostEpoch: session.hostEpoch, connectionEpoch: session.connectionEpoch, revisions: revisions,
        permission: permission, allowedScopes: [.parameter(Fixture.gain), .safety], allowedClasses: [.live, .safety],
        catalog: try ParameterCatalog([descriptor])
    )
}

private func intent(_ id: String = "command.one", session: PeerSyncSession = Fixture.session(),
                    revisions: CommandRevisions = Fixture.revisions(), value: Double = 0.25,
                    operation explicit: CommandOperation? = nil) throws -> CommandIntent {
    let operation = explicit ?? .set(Fixture.gain, Fixture.value(value))
    return try CommandIntent(.init(
        id: try CommandID(id), commandClass: operation.controlClass ?? .live, origin: .controller,
        hostEpoch: session.hostEpoch, connectionEpoch: session.connectionEpoch, revisions: revisions,
        operation: operation, permission: Fixture.permission
    ))
}

private func processor(_ session: PeerSyncSession = Fixture.session(), capacity: Int = 8) -> PeerCommandProcessor {
    do { return try PeerCommandProcessor(session: session, ledgerCapacity: capacity) } catch {
        preconditionFailure("invalid processor: \(error)")
    }
}

/// Sends envelopes with consecutive sequences from 1, like a well-behaved controller.
private struct Sender {
    var host: PeerCommandProcessor
    var sent = 0

    mutating func send(_ intent: CommandIntent, _ admission: AdmissionContext) -> PeerCommandOutcome {
        sent += 1
        return host.process(PeerCommandEnvelope(sequence: Fixture.sequence(sent), intent: intent),
                            admission: admission).outcome
    }
}

@Suite("PeerSyncTests+Commands")
struct PeerSyncCommandTests {
    @Test func oldEpochsRejectAbsoluteSettersAndSafetyBeforeTheLedger() throws {
        let live = Fixture.session(host: 2, connection: 5)
        var sender = Sender(host: processor(live))
        let oldHost = Fixture.session(host: 1, connection: 5)
        let oldConnection = Fixture.session(host: 2, connection: 4)
        #expect(sender.send(try intent(session: oldHost, value: 1), try context(live))
            == .refused(.command(.stale(.hostEpoch))))
        #expect(sender.send(try intent(session: oldConnection, operation: .panic), try context(live))
            == .refused(.command(.stale(.connectionEpoch))))
        #expect(sender.host.ledger.count == 0)
        #expect(sender.send(try intent(session: live), try context(live)) == .admitted)
    }

    @Test func duplicateIDAfterAnEpochBumpIsStaleNeverReplayed() throws {
        let first = Fixture.session(connection: 1)
        var sender = Sender(host: processor(first))
        let original = try intent(session: first)
        #expect(sender.send(original, try context(first)) == .admitted)
        try sender.host.complete(original.id, with: .applied(revisions: Fixture.revisions(parameter: 1)))
        let bumpedHost = Fixture.session(host: 2, connection: 1)
        #expect(sender.send(try intent(session: bumpedHost), try context(first))
            == .refused(.command(.stale(.hostEpoch))))

        let reconnected = Fixture.session(connection: 2)
        #expect(sender.send(original, try context(reconnected)) == .refused(.sessionRetired(.connectionEpoch)))
        var fresh = Sender(host: processor(reconnected))
        #expect(fresh.send(original, try context(reconnected, revisions: Fixture.revisions(parameter: 1)))
            == .refused(.command(.stale(.connectionEpoch))))
        #expect(fresh.host.ledger.count == 0)
    }

    @Test func lostAckRetryReplaysTheFirstResultWithoutReapplying() throws {
        var sender = Sender(host: processor())
        let command = try intent()
        #expect(sender.send(command, try context()) == .admitted)
        let applied = PeerCommandCompletion.applied(revisions: Fixture.revisions(parameter: 1))
        try sender.host.complete(command.id, with: applied)
        // The host moved on because of this very command; a fresh admission would refuse it.
        let after = try context(revisions: Fixture.revisions(parameter: 1))
        #expect(CommandAdmission.admit(command, in: after) == .refused(.rejected(.revisionChanged)))
        #expect(sender.send(command, after) == .replayed(applied))
        #expect(sender.send(command, after) == .replayed(applied))
        #expect(sender.host.ledger.count == 1)
    }

    @Test func duplicateWhilePendingIsInFlight() throws {
        var sender = Sender(host: processor())
        let command = try intent()
        #expect(sender.send(command, try context()) == .admitted)
        #expect(sender.send(command, try context()) == .inFlight)
    }

    @Test func reusedIDWithADifferentIntentIsRefused() throws {
        var sender = Sender(host: processor())
        #expect(sender.send(try intent(value: 0.25), try context()) == .admitted)
        #expect(sender.send(try intent(value: 0.75), try context()) == .refused(.conflictingReuse))
    }

    @Test func changedRevisionsNeedAFreshIntent() throws {
        var sender = Sender(host: processor())
        let moved = try context(revisions: Fixture.revisions(patch: 1))
        #expect(sender.send(try intent(), moved) == .refused(.command(.rejected(.revisionChanged))))
        #expect(sender.host.ledger.count == 0)
        #expect(sender.send(try intent("command.fresh", revisions: Fixture.revisions(patch: 1)), moved) == .admitted)
    }

    @Test func changedPermissionRejectsNewCommands() throws {
        var sender = Sender(host: processor())
        #expect(sender.send(try intent(), try context(permission: other))
            == .refused(.command(.rejected(.permissionChanged))))
        #expect(sender.send(try intent(), try context(permission: nil))
            == .refused(.command(.rejected(.permissionDenied))))
        #expect(sender.host.ledger.count == 0)
    }

    @Test func duplicatesFailClosedAfterAPermissionChange() throws {
        var sender = Sender(host: processor())
        let done = try intent("command.done")
        let pending = try intent("command.pending")
        #expect(sender.send(done, try context()) == .admitted)
        #expect(sender.send(pending, try context()) == .admitted)
        try sender.host.complete(done.id, with: .applied(revisions: Fixture.revisions()))
        let changed = try context(permission: other)
        #expect(sender.send(done, changed) == .refused(.command(.rejected(.permissionChanged))))
        #expect(sender.send(pending, changed) == .refused(.command(.rejected(.permissionChanged))))
        #expect(sender.send(done, try context(permission: nil)) == .refused(.command(.rejected(.permissionDenied))))
        #expect(sender.send(done, try context()) == .replayed(.applied(revisions: Fixture.revisions())))
    }

    @Test func fullLedgerRefusesWithoutEvicting() throws {
        var sender = Sender(host: processor(capacity: 1))
        let kept = try intent("command.kept")
        #expect(sender.send(kept, try context()) == .admitted)
        #expect(sender.send(try intent("command.extra"), try context()) == .refused(.ledgerFull(capacity: 1)))
        #expect(sender.send(kept, try context()) == .inFlight)
        #expect(sender.host.ledger.count == 1)
    }

    @Test func aBrokenSequenceLatchesTheSessionFailed() throws {
        var host = processor()
        let skipped = PeerCommandEnvelope(sequence: Fixture.sequence(2), intent: try intent())
        #expect(host.process(skipped, admission: try context()).outcome
            == .refused(.outOfSequence(expected: Fixture.sequence(1), found: Fixture.sequence(2))))
        let next = PeerCommandEnvelope(sequence: Fixture.sequence(1), intent: try intent())
        #expect(host.process(next, admission: try context()).outcome == .refused(.sessionFailed))
        #expect(host.hasFailed && host.ledger.count == 0)
    }

    @Test func freshnessOutranksTheSequenceButStillConsumesIt() throws {
        var host = processor()
        let stale = PeerCommandEnvelope(sequence: Fixture.sequence(3),
                                        intent: try intent(session: Fixture.session(host: 2)))
        let result = host.process(stale, admission: try context())
        #expect(result == PeerCommandResult(sequence: Fixture.sequence(3), command: stale.intent.id,
                                            outcome: .refused(.command(.stale(.hostEpoch)))))
        #expect(host.hasFailed)
    }

    @Test func admissionRefusalsAreNotRecorded() throws {
        var sender = Sender(host: processor())
        let outOfScope = try intent("command.scope", operation: .start)
        #expect(sender.send(outOfScope, try context()) == .refused(.command(.rejected(.scopeDenied))))
        let denied = try intent("command.denied", value: 2)
        #expect(sender.send(denied, try context())
            == .refused(.command(.rejected(.invalidValue(.outOfRange(2, lower: 0, upper: 1))))))
        #expect(sender.host.ledger.count == 0)
        #expect(sender.send(try intent("command.valid"), try context()) == .admitted)
    }

    @Test func ledgerRecordsOnceAndOnlyForItsConnection() throws {
        var ledger = try PeerCommandLedger(connectionEpoch: Fixture.session().connectionEpoch)
        let foreign = try intent(session: Fixture.session(connection: 2))
        #expect(throws: PeerCommandLedgerError.wrongConnection) {
            try ledger.reserve(foreign, permission: Fixture.permission)
        }
        let command = try intent()
        #expect(throws: PeerCommandLedgerError.unknownCommand(command.id)) {
            try ledger.complete(command.id, with: .refused(.rejected(.unsupportedOperation)))
        }
        try ledger.reserve(command, permission: Fixture.permission)
        #expect(throws: PeerCommandLedgerError.alreadyRecorded(command.id)) {
            try ledger.reserve(command, permission: Fixture.permission)
        }
        try ledger.complete(command.id, with: .applied(revisions: Fixture.revisions()))
        #expect(throws: PeerCommandLedgerError.alreadyCompleted(command.id)) {
            try ledger.complete(command.id, with: .applied(revisions: Fixture.revisions()))
        }
    }

    @Test func fullLedgerNeverEvictsOnReserve() throws {
        var ledger = try PeerCommandLedger(connectionEpoch: Fixture.session().connectionEpoch, capacity: 1)
        let kept = try intent("command.kept")
        try ledger.reserve(kept, permission: Fixture.permission)
        #expect(throws: PeerCommandLedgerError.full(capacity: 1)) {
            try ledger.reserve(try intent("command.extra"), permission: Fixture.permission)
        }
        #expect(ledger.entry(for: kept.id)?.intent == kept && ledger.count == 1)
    }

    @Test func ledgerCapacityIsPinned() throws {
        let epoch = Fixture.session().connectionEpoch
        #expect(PeerCommandLedger.standardCapacity == 1_024)
        #expect(try PeerCommandLedger(connectionEpoch: epoch).capacity == 1_024)
        #expect(try PeerCommandLedger(connectionEpoch: epoch, capacity: 16_384).capacity == 16_384)
        #expect(try PeerCommandLedger(connectionEpoch: epoch, capacity: 1).capacity == 1)
        for invalid in [0, 16_385] {
            #expect(throws: PeerCommandCapacityError.invalidCapacity(invalid)) {
                try PeerCommandLedger(connectionEpoch: epoch, capacity: invalid)
            }
            #expect(throws: PeerCommandCapacityError.invalidCapacity(invalid)) {
                try PeerCommandProcessor(session: Fixture.session(), ledgerCapacity: invalid)
            }
        }
    }

    @Test func aRefusedIDIsNotRememberedAndIsEvaluatedFreshLater() throws {
        var sender = Sender(host: processor(capacity: 1))
        let command = try intent()
        #expect(sender.send(command, try context(permission: other))
            == .refused(.command(.rejected(.permissionChanged))))
        #expect(sender.host.ledger.entry(for: command.id) == nil)
        #expect(sender.send(command, try context(revisions: Fixture.revisions(patch: 1)))
            == .refused(.command(.rejected(.revisionChanged))))
        #expect(sender.send(command, try context()) == .admitted)
        let blocked = try intent("command.blocked")
        #expect(sender.send(blocked, try context()) == .refused(.ledgerFull(capacity: 1)))
        try sender.host.complete(command.id, with: .applied(revisions: Fixture.revisions()))
        #expect(sender.send(blocked, try context()) == .refused(.ledgerFull(capacity: 1)))
        #expect(sender.host.ledger.entry(for: blocked.id) == nil)
        #expect(sender.send(command, try context()) == .replayed(.applied(revisions: Fixture.revisions())))
    }
}
