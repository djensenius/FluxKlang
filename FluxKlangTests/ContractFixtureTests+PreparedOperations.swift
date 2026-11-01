import Testing
@testable import FluxKlang

extension ContractFixtureTests {
    struct PreparedOperations {
        private let action = ContractFixtureIDs.action

        private func processor(
            supportsTimeStretch: Bool = false,
            failing: [Int: FixtureFault] = [:]
        ) throws -> FakeProcessor {
            try FakeProcessor(supportsTimeStretch: supportsTimeStretch,
                              faults: FaultScript(failing: failing, callLimit: 8))
        }

        private func stretchPolicy() throws -> ActionPolicy {
            try ActionPolicy(media: .audio, timePolicy: .timeStretch, latePolicy: .drop)
        }

        @Test func readyProcessorMarksActionReadyAgainstCurrentGenerations() throws {
            var fixture = try ReadinessFixture.make(.missing)
            var fake = try processor()
            #expect(!fixture.readiness.isCurrent(action, ledger: fixture.ledger))

            try fake.prepare(action, policy: nil, in: &fixture)
            #expect(fixture.readiness.state(action) == .ready)
            #expect(fixture.readiness.readyEntry(action) == 1)
            #expect(fixture.readiness.isCurrent(action, ledger: fixture.ledger))
            #expect(fixture.readiness.reasons[action] == nil)
            #expect(fake.prepareCalls.entries == [action] && fake.faults.callCount == 1)
            #expect(fake.node == FakeProcessor.fixtureNode)

            let requirements = fixture.requirements(for: action)
            #expect(requirements.map(\.key) == ReadinessFixture.dependencyKeys)
            #expect(requirements.allSatisfy(fixture.ledger.isCurrent))

            // A ready action cannot be prepared again without leaving `ready` first.
            let ready = fixture.snapshot
            #expect(throws: FakeProcessorError.readiness(.illegalTransition(action, from: .ready, to: .preparing))) {
                try fake.prepare(action, policy: nil, in: &fixture)
            }
            #expect(fixture.snapshot == ready)
        }

        @Test func failedPrepareRecordsPreparationFailedReason() throws {
            var fixture = try ReadinessFixture.make(.missing)
            let generations = fixture.ledger.current
            var fake = try processor(failing: [1: .prepareFailed])
            #expect(throws: FakeProcessorError.fault(.prepareFailed)) {
                try fake.prepare(action, policy: nil, in: &fixture)
            }
            #expect(fixture.readiness.state(action) == .failed)
            #expect(fixture.readiness.reasons[action] == .preparationFailed)
            #expect(fixture.readiness.readyEntry(action) == nil)
            #expect(!fixture.readiness.isCurrent(action, ledger: fixture.ledger))
            #expect(fixture.ledger.current == generations)

            // The next, unscripted call recovers `failed → preparing → ready` and clears the reason.
            try fake.prepare(action, policy: nil, in: &fixture)
            #expect(fixture.readiness.state(action) == .ready && fixture.readiness.reasons[action] == nil)

