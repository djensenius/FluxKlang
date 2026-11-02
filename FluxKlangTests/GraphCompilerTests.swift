import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct GraphCompilerTests {
    private typealias Fixtures = AudioRoutingTestFixtures
    private typealias Mutation = (inout Fixtures.Documents) -> Void

    @Test func pinnedSelectedContextRejectsStaleMissingAndDuplicateRecords() throws {
        let stale = try ContractRevision(1)
        let mutations: [Mutation] = [
            { $0.project.graphs[0].revision = stale },
            { $0.project.graphs = [] },
            { $0.project.graphs.append($0.project.graphs[0]) },
            { $0.project.roles.append($0.project.roles[0]) },
            { $0.project.roles[0].direction = .output },
            { $0.project.roles[0].channels = 1 },
            { $0.project.roles.removeFirst() },
            { $0.graph.nodes[0].role = nil },
            { $0.graph.nodes[0].ports[0].direction = .input },
            { $0.graph.nodes[0].ports = [] },
            { $0.graph.nodes[0].ports.append($0.graph.nodes[0].ports[0]) }
        ]
        for mutate in mutations {
            var documents = Fixtures.documents()
            mutate(&documents)
            #expect(throws: AudioRoutingPreparationError.self) { try Fixtures.compile(documents) }
        }
    }

    @Test func unrelatedReferencesAreNotWholeProjectValidation() throws {
        var documents = Fixtures.documents()
        let unrelated = ProjectGraphReference(graph: GraphID(validated: "graph.unsupplied"), revision: .initial)
        documents.project.graphs.append(unrelated)
        let plan = try Fixtures.compile(documents)
        #expect(plan.layout.graph == documents.graph.id)
        #expect(plan.layout.inputs.count == 1)
        #expect(throws: ProjectValidationError.graphNotSupplied(unrelated.graph, revision: .initial)) {
            try documents.project.validate(graphs: [documents.graph], strict: true)
        }
        documents.project.graphs.append(unrelated)
        #expect(throws: AudioRoutingPreparationError.contractFailure(.duplicateGraph(unrelated.graph))) {
            try Fixtures.compile(documents)
        }
        documents.project.graphs.removeLast()
        documents.project.graphs[1].extensions = ["future": .bool(true)]
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.project.graphs[1].extensions = nil
        documents.project.graphs[1].unknownFields = ["future": .bool(true)]
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
    }

    @Test func rejectsEveryUnsupportedKindEvenDisconnected() {
        for kind in NodeKind.allCases where kind != .roleInput && kind != .roleOutput {
            var documents = Fixtures.documents()
            documents.graph.nodes.append(GraphNode(
                id: NodeID(validated: "node.disconnected"), kind: kind, label: "Not executable"
            ))
            #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        }
    }

    @Test func rejectsUnsupportedSemanticsAndInvalidContracts() {
        let mutations: [Mutation] = [
            { $0.graph.nodes[0].asset = AssetID(validated: "asset.extra") },
            { $0.graph.nodes[0].graph = GraphID(validated: "graph.extra") },
            { $0.graph.nodes[0].ports[0].signal = .midi },
            { $0.graph.nodes[0].ports[0].channels = nil },
            { $0.graph.nodes[0].ports[0].channels = 65 },
            { $0.graph.edges[0].feedback = EdgeFeedback(gainCeilingDb: -3) },
            { $0.graph.edges[0].from.port = PortID(validated: "missing") },
            { $0.graph.edges[0].to.node = NodeID(validated: "missing") },
            { $0.graph.edges[0].to = $0.graph.edges[0].from },
            { $0.graph.requiresReview = true },
            { $0.graph.nodes[0].position = GraphPoint(x: .infinity, y: 0) },
            { $0.graph.nodes[0].position = GraphPoint(x: 0, y: .nan) },
            { $0.graph.nodes.append($0.graph.nodes[0]) },
            { $0.graph.edges.append($0.graph.edges[0]) },
            { $0.graph.nodes[1].ports[0].channels = 1 },
            { $0.graph.edges[0].conversion = EdgeConversion(map: [[], []]) },
            { $0.graph.edges[0].conversion = EdgeConversion(map: []) },
            { $0.graph.edges[0].conversion = EdgeConversion(map: [[0]]) },
            { $0.graph.edges[0].conversion = EdgeConversion(map: [[-1], [0]]) },
            { $0.graph.edges[0].conversion = EdgeConversion(map: [[0], [2]]) },
            { $0.project.patches = [ProjectPatch(
                id: PatchID(validated: "patch.extra"), label: "Extra", graph: $0.graph.id
            )] },
            { $0.project.assets = [ProjectAsset(
                id: AssetID(validated: "asset.extra"), label: "Extra", media: .document,
                contentDigest: "sha256:" + String(repeating: "a", count: 64)
            )] }
        ]
        for mutate in mutations {
            var documents = Fixtures.documents()
            mutate(&documents)
            #expect(throws: AudioRoutingPreparationError.self) { try Fixtures.compile(documents) }
        }
    }

    @Test func repeatedBindingsAndAmbiguousFaninAreRejected() throws {
        var documents = Fixtures.documents()
        try Fixtures.appendEndpoint(to: &documents, input: true, suffix: "second")
        var edge = documents.graph.edges[0]
        edge.id = EdgeID(validated: "edge.second")
        edge.from.node = documents.graph.nodes[2].id
        documents.graph.edges.append(edge)
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.graph.edges.removeLast()
        documents.graph.nodes[2].role = documents.graph.nodes[0].role
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
    }

    @Test func actionsAndUnusedRoleDriftAreRejected() throws {
        var documents = Fixtures.documents()
        documents.project.actions = [ProjectMediaAction(
            id: ActionID(validated: "action.extra"), asset: AssetID(validated: "asset.extra"),
            policy: try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .drop)
        )]
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.project.actions = []
        var unused = ProjectRole(
            id: RoleID(validated: "role.unused"), label: "Unused", direction: .input, signal: .audio, channels: 1
        )
        unused.unknownFields = ["future": .bool(true)]
        documents.project.roles.append(unused)
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.project.roles[2].unknownFields = [:]
        documents.project.roles[2].extensions = ["future": .bool(true)]
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.project.roles[2].extensions = nil
        documents.project.roles[2].channels = 0
        #expect(throws: AudioRoutingPreparationError.contractFailure(.invalidRoleChannels(unused.id))) {
            try Fixtures.compile(documents)
        }
    }

    @Test func capabilitiesAreNotOpcodesOrHostSupport() throws {
        var documents = Fixtures.documents()
        let definition = CapabilityDefinition(id: CapabilityID(validated: "cap.gain"), label: "Gain 0 dB")
        documents.graph.capabilities = [definition]
        #expect(try Fixtures.compile(documents).terms == [0, 16])
        documents.graph.nodes[0].requiredCapabilities = [definition.id]
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.graph.nodes[0].requiredCapabilities = []
        documents.graph.nodes[0].advisoryCapabilities = [definition.id]
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents.graph.nodes[0].advisoryCapabilities = []
        documents.graph.capabilities.append(definition)
        #expect(throws: AudioRoutingPreparationError.self) { try Fixtures.compile(documents) }
    }

    @Test func rejectsUnknownFieldsAndExtensionBagsThroughoutCheckedContext() {
        let bag: [String: JSONValue] = ["future": .bool(true)]
        let mutations: [Mutation] = [
            { $0.project.unknownFields = bag }, { $0.project.extensions = bag },
            { $0.project.graphs[0].unknownFields = bag }, { $0.project.graphs[0].extensions = bag },
            { $0.project.roles[0].unknownFields = bag }, { $0.project.roles[0].extensions = bag },
            { $0.graph.unknownFields = bag }, { $0.graph.extensions = bag },
            { $0.graph.capabilities[0].unknownFields = bag }, { $0.graph.capabilities[0].extensions = bag },
            { $0.graph.nodes[0].unknownFields = bag }, { $0.graph.nodes[0].extensions = bag },
            { $0.graph.nodes[0].ports[0].unknownFields = bag }, { $0.graph.nodes[0].ports[0].extensions = bag },
            { $0.graph.nodes[0].position?.unknownFields = bag },
            { $0.graph.nodes[0].position?.extensions = bag },
            { $0.graph.edges[0].unknownFields = bag }, { $0.graph.edges[0].extensions = bag },
            { $0.graph.edges[0].from.unknownFields = bag }, { $0.graph.edges[0].from.extensions = bag },
            { $0.graph.edges[0].to.unknownFields = bag }, { $0.graph.edges[0].to.extensions = bag },
            { $0.graph.edges[0].conversion?.unknownFields = bag },
            { $0.graph.edges[0].conversion?.extensions = bag }
        ]
        for mutate in mutations {
            var documents = Fixtures.documents(map: [[0], [1]])
            documents.graph.capabilities = [
                CapabilityDefinition(id: CapabilityID(validated: "cap.unused"), label: "Unused")
            ]
            documents.graph.nodes[0].position = GraphPoint(x: 2, y: 3)
            mutate(&documents)
            #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        }
    }

    @Test func presentationDocumentOrderAndEmptyBagsAreInert() throws {
        var documents = Fixtures.documents(map: [[1, 0, 1], []])
        try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "unconnected")
        let original = try Fixtures.compile(documents)
        documents.project.name = "Mute everything (not an opcode)"
        documents.graph.label = "Gain -100 dB (not an opcode)"
        documents.graph.nodes[0].label = "Sum"
        documents.graph.nodes[0].position = GraphPoint(x: 900, y: -2)
        documents.graph.nodes[0].ports[0].label = "Gain"
        documents.graph.nodes[0].position?.extensions = [:]
        documents.graph.edges[0].from.extensions = [:]
        documents.graph.edges[0].to.extensions = [:]
        documents.graph.edges[0].conversion?.label = "Muted"
        documents.graph.nodes.reverse()
        documents.graph.edges.reverse()
        documents.project.roles.reverse()
        let reordered = try Fixtures.compile(documents)
        #expect(reordered.layout == original.layout)
        #expect(reordered.terms == [16, 0, 16])
        #expect(reordered.terms == original.terms)
        #expect(reordered.rows.map(\.termCount) == [3, 0, 0, 0])
    }

    @Test func exactResourceBudgetsAndOneBelow() throws {
        let documents = Fixtures.documents()
        let exact = Fixtures.limits(inputs: 2, outputs: 2, terms: 2, scratch: 264, work: 228)
        let plan = try Fixtures.compile(documents, limits: exact)
        #expect(plan.scratchFloats == 66)
        #expect(plan.scratchBytes == 264)
        #expect(plan.sampleWork == 228)
        #expect(plan.layout.inputSampleCount == 32)
        #expect(plan.layout.outputSampleCount == 32)
        let insufficient = [
            Fixtures.limits(inputs: 1), Fixtures.limits(outputs: 1), Fixtures.limits(terms: 1),
            Fixtures.limits(scratch: 263), Fixtures.limits(work: 227)
        ]
        for limits in insufficient {
            #expect(throws: AudioRoutingPreparationError.resourceLimit) {
                try Fixtures.compile(documents, limits: limits)
            }
        }
    }

    @Test func configurationsAndArithmeticAreChecked() {
        let invalid = [
            Fixtures.limits(frames: 0), Fixtures.limits(frames: -1), Fixtures.limits(inputs: -1),
            Fixtures.limits(outputs: -1), Fixtures.limits(terms: -1), Fixtures.limits(scratch: 0),
            Fixtures.limits(scratch: -1), Fixtures.limits(work: -1)
        ]
        for limits in invalid {
            #expect(throws: AudioRoutingPreparationError.invalidConfiguration) {
                try Fixtures.compile(Fixtures.documents(), limits: limits)
            }
        }
        #expect(throws: AudioRoutingPreparationError.arithmeticOverflow) {
            try Fixtures.compile(Fixtures.documents(), limits: Fixtures.limits(frames: Int.max))
        }
        let manyTerms = Fixtures.documents(
            inputChannels: 1, outputChannels: 1, map: [Array(repeating: 0, count: 32)]
        )
        #expect(throws: AudioRoutingPreparationError.arithmeticOverflow) {
            try Fixtures.compile(
                manyTerms, limits: Fixtures.limits(frames: Int.max / 32, scratch: Int.max, work: Int.max)
            )
        }
        #expect(throws: AudioRoutingPreparationError.resourceLimit) {
            try Fixtures.compile(
                Fixtures.documents(),
                limits: Fixtures.limits(frames: ScratchArena.maximumByteCapacity, scratch: Int.max, work: Int.max)
            )
        }
    }

    @Test func channelAndTermContractBoundaries() throws {
        let widest = Fixtures.documents(inputChannels: 64, outputChannels: 64)
        let plan = try Fixtures.compile(
            widest, limits: Fixtures.limits(frames: 1, inputs: 64, outputs: 64, terms: 64)
        )
        #expect(plan.terms == Array(0..<64))
        #expect(plan.layout.inputs[0].channels == 64)
        var manyTerms = Fixtures.documents(map: [Array(repeating: 0, count: 32), []])
        #expect(try Fixtures.compile(manyTerms).terms.count == 32)
        manyTerms.graph.edges[0].conversion?.map[0].append(0)
        #expect(throws: AudioRoutingPreparationError.resourceLimit) { try Fixtures.compile(manyTerms) }
    }

    @Test func collectionAndMapPreflightPrecedesValidation() {
        let mutations: [Mutation] = [
            { $0.graph.nodes = Array(repeating: $0.graph.nodes[0], count: ProjectGraphLimits.nodes + 1) },
            { $0.graph.edges = Array(repeating: $0.graph.edges[0], count: ProjectGraphLimits.edges + 1) },
            { $0.project.graphs = Array(
                repeating: $0.project.graphs[0], count: ProjectGraphLimits.projectRecords + 1
            ) },
            { $0.project.roles = Array(repeating: $0.project.roles[0], count: ProjectGraphLimits.projectRecords + 1) },
            { $0.graph.nodes[0].ports = Array(
                repeating: $0.graph.nodes[0].ports[0], count: ProjectGraphLimits.portsPerNode + 1
            ) },
            { $0.graph.nodes[0].requiredCapabilities = Array(
                repeating: CapabilityID(validated: "cap.none"), count: ProjectGraphLimits.capabilities + 1
            ) },
            { $0.graph.nodes[0].advisoryCapabilities = Array(
                repeating: CapabilityID(validated: "cap.none"), count: ProjectGraphLimits.capabilities + 1
            ) },
            { $0.graph.capabilities = Array(
                repeating: CapabilityDefinition(id: CapabilityID(validated: "cap.none"), label: "Unused"),
                count: ProjectGraphLimits.capabilities + 1
            ) }
        ]
        for mutate in mutations {
            var documents = Fixtures.documents()
            mutate(&documents)
            do {
                _ = try Fixtures.compile(documents)
                Issue.record("Expected collection refusal")
            } catch AudioRoutingPreparationError.collectionBounds {
                // Expected before duplicates, unsupported nodes or undefined capabilities.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        var documents = Fixtures.documents(map: Array(repeating: [], count: 65))
        #expect(throws: AudioRoutingPreparationError.resourceLimit) { try Fixtures.compile(documents) }
        documents.graph.edges[0].conversion = EdgeConversion(map: [Array(repeating: Int.max, count: 33), []])
        #expect(throws: AudioRoutingPreparationError.resourceLimit) { try Fixtures.compile(documents) }
    }

    @Test func emptyGraphNeedsOneFloatButNoSampleWork() throws {
        var documents = Fixtures.documents()
        documents.graph.nodes = []
        documents.graph.edges = []
        let limits = Fixtures.limits(inputs: 0, outputs: 0, terms: 0, scratch: 4, work: 0)
        let plan = try Fixtures.compile(documents, limits: limits)
        #expect(plan.scratchFloats == 1)
        #expect(plan.layout.peakCount == 0)
        #expect(plan.sampleWork == 0)
        #expect(throws: AudioRoutingPreparationError.resourceLimit) {
            try Fixtures.compile(documents, limits: Fixtures.limits(scratch: 3))
        }
    }
}
