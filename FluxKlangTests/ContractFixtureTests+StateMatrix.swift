import Testing
@testable import FluxKlang

private let action = ContractFixtureIDs.action
private let required = CapabilitySnapshotFixture.requiredCapability
private let advisory = CapabilitySnapshotFixture.advisoryCapability
private let graphNode = NodeID(validated: "fx.node.matrix")
private let sourceKey = ReadinessFixture.sourceKey
private let transportKey = GenerationKey(.transport, ContractFixtureIDs.musicalClock)
/// One of the `preparing` fillers of `ReadinessFixture.make(.pressured)`.
private let bystander = ActionID(validated: "fx.pressure.1")

/// What the F2 capability snapshot and admission fixtures mean in one state.
private struct CapabilityRow {
    let presence: DevicePresence
    let advertised: Int
    let missingRequired: Set<CapabilityID>
    let missingAdvisory: Set<CapabilityID>
    /// How many host epochs the observed document lags the live host.
    let epochLag: Int
    /// The refusal of `validateForPreparation`, or nil when the graph prepares.
    let preparation: GraphValidationError?
    /// Admission never reads capabilities: only the stale epoch is refused, for every class.
    let admission: AdmissionDecision
}

/// What the F3 readiness fixture leaves for `fx.action` in one state.
private struct ReadinessRow {
    let state: ReadinessState
    let reason: ReadinessReason?
    let isCurrent: Bool
    let storeCount: Int
    /// Whether the store refuses any new action with `capacity`.
    let refusesNewAction: Bool
}

/// An F4 script, delivered from a fresh source to `ReadinessFixture.make(start)`.
private struct EventRow {
    let start: ContractFixtureState
    let script: [ContractFixtureEvent]
    let capacity: Int
    /// An existing action made ready before delivery against every counter except the source, so the
    /// script must leave it ready.
    let bystander: ActionID?
    /// A fault injected before delivery that the source must refuse without changing.
    let refusedFault: (fault: EventFault, error: ScriptedEventSourceError)?
    /// What each delivered event invalidated, or why the applier refused it.
    let results: [Result<[ActionID], FixtureEventError>]
    let endState: ReadinessState
    let endReason: ReadinessReason?
    /// The `make` state the result must equal, snapshot for snapshot, if any.
    let endsAs: ContractFixtureState?
}

/// One row per state. The switch is exhaustive, so a new state cannot compile without a row.
private struct StateExpectation {
    let capability: CapabilityRow
    let readiness: ReadinessRow
    let events: EventRow
    /// F5's `PressureFixture` models contract limits only, so it has a counterpart in
    /// `pressured` alone; every other state asserts instead that a new action is admitted.
    let atCapacity: Bool

