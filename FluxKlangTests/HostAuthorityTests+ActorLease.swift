import Testing
@testable import FluxKlang

private let host = HostID(validated: "host.lease")
private let hostEpoch = HostEpoch(host: host, generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let graphID = GraphID(validated: "graph.main")
private let audio = CapabilityID(validated: "cap.audio")
private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let projectC = ProjectID(validated: "prj.c")
private let runningPlan = PreparedActivationID(validated: "prep.running")
private let windowA = WindowID(validated: "win.a")
private let windowA2 = WindowID(validated: "win.a2")
private let windowB = WindowID(validated: "win.b")
private let node = NodeID(validated: "node.out")

private func liveState() throws -> HostLiveState {
    let device = try DeviceDescriptor(
        id: DeviceID(validated: "dev.interface"), kind: .audioInterface,
        layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: .reported,
        identity: DeviceIdentity(.init(uid: "physical-interface-1", evidence: [.deviceUID])),
        presence: .present, capabilities: [audio]
    )
    let document = try DeviceCapabilityDocument(revision: .initial, host: host, hostEpoch: hostEpoch.generation,
                                                devices: [device], routes: [])
    return HostLiveState(hostEpoch: hostEpoch, permission: permission, capabilities: document)
}

private func request() -> ActivationRequest {
    ActivationRequest(draft: DraftID(validated: "draft.main"), graph: graphID, baseRevision: .initial,
                      hostEpoch: hostEpoch, permission: permission,
                      digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human)
}

private func candidate() -> GraphDocument {
    GraphDocument(id: graphID, revision: .initial, capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
                  nodes: [GraphNode(id: node, kind: .plugin, label: "Out", requiredCapabilities: [audio])])
}

/// Project A runs `prep.running` (opened with `lifecycleA`); project B runs nothing.
private func makeAuthority(_ lifecycleA: EngineLifecycle? = nil,
                           recoveryBaseA: RunningSetState? = nil) async throws -> HostAuthority {
    let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.main"), musicalClock: nil,
                                      nominalRate: 48_000)
    let authority = try HostAuthority(host: ledger, live: try liveState())
    try await authority.open(project: projectA, running: RunningGraph(revision: .initial, prepared: runningPlan),
                             lifecycle: lifecycleA, recoveryBase: recoveryBaseA).get()
    try await authority.open(project: projectB, running: RunningGraph(revision: .initial, prepared: nil)).get()
    return authority
}

private func refusal<Success>(_ result: Result<Success, HostAuthorityRefusal>) -> HostAuthorityRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

/// The engine context counter every lease grant bumps.
private func context(_ authority: HostAuthority) async -> Generation? {
    await authority.snapshot().ledger[EngineLeaseRegistry.contextKey]
}

/// Begins project A and routes the engine's success; returns the reviewed plan.
private func review(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine) async throws
-> PreparedActivationID {
    try await authority.begin(request(), candidate: candidate(), project: projectA).get()
    await engine.drain(authority)
    let answer = try #require(await engine.answerNext(authority))
    #expect(answer.verdict == .success(.routed))
    return try answer.answer.get()
}

extension HostAuthorityTests {
    struct ActorLease {
        @Test func acquireBumpsContextExactlyOnce() async throws {
            let authority = try await makeAuthority()
            let before = try #require(await context(authority))
            let held = try await authority.acquire(project: projectA, window: windowA).get()
            let after = await authority.snapshot()
            #expect(held.project == projectA && held.windows == [windowA])
            #expect(after.lease == held && after.lastIssuedLease == .initial)
            #expect(after.ledger[EngineLeaseRegistry.contextKey] == (try before.next()))
        }

        @Test func attachAndDetachNeverBumpContext() async throws {
            let authority = try await makeAuthority()
            let held = try await authority.acquire(project: projectA, window: windowA).get()
            let granted = await context(authority)
            let attached = try await authority.attach(windowA2, project: projectA).get()
            #expect(attached.token == held.token && attached.windows == [windowA, windowA2])
            #expect(await context(authority) == granted)
            let detached = try await authority.detach(windowA).get()
            #expect(detached.token == held.token && detached.windows == [windowA2])
            #expect(await context(authority) == granted)
            // Detaching the last window keeps the lease, still without a bump.
            let empty = try await authority.detach(windowA2).get()
            #expect(empty.token == held.token && empty.windows.isEmpty && empty.project == projectA)
            #expect(await context(authority) == granted)
            #expect(await authority.snapshot().lastIssuedLease == .initial)
        }

