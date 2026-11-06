import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphCompilerPlanTests {
    @Test
    func claimedChannelCountsRefuseBeforeChannelExpansion() throws {
        let huge = Self.oneInputDraft(channels: Int.max)
        let oneInput = try Self.request(frames: 1, limits: Self.hardeningLimits(inputs: 1))
        #expect(throws: RoutingScheduleRefusal.resourceLimit(
            .inputChannels, required: Int.max, maximum: 1
        )) {
            try RoutingSchedule.make(draft: huge, request: oneInput)
        }

        let exact = try RoutingSchedule.make(
            draft: Self.oneInputDraft(channels: 2),
            request: Self.request(frames: 1, limits: Self.hardeningLimits(inputs: 2))
        )
        #expect(exact.accounting.inputChannels == 2)
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.inputChannels, required: 3, maximum: 2)) {
            try RoutingSchedule.make(
                draft: Self.oneInputDraft(channels: 3),
                request: Self.request(frames: 1, limits: Self.hardeningLimits(inputs: 2))
            )
        }
    }

    @Test
    func delayGeometryRejectsInvalidChannelsAndOverflowingLayout() throws {
        let valid = try Self.twoLineFeedbackPlan()
        let sourceLine = try #require(valid.delayLines.first)
        for channels in [-1, 0] {
            var draft = Self.scheduleDraft(valid)
            draft.delayLines[0] = Self.replacingDelayed(
                sourceLine, with: RoutingSlot(
                    offset: sourceLine.delayed.offset, channels: channels, frames: sourceLine.delayed.frames
                )
            )
            #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.delayLine)) {
                try RoutingSchedule.make(draft: draft, request: Self.request(frames: 2))
            }
        }

        var overflowingOffset = Self.scheduleDraft(valid)
        overflowingOffset.delayLines[0] = Self.replacingDelayed(
            sourceLine, with: RoutingSlot(offset: Int.max, channels: 1, frames: sourceLine.delayed.frames)
        )
        #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.slotLayout)) {
            try RoutingSchedule.make(draft: overflowingOffset, request: Self.request(frames: 2))
        }

        var overflowingFrames = Self.scheduleDraft(valid)
        overflowingFrames.delayLines[0] = Self.replacingDelayed(
            sourceLine, with: RoutingSlot(
                offset: sourceLine.delayed.offset, channels: 1, frames: Int.max
            )
        )
        #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.delayLine)) {
            try RoutingSchedule.make(draft: overflowingFrames, request: Self.request(frames: 2))
        }

        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.slotSamples)) {
            try RoutingSchedule.channelStart(
                RoutingSlot(offset: Int.max, channels: 2, frames: 1), channel: 1
            )
        }
    }

    @Test
    func geometryAndBudgetPrecedenceIsDeterministic() throws {
        var geometryDraft = Self.oneInputDraft(channels: 1, offset: 1)
        geometryDraft.steps = [Self.invalidTermStep(outputOffset: 2)]
        #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.slotLayout)) {
            try RoutingSchedule.make(
                draft: geometryDraft,
                request: Self.request(frames: 1, limits: Self.hardeningLimits(inputs: 0))
            )
        }

        var limitedDraft = Self.oneInputDraft(channels: 2)
        limitedDraft.steps = [Self.invalidTermStep(outputOffset: 2)]
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.inputChannels, required: 2, maximum: 1)) {
            try RoutingSchedule.make(
                draft: limitedDraft,
                request: Self.request(frames: 1, limits: Self.hardeningLimits(inputs: 1))
            )
        }
    }

    @Test
    func conversionTermsAreCountedBeforeLoweringAtNAndNPlusOne() throws {
        let termCount = 100_000
        let (exactGraph, _) = Self.conversionGraph(
            map: [[Int](repeating: 0, count: termCount), []]
        )
        let exact = try RoutingScheduleBuilder.build(
            exactGraph,
            request: Self.request(
                frames: 1,
                limits: Self.hardeningLimits(inputs: 1, outputs: 2, terms: termCount)
            )
        )
        #expect(exact.accounting.termCount == termCount)
        let gainStep = try #require(exact.steps.first { $0.node == Self.hardeningGainID })
        #expect(gainStep.rows.map(\.terms.count) == [termCount, 0])

        let (overGraph, _) = Self.conversionGraph(
            map: [[Int](repeating: 0, count: termCount + 1), []]
        )
        let enormousFrames = Int.max
        #expect(throws: RoutingScheduleRefusal.resourceLimit(
            .terms, required: termCount + 1, maximum: termCount
        )) {
            try RoutingScheduleBuilder.build(
                overGraph,
                request: Self.request(
                    frames: enormousFrames,
                    limits: Self.hardeningLimits(
                        frames: enormousFrames, inputs: 1, outputs: 2, terms: termCount
                    )
                )
            )
        }
    }

    @Test
    func feedbackEdgeTermsAreBudgetedBeforeDelayAllocation() throws {
        let frames = Int.max
        let limits = Self.hardeningLimits(frames: frames, inputs: 1, outputs: 1, terms: 4)
        #expect(throws: RoutingScheduleRefusal.resourceLimit(.terms, required: 5, maximum: 4)) {
            try RoutingScheduleBuilder.build(
                Self.twoLineFeedbackGraph(),
                request: Self.request(frames: frames, limits: limits)
            )
        }
    }

    @Test
    func feedbackFromRoleInputUsesTheInputSlotAndReverifies() throws {
        let gainID = NodeID(validated: "hardening.feedback.gain")
        let gainInput = PortID(validated: "hardening.feedback.gain.in")
        let gainOutput = PortID(validated: "hardening.feedback.gain.out")
        let outputInput = PortID(validated: "hardening.feedback.output.in")
        let gain = Self.gain(id: gainID, input: gainInput, output: gainOutput)
        let feedback = GraphEdge(
            id: EdgeID(validated: "hardening.feedback.edge"),
            from: PortAddress(node: Self.inputID, port: Self.inputPort),
            to: PortAddress(node: gainID, port: gainInput),
            feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: 0)
        )
        let output = try Self.edge(
            "hardening.feedback.output", from: gainID, gainOutput, to: Self.outputID, outputInput
        )
        let graph = GraphDocument(
            id: Self.graphID, nodes: [Self.roleInput(), gain, Self.roleOutput(port: outputInput)],
            edges: [feedback, output], requiredFeatures: [GraphDocument.constantGainFeature]
        )
        #expect(graph.validationErrors(strict: true).isEmpty)

        let request = try Self.request(frames: 1)
        let plan = try RoutingScheduleBuilder.build(graph, request: request)
        let line = try #require(plan.delayLines.first)
        #expect(line.source == plan.inputs[0].slot)
        let gainStep = try #require(plan.steps.first { $0.node == gainID })
        #expect(gainStep.rows.map(\.terms) == [[line.delayed.offset]])
        let outputStep = try #require(plan.steps.first { $0.node == Self.outputID })
        #expect(outputStep.rows.map(\.terms) == [[gainStep.output.offset]])
        #expect(try RoutingSchedule.make(draft: Self.scheduleDraft(plan), request: request) == plan)
    }

    @Test
    func silentConversionRowsBuildAndPreserveOtherFanInTerms() throws {
        let (silentGraph, _) = Self.conversionGraph(map: [[0], []])
        let silentPlan = try RoutingScheduleBuilder.build(silentGraph, request: Self.request(frames: 1))
        let silentStep = try #require(silentPlan.steps.first { $0.node == Self.hardeningGainID })
        #expect(silentStep.rows.map(\.terms) == [[0], []])
        #expect(silentStep.rows.map(\.isBitCopy) == [false, false])
        #expect(try RoutingSchedule.make(
            draft: Self.scheduleDraft(silentPlan), request: Self.request(frames: 1)
        ) == silentPlan)

        let (fanInGraph, _) = Self.conversionGraph(map: [[0], []], additionalSource: true)
        let fanInPlan = try RoutingScheduleBuilder.build(fanInGraph, request: Self.request(frames: 1))
        let fanInStep = try #require(fanInPlan.steps.first { $0.node == Self.hardeningGainID })
        #expect(fanInStep.rows.map(\.terms) == [[0, 1], [1]])
        #expect(fanInStep.rows.map(\.isBitCopy) == [false, false])
    }

    @Test
    func conversionStillRequiresOneNonemptyRowAndValidIndices() throws {
        for map in [[[], []], [[1], []]] {
            let (graph, edge) = Self.conversionGraph(map: map)
            #expect(throws: RoutingScheduleRefusal.invalidGraph(.invalidConversion(edge: edge))) {
                try RoutingScheduleBuilder.build(graph, request: Self.request(frames: 1))
            }
            #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.unresolvedReference)) {
                try RoutingScheduleBuilder.plan(graph, request: Self.request(frames: 1))
            }
        }
    }

    static let hardeningGainID = NodeID(validated: "hardening.conversion.gain")

    static func hardeningLimits(
        frames: Int = 1, inputs: Int = 8, outputs: Int = 8, terms: Int = 1_000_000
    ) -> AudioRoutingLimits {
        Self.limits(frames: frames, inputs: inputs, outputs: outputs, terms: terms,
                    bytes: Int.max, work: Int.max)
    }

    static func oneInputDraft(channels: Int, offset: Int = 0) -> RoutingScheduleDraft {
        let graph = Self.directGraph()
        let endpoint = AudioRoutingEndpoint(
            node: Self.inputID, port: Self.inputPort, role: Self.sourceRole, channels: channels, firstChannel: 0
        )
        return RoutingScheduleDraft(
            graph: graph.id, revision: graph.revision,
            inputs: [RoutingEndpoint(
                endpoint: endpoint, slot: RoutingSlot(offset: offset, channels: channels, frames: 1)
            )],
            steps: [], outputs: [], delayLines: []
        )
    }

    static func invalidTermStep(outputOffset: Int) -> RoutingStep {
        RoutingStep(
            node: NodeID(validated: "hardening.invalid.term"), level: 1, operation: .copy,
            output: RoutingSlot(offset: outputOffset, channels: 1, frames: 1),
            rows: [RoutingRow(terms: [Int.max], isBitCopy: true)], mixOrder: []
        )
    }

    static func scheduleDraft(_ schedule: RoutingSchedule) -> RoutingScheduleDraft {
        RoutingScheduleDraft(
            graph: schedule.graph, revision: schedule.revision, inputs: schedule.inputs,
            steps: schedule.steps, outputs: schedule.outputs, delayLines: schedule.delayLines
        )
    }

    static func replacingDelayed(_ line: RoutingDelayLine, with slot: RoutingSlot) -> RoutingDelayLine {
        RoutingDelayLine(cut: line.cut, source: line.source, delayed: slot, storage: line.storage)
    }

    static func conversionGraph(
        map: [[Int]], additionalSource: Bool = false
    ) -> (graph: GraphDocument, conversionEdge: EdgeID) {
        let sourceA = Self.roleInput(
            NodeID(validated: "hardening.source.a"), port: PortID(validated: "hardening.source.a.out"),
            role: RoleID(validated: "hardening.role.a")
        )
        let sourceB = Self.roleInput(
            NodeID(validated: "hardening.source.b"), port: PortID(validated: "hardening.source.b.out"),
            role: RoleID(validated: "hardening.role.b")
        )
        let gainInput = PortID(validated: "hardening.conversion.gain.in")
        let gainOutput = PortID(validated: "hardening.conversion.gain.out")
        let outputInput = PortID(validated: "hardening.conversion.output.in")
        let gain = GraphNode(
            id: Self.hardeningGainID, kind: .audioGain, label: "Conversion gain",
            ports: [
                GraphPort(id: gainInput, direction: .input, signal: .audio, channels: 2),
                GraphPort(id: gainOutput, direction: .output, signal: .audio, channels: 2)
            ], linearGain: 1
        )
        let outputNode = GraphNode(
            id: Self.outputID, kind: .roleOutput, label: "Output", role: Self.destinationRole,
            ports: [GraphPort(id: outputInput, direction: .input, signal: .audio, channels: 2)]
        )
        let conversionID = EdgeID(validated: "hardening.conversion.a")
        let conversion = GraphEdge(
            id: conversionID, from: PortAddress(node: sourceA.id, port: sourceA.ports[0].id),
            to: PortAddress(node: gain.id, port: gainInput), conversion: EdgeConversion(map: map)
        )
        var edges = [conversion]
        var nodes = [sourceA, gain, outputNode]
        if additionalSource {
            nodes.append(sourceB)
            edges.append(GraphEdge(
                id: EdgeID(validated: "hardening.conversion.b"),
                from: PortAddress(node: sourceB.id, port: sourceB.ports[0].id),
                to: PortAddress(node: gain.id, port: gainInput),
                conversion: EdgeConversion(map: [[0], [0]])
            ))
            edges.append(GraphEdge(
                id: EdgeID(validated: "hardening.conversion.out"),
                from: PortAddress(node: gain.id, port: gainOutput),
                to: PortAddress(node: outputNode.id, port: outputInput)
            ))
        }
        return (
            GraphDocument(
                id: Self.graphID, nodes: nodes, edges: edges,
                requiredFeatures: [GraphDocument.constantGainFeature]
            ),
            conversionID
        )
    }
}