    static func row(_ state: ContractFixtureState) -> Self {
        let unsupported = GraphValidationError.unsupportedRequiredCapability(node: graphNode, required)
        let lost = ContractFixtureEvent.bump(sourceKey, .sourceLost)
        switch state {
        case .available:
            // An unrelated transport bump leaves the action ready and current.
            return Self(
                capability: CapabilityRow(presence: .present, advertised: 2, missingRequired: [], missingAdvisory: [],
                                          epochLag: 0, preparation: nil, admission: .admitted),
                readiness: ReadinessRow(state: .ready, reason: nil, isCurrent: true, storeCount: 1,
                                        refusesNewAction: false),
                events: EventRow(start: .available, script: [.bump(transportKey, .transportRestart)], capacity: 4,
                                 bystander: nil, refusedFault: nil, results: [.success([])], endState: .ready,
                                 endReason: nil, endsAs: nil),
                atCapacity: false
            )
        case .missing:
            // Nothing was prepared, so losing the source invalidates nothing. Admitted: admission never reads
            // capabilities; the gating is asserted through `assess` and `validateForPreparation` instead.
            return Self(
                capability: CapabilityRow(presence: .missing, advertised: 2, missingRequired: [required],
                                          missingAdvisory: [advisory], epochLag: 0, preparation: unsupported,
                                          admission: .admitted),
                readiness: ReadinessRow(state: .unprepared, reason: nil, isCurrent: false, storeCount: 0,
                                        refusesNewAction: false),
                events: EventRow(start: .missing, script: [lost], capacity: 4, bystander: nil, refusedFault: nil,
                                 results: [.success([])], endState: .unprepared, endReason: nil, endsAs: nil),
                atCapacity: false
            )
        case .stale:
            // Delivering the source loss to an available fixture reproduces `make(.stale)` exactly.
            return Self(
                capability: CapabilityRow(presence: .stale, advertised: 2, missingRequired: [required],
                                          missingAdvisory: [advisory], epochLag: 1, preparation: unsupported,
                                          admission: .refused(.stale(.hostEpoch))),
                readiness: ReadinessRow(state: .invalidated, reason: .sourceChanged, isCurrent: false, storeCount: 1,
                                        refusesNewAction: false),
                events: EventRow(start: .available, script: [lost], capacity: 4, bystander: nil, refusedFault: nil,
                                 results: [.success([action])], endState: .invalidated, endReason: .sourceChanged,
                                 endsAs: .stale),
                atCapacity: false
            )
        case .failed:
            // A mismatched bump is refused; a real source loss does not touch a failed action.
            return Self(
                capability: CapabilityRow(presence: .present, advertised: 0, missingRequired: [required],
                                          missingAdvisory: [advisory], epochLag: 0, preparation: unsupported,
                                          admission: .admitted),
                readiness: ReadinessRow(state: .failed, reason: .preparationFailed, isCurrent: false, storeCount: 1,
                                        refusesNewAction: false),
                events: EventRow(start: .failed, script: [.bump(sourceKey, .contextChange), lost], capacity: 4,
                                 bystander: nil, refusedFault: nil,
                                 results: [.failure(.ledger(.reasonDoesNotMatchKind(sourceKey))), .success([])],
                                 endState: .failed, endReason: .preparationFailed, endsAs: nil),
                atCapacity: false
            )
        case .pressured:
            // A full source refuses a duplicate. A ready filler that does not depend on the source shows the
            // loss invalidates only `fx.action` of the 4,096 actions.
            return Self(
                capability: CapabilityRow(presence: .present, advertised: DeviceCapabilityLimits.capabilitiesPerDevice,
                                          missingRequired: [], missingAdvisory: [], epochLag: 0, preparation: nil,
                                          admission: .admitted),
                readiness: ReadinessRow(state: .ready, reason: nil, isCurrent: true,
                                        storeCount: ReadinessFixture.readinessCapacity, refusesNewAction: true),
                events: EventRow(start: .pressured, script: [lost], capacity: 1, bystander: bystander,
                                 refusedFault: (.duplicate, .capacity), results: [.success([action])],
                                 endState: .invalidated, endReason: .sourceChanged, endsAs: nil),
                atCapacity: true
            )
        }
    }
}

/// The source and fixture after delivering every scripted event, and what each event did.
private struct Delivery {
    let source: ScriptedEventSource
    let fixture: ReadinessFixture
    let results: [Result<[ActionID], FixtureEventError>]
}

/// Every stored property of `AdmissionContext`, which is not Equatable itself. `storedCount` pins the
/// field count, so a new context field fails the determinism test until it is compared here too.
private struct AdmissionFields: Equatable {
    static let storedCount = 8

    let hostEpoch: HostEpoch
    let connectionEpoch: ConnectionEpoch?
    let revisions: CommandRevisions
    let permission: PermissionFingerprint?
    let allowedScopes: Set<CommandScope>
    let allowedClasses: Set<CommandClass>
    let catalog: ParameterCatalog
    let ceiling: Double?

    init(_ context: AdmissionContext) {
        hostEpoch = context.hostEpoch
        connectionEpoch = context.connectionEpoch
        revisions = context.revisions
        permission = context.permission
        allowedScopes = context.allowedScopes
        allowedClasses = context.allowedClasses
        catalog = context.catalog
        ceiling = context.ceiling
    }
}

