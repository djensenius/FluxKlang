import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixtures of the #97 R3 backpressure tests (lane-prefixed so the test module has one definition).
enum PeerBackpressureFixture {
    static let host = HostID(validated: "host.backpressure")
    static let connection = ConnectionID(validated: "connection.backpressure")

    static func generation(_ value: Int) throws -> Generation { try Generation(value) }

    static func sequence(_ value: Int) throws -> PeerSequence { try PeerSequence(value) }

    static func session(host hostGeneration: Int = 1,
                        connection connectionGeneration: Int = 1) throws -> PeerSyncSession {
        let negotiated = PeerNegotiatedSession(
            protocolVersion: 1, hostEpoch: try generation(hostGeneration),
            connectionEpoch: try generation(connectionGeneration), capabilities: .empty
        )
        return PeerSyncSession(host: host, connection: connection, negotiated: negotiated)
    }

    /// A delta with `updates` updated and `removals` removed parameters; `changeCount` is their sum.
    static func delta(_ sequenceValue: Int, updates: Int = 1, removals: Int = 0,
                      session: PeerSyncSession? = nil) throws -> PeerSyncDelta {
        var updated: [ParameterID: ParameterValue] = [:]
        for index in 0..<updates {
            updated[try ParameterID("parameter.u\(index)")] = ParameterValue(value: 0.5, unit: .normalized)
        }
        var removed: Set<ParameterID> = []
        for index in 0..<removals { removed.insert(try ParameterID("parameter.r\(index)")) }
        return PeerSyncDelta(
            session: try session ?? self.session(), sequence: try sequence(sequenceValue),
            revisions: CommandRevisions(patch: try ContractRevision(0), parameter: try ContractRevision(sequenceValue)),
            updates: updated, removals: removed
        )
    }

    static func budget(commands: Int = 3, ticks: UInt64 = 100, inFlight: Int = 8,
                       first: UInt64 = 1, session: PeerSyncSession? = nil) throws -> PeerInboundBudget {
        try PeerInboundBudget.make(session: try session ?? self.session(), commandsPerWindow: commands,
                                   windowTicks: ticks, maxInFlight: inFlight, firstTicketID: first)
    }

    static func backlog(from snapshot: Int = 0, deltas: Int = 4, changes: Int = 20,
                        session: PeerSyncSession? = nil) throws -> PeerOutboundBacklog {
        try PeerOutboundBacklog.make(session: try session ?? self.session(), snapshotSequence: try sequence(snapshot),
                                     maxPendingDeltas: deltas, maxPendingChanges: changes)
    }

    /// The refusal `body` throws, nil when it does not throw.
    static func refusal<T>(_ body: () throws(PeerBackpressureRefusal) -> T) -> PeerBackpressureRefusal? {
        do { _ = try body() } catch { return error }
        return nil
    }
}

private typealias Fixture = PeerBackpressureFixture
private typealias Refusal = PeerBackpressureRefusal

@Suite("PeerBackpressureTests")
struct PeerBackpressureTests {
    // MARK: Inbound budget limits

    @Test func inboundFactoryAcceptsLowestLimits() throws {
        let budget = try PeerInboundBudget.make(session: try Fixture.session(), commandsPerWindow: 1, windowTicks: 1,
                                                maxInFlight: 1)
        #expect(budget.commandsPerWindow == 1)
        #expect(budget.windowTicks == 1)
        #expect(budget.maxInFlight == 1)
        #expect(budget.lastTick == nil)
        #expect(budget.windowStart == nil)
        #expect(budget.admittedInWindow == 0)
        #expect(budget.inFlightCount == 0)
    }

    @Test func inboundFactoryAcceptsHighestLimits() throws {
        let budget = try PeerInboundBudget.make(session: try Fixture.session(), commandsPerWindow: 4_096,
                                                windowTicks: 4_294_967_296, maxInFlight: 1_024)
        #expect(budget.commandsPerWindow == 4_096)
        #expect(budget.windowTicks == 4_294_967_296)
        #expect(budget.maxInFlight == 1_024)
    }

    @Test func inboundFactoryRefusesCommandsPerWindowOutsideOneTo4096() throws {
        let session = try Fixture.session()
        for bad in [0, -1, 4_097, Int.max] {
            let result = Fixture.refusal { () throws(Refusal) -> PeerInboundBudget in
                try PeerInboundBudget.make(session: session, commandsPerWindow: bad, windowTicks: 100, maxInFlight: 8)
            }
            #expect(result == .invalidLimit(.commandsPerWindow), "commandsPerWindow \(bad)")
        }
    }

    @Test func inboundFactoryRefusesWindowTicksOutsideOneToTwoPower32() throws {
        let session = try Fixture.session()
        for bad: UInt64 in [0, 4_294_967_297, UInt64.max] {
            let result = Fixture.refusal { () throws(Refusal) -> PeerInboundBudget in
                try PeerInboundBudget.make(session: session, commandsPerWindow: 3, windowTicks: bad, maxInFlight: 8)
            }
            #expect(result == .invalidLimit(.windowTicks), "windowTicks \(bad)")
        }
    }

