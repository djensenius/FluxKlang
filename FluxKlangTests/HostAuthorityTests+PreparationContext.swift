import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench
private typealias Routing = AudioRoutingTestFixtures

private func contextRequest(_ graph: GraphDocument) -> ActivationRequest {
    ActivationRequest(draft: .init(validated: "draft.context"), graph: graph.id, baseRevision: graph.revision,
                      hostEpoch: Bench.hostEpoch, permission: Bench.permission,
                      digest: ActivationDigest(rawValue: "caller-supplied-opaque-digest"), origin: .human)
}

/// Real public authority, no fixture bootstrap or state injection. Stopped is the
/// ENGINE lifecycle; GenerationLedger is not a transport-state attestation.
private func contextAuthority(
    _ documents: Routing.Documents, capacity: Int = HostAuthority.planCapacity
) async throws -> HostAuthority {
    let ledger = try GenerationLedger(primaryClock: .init(validated: "smp.context"),
                                      musicalClock: nil, nominalRate: 48_000)
    let authority = try HostAuthority(host: ledger, live: Bench.liveState(), planCapacity: capacity)
    try await authority.open(project: documents.project.id,
                             running: RunningGraph(revision: documents.graph.revision, prepared: nil),
                             lifecycle: .stopped).get()
    return authority
}

private enum ContextDefect: CaseIterable, Sendable {
    case identity, formatBounds, structural, encoding, encoded, selectedRevision, missingRole

    func corrupt(_ documents: inout Routing.Documents) throws -> HostAuthorityRefusal {
        switch self {
        case .identity:
            let expected = documents.project.id
            documents.project.id = Bench.projectB
            documents.project.name = String(repeating: "x", count: 131_073)
            return .projectDocumentMismatch(expected: expected, found: Bench.projectB)
        case .formatBounds:
            documents.project.graphs = Array(repeating: documents.project.graphs[0],
                                             count: ProjectGraphLimits.projectRecords + 1)
            documents.project.name = String(repeating: "x", count: 131_073)
            return .preparationProject(.formatBounds(
                .exceeded(path: "$.graphs", maximum: ProjectGraphLimits.projectRecords)
            ))
        case .structural:
            documents.project.name = String(repeating: "x", count: 131_073)
            return .preparationProject(.structuralLimit)
        case .encoding:
            documents.project.unknownFields = ["nonfinite": .double(.infinity)]
            return .preparationProject(.encoding)
        case .encoded:
            documents.project.name = String(repeating: "\"", count: 33_000)
            return .preparationProject(.encodedLimit)
        case .selectedRevision:
            documents.project.graphs[0].revision = try documents.graph.revision.next()
            return .preparationProject(.selected(
                .graphNotSupplied(documents.graph.id, revision: documents.graph.revision)
            ))
        case .missingRole:
            let node = documents.graph.nodes[0]
            let role = try #require(node.role)
            documents.project.roles.removeAll { $0.id == role }
            return .preparationProject(.selected(.missingRole(documents.graph.id, node: node.id, role)))
        }
    }
}

