import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Retry classes and held-intent revalidation (#97, slice RT1). The suite is split over
/// `PeerRetryClassTests+Classes`, `+Revalidate` and `+Order`; every fixture lives in `Fixture` and `Call`.
struct PeerRetryClassTests {
    enum Outcome: Equatable {
        case report(PeerRevalidationReport)
        case refused(PeerRevalidationRefusal)
    }

    /// A complete, valid call (a synced receiver, its own latch, the same session, no held intents); a test
    /// changes exactly the fields whose defect it studies.
    struct Call {
        var held: [CommandIntent] = []
        var awaiting: [CommandID] = []
        var reconnect: PeerReconnectState
        var receiver: PeerSyncReceiver
        var stamped: PeerLatched<PeerSyncReceiver>
        var expecting: PeerResyncLatch
        var session: PeerSyncSession
        var limits: PeerRevalidationLimits = .standard

        init(session: PeerSyncSession = Fixture.session(), receiver: PeerSyncReceiver? = nil) {
            let reconnect = Fixture.reconnect(session)
            let receiver = receiver ?? Fixture.receiver(session)
            self.reconnect = reconnect
            self.receiver = receiver
            stamped = reconnect.stamp(receiver)
            expecting = reconnect.latch
            self.session = session
        }

        mutating func use(_ next: PeerSyncReceiver) {
            receiver = next
            stamped = reconnect.stamp(next)
        }

        func run() throws(PeerRevalidationRefusal) -> PeerRevalidationReport {
            try PeerIntentRevalidator.revalidate(held: held, awaitingResultIDs: awaiting, latched: stamped,
                                                 expecting: expecting, session: session, limits: limits)
        }

        func run<Held: Collection>(core: Held) throws(PeerRevalidationRefusal) -> PeerRevalidationReport
            where Held.Element == PeerHeldIntent {
            try PeerIntentRevalidator.revalidate(heldIntents: core, awaitingResultIDs: awaiting, latched: stamped,
                                                 expecting: expecting, session: session, limits: limits)
        }

        func outcome() -> Outcome {
            do { return .report(try run()) } catch { return .refused(error) }
        }

        func outcome<Held: Collection>(core: Held) -> Outcome where Held.Element == PeerHeldIntent {
            do { return .report(try run(core: core)) } catch { return .refused(error) }
        }

        func reduced() -> [PeerHeldIntent] { held.map(PeerHeldIntent.init) }
    }

    enum Fixture {
        static let host = HostID(validated: "host.retry")
        static let otherHost = HostID(validated: "host.other")
        static let connection = ConnectionID(validated: "connection.live")
        static let droppedConnection = ConnectionID(validated: "connection.dropped")
        static let gain = ParameterID(validated: "parameter.gain")
        static let pan = ParameterID(validated: "parameter.pan")
        static let missing = ParameterID(validated: "parameter.missing")
        static let permission = PermissionFingerprint(rawValue: "permissions.retry")
        /// Every axis of the receiver's state; held revisions differ from it by +1 or -1 on one axis.
        static let current = revisions(3, 3, 3, 3, 3)

        static func generation(_ value: Int) -> Generation {
            do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
        }

        static func sequence(_ value: Int) -> PeerSequence {
            do { return try PeerSequence(value) } catch { preconditionFailure("invalid sequence \(value)") }
        }

        static func revision(_ value: Int) -> ContractRevision {
            do { return try ContractRevision(value) } catch { preconditionFailure("invalid revision \(value)") }
        }

        static func revisions(_ patch: Int, _ capability: Int, _ permission: Int, _ parameter: Int,
                              _ graph: Int) -> CommandRevisions {
            CommandRevisions(patch: revision(patch), capability: revision(capability),
                             permission: revision(permission), parameter: revision(parameter),
                             graph: revision(graph))
        }

        /// `current` with one axis moved by `delta`.
        static func moved(_ axis: PeerRevisionAxis, by delta: Int) -> CommandRevisions {
            var moved = current
            switch axis {
            case .patch: moved.patch = revision(3 + delta)
            case .capability: moved.capability = revision(3 + delta)
            case .permission: moved.permission = revision(3 + delta)
            case .parameter: moved.parameter = revision(3 + delta)
            case .graph: moved.graph = revision(3 + delta)
            }
            return moved
        }

        static func session(host hostGeneration: Int = 1, connection connectionGeneration: Int = 1,
                            hostID: HostID = host, connectionID: ConnectionID = connection) -> PeerSyncSession {
            let hostEpoch = HostEpoch(host: hostID, generation: generation(hostGeneration))
            let connectionEpoch = ConnectionEpoch(connection: connectionID, host: hostID,
                                                  generation: generation(connectionGeneration))
            guard let session = PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: connectionEpoch) else {
                preconditionFailure("invalid session")
            }
            return session
        }

        static func id(_ raw: String) -> CommandID {
            guard let id = CommandID(rawValue: raw) else { preconditionFailure("invalid command ID \(raw)") }
            return id
        }

        static func ids(_ prefix: String, count: Int) -> [CommandID] { (0..<count).map { id("\(prefix).\($0)") } }

        static func value(_ raw: Double) -> ParameterValue { ParameterValue(value: raw, unit: .normalized) }

        static func set(_ raw: Double = 0.5, _ parameter: ParameterID = gain) -> CommandOperation {
            .set(parameter, value(raw))
        }

        static func ramp(_ raw: Double = 0.5, _ parameter: ParameterID = gain) -> CommandOperation {
            .ramp(parameter, value(raw), milliseconds: 250)
        }

        static let routeID = RouteID(validated: "route.main")
        static let patchID = PatchID(validated: "patch.main")
        static let actionID = ActionID(validated: "action.main")
        static let draftID = DraftID(validated: "draft.main")

        static func intent(_ raw: String, _ operation: CommandOperation = set(), session: PeerSyncSession = session(),
                           revisions: CommandRevisions = current, withoutConnection: Bool = false) -> CommandIntent {
            do {
                return try CommandIntent(.init(
                    id: id(raw), commandClass: .live, origin: .controller, hostEpoch: session.hostEpoch,
                    connectionEpoch: withoutConnection ? nil : session.connectionEpoch, revisions: revisions,
                    operation: operation, permission: permission
                ))
            } catch { preconditionFailure("invalid intent \(raw): \(error)") }
        }

        static func held(_ raw: String, _ operation: CommandOperation = set(), session: PeerSyncSession = session(),
                         revisions: CommandRevisions = current) -> PeerHeldIntent {
            PeerHeldIntent(id: id(raw), operation: operation, revisions: revisions,
                           hostEpoch: session.hostEpoch, connectionEpoch: session.connectionEpoch)
        }

        static func values() -> [ParameterID: ParameterValue] { [gain: value(0.5), pan: value(0.0)] }

        static func snapshot(_ session: PeerSyncSession, sequence: Int = 0,
                             revisions: CommandRevisions = current) -> PeerSyncSnapshot {
            PeerSyncSnapshot(session: session, sequence: self.sequence(sequence), revisions: revisions,
                             values: values())
        }

        static func delta(_ session: PeerSyncSession, sequence: Int) -> PeerSyncDelta {
            PeerSyncDelta(session: session, sequence: self.sequence(sequence), revisions: current,
                          updates: [gain: value(0.25)], removals: [])
        }

        static func receiver(_ session: PeerSyncSession = session(), revisions: CommandRevisions = current,
                             values: [ParameterID: ParameterValue]? = nil) -> PeerSyncReceiver {
            var receiver = PeerSyncReceiver(session: session)
            let snapshot = PeerSyncSnapshot(session: session, sequence: .origin, revisions: revisions,
                                            values: values ?? self.values())
            _ = receiver.receive(snapshot)
            return receiver
        }

        static func reconnect(_ session: PeerSyncSession, latchGeneration: Int = 1) -> PeerReconnectState {
            do { return try PeerReconnectState(session: session, latchGeneration: generation(latchGeneration)) } catch {
                preconditionFailure("invalid reconnect state: \(error)")
            }
        }

        static func queue(_ session: PeerSyncSession, capacity: Int = 256) -> PeerOutboundQueue {
            do { return try PeerOutboundQueue(session: session, capacity: capacity) } catch {
                preconditionFailure("invalid queue: \(error)")
            }
        }

        static func limits(_ maximumListed: Int) -> PeerRevalidationLimits {
            do { return try PeerRevalidationLimits.make(maximumListed: maximumListed) } catch {
                preconditionFailure("invalid limits \(maximumListed)")
            }
        }

        /// A receiver that has no state: it awaits its first snapshot.
        static func unsynced(_ session: PeerSyncSession = session()) -> PeerSyncReceiver {
            PeerSyncReceiver(session: session)
        }

        /// A receiver that lost a delta: it needs a resync (its phase carries the request).
        static func resyncing(_ session: PeerSyncSession = session()) -> PeerSyncReceiver {
            var receiver = receiver(session)
            _ = receiver.receive(delta(session, sequence: 5))
            return receiver
        }

        /// Every operation with its exact class, in the declaration order of `CommandOperation`.
        static func everyOperation() -> [(operation: CommandOperation, retryClass: PeerRetryClass)] {
            [(set(), .freshIntentOnly), (ramp(), .freshIntentOnly), (.bind(routeID), .never),
             (.recall(patchID), .never), (.trigger(actionID), .never), (.start, .never), (.stop, .never),
             (.locate(ticks: 480), .never), (.panic, .never), (.safeMute, .never), (.propose(draftID), .never),
             (.editDraft(draftID), .never)]
        }

        static func neverOperations() -> [CommandOperation] {
            everyOperation().filter { $0.retryClass == .never }.map(\.operation)
        }
    }

    @Test func theFixtureBuildsASyncedReceiverAtTheCurrentRevisions() throws {
        let call = Call()
        let state = try #require(call.receiver.state)
        #expect(state.revisions == Fixture.current)
        #expect(state.values == Fixture.values())
        #expect(call.receiver.session == call.session)
        #expect(call.stamped.latch == call.expecting)
        #expect(call.outcome() == .report(PeerRevalidationReport(retryable: [], discarded: [], unknownOutcome: [],
                                                                 limits: .standard)))
    }
}