extension ContractFixtureTests {
    struct StateMatrix {
        /// One node that needs the required capability and would like the advisory one.
        private func graph() -> GraphDocument {
            GraphDocument(
                id: GraphID(validated: "fx.graph.matrix"),
                capabilities: [CapabilityDefinition(id: required, label: "Required"),
                               CapabilityDefinition(id: advisory, label: "Advisory")],
                nodes: [GraphNode(id: graphNode, kind: .plugin, label: "Processor",
                                  requiredCapabilities: [required], advisoryCapabilities: [advisory])]
            )
        }

        /// Delivers `row.script` in order. A refused event must leave the fixture unchanged.
        private func deliver(_ row: EventRow) throws -> Delivery {
            var source = try ScriptedEventSource(capacity: row.capacity, events: row.script)
            if let refused = row.refusedFault {
                let before = source
                #expect(throws: refused.error) { try source.inject(refused.fault) }
                #expect(source == before)
            }
            var fixture = try ReadinessFixture.make(row.start)
            if let bystander = row.bystander {
                let others = fixture.requirements(for: bystander).filter { $0.key != sourceKey }
                try fixture.readiness.markReady(bystander, preparedAgainst: others, ledger: fixture.ledger)
            }
            var results: [Result<[ActionID], FixtureEventError>] = []
            while let event = source.next() {
                let before = fixture.snapshot
                do throws(FixtureEventError) {
                    try results.append(.success(FixtureEventApplier.apply(
                        event, ledger: &fixture.ledger, readiness: &fixture.readiness
                    )))
                } catch {
                    results.append(.failure(error))
                    #expect(fixture.snapshot == before)
                }
            }
            return Delivery(source: source, fixture: fixture, results: results)
        }

        private func checkCapability(_ row: CapabilityRow, _ state: ContractFixtureState) throws {
            let snapshot = try CapabilitySnapshotFixture.make(state)
            let devices = snapshot.document.devices
            #expect(devices.map(\.presence) == [row.presence])
            #expect(devices.map(\.capabilities.count) == [row.advertised])
            let assessment = try snapshot.document.assess(snapshot.requirements)
            #expect(assessment.missingRequired == row.missingRequired)
            #expect(assessment.missingAdvisory == row.missingAdvisory)
            #expect(snapshot.currentHostEpoch.value - snapshot.document.hostEpoch.value == row.epochLag)
            if let refusal = row.preparation {
                #expect(throws: refusal) {
                    try graph().validateForPreparation(supportedCapabilities: snapshot.supportedCapabilities)
                }
            } else {
                try graph().validateForPreparation(supportedCapabilities: snapshot.supportedCapabilities)
            }
            for controlClass in ControlClass.allCases {
                let context = try AdmissionContextFixture.context(state, controlClass: controlClass)
                let intent = try AdmissionContextFixture.intent(state, controlClass: controlClass)
                #expect(CommandAdmission.admit(intent, in: context) == row.admission, "\(controlClass)")
            }
        }

        private func checkReadiness(_ row: ReadinessRow, _ fixture: ReadinessFixture) throws {
            let readiness = fixture.readiness
            #expect(readiness.state(action) == row.state && readiness.reasons[action] == row.reason)
            #expect(readiness.isCurrent(action, ledger: fixture.ledger) == row.isCurrent)
            #expect(readiness.states.count == row.storeCount)
            var probe = readiness
            let newcomer = ActionID(validated: "fx.action.matrix")
            if row.refusesNewAction {
                #expect(throws: ReadinessError.capacity) { try probe.transition(newcomer, to: .preparing) }
                #expect(ReadinessFixture(ledger: fixture.ledger, readiness: probe).snapshot == fixture.snapshot)
            } else {
                try probe.transition(newcomer, to: .preparing)
                #expect(probe.state(newcomer) == .preparing)
            }
        }

