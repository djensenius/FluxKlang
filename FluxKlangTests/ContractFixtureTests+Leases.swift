import Testing
@testable import FluxKlang

extension ContractFixtureTests {
    struct Leases {
        /// A window ID the fixture never hands out.
        private let extraWindow = WindowID(validated: "fx.window.extra")

        private func generation(_ value: Int) throws -> Generation { try Generation(value) }

        private func token(_ fixture: LeaseFixture) throws -> EngineLeaseToken {
            try #require(fixture.registry.snapshot).token
        }

        /// `operation` must be refused with `error` and leave the whole fixture,
        /// including the held token, unchanged.
        private func expectRefusal(
            _ error: EngineLeaseError, in fixture: LeaseFixture,
            sourceLocation: SourceLocation = #_sourceLocation,
            _ operation: (inout EngineLeaseRegistry) throws(EngineLeaseError) -> Void
        ) {
            var refused = fixture
            #expect(throws: error, sourceLocation: sourceLocation) { try operation(&refused.registry) }
            #expect(refused.snapshot == fixture.snapshot, sourceLocation: sourceLocation)
            #expect(refused.registry.snapshot == fixture.registry.snapshot, sourceLocation: sourceLocation)
            #expect(refused.ledger.current == fixture.ledger.current, sourceLocation: sourceLocation)
        }

        @Test(arguments: ContractFixtureState.allCases)
        func everyLeaseStateIsReachableByLegalTransitions(_ state: ContractFixtureState) throws {
            let fixture = try LeaseFixture.make(state)
            let key = LeaseFixture.contextKey
            #expect(key == EngineLeaseRegistry.contextKey && key.description == "context/ctx.engine")
            #expect(fixture.ledger.current.keys.contains(key) && fixture.contextRequirement.key == key)
            #expect(fixture.project.rawValue == "fx.project.1" && fixture.otherProject.rawValue == "fx.project.2")
            #expect(fixture.window.rawValue == "fx.window.1" && fixture.otherWindow.rawValue == "fx.window.2")
            let held = fixture.registry.snapshot
            // Every lease change bumped the context counter exactly once.
            let holder = [.available, .stale, .pressured].contains(state) ? fixture.project : nil
            let lastIssued: Int? = switch state {
            case .available, .failed, .pressured: 1
            case .missing: nil
            case .stale: 2
            }
            let context = switch state {
            case .missing: 1
            case .available, .pressured: 2
            case .failed: 3
            case .stale: 4
            }
            #expect(held?.project == holder && fixture.registry.lastIssued?.value == lastIssued)
            #expect(held?.generation.value == (holder == nil ? nil : lastIssued))
            #expect(fixture.ledger.generation(key) == (try generation(context)))
            #expect((fixture.staleToken != nil) == (state == .stale))
            let lifecycle: EngineLifecycle = switch state {
            case .available, .stale, .pressured: .running
            case .missing: .stopped
            case .failed: .recovering
            }
            #expect(fixture.lifecycle == lifecycle)
            let windows = held?.windows.count ?? 0
            #expect(windows == (state == .pressured ? EngineLeaseRegistry.windowLimit : holder == nil ? 0 : 1))

            let other = try LeaseFixture.heldByOther()
            #expect(other.registry.snapshot?.project == other.otherProject)
            #expect(other.registry.snapshot?.windows == [other.otherWindow])
            #expect(other.lifecycle == .heldByOther(other.otherProject) && other.staleToken == nil)
            #expect(other.ledger.isCurrent(other.contextRequirement) && other.contextRequirement.generation.value == 2)
        }

        @Test func availableLeaseRendersOnlyItsWindows() throws {
            let fixture = try LeaseFixture.make(.available)
            let token = try token(fixture)
            #expect(fixture.registry.snapshot?.windows == [fixture.window])
            #expect(fixture.registry.role(of: fixture.window, project: fixture.project) == .renders(token))
            #expect(fixture.lifecycle == .running && fixture.lifecycle.rendersOutput && !fixture.lifecycle.outputsMuted)
            let notOnLease = [
                (fixture.otherWindow, fixture.otherProject), (extraWindow, fixture.project),
                (fixture.window, fixture.otherProject)
            ]
            for (window, project) in notOnLease {
                let role = fixture.registry.role(of: window, project: project)
                #expect(role == .editAndPrepareOnly(heldBy: fixture.project))
                let observed = EngineLifecycle.observed(by: window, of: project, in: fixture.registry, engine: .running)
                #expect(observed == .heldByOther(fixture.project) && !observed.rendersOutput)
            }
            expectRefusal(.alreadyHeld, in: fixture) { registry throws(EngineLeaseError) in
                _ = try registry.acquire(project: fixture.project, window: extraWindow)
            }
            expectRefusal(.heldByOtherProject(fixture.project), in: fixture) { registry throws(EngineLeaseError) in
                _ = try registry.acquire(project: fixture.otherProject, window: fixture.otherWindow)
            }
        }

