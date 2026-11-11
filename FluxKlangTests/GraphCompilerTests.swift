import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
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
        for kind in NodeKind.allCases where kind != .roleInput && kind != .roleOutput && kind != .audioMute {
            var documents = Fixtures.documents()
            documents.graph.nodes.append(GraphNode(
                id: NodeID(validated: "node.disconnected"), kind: kind, label: "Not executable"
            ))
            #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        }
    }
}

extension GraphCompilerTests {
    @Test func malformedMuteAndUnsupportedMuteMetadataRefuse() {
        let mutations: [(inout GraphNode) -> Void] = [
            { $0.muted = nil }, { $0.ports = [] }, { $0.ports.removeLast() },
            { $0.ports[0].direction = .output }, { $0.ports[1].signal = .midi },
            { $0.ports[0].channels = 0 }, { $0.ports[1].channels = 65 },
            { $0.ports[1].channels = 1 }, { $0.ports[0].channels = nil },
            { $0.ports[1].id = $0.ports[0].id },
            { $0.role = RoleID(validated: "role.source") },
            { $0.asset = AssetID(validated: "asset.extra") },
            { $0.graph = GraphID(validated: "graph.extra") },
            { $0.requiredCapabilities = [CapabilityID(validated: "cap.extra")] },
            { $0.advisoryCapabilities = [CapabilityID(validated: "cap.extra")] },
            { $0.unknownFields = ["muted": .bool(true)] },
            { $0.extensions = ["future": .bool(true)] },
            { $0.ports[1].extensions = ["future": .bool(true)] }
        ]
        for mutate in mutations {
            var documents = Fixtures.muteDocuments(false)
            mutate(&documents.graph.nodes[2])
            #expect(throws: AudioRoutingPreparationError.self) { try Fixtures.compile(documents) }
        }
        var documents = Fixtures.muteDocuments(false)
        documents.graph.requiredFeatures = []
        #expect(throws: AudioRoutingPreparationError.self) { try Fixtures.compile(documents) }
    }

