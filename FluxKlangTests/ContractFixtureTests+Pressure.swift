import Testing
@testable import FluxKlang

extension ContractFixtureTests {
    struct Pressure {
        private let trigger = TriggerID(validated: "fx.trigger.1")

        private func stamp(_ requires: [GenerationRequirement]) -> TriggerStamp {
            TriggerStamp(id: trigger, action: ContractFixtureIDs.action, originHost: HostStamp(ticks: 1_000),
                         horizonFrame: 0, requires: requires, target: .asap, latePolicy: .drop)
        }

        private func validate(_ stamp: TriggerStamp) throws(TriggerValidationError) {
            try stamp.validate(primaryClock: ReadinessFixture.primaryKey, musicalClock: ContractFixtureIDs.musicalClock)
        }

        /// Dense prepare-time slots for the stamp's trigger and action and for
        /// every requirement key, each bound in the role its kind declares.
        private func preparation(for requires: [GenerationRequirement]) throws -> RuntimePreparation {
            let keys: [RuntimeIdentity] = try requires.map { requirement in
                let subject = requirement.key.subject
                switch requirement.key.kind {
                case .sampleClock: return .sampleClock(ContractFixtureIDs.primaryClock)
                case .transport, .musicalMap: return .musicalClock(ContractFixtureIDs.musicalClock)
                case .source: return try .stream(StreamID(subject.rawValue), direction: .playback)
                case .context: return .context(subject)
                case .cancelScope: return .cancelScope(subject)
                }
            }
            let identities: [RuntimeIdentity] = [.trigger(trigger), .action(ContractFixtureIDs.action)] + keys
            return try RuntimePreparation(
                primaryClock: ContractFixtureIDs.primaryClock, musicalClock: ContractFixtureIDs.musicalClock,
                bindings: identities.enumerated().map { ($1, UInt32($0)) }
            )
        }

        /// The kernel form of `requires`, with slots in list order.
        private func runtime(_ requires: [GenerationRequirement]) -> [RuntimeGenerationRequirement] {
            requires.enumerated().map { index, requirement in
                RuntimeGenerationRequirement(key: RuntimeGenerationKey(kind: requirement.key.kind, slot: UInt32(index)),
                                             generation: UInt64(requirement.generation.value))
            }
        }

        @Test func saturatedSessionRefusesReservationWithoutMutation() throws {
            let capacity = 4
            let (session, handles) = try PressureFixture.saturatedSession(capacity: capacity)
            let token = session.currentToken
            #expect(handles.map(\.trigger.rawValue) == (1...capacity).map { "fx.trigger.\($0)" })
            #expect(handles.allSatisfy { $0.session == token })
            #expect(session.pendingCount == capacity && session.reservedOutcomeCount == capacity)

            var refused = session
            let extra = TriggerID(validated: "fx.trigger.extra")
            #expect(throws: TriggerSessionError.outcomeCapacity) { try refused.reserve(id: extra, session: token) }
            #expect(throws: TriggerSessionError.duplicateID) {
                try refused.reserve(id: handles[0].trigger, session: token)
            }
            #expect(refused.currentToken == token)
            #expect(refused.pendingCount == capacity && refused.reservedOutcomeCount == capacity)
            for handle in handles {
                #expect(throws: TriggerSessionError.duplicateID) {
                    try refused.preflight(id: handle.trigger, session: token)
                }
            }

