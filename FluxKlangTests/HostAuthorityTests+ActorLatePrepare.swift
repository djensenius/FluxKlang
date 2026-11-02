import Testing
@testable import FluxKlang

private let host = HostID(validated: "host.late")
private let hostEpoch = HostEpoch(host: host, generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let graphID = GraphID(validated: "graph.main")
private let audio = CapabilityID(validated: "cap.audio")
private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let projectC = ProjectID(validated: "prj.c")
private let runningPlan = PreparedActivationID(validated: "prep.running")
private let reused = PreparedActivationID(validated: "prep.reused")
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

private func begin(_ authority: HostAuthority, _ project: ProjectID) async -> Result<Void, HostAuthorityRefusal> {
    let request = ActivationRequest(draft: DraftID(validated: "draft.main"), graph: graphID, baseRevision: .initial,
                                    hostEpoch: hostEpoch, permission: permission,
                                    digest: ActivationDigest(rawValue: "sha256:activation"), origin: .human)
    let candidate = GraphDocument(id: graphID, revision: .initial,
                                  capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
                                  nodes: [GraphNode(id: node, kind: .plugin, label: "Out",
                                                    requiredCapabilities: [audio])])
    return await authority.begin(request, candidate: candidate, project: project)
}

/// Project A runs `prep.running`; project B runs nothing.
private func makeAuthority() async throws -> HostAuthority {
    let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.main"), musicalClock: nil,
                                      nominalRate: 48_000)
    let authority = try HostAuthority(host: ledger, live: try liveState())
    try await authority.open(project: projectA, running: RunningGraph(revision: .initial, prepared: runningPlan)).get()
    try await authority.open(project: projectB, running: RunningGraph(revision: .initial, prepared: nil)).get()
    return authority
}

private func refusal<Success>(_ result: Result<Success, HostAuthorityRefusal>) -> HostAuthorityRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

/// The queue holds no `.discard` at all.
private func noDiscardQueued(_ snapshot: HostAuthoritySnapshot) -> Bool {
    !snapshot.queue.pending.contains { if case .discard = $0 { true } else { false } }
}

/// Project A's prepare, taken by the engine and prepared as `reused`, then abandoned
/// by the actor; the engine later lets that plan go, freeing `reused`. Returns the
/// abandoned attempt and its late, still undelivered, success.
private func abandonPreparedAsReused(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine)
async throws -> (PrepareAttemptID, Result<PreparedActivationID, PrepareFailure>) {
    try await begin(authority, projectA).get()
    await engine.drain(authority)
    let taken = engine.withholdNext()
    let old = try #require(taken)
    let late = engine.prepare(old, as: reused)
    try await authority.abandonPrepare(project: projectA).get()
    engine.release(old)
    return (old, late)
}

/// The exact late outcome: a live reused ID is dropped; otherwise it is unreclaimed, refused by the
/// abandoned project's phase (preparing a newer attempt, or idle when the reuse is cross-project).
private func expectedLateOutcome(_ reuse: LatePrepareReuse, _ order: LatePrepareOrder)
-> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
    if order == .newerFirst { return .success(.dropped) }
    let refusal: ActivationRefusal = reuse == .sameProject ? .stalePrepareResponse : .unexpectedPhase(.idle)
    return .success(.unreclaimed(reused, refusal: refusal))
}

/// Which project's newer prepare the engine answers with the reused ID.
enum LatePrepareReuse: CaseIterable, Sendable {
    case sameProject, crossProject
}

/// The order the abandoned attempt's late answer and the newer answer reach the actor.
enum LatePrepareOrder: CaseIterable, Sendable {
    /// The late answer first, while the newer answer is outstanding.
    case lateFirst
    /// The late answer first, and the engine takes the queue before the newer answer.
    case lateFirstThenDrain
    /// The newer answer first: the reused ID is in review when the late answer arrives.
    case newerFirst
}