private func completeContext() throws -> Routing.Documents {
    var documents = Routing.documents()
    documents.project.revision = try ContractRevision(99)
    let unrelated = GraphID(validated: "graph.unrelated")
    documents.project.graphs.append(ProjectGraphReference(graph: unrelated, revision: try ContractRevision(77)))
    documents.project.roles.append(ProjectRole(
        id: .init(validated: "role.unused"), label: "Unused", direction: .input, signal: .control
    ))
    documents.project.patches = [ProjectPatch(id: .init(validated: "patch.other"), label: "Other", graph: unrelated)]
    let asset = AssetID(validated: "asset.other")
    documents.project.assets = [ProjectAsset(
        id: asset, label: "Other", media: .audio, contentDigest: ProjectPreparationContextTests.digest,
        timePolicy: .fixedRate, timing: AssetTiming(startTicks: 0)
    )]
    documents.project.actions = [ProjectMediaAction(
        id: .init(validated: "action.other"), asset: asset,
        policy: try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .drop)
    )]
    documents.project.unknownFields = ["future": .array([.int(7)]), "name": .string("retained but elided")]
    documents.project.extensions = ["vendor": .string("音")]
    documents.project.graphs[0].unknownFields = ["pin": .bool(true)]
    documents.project.roles[0].unknownFields = ["role": .int(3)]
    documents.project.patches[0].unknownFields = ["patch": .null]
    documents.project.assets[0].unknownFields = ["asset": .uint(4)]
    documents.project.assets[0].timing?.unknownFields = ["timing": .double(0.5)]
    documents.project.actions[0].unknownFields = ["action": .bool(true)]
    documents.project.actions[0].policy.unknownFields = ["policy": .null]
    documents.graph.unknownFields = ["future": .array([.bool(true)])]
    documents.graph.extensions = ["vendor": .object(["kept": .int(1)])]
    documents.graph.nodes[0].unknownFields = ["node": .string("kept")]
    return documents
}

/// All processor and pointer ownership stays within this synchronous call.
/// Separate arrays are disjoint; channel stride is the admitted maxFrames (4),
/// not the two frames rendered. Only the delivered document/graph are compiled.
private func checkDeliveredRouting(graph: GraphDocument, project: ProjectDocument) throws {
    var processor = try OfflineAudioRoutingProcessor(
        project: project, selectedGraph: graph, limits: Routing.limits(frames: 4)
    )
    let input: [Float] = [0.5, -1, 99, 99, -2, 0.25, 99, 99]
    var output: [Float] = [-37, -37, -37, -37, -37, -37, -37, -37]
    var peaks: [Float] = [-1, -1]
    let result = input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            peaks.withUnsafeMutableBufferPointer { meters in
                processor.process(frames: 2, input: source, output: destination, peaks: meters)
            }
        }
    }
    #expect(result == .processed)
    #expect(output == [-1, -1.75, -37, -37, -4, 0.5, -37, -37])
    #expect(peaks == [1.75, 4])
}