        @Test func missingLeaseIsStoppedForEveryWindow() throws {
            let fixture = try LeaseFixture.make(.missing)
            #expect(fixture.registry.snapshot == nil && fixture.registry.lastIssued == nil)
            #expect(fixture.lifecycle == .stopped && !fixture.lifecycle.rendersOutput)
            #expect(!fixture.lifecycle.outputsMuted && fixture.lifecycle.acceptsRunningSetChanges)
            #expect(fixture.ledger.isCurrent(fixture.contextRequirement))
            for window in [fixture.window, fixture.otherWindow, extraWindow] {
                for project in [fixture.project, fixture.otherProject] {
                    #expect(fixture.registry.role(of: window, project: project) == .stopped)
                    let observed = EngineLifecycle.observed(by: window, of: project, in: fixture.registry,
                                                            engine: .stopped)
                    #expect(observed == .stopped)
                }
            }
            let foreign = try token(LeaseFixture.make(.available))
            expectRefusal(.notHeld, in: fixture) { registry throws(EngineLeaseError) in
                try registry.attach(fixture.window, project: fixture.project, expected: foreign)
            }
            expectRefusal(.notHeld, in: fixture) { registry throws(EngineLeaseError) in
                _ = try registry.release(expected: foreign)
            }
        }

        @Test func staleTokenIsRefusedByEveryTokenOperation() throws {
            let fixture = try LeaseFixture.make(.stale)
            let stale = try #require(fixture.staleToken)
            let current = try token(fixture)
            let second = try generation(2)
            #expect(stale != current && stale.generation == .initial && current.generation == second)
            #expect(fixture.registry.role(of: fixture.window, project: fixture.project) == .renders(current))
            expectRefusal(.staleToken, in: fixture) { registry throws(EngineLeaseError) in
                try registry.attach(extraWindow, project: fixture.project, expected: stale)
            }
            expectRefusal(.staleToken, in: fixture) { registry throws(EngineLeaseError) in
                try registry.detach(fixture.window, expected: stale)
            }
            expectRefusal(.staleToken, in: fixture) { registry throws(EngineLeaseError) in
                _ = try registry.release(expected: stale)
            }
            expectRefusal(.staleToken, in: fixture) { registry throws(EngineLeaseError) in
                _ = try registry.transfer(to: fixture.otherProject, window: fixture.otherWindow, expected: stale)
            }
            // The current token is accepted by the same operation, so the refusal was the token's.
            var accepted = fixture
            try accepted.registry.attach(extraWindow, project: fixture.project, expected: current)
            #expect(accepted.registry.snapshot?.windows == [fixture.window, extraWindow])
        }