extension HostAuthorityTests {
    /// #191: a late success for an abandoned prepare names only a bare ID, which
    /// the engine may have reused; the actor never disposes of a plan from it.
    struct ActorLatePrepare {
        @Test(arguments: LatePrepareReuse.allCases, LatePrepareOrder.allCases)
        func lateSuccessNeverDisposesAReusedID(_ reuse: LatePrepareReuse, _ order: LatePrepareOrder) async throws {
            let authority = try await makeAuthority()
            var engine = try ScriptedActivationEngine()
            let (old, late) = try await abandonPreparedAsReused(authority, &engine)
            let project = reuse == .sameProject ? projectA : projectB
            try await begin(authority, project).get()
            await engine.drain(authority)
            let taken = engine.withholdNext()
            let newer = try #require(taken)
            let current = engine.prepare(newer, as: reused)
            if order == .newerFirst {
                #expect(await authority.prepareAnswered(current, attempt: newer) == .success(.routed))
            }
            let before = await authority.snapshot()
            let verdict = await authority.prepareAnswered(late, attempt: old)
            let after = await authority.snapshot()
            // Handled once, without a transaction, a queue slot or a discard.
            #expect(verdict == expectedLateOutcome(reuse, order))
            #expect(after.projects == before.projects && after.outstanding == before.outstanding)
            #expect(after.queue == before.queue && noDiscardQueued(after))
            #expect(after.abandoned == before.abandoned.filter { $0.attempt != old })
            #expect(after.ledger == before.ledger && after.lease == before.lease)
            let duplicate = await authority.prepareAnswered(late, attempt: old)
            #expect(refusal(duplicate) == .activation(.stalePrepareResponse))
            #expect(await authority.snapshot() == after)
            if order == .lateFirstThenDrain { await engine.drain(authority) }
            if order != .newerFirst {
                #expect(await authority.prepareAnswered(current, attempt: newer) == .success(.routed))
            }
            // The newer plan is still held by the engine and in review: nothing disposed of it.
            await engine.drain(authority)
            #expect(engine.discarded.isEmpty && engine.disposed.isEmpty)
            #expect(engine.held == [ScriptedHeldPlan(id: reused, attempt: newer)])
            let reviewing = try #require(await authority.snapshot().projects[project])
            #expect(reviewing.phase == .awaitingReview && reviewing.reviewed == reused)
        }

        @Test func lateSuccessNeverPoisonsALaterOpen() async throws {
            let authority = try await makeAuthority()
            var engine = try ScriptedActivationEngine()
            let (old, late) = try await abandonPreparedAsReused(authority, &engine)
            #expect(refusal(await authority.prepareAnswered(late, attempt: old)) == nil)
            #expect(noDiscardQueued(await authority.snapshot()))
            // Another project may run the reused ID: nothing queued would destroy it.
            let running = RunningGraph(revision: .initial, prepared: reused)
            try await authority.open(project: projectC, running: running).get()
            await engine.drain(authority)
            #expect(engine.discarded.isEmpty)
            #expect(await authority.snapshot().projects[projectC]?.running == running)
        }

        @Test func lateSuccessNeverNeedsQueueRoom() async throws {
            let authority = try await makeAuthority()
            var newest: PrepareAttemptID?
            while await authority.snapshot().queue.count < EngineCommandQueue.capacity {
                try await begin(authority, projectA).get()
                newest = await authority.snapshot().projects[projectA]?.lastPrepareAttempt
                try await authority.abandonPrepare(project: projectA).get()
            }
            let attempt = try #require(newest)
            let full = await authority.snapshot()
            // Never `.queueFull`: the answer is handled now, and never needs re-delivery.
            let verdict = await authority.prepareAnswered(.success(reused), attempt: attempt)
            #expect(refusal(verdict) == nil)
            let after = await authority.snapshot()
            #expect(after.queue == full.queue && after.projects == full.projects)
            #expect(after.abandoned == full.abandoned.filter { $0.attempt != attempt })
        }
    }
}
