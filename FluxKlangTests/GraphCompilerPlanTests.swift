import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct GraphCompilerPlanTests {
    static let graphID = GraphID(validated: "plan.graph")
    static let inputID = NodeID(validated: "plan.input")
    static let outputID = NodeID(validated: "plan.output")
    static let inputPort = PortID(validated: "plan.in.out")
    static let outputPort = PortID(validated: "plan.out.in")
    static let sourceRole = RoleID(validated: "plan.source")
    static let destinationRole = RoleID(validated: "plan.destination")

    static func limits(
        frames: Int = 16, inputs: Int = 64, outputs: Int = 64, terms: Int = 256,
        bytes: Int = 1_000_000, work: Int = 1_000_000
    ) -> AudioRoutingLimits {
        AudioRoutingLimits(
            maxFrames: frames, maxInputChannels: inputs, maxOutputChannels: outputs,
            maxTerms: terms, maxScratchBytes: bytes, maxSampleWork: work
        )
    }

    static func request(
        frames: Int = 2, limits: AudioRoutingLimits? = nil
    ) throws -> RoutingScheduleRequest {
        try RoutingScheduleRequest(
            sampleRate: 48_000, blockFrames: frames,
            limits: limits ?? self.limits(frames: max(frames, 16))
        )
    }

    static func roleInput(_ id: NodeID = inputID, port: PortID = inputPort, role: RoleID = sourceRole) -> GraphNode {
        GraphNode(
            id: id, kind: .roleInput, label: "Input", role: role,
            ports: [GraphPort(id: port, direction: .output, signal: .audio, channels: 1)]
        )
    }

    static func roleOutput(
        _ id: NodeID = outputID, port: PortID = outputPort, role: RoleID = destinationRole
    ) -> GraphNode {
        GraphNode(
            id: id, kind: .roleOutput, label: "Output", role: role,
            ports: [GraphPort(id: port, direction: .input, signal: .audio, channels: 1)]
        )
    }

    static func directGraph() -> GraphDocument {
        GraphDocument(
            id: graphID,
            nodes: [roleInput(), roleOutput()],
            edges: [GraphEdge(
                id: EdgeID(validated: "plan.edge"),
                from: PortAddress(node: inputID, port: inputPort),
                to: PortAddress(node: outputID, port: outputPort)
            )]
        )
    }

    @Test
    func deterministicDirectPlanAndBitExactOutputOperation() throws {
        let graph = Self.directGraph()
        let first = try RoutingScheduleBuilder.build(graph, request: Self.request())
        let second = try RoutingScheduleBuilder.build(graph, request: Self.request())
        #expect(first == second)
        #expect(first.steps.map(\.level) == [1])
        #expect(first.steps[0].rows == [RoutingRow(terms: [0], isBitCopy: true)])
        #expect(first.steps[0].operation == .copy)
        #expect(first.outputs[0].slot == first.steps[0].output)
        #expect(first.accounting.inputChannels == 1)
        #expect(first.accounting.outputChannels == 1)
        #expect(first.accounting.scratchFloats == 4)
        #expect(first.accounting.scratchBytes == 16)
        #expect(first.accounting.sampleWork == 10)
    }

    @Test
    func requestBoundariesAndTypedRefusals() throws {
        #expect(try RoutingScheduleRequest(
            sampleRate: 1, blockFrames: 1, limits: Self.limits(frames: 1)
        ).sampleRate == 1)
        #expect(throws: RoutingScheduleRefusal.invalidSampleRate(0)) {
            try RoutingScheduleRequest(sampleRate: 0, blockFrames: 1, limits: Self.limits())
        }
        #expect(throws: RoutingScheduleRefusal.invalidSampleRate(768_001)) {
            try RoutingScheduleRequest(sampleRate: 768_001, blockFrames: 1, limits: Self.limits())
        }
        #expect(try RoutingScheduleRequest(
            sampleRate: 768_000, blockFrames: 1, limits: Self.limits(frames: 1)
        ).blockFrames == 1)
        #expect(throws: RoutingScheduleRefusal.invalidBlockFrames(0)) {
            try RoutingScheduleRequest(sampleRate: 48_000, blockFrames: 0, limits: Self.limits())
        }
        #expect(throws: RoutingScheduleRefusal.resourceLimit(
            .blockFrames, required: 2, maximum: 1
        )) {
            try RoutingScheduleRequest(sampleRate: 48_000, blockFrames: 2, limits: Self.limits(frames: 1))
        }
        #expect(throws: RoutingScheduleRefusal.invalidLimits(.inputChannels)) {
            try RoutingScheduleRequest(
                sampleRate: 48_000, blockFrames: 1,
                limits: Self.limits(frames: 1, inputs: -1)
            )
        }
    }

    @Test
    func workAndScratchLimitsAreInclusive() throws {
        let graph = Self.directGraph()
        let exact = Self.limits(frames: 2, inputs: 1, outputs: 1, terms: 1, bytes: 16, work: 10)
        #expect(try RoutingScheduleBuilder.build(graph, request: Self.request(limits: exact))
            .accounting.sampleWork == 10)
        let oneLess = Self.limits(frames: 2, inputs: 1, outputs: 1, terms: 1, bytes: 16, work: 9)
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.sampleWork, required: 10, maximum: 9)) {
            try RoutingScheduleBuilder.build(graph, request: Self.request(limits: oneLess))
        }
        let lessScratch = Self.limits(frames: 2, inputs: 1, outputs: 1, terms: 1, bytes: 15, work: 10)
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.scratchBytes, required: 16, maximum: 15)) {
            try RoutingScheduleBuilder.build(graph, request: Self.request(limits: lessScratch))
        }
    }

    @Test
    func channelAndTermLimitsAcceptNAndRefuseNMinusOne() throws {
        let graph = Self.directGraph()
        #expect(try RoutingScheduleBuilder.build(
            graph, request: Self.request(limits: Self.limits(inputs: 1, outputs: 1, terms: 1))
        ).accounting.termCount == 1)
        let verifierRequest = try Self.request(
            frames: 1, limits: Self.limits(frames: 4, inputs: 1, outputs: 4, terms: 2, bytes: 64, work: 64)
        )
        let seed = try RoutingScheduleBuilder.build(graph, request: verifierRequest)
        var exactDraft = Self.scheduleDraft(seed)
        exactDraft.steps[0] = Self.withRows(
            exactDraft.steps[0], [RoutingRow(terms: [0, 0], isBitCopy: false)]
        )
        #expect(try RoutingSchedule.make(draft: exactDraft, request: verifierRequest)
            .accounting.termCount == 2)

        var overDraft = exactDraft
        overDraft.steps[0] = Self.withRows(
            overDraft.steps[0], [RoutingRow(terms: [0, 0, 0], isBitCopy: false)]
        )
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.terms, required: 3, maximum: 2)) {
            try RoutingSchedule.make(draft: overDraft, request: verifierRequest)
        }
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.inputChannels, required: 1, maximum: 0)) {
            try RoutingScheduleBuilder.build(
                graph, request: Self.request(limits: Self.limits(inputs: 0, outputs: 1, terms: 1))
            )
        }
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.outputChannels, required: 1, maximum: 0)) {
            try RoutingScheduleBuilder.build(
                graph, request: Self.request(limits: Self.limits(inputs: 1, outputs: 0, terms: 1))
            )
        }
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.terms, required: 1, maximum: 0)) {
            try RoutingScheduleBuilder.build(
                graph, request: Self.request(limits: Self.limits(inputs: 1, outputs: 1, terms: 0))
            )
        }
    }

    @Test
    func refusalLeavesInputGraphUnchangedAndReturnsNoSchedule() throws {
        let graph = Self.directGraph()
        let original = graph
        let limits = Self.limits(frames: 2, inputs: 1, outputs: 1, terms: 1, bytes: 15, work: 10)
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.scratchBytes, required: 16, maximum: 15)) {
            try RoutingScheduleBuilder.build(graph, request: Self.request(limits: limits))
        }
        #expect(graph == original)
    }

}
