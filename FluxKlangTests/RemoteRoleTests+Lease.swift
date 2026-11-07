import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteRoleTests {
    private static func heldLease() throws -> (registry: EngineLeaseRegistry, snapshot: EngineLeaseSnapshot) {
        var registry = EngineLeaseRegistry()
        let snapshot = try acquire(&registry)
        return (registry, snapshot)
    }

    @Test func enterRemoteWithAHeldLeaseAndNoTokenIsRefusedLocalLeaseHeld() throws {
        let held = try Self.heldLease()
        var role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.localLeaseHeld(Self.projectP)) {
            try role.advance(.enterRemote(Self.session(), releasing: nil), local: Self.context(lease: held.snapshot))
        }
        #expect(role == RemoteRole())
        #expect(held.registry.snapshot == held.snapshot)
    }

    @Test func enterRemoteWithTheMatchingTokenPlansReleaseBeforeBegin() throws {
        let held = try Self.heldLease()
        var role = RemoteRole()
        let plan = try role.advance(
            .enterRemote(Self.session(), releasing: held.snapshot.token), local: Self.context(lease: held.snapshot)
        )
        #expect(plan == [.releaseEngineLease(held.snapshot.token), .beginRemoteControl(Self.session())])
        #expect(role.kind == .remoteController)
        #expect(held.registry.snapshot == held.snapshot)
    }

    @Test func enterRemoteSucceedsAfterTheCallerReleasedThroughTheRegistryFirst() throws {
        var held = try Self.heldLease()
        _ = try held.registry.release(expected: held.snapshot.token)
        var role = RemoteRole()
        let plan = try role.advance(
            .enterRemote(Self.session(), releasing: nil), local: Self.context(lease: held.registry.snapshot)
        )
        #expect(plan == [.beginRemoteControl(Self.session())])
        #expect(role.kind == .remoteController)
    }

    @Test func aTokenFromAnEarlierGenerationOfTheSameRegistryIsStale() throws {
        var registry = EngineLeaseRegistry()
        let first = try Self.acquire(&registry)
        _ = try registry.release(expected: first.token)
        let second = try Self.acquire(&registry)
        #expect(first.token != second.token)
        let role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.staleLeaseToken) {
            try role.apply(.enterRemote(Self.session(), releasing: first.token), local: Self.context(lease: second))
        }
    }

    @Test func aForeignRegistryTokenAtTheSameGenerationIsRefused() throws {
        let held = try Self.heldLease()
        var foreign = EngineLeaseRegistry()
        let alien = try Self.acquire(&foreign)
        #expect(alien.generation == held.snapshot.generation)
        let role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.staleLeaseToken) {
            try role.apply(
                .enterRemote(Self.session(), releasing: alien.token), local: Self.context(lease: held.snapshot)
            )
        }
    }

    @Test func aTokenWithoutAHeldLeaseIsStale() throws {
        var registry = EngineLeaseRegistry()
        let snapshot = try Self.acquire(&registry)
        _ = try registry.release(expected: snapshot.token)
        let role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.staleLeaseToken) {
            try role.apply(.enterRemote(Self.session(), releasing: snapshot.token), local: Self.idle)
        }
    }

    @Test func aRunningDegradedPreparingOrHeldByOtherEngineIsAShowRunningRefusal() throws {
        let capability = CapabilityID(validated: "cap.audio")
        let lifecycles: [EngineLifecycle] = [
            .running, .degraded([capability]), .preparing(.initial, over: .absent),
            .preparing(.initial, over: .running), .heldByOther(Self.projectQ)
        ]
        for lifecycle in lifecycles {
            var role = RemoteRole()
            #expect(throws: RemoteRoleRefusal.showRunning(lifecycle)) {
                try role.advance(
                    .enterRemote(Self.session(), releasing: nil), local: Self.context(lease: nil, lifecycle)
                )
            }
            #expect(role == RemoteRole())
        }
    }

    @Test func aRecoveringEngineRefusesEnterRemoteAsEngineRecovering() throws {
        let role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.engineRecovering) {
            try role.apply(.enterRemote(Self.session(), releasing: nil), local: Self.context(lease: nil, .recovering))
        }
    }

    @Test func aStoppedEngineWithNoLeaseAdmitsEnterRemote() throws {
        let entered = try RemoteRole().apply(.enterRemote(Self.session(), releasing: nil), local: Self.idle)
        #expect(entered.role.kind == .remoteController)
    }

    @Test func aMatchingReleaseOverARunningShowIsStillRefusedAndNeverPlansARelease() throws {
        let held = try Self.heldLease()
        let role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.showRunning(.running)) {
            try role.apply(
                .enterRemote(Self.session(), releasing: held.snapshot.token),
                local: Self.context(lease: held.snapshot, .running)
            )
        }
    }

    @Test func leaseDefectsComeBeforeLifecycleDefectsInBothCombinations() throws {
        let held = try Self.heldLease()
        let role = RemoteRole()
        #expect(throws: RemoteRoleRefusal.localLeaseHeld(Self.projectP)) {
            try role.apply(
                .enterRemote(Self.session(), releasing: nil), local: Self.context(lease: held.snapshot, .running)
            )
        }
        var foreign = EngineLeaseRegistry()
        let alien = try Self.acquire(&foreign)
        #expect(throws: RemoteRoleRefusal.staleLeaseToken) {
            try role.apply(
                .enterRemote(Self.session(), releasing: alien.token),
                local: Self.context(lease: held.snapshot, .recovering)
            )
        }
        #expect(throws: RemoteRoleRefusal.engineRecovering) {
            try role.apply(.enterRemote(Self.session(), releasing: nil), local: Self.context(lease: nil, .recovering))
        }
    }

    @Test func theHeldSnapshotAndRegistryAreNeverModifiedByAnyEntryOutcome() throws {
        let held = try Self.heldLease()
        let before = held.registry
        let role = RemoteRole()
        _ = try role.apply(
            .enterRemote(Self.session(), releasing: held.snapshot.token), local: Self.context(lease: held.snapshot)
        )
        _ = try? role.apply(.enterRemote(Self.session(), releasing: nil), local: Self.context(lease: held.snapshot))
        #expect(before.snapshot == held.registry.snapshot)
        #expect(before.lastIssued == held.registry.lastIssued)
        #expect(held.registry.snapshot?.windows == [Self.windowW])
    }

    @Test func entryAlsoCarriesTheObserverGrantIntoTheSession() throws {
        let entered = try RemoteRole().apply(
            .enterRemote(Self.session(grant: .observer), releasing: nil), local: Self.idle
        )
        #expect(entered.role.session == Self.session(grant: .observer))
    }
}
