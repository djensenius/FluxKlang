import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum PeerSyncFixture {
    static let host = HostID(validated: "host.sync")
    static let connection = ConnectionID(validated: "connection.sync")
    static let gain = ParameterID(validated: "parameter.gain")
    static let mix = ParameterID(validated: "parameter.mix")
    static let width = ParameterID(validated: "parameter.width")
    static let permission = PermissionFingerprint(rawValue: "permissions.sync")

    static func generation(_ value: Int) -> Generation {
        do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
    }

    static func sequence(_ value: Int) -> PeerSequence {
        do { return try PeerSequence(value) } catch { preconditionFailure("invalid sequence \(value)") }
    }

    static func revision(_ value: Int) -> ContractRevision {
        do { return try ContractRevision(value) } catch { preconditionFailure("invalid revision \(value)") }
    }

    static func revisions(parameter: Int = 0, patch: Int = 0) -> CommandRevisions {
        CommandRevisions(patch: revision(patch), parameter: revision(parameter))
    }

    static func session(host hostGeneration: Int = 1, connection connectionGeneration: Int = 1) -> PeerSyncSession {
        let negotiated = PeerNegotiatedSession(
            protocolVersion: 1, hostEpoch: generation(hostGeneration),
            connectionEpoch: generation(connectionGeneration), capabilities: PeerCapabilitySet([])!
        )
        return PeerSyncSession(host: host, connection: connection, negotiated: negotiated)
    }

    static func value(_ value: Double) -> ParameterValue { ParameterValue(value: value, unit: .normalized) }

    static func limits(snapshot: Int, delta: Int) -> PeerSyncLimits {
        guard let limits = PeerSyncLimits(maximumSnapshotValues: snapshot, maximumDeltaChanges: delta) else {
            preconditionFailure("invalid limits")
        }
        return limits
    }
}

private typealias Fixture = PeerSyncFixture

private func publisher(_ session: PeerSyncSession = Fixture.session(),
                       limits: PeerSyncLimits = .standard) throws -> PeerSyncPublisher {
    try PeerSyncPublisher(session: session, revisions: Fixture.revisions(),
                          values: [Fixture.gain: Fixture.value(0.5)], limits: limits)
}

private func delta(_ sequence: Int, session: PeerSyncSession = Fixture.session(), parameter: Int,
                   updates: [ParameterID: ParameterValue] = [:], removals: Set<ParameterID> = []) -> PeerSyncDelta {
    PeerSyncDelta(session: session, sequence: Fixture.sequence(sequence),
                  revisions: Fixture.revisions(parameter: parameter), updates: updates, removals: removals)
}

private extension PeerSyncPublisher {
    mutating func step(_ parameter: Int, gain: Double) throws -> PeerSyncDelta {
        try publish(revisions: Fixture.revisions(parameter: parameter), updates: [Fixture.gain: Fixture.value(gain)])
    }
}

@Suite("PeerSyncTests", .productionAccessAudit)
struct PeerSyncTests {
    @Test func snapshotThenContiguousDeltasConverge() throws {
        var host = try publisher()
        var controller = PeerSyncReceiver(session: host.session)
        #expect(controller.receive(host.snapshot()) == .applied(.origin))
        let first = try host.publish(revisions: Fixture.revisions(parameter: 1),
                                     updates: [Fixture.mix: Fixture.value(0.2)])
        let second = try host.publish(revisions: Fixture.revisions(parameter: 2), removals: [Fixture.gain])
        #expect(controller.receive(first) == .applied(Fixture.sequence(1)))
        #expect(controller.receive(second) == .applied(Fixture.sequence(2)))
        #expect(controller.state == host.state)
        #expect(controller.state?.values == [Fixture.mix: Fixture.value(0.2)])
    }

