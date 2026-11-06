import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphCompilerPlanTests {
    @Test
    func fanInTermsAndMixOrderPreserveEdgeDocumentOrder() throws {
        let inputA = Self.roleInput(
            NodeID(validated: "fan.input.a"), port: PortID(validated: "fan.port.a"),
            role: RoleID(validated: "fan.role.a")
        )
        let inputB = Self.roleInput(
            NodeID(validated: "fan.input.b"), port: PortID(validated: "fan.port.b"),
            role: RoleID(validated: "fan.role.b")
        )
        let gain = Self.gain(
            id: NodeID(validated: "fan.gain"), input: PortID(validated: "fan.gain.in"),
            output: PortID(validated: "fan.gain.out")
        )
        let toA = try Self.edge(
            "fan.edge.b", from: inputB.id, inputB.ports[0].id, to: gain.id, gain.ports[0].id
        )
        let toB = try Self.edge(
            "fan.edge.a", from: inputA.id, inputA.ports[0].id, to: gain.id, gain.ports[0].id
        )
        let out = try Self.edge(
            "fan.edge.out", from: gain.id, gain.ports[1].id,
            to: Self.outputID, Self.outputPort
        )
        let graph = GraphDocument(
            id: Self.graphID, nodes: [inputA, inputB, gain, Self.roleOutput()], edges: [toA, toB, out],
            requiredFeatures: [GraphDocument.constantGainFeature]
        )
        let plan = try RoutingScheduleBuilder.build(graph, request: Self.request())
        #expect(plan.steps[0].rows[0].terms == [2, 0])
        #expect(plan.steps[0].rows[0].isBitCopy == false)
        #expect(plan.steps[0].mixOrder == [toA.id, toB.id])
    }

    @Test
    func explicitChannelMapPreservesRowIndexAndTermOrder() throws {
        let source = Self.roleInput(
            NodeID(validated: "map.input"), port: PortID(validated: "map.input.out"),
            role: RoleID(validated: "map.role.input")
        )
        let gainID = NodeID(validated: "map.gain")
        let input = PortID(validated: "map.gain.in")
        let output = PortID(validated: "map.gain.out")
        let outputInput = PortID(validated: "map.output.in")
        let gain = GraphNode(
            id: gainID, kind: .audioGain, label: "Gain",
            ports: [
                GraphPort(id: input, direction: .input, signal: .audio, channels: 2),
                GraphPort(id: output, direction: .output, signal: .audio, channels: 2)
            ], linearGain: 0.5
        )
        let sourceTwo = GraphNode(
            id: source.id, kind: .roleInput, label: "Stereo", role: source.role,
            ports: [GraphPort(id: source.ports[0].id, direction: .output, signal: .audio, channels: 2)]
        )
        let destinationTwo = GraphNode(
            id: Self.outputID, kind: .roleOutput, label: "Stereo out", role: Self.destinationRole,
            ports: [GraphPort(id: outputInput, direction: .input, signal: .audio, channels: 2)]
        )
        let map = GraphEdge(
            id: EdgeID(validated: "map.edge.in"),
            from: PortAddress(node: sourceTwo.id, port: sourceTwo.ports[0].id),
            to: PortAddress(node: gainID, port: input),
            conversion: EdgeConversion(map: [[1, 0], [1]])
        )
        let out = try Self.edge("map.edge.out", from: gainID, output, to: destinationTwo.id, outputInput)
        let graph = GraphDocument(
            id: Self.graphID, nodes: [sourceTwo, gain, destinationTwo], edges: [map, out],
            requiredFeatures: [GraphDocument.constantGainFeature]
        )
        let plan = try RoutingScheduleBuilder.build(graph, request: Self.request())
        #expect(plan.steps[0].rows.map(\.terms) == [[2, 0], [2]])
        #expect(plan.steps[0].rows.allSatisfy { !$0.isBitCopy })
        #expect(plan.steps[0].operation == .scale(0.5))
    }
}