        @Test func leaseRefusalsChangeNothing() async throws {
            let unheld = try await makeAuthority()
            let idle = await unheld.snapshot()
            #expect(refusal(await unheld.attach(windowA, project: projectA)) == .lease(.notHeld))
            #expect(refusal(await unheld.detach(windowA)) == .lease(.notHeld))
            #expect(refusal(await unheld.acquire(project: projectC, window: windowA)) == .unknownProject(projectC))
            #expect(await unheld.snapshot() == idle)

            let authority = try await makeAuthority()
            try await authority.acquire(project: projectA, window: windowA).get()
            let held = await authority.snapshot()
            let refusals: [(HostAuthorityRefusal?, HostAuthorityRefusal)] = [
                (refusal(await authority.acquire(project: projectA, window: windowA2)), .lease(.alreadyHeld)),
                (refusal(await authority.acquire(project: projectB, window: windowB)),
                 .lease(.heldByOtherProject(projectA))),
                (refusal(await authority.acquire(project: projectC, window: windowB)), .unknownProject(projectC)),
                (refusal(await authority.attach(windowB, project: projectB)), .lease(.heldByOtherProject(projectA))),
                (refusal(await authority.attach(windowA, project: projectA)), .lease(.alreadyAttached)),
                (refusal(await authority.detach(windowB)), .lease(.unknownWindow))
            ]
            for (actual, expected) in refusals { #expect(actual == expected) }
            #expect(await authority.snapshot() == held)
        }

        @Test func attachRefusedAtTheWindowLimit() async throws {
            let authority = try await makeAuthority()
            try await authority.acquire(project: projectA, window: windowA).get()
            for index in 1..<EngineLeaseRegistry.windowLimit {
                try await authority.attach(try WindowID("win.extra.\(index)"), project: projectA).get()
            }
            let full = await authority.snapshot()
            #expect(full.lease?.windows.count == EngineLeaseRegistry.windowLimit)
            #expect(refusal(await authority.attach(windowA2, project: projectA)) == .lease(.windowLimit))
            #expect(await authority.snapshot() == full)
        }

        @Test func onlyLeasedWindowsSeeTheRenderingLifecycle() async throws {
            let authority = try await makeAuthority()
            // No holder: nothing renders.
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .stopped)
            #expect(await authority.lifecycle(of: projectB, window: windowB) == .stopped)
            #expect(await authority.lifecycle(of: projectC, window: windowA) == nil)
            try await authority.acquire(project: projectA, window: windowA).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .running)
            // The holder's window off the lease, and other projects' windows, do not render.
            #expect(await authority.lifecycle(of: projectA, window: windowA2) == .heldByOther(projectA))
            #expect(await authority.lifecycle(of: projectB, window: windowB) == .heldByOther(projectA))
            #expect(await authority.lifecycle(of: projectB, window: windowA) == .heldByOther(projectA))
            try await authority.attach(windowA2, project: projectA).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA2) == .running)
            try await authority.detach(windowA).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .heldByOther(projectA))
            #expect(await authority.lifecycle(of: projectA, window: windowA2) == .running)
        }

        @Test func recoveringHolderStaysRecoveringOffTheLease() async throws {
            let authority = try await makeAuthority(.recovering, recoveryBaseA: .running)
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .recovering)
            try await authority.acquire(project: projectA, window: windowA).get()
            #expect(await authority.lifecycle(of: projectA, window: windowA) == .recovering)
            #expect(await authority.lifecycle(of: projectA, window: windowA2) == .recovering)
            #expect(await authority.lifecycle(of: projectB, window: windowB) == .heldByOther(projectA))
        }
    }

    struct ActorOpen {
        @Test func openRefusesAnotherProjectsRunningPlan() async throws {
            let authority = try await makeAuthority()
            let before = await authority.snapshot()
            let opened = await authority.open(project: projectC,
                                              running: RunningGraph(revision: .initial, prepared: runningPlan))
            #expect(refusal(opened) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
        }

        @Test func openRefusesAnotherProjectsReviewedPlan() async throws {
            let authority = try await makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await review(authority, &engine)
            let before = await authority.snapshot()
            let opened = await authority.open(project: projectC,
                                              running: RunningGraph(revision: .initial, prepared: reviewed))
            #expect(refusal(opened) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
        }

        @Test func openRefusesAPlanWhoseDiscardIsQueued() async throws {
            let authority = try await makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await review(authority, &engine)
            try await authority.cancel(project: projectA).get()
            let before = await authority.snapshot()
            #expect(before.queue.pending == [.discard(reviewed)])
            let running = RunningGraph(revision: .initial, prepared: reviewed)
            #expect(refusal(await authority.open(project: projectC, running: running)) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
            // Once the engine has taken the discard, the ID is free again.
            #expect(await engine.drain(authority) == [.discard(reviewed)])
            try await authority.open(project: projectC, running: running).get()
            #expect(await authority.snapshot().projects[projectC]?.running == running)
        }
    }
}