            // A ready action cannot enter `preparing`, so the failure is refused and nothing changes.
            let ready = fixture.snapshot
            var again = try processor(failing: [1: .prepareFailed])
            #expect(throws: FakeProcessorError.readiness(.illegalTransition(action, from: .ready, to: .preparing))) {
                try again.prepare(action, policy: nil, in: &fixture)
            }
            #expect(fixture.snapshot == ready)

            let made = try ReadinessFixture.make(.failed)
            #expect(made.readiness.state(action) == .failed && made.readiness.reasons[action] == .preparationFailed)
        }

        @Test func timeStretchUnavailableFailsAction() throws {
            var fixture = try ReadinessFixture.make(.missing)
            var fixedRate = try processor()
            #expect(throws: FakeProcessorError.readiness(.timeStretchUnavailable)) {
                try fixedRate.prepare(action, policy: stretchPolicy(), in: &fixture)
            }
            #expect(fixture.readiness.state(action) == .failed)
            #expect(fixture.readiness.reasons[action] == .timeStretchUnavailable)
            #expect(!fixture.readiness.isCurrent(action, ledger: fixture.ledger))

            // The same policy prepares on a processor that can stretch.
            var stretching = try processor(supportsTimeStretch: true)
            try stretching.prepare(action, policy: stretchPolicy(), in: &fixture)
            #expect(fixture.readiness.state(action) == .ready)
            #expect(fixture.readiness.isCurrent(action, ledger: fixture.ledger))

            // A fixed-rate audio policy never needs stretching.
            var other = try ReadinessFixture.make(.missing)
            let fixedPolicy = try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .drop)
            try fixedRate.prepare(action, policy: fixedPolicy, in: &other)
            #expect(other.readiness.state(action) == .ready)
        }

        @Test func sourceBumpInvalidatesPreparedAction() throws {
            var fixture = try ReadinessFixture.make(.available)
            #expect(fixture.readiness.isCurrent(action, ledger: fixture.ledger))
            let firstEntry = try #require(fixture.readiness.readyEntry(action))

            let source = ReadinessFixture.sourceKey
            let generation = try fixture.ledger.bump(source, reason: .sourceLost)
            #expect(generation == (try Generation.initial.next()))
            // The bump alone makes the preparation stale before readiness hears of it.
            #expect(fixture.readiness.state(action) == .ready)
            #expect(!fixture.readiness.isCurrent(action, ledger: fixture.ledger))

            #expect(fixture.readiness.generationChanged(source) == [action])
            #expect(fixture.readiness.state(action) == .invalidated)
            #expect(fixture.readiness.reasons[action] == .sourceChanged)
            #expect(fixture.readiness.generationChanged(ReadinessFixture.sourceKey).isEmpty)

            let stale = try ReadinessFixture.make(.stale)
            #expect(stale.snapshot == fixture.snapshot)

            var fake = try processor()
            try fake.prepare(action, policy: nil, in: &fixture)
            #expect(fixture.readiness.isCurrent(action, ledger: fixture.ledger))
            #expect(fixture.readiness.readyEntry(action) == firstEntry + 1)
            #expect(fixture.requirements(for: action).contains(.init(key: source, generation: generation)))
        }

        @Test func snapshotsDistinguishDependencyDrivenInvalidation() throws {
            func prepared(against key: GenerationKey) throws -> ReadinessFixture {
                var fixture = try ReadinessFixture.make(.missing)
                let requirement = try #require(fixture.requirements(for: action).first { $0.key == key })
                var fake = try processor()
                try fake.prepare(action, policy: nil, against: [requirement], in: &fixture)
                return fixture
            }
            var onSource = try prepared(against: ReadinessFixture.sourceKey)
            var onContext = try prepared(against: ReadinessFixture.contextKey)
            #expect(onSource.readiness.state(action) == .ready && onContext.readiness.state(action) == .ready)
            let sourceSnapshot = onSource.snapshot
            #expect(sourceSnapshot != onContext.snapshot)
            // Taking a snapshot probes copies only.
            #expect(onSource.snapshot == sourceSnapshot && onSource.readiness.state(action) == .ready)

            try onSource.ledger.bump(ReadinessFixture.sourceKey, reason: .sourceLost)
            try onContext.ledger.bump(ReadinessFixture.sourceKey, reason: .sourceLost)
            #expect(onSource.readiness.generationChanged(ReadinessFixture.sourceKey) == [action])
            #expect(onContext.readiness.generationChanged(ReadinessFixture.sourceKey).isEmpty)
            #expect(onSource.readiness.state(action) == .invalidated)
            #expect(onContext.readiness.state(action) == .ready)
            #expect(onContext.readiness.isCurrent(action, ledger: onContext.ledger))
        }

        @Test func preparationAgainstStaleGenerationIsRefused() throws {
            var fixture = try ReadinessFixture.make(.missing)
            let captured = fixture.requirements(for: action)
            try fixture.ledger.bump(ReadinessFixture.contextKey, reason: .contextChange)
            let before = fixture.snapshot

            var fake = try processor()
            #expect(throws: FakeProcessorError.readiness(.stalePreparation(action))) {
                try fake.prepare(action, policy: nil, against: captured, in: &fixture)
            }
            #expect(fixture.snapshot == before)
            #expect(fixture.readiness.state(action) == .unprepared)

            try fake.prepare(action, policy: nil, in: &fixture)
            #expect(fixture.readiness.isCurrent(action, ledger: fixture.ledger))
            #expect(!captured.allSatisfy(fixture.ledger.isCurrent))
            #expect(fake.prepareCalls.entries == [action, action])
        }

        @Test func scriptedFaultLeavesReadinessUnchanged() throws {
            for state in ContractFixtureState.allCases {
                var fixture = try ReadinessFixture.make(state)
                let before = fixture.snapshot
                var fake = try FakeProcessor(
                    faults: FaultScript(failing: [1: .timedOut, 2: .capacity, 3: .disconnected], callLimit: 3)
                )
                for fault: FixtureFault in [.timedOut, .capacity, .disconnected, .callLimitExceeded] {
                    #expect(throws: FakeProcessorError.fault(fault)) {
                        try fake.prepare(action, policy: nil, in: &fixture)
                    }
                    #expect(fixture.snapshot == before, "\(state) after \(fault)")
                }
                #expect(fake.prepareCalls.entries.count == 4 && fake.faults.callCount == 3)
            }
        }

        @Test func everyStateBuildsADeterministicReadinessFixture() throws {
            for state in ContractFixtureState.allCases {
                let first = try ReadinessFixture.make(state)
                #expect(first.snapshot == (try ReadinessFixture.make(state)).snapshot, "\(state)")
                #expect(first.requirements(for: action).count == ReadinessFixture.dependencyKeys.count)
            }
            let current = try ContractFixtureState.allCases.filter {
                try ReadinessFixture.make($0).readiness.isCurrent(action, ledger: ReadinessFixture.make($0).ledger)
            }
            #expect(current == [.available, .pressured])

            var pressured = try ReadinessFixture.make(.pressured)
            #expect(pressured.readiness.states.count == ReadinessFixture.readinessCapacity)
            let full = pressured.snapshot
            var fake = try processor()
            let newcomer = ActionID(validated: "fx.action.new")
            #expect(throws: FakeProcessorError.readiness(.capacity)) {
                try fake.prepare(newcomer, policy: nil, in: &pressured)
            }
            #expect(pressured.snapshot == full)
        }
    }
}