        @Test func staleLeaseMakesOldContextRequirementStale() throws {
            let fixture = try LeaseFixture.make(.stale)
            let key = LeaseFixture.contextKey
            #expect(fixture.contextRequirement == GenerationRequirement(key: key, generation: try generation(2)))
            #expect(!fixture.ledger.isCurrent(fixture.contextRequirement))
            // Release and reacquire each bumped the context once.
            #expect(fixture.ledger.generation(key) == (try generation(4)))
            let renewed = GenerationRequirement(key: key, generation: try #require(fixture.ledger.generation(key)))
            #expect(fixture.ledger.isCurrent(renewed))
            for state in ContractFixtureState.allCases where state != .stale {
                let other = try LeaseFixture.make(state)
                #expect(other.ledger.isCurrent(other.contextRequirement), "\(state)")
            }
        }

        @Test func failedLeaseIsRecoveringAndMuted() throws {
            let fixture = try LeaseFixture.make(.failed)
            #expect(fixture.lifecycle == .recovering && fixture.lifecycle.outputsMuted)
            #expect(!fixture.lifecycle.rendersOutput && !fixture.lifecycle.acceptsRunningSetChanges)
            #expect(fixture.registry.snapshot == nil && fixture.registry.lastIssued == .initial)
            #expect(fixture.registry.role(of: fixture.window, project: fixture.project) == .stopped)
            // Losing the lease was a context change, and recovery outlives the lease.
            #expect(fixture.ledger.generation(LeaseFixture.contextKey) == (try generation(3)))
            #expect(fixture.ledger.isCurrent(fixture.contextRequirement))
            let observed = EngineLifecycle.observed(by: fixture.window, of: fixture.project, in: fixture.registry,
                                                    engine: fixture.lifecycle)
            #expect(observed == .recovering)
            #expect(EngineLifecycle.running.after(.leaseLost) == fixture.lifecycle)
        }

        @Test func pressuredLeaseRefusesNextWindowWithoutMutation() throws {
            let fixture = try LeaseFixture.make(.pressured)
            let token = try token(fixture)
            let windows = try #require(fixture.registry.snapshot).windows
            #expect(windows.count == EngineLeaseRegistry.windowLimit && windows.count == 64)
            #expect(windows.contains(fixture.window) && !windows.contains(fixture.otherWindow))
            #expect(Set(windows.map(\.rawValue)) == Set(([1] + Array(3...65)).map { "fx.window.\($0)" }))
            #expect(fixture.lifecycle == .running)
            expectRefusal(.windowLimit, in: fixture) { registry throws(EngineLeaseError) in
                try registry.attach(extraWindow, project: fixture.project, expected: token)
            }
            expectRefusal(.alreadyAttached, in: fixture) { registry throws(EngineLeaseError) in
                try registry.attach(fixture.window, project: fixture.project, expected: token)
            }
            expectRefusal(.heldByOtherProject(fixture.project), in: fixture) { registry throws(EngineLeaseError) in
                try registry.attach(fixture.otherWindow, project: fixture.otherProject, expected: token)
            }
            // One slot freed: the same window is accepted, so the limit was the reason.
            var freed = fixture
            try freed.registry.detach(fixture.window, expected: token)
            try freed.registry.attach(extraWindow, project: fixture.project, expected: token)
            #expect(freed.registry.snapshot?.windows.count == EngineLeaseRegistry.windowLimit)
        }

        @Test func heldByOtherWindowIsEditAndPrepareOnly() throws {
            let fixture = try LeaseFixture.heldByOther()
            let token = try token(fixture)
            let held = EngineLeaseError.heldByOtherProject(fixture.otherProject)
            #expect(fixture.registry.role(of: fixture.window, project: fixture.project)
                == .editAndPrepareOnly(heldBy: fixture.otherProject))
            #expect(fixture.registry.role(of: fixture.otherWindow, project: fixture.otherProject) == .renders(token))
            #expect(fixture.lifecycle == .heldByOther(fixture.otherProject))
            #expect(!fixture.lifecycle.rendersOutput && !fixture.lifecycle.outputsMuted)
            #expect(!fixture.lifecycle.acceptsRunningSetChanges)
            expectRefusal(held, in: fixture) { registry throws(EngineLeaseError) in
                _ = try registry.acquire(project: fixture.project, window: fixture.window)
            }
            // Even the holder's current token does not let another project's window join.
            expectRefusal(held, in: fixture) { registry throws(EngineLeaseError) in
                try registry.attach(fixture.window, project: fixture.project, expected: token)
            }
        }

        @Test func leaseFixturesAreDeterministic() throws {
            let builders: [() throws -> LeaseFixture] = ContractFixtureState.allCases.map { state in
                { try LeaseFixture.make(state) }
            } + [{ try LeaseFixture.heldByOther() }]
            var snapshots: [LeaseFixture.Snapshot] = []
            for build in builders {
                let first = try build()
                let second = try build()
                #expect(first.snapshot == second.snapshot)
                // The snapshot records the fixture's own lifecycle and lease generation.
                #expect(first.snapshot.lifecycle == first.lifecycle)
                #expect(first.snapshot.generation == first.registry.snapshot?.generation)
                // Equal snapshots although every issued token has its own identity.
                if let held = first.registry.snapshot {
                    #expect(held.token != second.registry.snapshot?.token)
                }
                if let stale = first.staleToken {
                    #expect(stale != second.staleToken && stale.generation == second.staleToken?.generation)
                }
                snapshots.append(first.snapshot)
            }
            #expect(Set(snapshots).count == builders.count)
        }
    }
}