    @Test func gapLatchesResyncAndLaterDeltasAreReportedNotApplied() throws {
        var host = try publisher()
        var controller = PeerSyncReceiver(session: host.session)
        _ = controller.receive(host.snapshot())
        let first = try host.step(1, gain: 0.1)
        let second = try host.step(2, gain: 0.2)
        let third = try host.step(3, gain: 0.3)
        #expect(controller.receive(first) == .applied(Fixture.sequence(1)))
        let request = PeerResyncRequest(session: host.session, lastApplied: Fixture.sequence(1),
                                        reason: .gap(expected: Fixture.sequence(2), found: Fixture.sequence(3)))
        #expect(controller.receive(third) == .resyncRequested(request))
        #expect(controller.phase == .resyncRequired(request))
        #expect(controller.state == nil)
        #expect(controller.receive(second) == .discardedAwaitingSnapshot(Fixture.sequence(2)))
        #expect(controller.phase == .resyncRequired(request))
        #expect(controller.receive(host.snapshot()) == .applied(Fixture.sequence(3)))
        #expect(controller.state == host.state)
    }

    @Test func repeatedDeltaRequestsResync() throws {
        var host = try publisher()
        var controller = PeerSyncReceiver(session: host.session)
        _ = controller.receive(host.snapshot())
        let first = try host.step(1, gain: 0.1)
        _ = controller.receive(first)
        #expect(controller.receive(first) == .resyncRequested(PeerResyncRequest(
            session: host.session, lastApplied: Fixture.sequence(1), reason: .repeated(Fixture.sequence(1)))))
    }

    @Test func deltasBeforeAnySnapshotAreDiscardedAndReported() {
        var controller = PeerSyncReceiver(session: Fixture.session())
        #expect(controller.receive(delta(1, parameter: 1, updates: [Fixture.gain: Fixture.value(0.1)]))
            == .discardedAwaitingSnapshot(Fixture.sequence(1)))
        #expect(controller.phase == .awaitingSnapshot)
    }

    @Test func staleEpochSnapshotsAndDeltasChangeNothing() throws {
        let current = Fixture.session(host: 2, connection: 3)
        var controller = PeerSyncReceiver(session: current)
        _ = controller.receive(try publisher(current).snapshot())
        let before = controller.phase
        let oldHost = Fixture.session(host: 1, connection: 3)
        let oldConnection = Fixture.session(host: 2, connection: 2)
        #expect(controller.receive(try publisher(oldHost).snapshot()) == .stale(.hostEpoch))
        #expect(controller.receive(try publisher(oldConnection).snapshot()) == .stale(.connectionEpoch))
        let absolute = [Fixture.gain: Fixture.value(1)]
        #expect(controller.receive(delta(1, session: oldConnection, parameter: 1, updates: absolute))
            == .stale(.connectionEpoch))
        #expect(controller.receive(delta(1, session: oldHost, parameter: 1, updates: absolute)) == .stale(.hostEpoch))
        #expect(controller.phase == before)
    }

    @Test func snapshotBehindTheMirrorIsRefused() throws {
        var host = try publisher()
        let early = host.snapshot()
        var controller = PeerSyncReceiver(session: host.session)
        _ = try host.step(1, gain: 0.1)
        _ = controller.receive(host.snapshot())
        #expect(controller.receive(early)
            == .refused(.snapshotBehind(current: Fixture.sequence(1), found: .origin)))
        let late = try host.step(3, gain: 0.3)
        _ = controller.receive(PeerSyncDelta(session: late.session, sequence: Fixture.sequence(3),
                                             revisions: late.revisions, updates: late.updates, removals: late.removals))
        #expect(controller.receive(early) == .resyncRequested(PeerResyncRequest(
            session: host.session, lastApplied: Fixture.sequence(1),
            reason: .snapshotRefused(.snapshotBehind(current: Fixture.sequence(3), found: .origin)))))
    }

    @Test func snapshotLoweringARevisionRelatchesASyncedReceiver() {
        var controller = PeerSyncReceiver(session: Fixture.session())
        #expect(controller.receive(snapshot(5, parameter: 5)) == .applied(Fixture.sequence(5)))
        let request = PeerResyncRequest(session: Fixture.session(), lastApplied: Fixture.sequence(5),
                                        reason: .snapshotRefused(.revisionRegressed))
        #expect(controller.receive(snapshot(6, parameter: 3, gain: 0.9)) == .resyncRequested(request))
        #expect(controller.phase == .resyncRequired(request))
        #expect(controller.state == nil)
        #expect(controller.revisionFloor == Fixture.revisions(parameter: 5))
        #expect(controller.highWaterMark == Fixture.sequence(5))
        #expect(controller.receive(snapshot(6, parameter: 3, gain: 0.9)) == .resyncRequested(request))
        #expect(controller.receive(snapshot(7, parameter: 5)) == .applied(Fixture.sequence(7)))
        #expect(controller.state?.values == [Fixture.gain: Fixture.value(0.5)])
        #expect(controller.state?.revisions == Fixture.revisions(parameter: 5))
    }

    @Test func revisionFloorSurvivesTheResyncLatch() {
        var controller = PeerSyncReceiver(session: Fixture.session())
        _ = controller.receive(snapshot(5, parameter: 5))
        let gap = PeerResyncRequest(session: Fixture.session(), lastApplied: Fixture.sequence(5),
                                    reason: .gap(expected: Fixture.sequence(6), found: Fixture.sequence(7)))
        #expect(controller.receive(delta(7, parameter: 7)) == .resyncRequested(gap))
        #expect(controller.revisionFloor == Fixture.revisions(parameter: 5))
        let refused = PeerResyncRequest(session: Fixture.session(), lastApplied: Fixture.sequence(5),
                                        reason: .snapshotRefused(.revisionRegressed))
        #expect(controller.receive(snapshot(8, parameter: 3)) == .resyncRequested(refused))
        #expect(controller.phase == .resyncRequired(refused))
        #expect(controller.state == nil)
        #expect(controller.receive(snapshot(8, parameter: 8)) == .applied(Fixture.sequence(8)))
    }

    @Test func revisionFloorFollowsAppliedDeltas() {
        var controller = PeerSyncReceiver(session: Fixture.session())
        _ = controller.receive(snapshot(0, parameter: 0))
        #expect(controller.receive(delta(1, parameter: 4)) == .applied(Fixture.sequence(1)))
        _ = controller.receive(delta(3, parameter: 5))
        let refused = PeerResyncRequest(session: Fixture.session(), lastApplied: Fixture.sequence(1),
                                        reason: .snapshotRefused(.revisionRegressed))
        #expect(controller.receive(snapshot(3, parameter: 2)) == .resyncRequested(refused))
        #expect(controller.state == nil)
    }

    @Test func staleRecoverySnapshotKeepsTheResyncLatch() throws {
        var host = try publisher()
        var controller = PeerSyncReceiver(session: host.session)
        #expect(controller.receive(host.snapshot()) == .applied(.origin))
        _ = try host.step(1, gain: 0.1)
        let second = try host.step(2, gain: 0.2)
        let stale = host.snapshot()
        let third = try host.step(3, gain: 0.3)
        let gap = PeerResyncRequest(session: host.session, lastApplied: .origin,
                                    reason: .gap(expected: Fixture.sequence(1), found: Fixture.sequence(2)))
        #expect(controller.receive(second) == .resyncRequested(gap))
        #expect(controller.receive(third) == .discardedAwaitingSnapshot(Fixture.sequence(3)))
        #expect(controller.highWaterMark == Fixture.sequence(3))
        let behind = PeerResyncRequest(session: host.session, lastApplied: .origin, reason: .snapshotRefused(
            .snapshotBehind(current: Fixture.sequence(3), found: Fixture.sequence(2))))
        #expect(controller.receive(stale) == .resyncRequested(behind))
        #expect(controller.phase == .resyncRequired(behind))
        #expect(controller.receive(host.snapshot()) == .applied(Fixture.sequence(3)))
        #expect(controller.state == host.state)
    }

    @Test func oversizeSnapshotsAndDeltasAreRefused() throws {
        let limits = Fixture.limits(snapshot: 2, delta: 1)
        let three = [Fixture.gain: Fixture.value(0), Fixture.mix: Fixture.value(0), Fixture.width: Fixture.value(0)]
        #expect(throws: PeerSyncError.snapshotTooLarge(count: 3, limit: 2)) {
            try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(), values: three,
                                  limits: limits)
        }
        var controller = PeerSyncReceiver(session: Fixture.session(), limits: limits)
        let big = PeerSyncSnapshot(session: Fixture.session(), sequence: .origin, revisions: Fixture.revisions(),
                                   values: three)
        #expect(controller.receive(big) == .refused(.snapshotTooLarge(count: 3, limit: 2)))
        #expect(controller.phase == .awaitingSnapshot)

        var host = try publisher(limits: limits)
        let two = [Fixture.mix: Fixture.value(0), Fixture.width: Fixture.value(0)]
        #expect(throws: PeerSyncError.deltaTooLarge(count: 2, limit: 1)) {
            try host.publish(revisions: Fixture.revisions(parameter: 1), updates: two)
        }
        #expect(host.state.sequence == .origin)
        _ = controller.receive(host.snapshot())
        #expect(controller.receive(delta(1, parameter: 1, updates: two)) == .resyncRequested(PeerResyncRequest(
            session: host.session, lastApplied: .origin, reason: .unappliable(.deltaTooLarge(count: 2, limit: 1)))))
    }

    @Test(arguments: [
        (delta(1, parameter: 1, updates: [PeerSyncFixture.gain: PeerSyncFixture.value(0)],
               removals: [PeerSyncFixture.gain]), PeerSyncError.overlappingChanges(PeerSyncFixture.gain)),
        (delta(1, parameter: 1, removals: [PeerSyncFixture.mix]), .removedUnknownValue(PeerSyncFixture.mix)),
        (delta(1, parameter: 0), .emptyDelta),
        (PeerSyncDelta(session: PeerSyncFixture.session(), sequence: PeerSyncFixture.sequence(1),
                       revisions: CommandRevisions(), updates: [PeerSyncFixture.gain: PeerSyncFixture.value(0)],
                       removals: []), .revisionRegressed)
    ])
    func unappliableDeltaRequestsResync(candidate: PeerSyncDelta, error: PeerSyncError) throws {
        var host = try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(patch: 1),
                                         values: [Fixture.gain: Fixture.value(0.5)])
        var controller = PeerSyncReceiver(session: host.session)
        _ = controller.receive(host.snapshot())
        let adjusted = PeerSyncDelta(
            session: candidate.session, sequence: candidate.sequence,
            revisions: error == .revisionRegressed ? candidate.revisions
                : CommandRevisions(patch: Fixture.revision(1), parameter: candidate.revisions.parameter),
            updates: candidate.updates, removals: candidate.removals)
        #expect(controller.receive(adjusted) == .resyncRequested(PeerResyncRequest(
            session: host.session, lastApplied: .origin, reason: .unappliable(error))))
        #expect(throws: error) {
            try host.publish(revisions: adjusted.revisions, updates: adjusted.updates, removals: adjusted.removals)
        }
    }

    @Test func sequencesAreBoundedAndNeverWrap() {
        #expect(throws: PeerSequenceError.outOfRange(-1)) { try PeerSequence(-1) }
        #expect(throws: PeerSequenceError.outOfRange(PeerSequence.maximumValue + 1)) {
            try PeerSequence(PeerSequence.maximumValue + 1)
        }
        let last = Fixture.sequence(PeerSequence.maximumValue)
        #expect(throws: PeerSequenceError.exhausted) { try last.next() }
        var controller = PeerSyncReceiver(session: Fixture.session())
        _ = controller.receive(PeerSyncSnapshot(session: Fixture.session(), sequence: last,
                                                revisions: Fixture.revisions(), values: [:]))
        #expect(controller.receive(delta(1, parameter: 1)) == .resyncRequested(PeerResyncRequest(
            session: Fixture.session(), lastApplied: last, reason: .unappliable(.sequenceExhausted))))
    }

    @Test func sessionsBindNegotiatedEpochsToHostIdentities() {
        let session = Fixture.session(host: 4, connection: 9)
        #expect(session.hostEpoch == HostEpoch(host: Fixture.host, generation: Fixture.generation(4)))
        #expect(session.connectionEpoch == ConnectionEpoch(connection: Fixture.connection, host: Fixture.host,
                                                           generation: Fixture.generation(9)))
        let foreign = ConnectionEpoch(connection: Fixture.connection, host: HostID(validated: "host.other"),
                                      generation: .initial)
        #expect(PeerSyncSession(hostEpoch: session.hostEpoch, connectionEpoch: foreign) == nil)
        #expect(PeerSyncSession(hostEpoch: session.hostEpoch, connectionEpoch: session.connectionEpoch) == session)
        #expect(PeerSyncLimits(maximumSnapshotValues: 0, maximumDeltaChanges: 1) == nil)
        #expect(PeerSyncLimits(maximumSnapshotValues: 1, maximumDeltaChanges: 4_097) == nil)
    }

    @Test func standardSnapshotLimitIsPinnedAt4096() {
        #expect(PeerSyncLimits.standard.maximumSnapshotValues == 4_096)
        var controller = PeerSyncReceiver(session: Fixture.session())
        #expect(controller.receive(snapshot(values: 4_097))
            == .refused(.snapshotTooLarge(count: 4_097, limit: 4_096)))
        #expect(controller.receive(snapshot(values: 4_096)) == .applied(.origin))
        #expect(throws: PeerSyncError.snapshotTooLarge(count: 4_097, limit: 4_096)) {
            try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(), values: values(4_097))
        }
    }

    @Test func standardDeltaLimitIsPinnedAt256() throws {
        #expect(PeerSyncLimits.standard.maximumDeltaChanges == 256)
        var host = try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(), values: [:])
        #expect(throws: PeerSyncError.deltaTooLarge(count: 257, limit: 256)) {
            try host.publish(revisions: Fixture.revisions(parameter: 1), updates: values(257))
        }
        var controller = PeerSyncReceiver(session: Fixture.session())
        _ = controller.receive(host.snapshot())
        let exact = try host.publish(revisions: Fixture.revisions(parameter: 1), updates: values(256))
        #expect(controller.receive(exact) == .applied(Fixture.sequence(1)))
        #expect(controller.receive(delta(2, parameter: 2, updates: values(257))) == .resyncRequested(PeerResyncRequest(
            session: host.session, lastApplied: Fixture.sequence(1),
            reason: .unappliable(.deltaTooLarge(count: 257, limit: 256)))))
    }

    @Test func deltasCannotGrowTheStatePastTheSnapshotLimit() throws {
        let extra = [ParameterID(validated: "parameter.extra"): Fixture.value(0)]
        var full = PeerSyncReceiver(session: Fixture.session())
        _ = full.receive(snapshot(values: 4_096))
        #expect(full.receive(delta(1, parameter: 1, updates: extra)) == .resyncRequested(PeerResyncRequest(
            session: Fixture.session(), lastApplied: .origin,
            reason: .unappliable(.snapshotTooLarge(count: 4_097, limit: 4_096)))))
        var host = try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(),
                                         values: values(4_096))
        #expect(throws: PeerSyncError.snapshotTooLarge(count: 4_097, limit: 4_096)) {
            try host.publish(revisions: Fixture.revisions(parameter: 1), updates: extra)
        }
        var room = PeerSyncReceiver(session: Fixture.session())
        _ = room.receive(snapshot(values: 4_095))
        #expect(room.receive(delta(1, parameter: 1, updates: extra)) == .applied(Fixture.sequence(1)))
        #expect(room.state?.values.count == 4_096)
    }

    @Test func multipleOffendingIDsReportTheSmallest() throws {
        let names = ["parameter.zeta", "parameter.alpha", "parameter.mu", "parameter.beta", "parameter.omega",
                     "parameter.delta", "parameter.kappa", "parameter.gamma", "parameter.theta", "parameter.epsilon"]
        let ids = try names.map { try ParameterID($0) }
        for count in 2...ids.count {
            let chosen = Array(ids.prefix(count))
            let smallest = try #require(chosen.min())
            let overlapping = PeerSyncDelta(
                session: Fixture.session(), sequence: Fixture.sequence(1), revisions: Fixture.revisions(parameter: 1),
                updates: Dictionary(uniqueKeysWithValues: chosen.map { ($0, Fixture.value(0)) }), removals: Set(chosen))
            #expect(throws: PeerSyncError.overlappingChanges(smallest)) { try overlapping.validate(.standard) }
            var host = try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(), values: [:])
            #expect(throws: PeerSyncError.removedUnknownValue(smallest)) {
                try host.publish(revisions: Fixture.revisions(parameter: 1), removals: Set(chosen))
            }
        }
    }
}