    @Test func inboundFactoryRefusesMaxInFlightOutsideOneTo1024() throws {
        let session = try Fixture.session()
        for bad in [0, -1, 1_025, Int.max] {
            let result = Fixture.refusal { () throws(Refusal) -> PeerInboundBudget in
                try PeerInboundBudget.make(session: session, commandsPerWindow: 3, windowTicks: 100, maxInFlight: bad)
            }
            #expect(result == .invalidLimit(.maxInFlight), "maxInFlight \(bad)")
        }
    }

    @Test func inboundFactoryNamesTheFirstBadLimitInParameterOrder() throws {
        let session = try Fixture.session()
        let commandsFirst = Fixture.refusal { () throws(Refusal) -> PeerInboundBudget in
            try PeerInboundBudget.make(session: session, commandsPerWindow: 0, windowTicks: 0, maxInFlight: 0)
        }
        #expect(commandsFirst == .invalidLimit(.commandsPerWindow))
        let ticksBeforeInFlight = Fixture.refusal { () throws(Refusal) -> PeerInboundBudget in
            try PeerInboundBudget.make(session: session, commandsPerWindow: 3, windowTicks: 0, maxInFlight: 0)
        }
        #expect(ticksBeforeInFlight == .invalidLimit(.windowTicks))
    }

    // MARK: Outbound backlog limits

    @Test func backlogFactoryAcceptsLowestLimits() throws {
        let backlog = try Fixture.backlog(from: 7, deltas: 1, changes: 1)
        #expect(backlog.maxPendingDeltas == 1)
        #expect(backlog.maxPendingChanges == 1)
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(7)))
        #expect(backlog.recordedThrough == (try Fixture.sequence(7)))
        #expect(backlog.pendingDeltas == 0)
        #expect(backlog.pendingChanges == 0)
        #expect(!backlog.requiresSnapshot)
    }

    @Test func backlogFactoryAcceptsHighestLimits() throws {
        let backlog = try Fixture.backlog(deltas: 4_096, changes: 65_536)
        #expect(backlog.maxPendingDeltas == 4_096)
        #expect(backlog.maxPendingChanges == 65_536)
    }

    @Test func backlogFactoryRefusesMaxPendingDeltasOutsideOneTo4096() throws {
        let session = try Fixture.session()
        for bad in [0, -1, 4_097, Int.max] {
            let result = Fixture.refusal { () throws(Refusal) -> PeerOutboundBacklog in
                try PeerOutboundBacklog.make(session: session, snapshotSequence: .origin, maxPendingDeltas: bad,
                                             maxPendingChanges: 10)
            }
            #expect(result == .invalidLimit(.maxPendingDeltas), "maxPendingDeltas \(bad)")
        }
    }

    @Test func backlogFactoryRefusesMaxPendingChangesOutsideOneTo65536() throws {
        let session = try Fixture.session()
        for bad in [0, -1, 65_537, Int.max] {
            let result = Fixture.refusal { () throws(Refusal) -> PeerOutboundBacklog in
                try PeerOutboundBacklog.make(session: session, snapshotSequence: .origin, maxPendingDeltas: 4,
                                             maxPendingChanges: bad)
            }
            #expect(result == .invalidLimit(.maxPendingChanges), "maxPendingChanges \(bad)")
        }
    }

    @Test func backlogFactoryNamesTheDeltaLimitBeforeTheChangeLimit() throws {
        let session = try Fixture.session()
        let result = Fixture.refusal { () throws(Refusal) -> PeerOutboundBacklog in
            try PeerOutboundBacklog.make(session: session, snapshotSequence: .origin, maxPendingDeltas: 0,
                                         maxPendingChanges: 0)
        }
        #expect(result == .invalidLimit(.maxPendingDeltas))
    }

    // MARK: Telemetry window limits

    @Test func telemetryFactoryAcceptsCapacityOneAndThe1024Maximum() throws {
        #expect(try PeerTelemetryWindow.make(capacity: 1).capacity == 1)
        let widest = try PeerTelemetryWindow.make(capacity: 1_024)
        #expect(widest.capacity == 1_024)
        #expect(widest.count == 0)
        #expect(widest.droppedSamples == 0)
    }

    @Test func telemetryFactoryRefusesCapacityOutsideOneTo1024() {
        for bad in [0, -1, 1_025, Int.max] {
            let result = Fixture.refusal { () throws(Refusal) -> PeerTelemetryWindow in
                try PeerTelemetryWindow.make(capacity: bad)
            }
            #expect(result == .invalidLimit(.capacity), "capacity \(bad)")
        }
    }
}
