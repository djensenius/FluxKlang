import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphCompilerPlanTests {
    @Test
    func unsupportedKindsCapabilitiesAndUnmarkedCyclesRefuse() throws {
        let unsupported: [NodeKind] = [
            .spatialBus, .plugin, .externalInsert, .mediaPlayer, .sharedGraph, .observedShortcut
        ]
        for kind in unsupported {
            let id = try NodeID("semantics.\(kind.rawValue)")
            let graph = GraphDocument(id: Self.graphID, nodes: [GraphNode(id: id, kind: kind, label: "Unsupported")])
            #expect(throws: RoutingScheduleRefusal.unsupportedNodeKind(id, kind)) {
                try RoutingScheduleBuilder.plan(graph, request: Self.request())
            }
        }

        let gainID = NodeID(validated: "semantics.cap.gain")
        let input = PortID(validated: "semantics.cap.in")
        let output = PortID(validated: "semantics.cap.out")
        let dependent = GraphNode(
            id: gainID, kind: .audioGain, label: "Dependent",
            ports: [
                GraphPort(id: input, direction: .input, signal: .audio, channels: 1),
                GraphPort(id: output, direction: .output, signal: .audio, channels: 1)
            ],
            requiredCapabilities: [CapabilityID(validated: "semantics.capability")], linearGain: 1
        )
        let capabilityGraph = GraphDocument(
            id: Self.graphID, nodes: [dependent], requiredFeatures: [GraphDocument.constantGainFeature]
        )
        #expect(throws: RoutingScheduleRefusal.unsupportedCapabilities(gainID)) {
            try RoutingScheduleBuilder.plan(capabilityGraph, request: Self.request())
        }

        let loop = GraphEdge(
            id: EdgeID(validated: "semantics.unmarked.loop"),
            from: PortAddress(node: gainID, port: output),
            to: PortAddress(node: gainID, port: input)
        )
        let plainGain = GraphNode(
            id: gainID, kind: .audioGain, label: "Plain",
            ports: [
                GraphPort(id: input, direction: .input, signal: .audio, channels: 1),
                GraphPort(id: output, direction: .output, signal: .audio, channels: 1)
            ], linearGain: 1
        )
        let cyclicGraph = GraphDocument(
            id: Self.graphID, nodes: [plainGain], edges: [loop],
            requiredFeatures: [GraphDocument.constantGainFeature]
        )
        #expect(throws: RoutingScheduleRefusal.cycleWithoutDelay([gainID])) {
            try RoutingScheduleBuilder.plan(cyclicGraph, request: Self.request())
        }
    }

    @Test
    func mutedStepKeepsRowsAndUsesPositiveZeroOperation() throws {
        let muteID = NodeID(validated: "semantics.mute")
        let muteInput = PortID(validated: "semantics.mute.in")
        let muteOutput = PortID(validated: "semantics.mute.out")
        let mute = GraphNode(
            id: muteID, kind: .audioMute, label: "Mute",
            ports: [
                GraphPort(id: muteInput, direction: .input, signal: .audio, channels: 1),
                GraphPort(id: muteOutput, direction: .output, signal: .audio, channels: 1)
            ], muted: true
        )
        let edges = [
            try Self.edge("semantics.mute.in.edge", from: Self.inputID, Self.inputPort, to: muteID, muteInput),
            try Self.edge("semantics.mute.out.edge", from: muteID, muteOutput, to: Self.outputID, Self.outputPort)
        ]
        let graph = GraphDocument(
            id: Self.graphID, nodes: [Self.roleInput(), mute, Self.roleOutput()], edges: edges,
            requiredFeatures: [GraphDocument.constantMuteFeature]
        )
        let plan = try RoutingScheduleBuilder.build(graph, request: Self.request())
        let step = try #require(plan.steps.first(where: { $0.node == muteID }))
        #expect(step.operation == .zero)
        #expect(step.rows[0].terms == [0])
        #expect(step.rows[0].isBitCopy)
    }

    @Test
    func nodeArrayPermutationProducesTheSameValuePlan() throws {
        var graph = Self.directGraph()
        graph.nodes.reverse()
        let permuted = try RoutingScheduleBuilder.build(graph, request: Self.request())
        #expect(permuted == (try RoutingScheduleBuilder.build(Self.directGraph(), request: Self.request())))
    }
}