extension PeerSyncTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteValuesAreRefusedInSnapshotsAndDeltas(bad: Double) throws {
        let values = [Fixture.gain: Fixture.value(0.5), Fixture.mix: Fixture.value(bad)]
        let candidate = PeerSyncSnapshot(session: Fixture.session(), sequence: .origin,
                                         revisions: Fixture.revisions(), values: values)
        #expect(throws: PeerSyncError.nonFiniteValue(Fixture.mix)) { try candidate.validate(.standard) }
        #expect(throws: PeerSyncError.nonFiniteValue(Fixture.mix)) {
            try PeerSyncPublisher(session: Fixture.session(), revisions: Fixture.revisions(), values: values)
        }
        var controller = PeerSyncReceiver(session: Fixture.session())
        #expect(controller.receive(candidate) == .refused(.nonFiniteValue(Fixture.mix)))
        #expect(controller.phase == .awaitingSnapshot)
        #expect(throws: PeerSyncError.nonFiniteValue(Fixture.mix)) {
            try delta(1, parameter: 1, updates: values).validate(.standard)
        }
        var host = try publisher()
        let before = host.state
        #expect(throws: PeerSyncError.nonFiniteValue(Fixture.mix)) {
            try host.publish(revisions: Fixture.revisions(parameter: 1), updates: values)
        }
        #expect(host.state == before)
        #expect(host.snapshot() == PeerSyncSnapshot(session: Fixture.session(), sequence: .origin,
                                                    revisions: Fixture.revisions(),
                                                    values: [Fixture.gain: Fixture.value(0.5)]))
    }

    @Test func multipleNonFiniteIDsReportTheSmallest() throws {
        let names = ["parameter.zeta", "parameter.alpha", "parameter.mu", "parameter.beta", "parameter.omega",
                     "parameter.delta", "parameter.kappa", "parameter.gamma", "parameter.theta", "parameter.epsilon"]
        let ids = try names.map { try ParameterID($0) }
        for count in 2...ids.count {
            let chosen = Array(ids.prefix(count))
            let smallest = try #require(chosen.min())
            let bad = Dictionary(uniqueKeysWithValues: chosen.map { ($0, Fixture.value(.nan)) })
            let candidate = PeerSyncSnapshot(session: Fixture.session(), sequence: .origin,
                                             revisions: Fixture.revisions(), values: bad)
            #expect(throws: PeerSyncError.nonFiniteValue(smallest)) { try candidate.validate(.standard) }
            #expect(throws: PeerSyncError.nonFiniteValue(smallest)) {
                try delta(1, parameter: 1, updates: bad).validate(.standard)
            }
        }
    }

    @Test func nonFiniteDeltaLatchesResyncUntilACoveringSnapshot() throws {
        var host = try publisher()
        var controller = PeerSyncReceiver(session: host.session)
        _ = controller.receive(host.snapshot())
        let before = controller.revisionFloor
        let request = PeerResyncRequest(session: host.session, lastApplied: .origin,
                                        reason: .unappliable(.nonFiniteValue(Fixture.gain)))
        let poisoned = delta(1, parameter: 1, updates: [Fixture.gain: Fixture.value(.infinity)])
        #expect(controller.receive(poisoned) == .resyncRequested(request))
        #expect(controller.phase == .resyncRequired(request))
        #expect(controller.revisionFloor == before)
        #expect(controller.highWaterMark == Fixture.sequence(1))
        _ = try host.step(1, gain: 0.25)
        #expect(controller.receive(host.snapshot()) == .applied(Fixture.sequence(1)))
        #expect(controller.state == host.state)
    }
}

private func values(_ count: Int) -> [ParameterID: ParameterValue] {
    Dictionary(uniqueKeysWithValues: (0..<count).map { index in
        (ParameterID(rawValue: "parameter.bulk\(index)") ?? Fixture.gain, Fixture.value(0))
    })
}

private func snapshot(values count: Int) -> PeerSyncSnapshot {
    PeerSyncSnapshot(session: Fixture.session(), sequence: .origin, revisions: Fixture.revisions(),
                     values: values(count))
}

private func snapshot(_ sequence: Int, parameter: Int, gain: Double = 0.5) -> PeerSyncSnapshot {
    PeerSyncSnapshot(session: Fixture.session(), sequence: Fixture.sequence(sequence),
                     revisions: Fixture.revisions(parameter: parameter), values: [Fixture.gain: Fixture.value(gain)])
}