    @Test func multipleIndependentDisconnectedAndChainedMutesRefuse() throws {
        for topology in 0..<3 {
            var documents = Fixtures.muteDocuments(false)
            var second = Fixtures.muteNode(true)
            second.id = NodeID(validated: "node.secondMute")
            documents.graph.nodes.append(second)
            if topology == 1 {
                var incoming = documents.graph.edges[0]
                incoming.id = EdgeID(validated: "edge.independent")
                incoming.to.node = second.id
                documents.graph.edges.append(incoming)
            } else if topology == 2 {
                var chain = documents.graph.edges[0]
                chain.id = EdgeID(validated: "edge.chain")
                chain.from = documents.graph.edges[1].from
                chain.to.node = second.id
                documents.graph.edges.append(chain)
            }
            try documents.project.validate(graphs: [documents.graph], strict: true)
            #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        }
    }

    @Test func muteCyclesFeedbackAndAmbiguousIncomingRefuse() throws {
        var documents = Fixtures.muteDocuments(false)
        documents.graph.edges[0].from = documents.graph.edges[1].from
        #expect(throws: AudioRoutingPreparationError.self) { try Fixtures.compile(documents) }
        documents.graph.edges[0].feedback = EdgeFeedback(gainCeilingDb: -3)
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
        documents = Fixtures.muteDocuments(false)
        try Fixtures.appendEndpoint(to: &documents, input: true, suffix: "second")
        var incoming = documents.graph.edges[0]
        incoming.id = EdgeID(validated: "edge.second")
        incoming.from.node = documents.graph.nodes[3].id
        documents.graph.edges.append(incoming)
        #expect(throws: AudioRoutingPreparationError.unsupported) { try Fixtures.compile(documents) }
    }

    @Test(arguments: [false, true], [false, true])
    func muteExactBudgetsAndAllEdgeTermsAreCharged(muted: Bool, reversed: Bool) throws {
        var documents = Fixtures.muteDocuments(muted)
        let nodeID = NodeID(validated: reversed ? "node.reverseMute" : "node.forwardMute")
        documents.graph.nodes[2].id = nodeID
        documents.graph.nodes[2].ports[0].id = PortID(validated: "receive")
        documents.graph.nodes[2].ports[1].id = PortID(validated: "send")
        documents.graph.edges[0].to = PortAddress(node: nodeID, port: PortID(validated: "receive"))
        documents.graph.edges[1].from = PortAddress(node: nodeID, port: PortID(validated: "send"))
        if reversed { documents.graph.nodes[2].ports.reverse() }
        let plan = try Fixtures.compile(
            documents, limits: Fixtures.limits(inputs: 2, outputs: 2, terms: 4, scratch: 520, work: 388)
        )
        #expect(plan.scratchFloats == 130 && plan.scratchBytes == 520 && plan.sampleWork == 388)
        let mute = try #require(plan.mute)
        #expect(mute.node == nodeID && mute.muted == muted)
        #expect(mute.inputPort == documents.graph.edges[0].to.port)
        #expect(mute.outputPort == documents.graph.edges[1].from.port)
        #expect(mute.inputOffset == 32 && mute.resultOffset == 64 && plan.terms == [0, 16, 64, 80])
        #expect(mute.rows.map(\.firstTerm) == [0, 1] && mute.rows.map(\.termCount) == [1, 1])
        #expect(mute.rows.allSatisfy(\.isIdentity) && plan.rows.allSatisfy(\.isIdentity))
        #expect(plan.rows.map(\.firstTerm) == [2, 3] && plan.rows.map(\.termCount) == [1, 1])
        for limits in [Fixtures.limits(terms: 3), Fixtures.limits(scratch: 519), Fixtures.limits(work: 387)] {
            #expect(throws: AudioRoutingPreparationError.resourceLimit) {
                try Fixtures.compile(documents, limits: limits)
            }
        }
        for topology in 0..<3 {
            var disconnected = documents
            disconnected.graph.edges = topology == 1 ? [documents.graph.edges[0]] : []
            if topology == 2 { disconnected.graph.nodes = [documents.graph.nodes[2]] }
            let work = [324, 356, 128][topology], terms = topology == 1 ? 2 : 0
            let isolated = try Fixtures.compile(disconnected, limits: Fixtures.limits(terms: terms, work: work))
            let operation = try #require(isolated.mute)
            #expect(operation.node == mute.node && operation.muted == muted)
            #expect(operation.inputPort == mute.inputPort && operation.outputPort == mute.outputPort)
            #expect(operation.rows.count == 2 && isolated.rows.count == (topology == 2 ? 0 : 2))
            #expect(operation.rows.map(\.firstTerm) == (topology == 1 ? [0, 1] : [0, 0]))
            #expect(operation.rows.map(\.termCount) == (topology == 1 ? [1, 1] : [0, 0]))
            #expect(operation.rows.allSatisfy { $0.isIdentity == (topology == 1) })
            #expect(isolated.rows.allSatisfy { $0.firstTerm == terms && $0.termCount == 0 && !$0.isIdentity })
            let start = topology == 2 ? 0 : 32, width = operation.rows.count * isolated.layout.maxFrames
            #expect(operation.inputOffset..<operation.inputOffset + width == start..<start + 32)
            #expect(operation.resultOffset..<operation.resultOffset + width == start + 32..<start + 64)
            #expect(isolated.layout.inputs == (topology == 2 ? [] : plan.layout.inputs))
            #expect(isolated.layout.outputs == (topology == 2 ? [] : plan.layout.outputs))
            #expect(isolated.layout.inputSampleCount == start && isolated.layout.outputSampleCount == start)
            #expect(isolated.layout.peakCount == (topology == 2 ? 0 : 2))
            #expect(isolated.scratchBytes == (topology == 2 ? 256 : 520) && isolated.sampleWork == work)
            #expect(isolated.terms == (topology == 1 ? [0, 16] : []))
            #expect(throws: AudioRoutingPreparationError.resourceLimit) {
                try Fixtures.compile(disconnected, limits: Fixtures.limits(terms: terms, work: work - 1))
            }
        }
        var fanout = Fixtures.muteDocuments(false, inputMap: [[1, 0, 1], []], outputMap: [[0], [0, 0]])
        try Fixtures.appendEndpoint(to: &fanout, input: false, suffix: "second")
        var edge = fanout.graph.edges[1]
        edge.id = EdgeID(validated: "edge.fanout")
        edge.to.node = fanout.graph.nodes[3].id
        fanout.graph.edges.append(edge)
        let fanoutPlan = try Fixtures.compile(fanout, limits: Fixtures.limits(terms: 9))
        #expect(fanoutPlan.terms.count == 9)
        #expect(throws: AudioRoutingPreparationError.resourceLimit) {
            try Fixtures.compile(fanout, limits: Fixtures.limits(terms: 8))
        }
    }

    @Test func muteCheckedOverflowAndMapPreflightPrecedeInvalidIndices() {
        for frames in [Int.max, Int.max / 8] {
            #expect(throws: AudioRoutingPreparationError.arithmeticOverflow) {
                try Fixtures.compile(
                    Fixtures.muteDocuments(false),
                    limits: Fixtures.limits(frames: frames, scratch: Int.max, work: Int.max)
                )
            }
        }
        #expect(throws: AudioRoutingPreparationError.arithmeticOverflow) {
            try Fixtures.compile(
                Fixtures.muteDocuments(false, inputMap: [Array(repeating: 0, count: 30), []]),
                limits: Fixtures.limits(frames: Int.max / 52 + 1, scratch: Int.max, work: Int.max)
            )
        }
        for edge in 0..<2 {
            for map in [Array(repeating: [Int.max], count: 65), [Array(repeating: Int.max, count: 33), []]] {
                var documents = Fixtures.muteDocuments(false)
                documents.graph.edges[edge].conversion = EdgeConversion(map: map)
                #expect(throws: AudioRoutingPreparationError.resourceLimit) { try Fixtures.compile(documents) }
            }
        }
    }
}

