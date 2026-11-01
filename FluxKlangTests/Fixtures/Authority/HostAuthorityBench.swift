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
    static func candidate(withAux: Bool = false) -> GraphDocument {
        let out = GraphNode(id: nodeOut, kind: .plugin, label: "Out", requiredCapabilities: [audio])
        let aux = GraphNode(id: nodeAux, kind: .plugin, label: "Aux", requiredCapabilities: [audio])
        return GraphDocument(id: graphID, revision: .initial,
                             capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
                             nodes: withAux ? [out, aux] : [out])
    }

    static func request() -> ActivationRequest {
        ActivationRequest(draft: DraftID(validated: "draft.main"), graph: graphID, baseRevision: .initial,
                          hostEpoch: hostEpoch, permission: permission,
                          digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human)
    }

    static func gesture(_ window: WindowID = windowA, origin: CommandOrigin = .human) -> ActivationGesture {
        ActivationGesture(origin: origin, window: window)
    }

    /// Opens A (with `lifecycleA`) and B; A acquires the lease on `window` unless it is nil.
    static func makeAuthority(holding window: WindowID? = windowA,
                              lifecycleA: EngineLifecycle? = nil,
                              recoveryBaseA: RunningSetState? = nil) async throws -> HostAuthority {
        let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.main"), musicalClock: nil,
                                          nominalRate: 48_000)
        let authority = try HostAuthority(host: ledger, live: try liveState())
        try await authority.open(project: projectA, running: RunningGraph(revision: .initial, prepared: runningPlan),
                                 lifecycle: lifecycleA, recoveryBase: recoveryBaseA).get()
        try await authority.open(project: projectB, running: RunningGraph(revision: .initial, prepared: nil)).get()
        if let window { _ = try await authority.acquire(project: projectA, window: window).get() }
        return authority
    }

    /// Begins `project`, drains the queue and routes the engine's success; returns the reviewed plan.
    static func review(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine,
                       project: ProjectID = projectA, withAux: Bool = false) async throws -> PreparedActivationID {
        try await authority.begin(request(), candidate: candidate(withAux: withAux), project: project).get()
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