        private func checkEvents(_ row: EventRow) throws {
            let delivery = try deliver(row)
            #expect(delivery.results == row.results)
            #expect(delivery.source.deliveredCount == row.script.count && delivery.source.lostCount == 0)
            #expect(delivery.source.pending.isEmpty)
            let readiness = delivery.fixture.readiness
            #expect(readiness.state(action) == row.endState && readiness.reasons[action] == row.endReason)
            if let bystander = row.bystander {
                #expect(readiness.state(bystander) == .ready)
                #expect(readiness.isCurrent(bystander, ledger: delivery.fixture.ledger))
            }
            if let target = row.endsAs {
                #expect(try delivery.fixture.snapshot == ReadinessFixture.make(target).snapshot)
            }
        }

        private func checkPressure(_ fixture: ReadinessFixture) throws {
            #expect(try PressureFixture.readinessAtCapacity().states == fixture.readiness.states)
            let (session, handles) = try PressureFixture.saturatedSession(capacity: 2)
            var probe = session
            let token = session.currentToken
            #expect(throws: TriggerSessionError.outcomeCapacity) {
                try probe.reserve(id: TriggerID(validated: "fx.trigger.matrix"), session: token)
            }
            #expect(probe.currentToken == token && probe.pendingCount == 2 && probe.reservedOutcomeCount == 2)
            #expect(handles.map(\.trigger.rawValue) == ["fx.trigger.1", "fx.trigger.2"])
            #expect(PressureFixture.maximumRequirements().count == TriggerStamp.maximumRequirements)
        }

        @Test(arguments: ContractFixtureState.allCases)
        func everyStateHasCapabilityReadinessAndEventFixture(state: ContractFixtureState) throws {
            let row = StateExpectation.row(state)
            let fixture = try ReadinessFixture.make(state)
            try checkCapability(row.capability, state)
            try checkReadiness(row.readiness, fixture)
            try checkEvents(row.events)
            #expect(row.atCapacity == (fixture.readiness.states.count == ReadinessFixture.readinessCapacity))
            if row.atCapacity { try checkPressure(fixture) }
        }

        @Test func fixtureConstructionIsDeterministicAcrossRuns() throws {
            for state in ContractFixtureState.allCases {
                #expect(try CapabilitySnapshotFixture.make(state) == CapabilitySnapshotFixture.make(state))
                for controlClass in ControlClass.allCases {
                    let first = try AdmissionContextFixture.context(state, controlClass: controlClass)
                    let second = try AdmissionContextFixture.context(state, controlClass: controlClass)
                    #expect(AdmissionFields(first) == AdmissionFields(second), "\(state) \(controlClass)")
                    #expect(Mirror(reflecting: first).children.count == AdmissionFields.storedCount)
                    #expect(try AdmissionContextFixture.intent(state, controlClass: controlClass)
                        == AdmissionContextFixture.intent(state, controlClass: controlClass))
                }
                #expect(try ReadinessFixture.make(state).snapshot == ReadinessFixture.make(state).snapshot)
                let events = StateExpectation.row(state).events
                let first = try deliver(events)
                let second = try deliver(events)
                #expect(first.source == second.source && first.results == second.results)
                #expect(first.fixture.snapshot == second.fixture.snapshot)
            }

            // F5's limit fixtures are compared once. Session tokens are fresh identities, so compare trigger IDs.
            let capacity = PressureFixture.maximumSessionCapacity
            let (session, handles) = try PressureFixture.saturatedSession(capacity: capacity)
            let (again, rebuilt) = try PressureFixture.saturatedSession(capacity: capacity)
            #expect(handles.map(\.trigger) == rebuilt.map(\.trigger))
            #expect(session.reservedOutcomeCount == again.reservedOutcomeCount)
            #expect(try PressureFixture.readinessAtCapacity().states == PressureFixture.readinessAtCapacity().states)
            #expect(PressureFixture.maximumRequirements() == PressureFixture.maximumRequirements())
            #expect(try PressureFixture.documentAtDeviceLimit() == PressureFixture.documentAtDeviceLimit())
        }
    }
}
