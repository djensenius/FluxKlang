import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphCompilerPlanTests {
    @Test
    func contractCollectionCeilingsAcceptNAndRefuseNPlusOne() throws {
        try ProjectGraphLimits.check(ProjectGraphLimits.nodes, maximum: ProjectGraphLimits.nodes, path: "$.nodes")
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes)) {
            try ProjectGraphLimits.check(
                ProjectGraphLimits.nodes + 1, maximum: ProjectGraphLimits.nodes, path: "$.nodes"
            )
        }
        try ProjectGraphLimits.check(ProjectGraphLimits.edges, maximum: ProjectGraphLimits.edges, path: "$.edges")
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges)) {
            try ProjectGraphLimits.check(
                ProjectGraphLimits.edges + 1, maximum: ProjectGraphLimits.edges, path: "$.edges"
            )
        }
        try ProjectGraphLimits.check(
            ProjectGraphLimits.portsPerNode, maximum: ProjectGraphLimits.portsPerNode, path: "$.ports"
        )
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$.ports", maximum: ProjectGraphLimits.portsPerNode)) {
            try ProjectGraphLimits.check(
                ProjectGraphLimits.portsPerNode + 1, maximum: ProjectGraphLimits.portsPerNode, path: "$.ports"
            )
        }
    }

    @Test
    func checkedIntBoundariesRefuseOverflowForEachResource() throws {
        #expect(try RoutingMath.add(Int.max - 1, 1, resource: .scratchFloats) == Int.max)
        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.scratchFloats)) {
            try RoutingMath.add(Int.max, 1, resource: .scratchFloats)
        }
        #expect(try RoutingMath.multiply(Int.max / 2, 2, resource: .slotSamples) == Int.max - 1)
        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.slotSamples)) {
            try RoutingMath.multiply(Int.max / 2 + 1, 2, resource: .slotSamples)
        }
        #expect(try RoutingMath.multiply(Int.max / 4, 4, resource: .scratchBytes) == Int.max - 3)
        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.scratchBytes)) {
            try RoutingMath.multiply(Int.max / 4 + 1, 4, resource: .scratchBytes)
        }
        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.sampleWork)) {
            try RoutingMath.multiply(Int.max, 2, resource: .sampleWork)
        }
    }

    @Test
    func gainBoundariesAcceptValidExactFloatAndRejectInvalidValues() throws {
        let validGains = [1.0, 0.5, 16.0, Double(Float.leastNormalMagnitude)]
        for gain in validGains {
            let plan = try RoutingScheduleBuilder.build(Self.gainGraph(gain), request: Self.request())
            #expect(plan.steps[0].operation == (gain == 1 ? .copy : .scale(Float(gain))))
        }
        let invalidGains = [
            0.0, -0.0, -1.0, 16.000_001, 0.1, Double(Float.leastNonzeroMagnitude),
            Double.infinity, -.infinity, Double.nan
        ]
        let node = NodeID(validated: "budget.gain")
        for gain in invalidGains {
            #expect(throws: RoutingScheduleRefusal.invalidGain(node)) {
                try RoutingScheduleBuilder.build(Self.gainGraph(gain), request: Self.request())
            }
        }
    }

    static func gainGraph(_ gain: Double) -> GraphDocument {
        let nodeID = NodeID(validated: "budget.gain")
        let input = PortID(validated: "budget.gain.in")
        let output = PortID(validated: "budget.gain.out")
        let gainNode = GraphNode(
            id: nodeID, kind: .audioGain, label: "Boundary gain",
            ports: [
                GraphPort(id: input, direction: .input, signal: .audio, channels: 1),
                GraphPort(id: output, direction: .output, signal: .audio, channels: 1)
            ], linearGain: gain
        )
        return GraphDocument(
            id: Self.graphID,
            nodes: [Self.roleInput(), gainNode, Self.roleOutput()],
            edges: [
                GraphEdge(
                    id: EdgeID(validated: "budget.gain.in.edge"),
                    from: PortAddress(node: Self.inputID, port: Self.inputPort),
                    to: PortAddress(node: nodeID, port: input)
                ),
                GraphEdge(
                    id: EdgeID(validated: "budget.gain.out.edge"),
                    from: PortAddress(node: nodeID, port: output),
                    to: PortAddress(node: Self.outputID, port: Self.outputPort)
                )
            ],
            requiredFeatures: [GraphDocument.constantGainFeature]
        )
    }
}
