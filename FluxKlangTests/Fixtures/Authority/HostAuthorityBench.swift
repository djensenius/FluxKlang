//
//  HostAuthorityBench.swift
//  FluxKlangTests
//
//  Shared setup for the HostAuthority commit-path tests: one host whose project
//  A runs `prep.running` and whose project B runs nothing. No audio, MIDI,
//  hardware or I/O.
//

import Testing
@testable import FluxKlang

enum AuthorityBench {
    static let host = HostID(validated: "host.bench")
    static let hostEpoch = HostEpoch(host: host, generation: .initial)
    static let permission = PermissionFingerprint(rawValue: "permissions.current")
    static let graphID = GraphID(validated: "graph.main")
    static let audio = CapabilityID(validated: "cap.audio")
    static let projectA = ProjectID(validated: "prj.a")
    static let projectB = ProjectID(validated: "prj.b")
    static let projectC = ProjectID(validated: "prj.c")
    static let runningPlan = PreparedActivationID(validated: "prep.running")
    static let windowA = WindowID(validated: "win.a")
    static let windowA2 = WindowID(validated: "win.a2")
    static let windowB = WindowID(validated: "win.b")
    static let nodeOut = NodeID(validated: "node.out")
    static let nodeAux = NodeID(validated: "node.aux")

    static func liveState(epoch: HostEpoch = hostEpoch) throws -> HostLiveState {
        let device = try DeviceDescriptor(
            id: DeviceID(validated: "dev.interface"), kind: .audioInterface,
            layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: .reported,
            identity: DeviceIdentity(.init(uid: "physical-interface-1", evidence: [.deviceUID])),
            presence: .present, capabilities: [audio]
        )
        let document = try DeviceCapabilityDocument(revision: .initial, host: epoch.host,
                                                    hostEpoch: epoch.generation, devices: [device], routes: [])
        return HostLiveState(hostEpoch: epoch, permission: permission, capabilities: document)
    }

    /// One output node; `withAux` adds a second node, for consistent partial reports.
    static func candidate(withAux: Bool = false, revision: ContractRevision = .initial) -> GraphDocument {
        let out = GraphNode(id: nodeOut, kind: .plugin, label: "Out", requiredCapabilities: [audio])
        let aux = GraphNode(id: nodeAux, kind: .plugin, label: "Aux", requiredCapabilities: [audio])
        return GraphDocument(id: graphID, revision: revision,
                             capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
                             nodes: withAux ? [out, aux] : [out])
    }

    static func request(base: ContractRevision = .initial) -> ActivationRequest {
        ActivationRequest(draft: DraftID(validated: "draft.main"), graph: graphID, baseRevision: base,
                          hostEpoch: hostEpoch, permission: permission,
                          digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human)
    }

    static func gesture(_ window: WindowID = windowA, origin: CommandOrigin = .human) -> ActivationGesture {
        ActivationGesture(origin: origin, window: window)
    }