extension GraphCompilerTests {
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
        var documents = Fixtures.muteDocuments(false, inputMap: [[1, 0, 1], []], outputMap: [[1, 0, 1], []])
        try Fixtures.appendEndpoint(to: &documents, input: false, suffix: "unconnected")
        let nodes = documents.graph.nodes
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
        documents.graph.nodes[1].id = NodeID(validated: "node.changed")
        documents.graph.nodes[1].ports[0].id = PortID(validated: "changed")
        documents.graph.nodes[1].ports[1].id = PortID(validated: "alsoChanged")
        documents.graph.nodes[1].muted = true
        documents.graph.edges = []
        documents.project.roles = []
        for plan in [original, reordered] {
            for endpoint in plan.layout.inputs + plan.layout.outputs {
                let node = try #require(nodes.first { $0.id == endpoint.node })
                #expect(endpoint.port == node.ports[0].id && endpoint.role == node.role && endpoint.channels == 2)
                #expect(endpoint.firstChannel == (node.id == nodes[3].id ? 2 : 0))
            }
            let mute = try #require(plan.mute)
            #expect(mute.node == nodes[2].id && mute.inputPort == nodes[2].ports[0].id)
            #expect(mute.outputPort == nodes[2].ports[1].id && !mute.muted)
            #expect(mute.inputOffset == 32 && mute.resultOffset == 64 && mute.rows.count == 2)
            #expect(mute.rows.map(\.firstTerm) == [0, 3] && mute.rows.map(\.termCount) == [3, 0])
            #expect(plan.terms == [16, 0, 16, 80, 64, 80] && plan.rows.map(\.firstTerm) == [3, 6, 6, 6])
            #expect(plan.rows.map(\.termCount) == [3, 0, 0, 0])
            #expect((mute.rows + plan.rows).allSatisfy { !$0.isIdentity })
        }
    }

    @Test func exactResourceBudgetsAndOneBelow() throws {
        let documents = Fixtures.documents()
        let exact = Fixtures.limits(inputs: 2, outputs: 2, terms: 2, scratch: 264, work: 228)
        let plan = try Fixtures.compile(documents, limits: exact)
        #expect(plan.scratchFloats == 66 && plan.scratchBytes == 264 && plan.sampleWork == 228)
        #expect(plan.layout.inputSampleCount == 32 && plan.layout.outputSampleCount == 32 && plan.mute == nil)
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
                repeating: $0.project.graphs[0], count: ProjectGraphLimits.projectRecords + 1) },
            { $0.project.roles = Array(repeating: $0.project.roles[0], count: ProjectGraphLimits.projectRecords + 1) },
            { $0.graph.nodes[0].ports = Array(
                repeating: $0.graph.nodes[0].ports[0], count: ProjectGraphLimits.portsPerNode + 1) },
            { $0.graph.nodes[0].requiredCapabilities = Array(
                repeating: CapabilityID(validated: "cap.none"), count: ProjectGraphLimits.capabilities + 1) },
            { $0.graph.nodes[0].advisoryCapabilities = Array(
                repeating: CapabilityID(validated: "cap.none"), count: ProjectGraphLimits.capabilities + 1) },
            { $0.graph.capabilities = Array(
                repeating: CapabilityDefinition(id: CapabilityID(validated: "cap.none"), label: "Unused"),
                count: ProjectGraphLimits.capabilities + 1) }
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
        #expect(plan.scratchFloats == 1 && plan.scratchBytes == 4)
        #expect(plan.mute == nil && plan.layout.inputs.isEmpty && plan.layout.outputs.isEmpty)
        #expect(plan.rows.isEmpty && plan.terms.isEmpty)
        #expect(plan.layout.inputSampleCount == 0 && plan.layout.outputSampleCount == 0)
        #expect(plan.layout.peakCount == 0 && plan.sampleWork == 0)
        #expect(throws: AudioRoutingPreparationError.resourceLimit) {
            try Fixtures.compile(documents, limits: Fixtures.limits(scratch: 3))
        }
    }
}