extension HostAuthorityTests {
    struct PreparationContext {
        @Test(arguments: ContextDefect.allCases)
        fileprivate func typedRefusalsAreAtomicAndDoNotPublishAttempts(_ defect: ContextDefect) async throws {
            let documents = Routing.documents()
            let authority = try await contextAuthority(documents)
            var invalid = documents
            let expected = try defect.corrupt(&invalid)
            var generation = Generation.initial
            // Repeat after an accepted/abandoned admission as well as before the first.
            for _ in 0..<2 {
                let before = await authority.snapshot()
                let result = await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                                   projectDocument: invalid.project, project: documents.project.id)
                #expect(Bench.refusal(result) == expected)
                #expect(await authority.snapshot() == before)
                try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                          projectDocument: documents.project, project: documents.project.id).get()
                let admitted = await authority.snapshot()
                let preparation = try #require(admitted.outstanding[documents.project.id])
                #expect(preparation.attempt.generation == generation)
                #expect(admitted.projects[documents.project.id]?.lastPrepareAttempt == preparation.attempt)
                try await authority.abandonPrepare(project: documents.project.id).get()
                generation = try generation.next()
            }
        }

        @Test func busyAndFullQueuePrecedeInvalidProject() async throws {
            let documents = Routing.documents()
            let authority = try await contextAuthority(documents, capacity: EngineCommandQueue.capacity + 1)
            var invalid = documents
            _ = try ContextDefect.identity.corrupt(&invalid)
            try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                      projectDocument: documents.project, project: documents.project.id).get()
            let busy = await authority.snapshot()
            #expect(Bench.refusal(await authority.begin(
                contextRequest(documents.graph), candidate: documents.graph,
                projectDocument: invalid.project, project: documents.project.id
            )) == .activation(.busy))
            #expect(await authority.snapshot() == busy)
            try await authority.abandonPrepare(project: documents.project.id).get()
            for _ in 1..<EngineCommandQueue.capacity {
                try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                          projectDocument: documents.project, project: documents.project.id).get()
                try await authority.abandonPrepare(project: documents.project.id).get()
            }
            let full = await authority.snapshot()
            #expect(full.queue.count == EngineCommandQueue.capacity)
            #expect(Bench.refusal(await authority.begin(
                contextRequest(documents.graph), candidate: documents.graph,
                projectDocument: invalid.project, project: documents.project.id
            )) == .queueFull)
            #expect(await authority.snapshot() == full)
        }

        @Test func projectGatePrecedesCanonicalCapacityAndBothRefuseAtomically() async throws {
            let documents = Routing.documents()
            let authority = try await contextAuthority(documents, capacity: 1)
            try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                      projectDocument: documents.project, project: documents.project.id).get()
            try await authority.abandonPrepare(project: documents.project.id).get()
            let full = await authority.snapshot()
            var invalid = documents
            let expected = try ContextDefect.structural.corrupt(&invalid)
            #expect(Bench.refusal(await authority.begin(
                contextRequest(documents.graph), candidate: documents.graph,
                projectDocument: invalid.project, project: documents.project.id
            )) == expected)
            #expect(await authority.snapshot() == full)
            #expect(Bench.refusal(await authority.begin(
                contextRequest(documents.graph), candidate: documents.graph,
                projectDocument: documents.project, project: documents.project.id
            )) == .plans(.capacityReached))
            #expect(await authority.snapshot() == full)
        }

        @Test func completeSnapshotsSurviveCallerMutationAndKeepCanonicalBinding() async throws {
            var documents = try completeContext()
            let original = documents
            let graphBytes = try original.graph.encoded()
            let projectBytes = try original.project.encoded()
            let authority = try await contextAuthority(documents)
            try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                      projectDocument: documents.project, project: documents.project.id).get()
            let admitted = await authority.snapshot()
            let preparation = try #require(admitted.outstanding[original.project.id])
            documents.graph.label = "Changed graph"
            documents.graph.nodes[0].label = "Changed node"
            documents.graph.unknownFields = [:]
            documents.graph.extensions = nil
            documents.project.name = "Changed project"
            documents.project.graphs.removeAll()
            documents.project.roles.removeAll()
            documents.project.unknownFields = [:]
            documents.project.extensions = nil
            #expect(await authority.snapshot() == admitted)
            let command = try #require(await authority.nextEngineCommand())
            guard case .prepare(let graph, let project, let instance, let attempt) = command else {
                Issue.record("Expected complete preparation")
                return
            }
            #expect(graph == original.graph && project == original.project)
            #expect(try graph.encoded() == graphBytes)
            #expect(try project.encoded() == projectBytes)
            #expect(HostPrepare(instance: instance, attempt: attempt) == preparation)
            #expect(instance == admitted.plans.currentInstance)
            let record = try #require(admitted.plans.records.first { $0.instance == instance })
            #expect(record.entries == [.init(attempt: attempt, state: .pending(reclaim: false))])
            #expect(admitted.projects[original.project.id]?.lastPrepareAttempt == attempt)
            // No unrelated graph body was supplied; the complete declaration survived.
            #expect(project.graphs.count == 2 && project.patches[0].graph == project.graphs[1].graph)
        }

        @Test func abandonedFIFOAssociatesEachDocumentWithItsOwnGraphAndAttempt() async throws {
            let first = Routing.documents()
            var second = Routing.documents(map: [[1], [0]])
            second.graph.id = .init(validated: "graph.second")
            second.project.graphs[0].graph = second.graph.id
            second.project.name = "Second"
            let authority = try await contextAuthority(first)
            var preparations: [HostPrepare] = []
            for documents in [first, second] {
                try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                          projectDocument: documents.project, project: documents.project.id).get()
                preparations.append(try #require(await authority.snapshot().outstanding[documents.project.id]))
                try await authority.abandonPrepare(project: documents.project.id).get()
            }
            #expect(preparations[0].attempt != preparations[1].attempt)
            #expect(preparations[1].attempt.generation == (try preparations[0].attempt.generation.next()))
            let before = await authority.snapshot()
            for (documents, preparation) in zip([first, second], preparations) {
                #expect(await authority.nextEngineCommand() == .prepare(
                    documents.graph, documents.project, preparation.instance, preparation.attempt
                ))
            }
            #expect(await authority.nextEngineCommand() == nil)
            #expect(await authority.snapshot().plans == before.plans)
            #expect(before.plans.records[0].entries.map(\.state) == [
                .pending(reclaim: true), .pending(reclaim: true)
            ])
        }

        @Test func bookStagesContextWithoutRebindingCallerDigest() throws {
            let documents = Routing.documents()
            let ledger = try GenerationLedger(primaryClock: .init(validated: "smp.context.book"),
                                              musicalClock: nil, nominalRate: 48_000)
            var book = try HostAuthorityBook(host: ledger, live: Bench.liveState())
            try book.open(project: documents.project.id,
                          running: RunningGraph(revision: documents.graph.revision, prepared: nil)).get()
            let request = contextRequest(documents.graph)
            var invalid = documents
            let expected = try ContextDefect.selectedRevision.corrupt(&invalid)
            let before = book.snapshot()
            #expect(Bench.refusal(book.begin(
                request, candidate: documents.graph, projectDocument: invalid.project, project: documents.project.id
            )) == expected)
            #expect(book.snapshot() == before)
            try book.begin(request, candidate: documents.graph,
                           projectDocument: documents.project, project: documents.project.id).get()
            #expect(book.projects[documents.project.id]?.transaction.validated?.request == request)
            let preparation = try #require(book.outstanding[documents.project.id])
            #expect(preparation.attempt.generation == .initial)
            #expect(book.nextEngineCommand() == .prepare(
                documents.graph, documents.project, preparation.instance, preparation.attempt
            ))
        }

        @Test func realDeliveredPairCompilesAndProcessesWithoutCompletingPreparation() async throws {
            let documents = Routing.documents(map: [[0, 1, 0], [1, 1]])
            let authority = try await contextAuthority(documents)
            let opened = await authority.snapshot()
            #expect(opened.projects[documents.project.id]?.lifecycle == .stopped)
            #expect(opened.projects[documents.project.id]?.running.prepared == nil)
            #expect(opened.plans.records[0].entries.isEmpty)
            try await authority.begin(contextRequest(documents.graph), candidate: documents.graph,
                                      projectDocument: documents.project, project: documents.project.id).get()
            let admitted = await authority.snapshot()
            let command = try #require(await authority.nextEngineCommand())
            guard case .prepare(let graph, let project, let instance, let attempt) = command else {
                Issue.record("Expected real delivered preparation")
                return
            }
            #expect(graph == documents.graph && project == documents.project)
            #expect(admitted.outstanding[project.id] == HostPrepare(instance: instance, attempt: attempt))
            #expect(instance == admitted.plans.currentInstance)
            #expect(admitted.plans.records[0].entries == [
                .init(attempt: attempt, state: .pending(reclaim: false))
            ])
            let pending = await authority.snapshot()
            try checkDeliveredRouting(graph: graph, project: project)
            let after = await authority.snapshot()
            #expect(after == pending)
            let state = try #require(after.projects[project.id])
            #expect(state.phase == .preparing)
            #expect(state.lifecycle == .preparing(try graph.revision.next(), over: .absent))
            #expect(state.installed == nil && state.reviewed == nil && state.running.prepared == nil)
            #expect(after.outstanding[project.id] == HostPrepare(instance: instance, attempt: attempt))
            #expect(after.plans == admitted.plans && after.queue.isEmpty)
            // Pure compatibility only: no ACK, commit, retirement, quiescence or backend custody.
        }
    }
}