    /// Opens A and B; any resident is created and installed through public host APIs.
    static func makeAuthority(_ engine: inout ScriptedActivationEngine, holding window: WindowID? = windowA,
                              lifecycleA: EngineLifecycle? = nil,
                              recoveryBaseA: RunningSetState? = nil,
                              planCapacity: Int = 512) async throws -> HostAuthority {
        let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.main"), musicalClock: nil,
                                          nominalRate: 48_000)
        let authority = try HostAuthority(host: ledger, live: try liveState(), planCapacity: planCapacity)
        let recoveryBase = lifecycleA == .recovering ? recoveryBaseA : nil
        let hasKnownRecoveryBase: Bool
        switch recoveryBase {
        case .running, .degraded: hasKnownRecoveryBase = true
        case .absent, nil: hasKnownRecoveryBase = false
        }
        let canBootstrap = lifecycleA != .recovering || hasKnownRecoveryBase
        let opening: EngineLifecycle = lifecycleA == .recovering && !canBootstrap ? .recovering : .stopped
        try await authority.open(project: projectA, running: RunningGraph(revision: .initial, prepared: nil),
                                 lifecycle: opening,
                                 recoveryBase: opening == .recovering ? recoveryBase : nil).get()
        try await authority.open(project: projectB, running: RunningGraph(revision: .initial, prepared: nil)).get()
        if canBootstrap && lifecycleA != .stopped {
            try await bootstrap(authority, engine: &engine, lifecycle: lifecycleA, recoveryBase: recoveryBase)
        }
        try await configureLease(authority, holding: window)
        return authority
    }

    private static func bootstrap(
        _ authority: HostAuthority, engine: inout ScriptedActivationEngine,
        lifecycle: EngineLifecycle?, recoveryBase: RunningSetState?
    ) async throws {
        _ = try await authority.acquire(project: projectA, window: windowA).get()
        try await authority.begin(request(), candidate: candidate(), project: projectA).get()
        await engine.drain(authority)
        let taken = try engine.requireNext()
        let answer = engine.prepare(taken, as: runningPlan)
        _ = try await authority.prepareAnswered(answer, instance: taken.instance, attempt: taken.attempt).get()
        let authorization = try await authority.authorize(project: projectA, gesture: gesture()).get()
        try await authority.commit(project: projectA, authorization: authorization).get()
        await engine.drain(authority)
        _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
        #expect(await authority.snapshot().queue.isEmpty)
        for capability in lostCapabilities(lifecycle, recoveryBase: recoveryBase) {
            try await authority.capabilityLost(capability, project: projectA,
                                                token: try await leaseToken(authority)).get()
        }
        if lifecycle == .recovering {
            try await authority.leaseLost(try await leaseToken(authority)).get()
        }
    }

    private static func lostCapabilities(
        _ lifecycle: EngineLifecycle?, recoveryBase: RunningSetState?
    ) -> [CapabilityID] {
        switch lifecycle {
        case .degraded(let lost): return lost
        case .recovering:
            if case .degraded(let lost)? = recoveryBase { return lost }
            return []
        default: return []
        }
    }

    private static func configureLease(_ authority: HostAuthority, holding window: WindowID?) async throws {
        if let window {
            if await authority.snapshot().lease == nil {
                _ = try await authority.acquire(project: projectA, window: window).get()
            } else if window != windowA, await authority.snapshot().lease?.windows.contains(windowA) == true {
                try await authority.release(project: projectA).get()
                _ = try await authority.acquire(project: projectA, window: window).get()
            }
        } else if await authority.snapshot().lease != nil {
            try await authority.release(project: projectA).get()
        }
    }

    /// Convenience only for tests that never hand engine work to a second double.
    static func makeAuthority(holding window: WindowID? = windowA,
                              lifecycleA: EngineLifecycle? = nil,
                              recoveryBaseA: RunningSetState? = nil) async throws -> HostAuthority {
        var engine = try ScriptedActivationEngine()
        return try await makeAuthority(&engine, holding: window, lifecycleA: lifecycleA,
                                       recoveryBaseA: recoveryBaseA)
    }

    static func begin(_ authority: HostAuthority, project: ProjectID = projectA,
                      withAux: Bool = false) async throws {
        let revision = try await state(authority, project).running.revision
        try await authority.begin(request(base: revision), candidate: candidate(withAux: withAux, revision: revision),
                                  project: project).get()
    }

    /// Begins `project`, drains the queue and routes the engine's success; returns the reviewed plan.
    static func review(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                       project: ProjectID = projectA, withAux: Bool = false) async throws -> PreparedActivationID {
        try await begin(authority, project: project, withAux: withAux)
        await engine.drain(authority)
        let answer = try #require(await engine.answerNext(authority))
        #expect(answer.verdict == .success(.routed))
        return try answer.answer.get()
    }

    /// Reviews `project`, authorizes from `window` and commits; the `.commit` stays queued.
    /// Returns the reviewed plan.
    static func commitQueued(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                             window: WindowID = windowA, project: ProjectID = projectA,
                             withAux: Bool = false) async throws -> PreparedActivationID {
        let reviewed = try await review(authority, &engine, project: project, withAux: withAux)
        let authorization = try await authority.authorize(project: project, gesture: gesture(window)).get()
        try await authority.commit(project: project, authorization: authorization).get()
        return reviewed
    }

    /// `commitQueued`, then drains so the engine takes (and holds) the `.commit`.
    static func commitDelivered(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                                project: ProjectID = projectA, window: WindowID = windowA,
                                withAux: Bool = false) async throws -> PreparedActivationID {
        let reviewed = try await commitQueued(authority, &engine, window: window, project: project, withAux: withAux)
        await engine.drain(authority)
        return reviewed
    }

    static func refusal<Success>(_ result: Result<Success, HostAuthorityRefusal>) -> HostAuthorityRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    static func state(_ authority: HostAuthority, _ project: ProjectID = projectA) async throws
    -> HostProjectSnapshot {
        try #require(await authority.snapshot().projects[project])
    }

    /// The project's last issued commit attempt.
    static func attempt(_ authority: HostAuthority, _ project: ProjectID = projectA) async throws
    -> CommitAttemptID {
        try #require(try await state(authority, project).lastCommitAttempt)
    }

    /// The engine context counter that lease changes bump.
    static func context(_ snapshot: HostAuthoritySnapshot) -> Generation? {
        snapshot.ledger[EngineLeaseRegistry.contextKey]
    }

    /// The current lease token (the one an involuntary `leaseLost` names).
    static func leaseToken(_ authority: HostAuthority) async throws -> EngineLeaseToken {
        try #require(await authority.snapshot().lease?.token)
    }

    /// Fills the command queue with `project`'s prepares, abandoning each.
    static func fillQueue(_ authority: HostAuthority, with project: ProjectID = projectB) async throws {
        while await authority.snapshot().queue.count < EngineCommandQueue.capacity {
            try await authority.begin(request(), candidate: candidate(), project: project).get()
            try await authority.abandonPrepare(project: project).get()
        }
    }
}