            // Every pending reservation survived the refusals: each completes, and all drain in order.
            for handle in handles {
                try refused.complete(handle, outcome: TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                                     reason: .notReady))
            }
            #expect(throws: TriggerSessionError.outcomeCapacity) { try refused.preflight(id: extra, session: token) }
            #expect(refused.drain().map(\.handle) == handles)
            // The refused ID was never recorded: with the slots drained it is accepted, not a duplicate.
            #expect(try refused.reserve(id: extra, session: token).trigger == extra)
            #expect(refused.pendingCount == 1 && refused.reservedOutcomeCount == 1)

            let maximum = PressureFixture.maximumSessionCapacity
            let (full, all) = try PressureFixture.saturatedSession(capacity: maximum)
            #expect(full.reservedOutcomeCount == maximum && Set(all.map(\.trigger)).count == maximum)
            #expect(throws: PressureFixtureError.ids(.invalidLimit)) {
                try PressureFixture.saturatedSession(capacity: maximum + 1)
            }
            #expect(throws: PressureFixtureError.session(.invalidOutcomeCapacity)) {
                try PressureFixture.saturatedSession(capacity: 0)
            }
        }

        @Test func readinessCapacityRefusesNewAction() throws {
            var readiness = try PressureFixture.readinessAtCapacity()
            let pressured = try ReadinessFixture.make(.pressured)
            #expect(readiness.states == pressured.readiness.states)
            #expect(readiness.states.count == ReadinessFixture.readinessCapacity)
            let before = ReadinessFixture(ledger: pressured.ledger, readiness: readiness).snapshot
            #expect(before == pressured.snapshot)

            let newcomer = ActionID(validated: "fx.action.new")
            #expect(throws: ReadinessError.capacity) { try readiness.transition(newcomer, to: .preparing) }
            #expect(throws: ReadinessError.capacity) {
                try readiness.transition(newcomer, to: .failed, reason: .preparationFailed)
            }
            #expect(readiness.states[newcomer] == nil && readiness.reasons[newcomer] == nil)
            #expect(ReadinessFixture(ledger: pressured.ledger, readiness: readiness).snapshot == before)

            // Capacity refuses only new actions: a held one still moves, but stays in the store, so it stays full.
            let held = ActionID(validated: "fx.pressure.1")
            try readiness.transition(held, to: .unprepared)
            #expect(throws: ReadinessError.capacity) { try readiness.transition(newcomer, to: .preparing) }
            #expect(readiness.state(ContractFixtureIDs.action) == .ready)
        }

        @Test func ninthRequirementIsRejected() throws {
            let requirements = PressureFixture.maximumRequirements()
            let maximum = TriggerStamp.maximumRequirements
            #expect(requirements.count == maximum && maximum == 8)
            #expect(Set(requirements.map(\.key)).count == maximum)
            #expect(requirements == PressureFixture.maximumRequirements())
            try validate(stamp(requirements))

            let overflow = PressureFixture.overflowRequirement
            #expect(!requirements.map(\.key).contains(overflow.key))
            let nine = requirements + [overflow]
            #expect(throws: TriggerValidationError.tooManyRequirements(9)) { try validate(stamp(nine)) }

            let accepted = try RuntimeRequirements(runtime(requirements))
            #expect(accepted.count == maximum && accepted[maximum] == nil)
            #expect(accepted[maximum - 1] == runtime(requirements).last)
            #expect(throws: TriggerValidationError.tooManyRequirements(9)) { try RuntimeRequirements(runtime(nine)) }

            let prepared = try preparation(for: nine).trigger(stamp(requirements))
            #expect(prepared.requires.count == maximum)
            #expect(throws: TriggerValidationError.tooManyRequirements(9)) {
                try preparation(for: nine).trigger(stamp(nine))
            }

            // markReady has its own limit: 9 is refused for its count; 8 passes the count check and is refused only
            // because the extra keys are not declared in the fixture ledger. Neither refusal changes anything.
            let action = ContractFixtureIDs.action
            var fixture = try ReadinessFixture.make(.missing)
            try fixture.readiness.transition(action, to: .preparing)
            let before = fixture.snapshot
            #expect(throws: ReadinessError.capacity) {
                try fixture.readiness.markReady(action, preparedAgainst: nine, ledger: fixture.ledger)
            }
            #expect(throws: ReadinessError.stalePreparation(action)) {
                try fixture.readiness.markReady(action, preparedAgainst: requirements, ledger: fixture.ledger)
            }
            #expect(fixture.snapshot == before)
        }

        @Test func deviceLimitDocumentIsAcceptedAndOneMoreIsNot() throws {
            let limit = PressureFixture.deviceLimit
            let document = try PressureFixture.documentAtDeviceLimit()
            #expect(limit == DeviceCapabilityLimits.devices && document.devices.count == limit)
            #expect(document.devices.map(\.id.rawValue) == (1...limit).map { "fx.pressure.device.\($0)" })
            try document.validate()
            let data = try document.encoded()
            #expect(data.count < DeviceCapabilityLimits.documentBytes)
            #expect(try DeviceCapabilityDocument.decode(from: data) == document)

            let error = DeviceCapabilityLimitError.exceeded(path: "$.devices", maximum: limit)
            let past = try PressureFixture.devices(count: limit + 1)
            #expect(Array(past.prefix(limit)) == document.devices)
            #expect(throws: error) {
                try DeviceCapabilityDocument(revision: .initial, host: ContractFixtureIDs.host, hostEpoch: .initial,
                                             devices: past, routes: [])
            }
            var grown = document
            grown.devices.append(past[limit])
            #expect(throws: error) { try grown.validate() }
            #expect(throws: error) { try grown.encoded() }
        }
    }
}
