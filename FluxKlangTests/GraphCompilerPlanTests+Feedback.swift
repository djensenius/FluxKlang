import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphCompilerPlanTests {
    static let nodeAID = NodeID(validated: "plan.gain.a")
    static let nodeBID = NodeID(validated: "plan.gain.b")
    static let nodeAInput = PortID(validated: "plan.gain.a.in")
    static let nodeAOutput = PortID(validated: "plan.gain.a.out")
    static let nodeBInput = PortID(validated: "plan.gain.b.in")
    static let nodeBOutput = PortID(validated: "plan.gain.b.out")
    static let feedbackB = EdgeID(validated: "plan.feedback.b")
    static let feedbackA = EdgeID(validated: "plan.feedback.a")

    @Test
    func explicitSelfLoopCutsCreateIndependentOneAndThreeBlockRings() throws {
        let plan = try Self.twoLineFeedbackPlan()
        #expect(plan.delayLines.map(\.cut.edge) == [Self.feedbackB, Self.feedbackA])
        #expect(plan.delayLines.map(\.cut.delayFrames) == [6, 2])
        #expect(plan.delayLines.map(\.source.offset) == [4, 2])
        #expect(plan.delayLines.map(\.delayed.offset) == [8, 16])
        #expect(plan.delayLines.map(\.storage.offset) == [10, 18])
        #expect(plan.accounting.scratchFloats == 20)
        #expect(plan.accounting.scratchBytes == 80)
        #expect(plan.accounting.termCount == 5)
        #expect(plan.accounting.sampleWork == 30)
        #expect(plan.steps.map(\.node) == [Self.nodeAID, Self.nodeBID, Self.outputID])
        #expect(plan.steps[0].rows[0].terms == [0, plan.delayLines[1].delayed.offset])
        #expect(plan.steps[1].rows[0].terms == [0, plan.delayLines[0].delayed.offset])
        #expect(plan.steps[2].rows[0].terms == [plan.steps[0].output.offset])
        #expect(plan.delayLines[0].storage.offset + 0 * 6 + 2 * 2 + 1 == 15)

        let externalBlocks: [[Float]] = [[1, 10], [2, 20], [3, 30], [4, 40], [5, 50]]
        let evaluated = try Self.evaluateFeedback(plan, inputs: externalBlocks)
        #expect(evaluated[Self.nodeAID] == [[1, 10], [3, 30], [6, 60], [10, 100], [15, 150]])
        #expect(evaluated[Self.nodeBID] == [[1, 10], [2, 20], [3, 30], [5, 50], [7, 70]])
        #expect(evaluated[Self.outputID] == evaluated[Self.nodeAID])
    }

    @Test
    func referenceEvaluatorBitCopyPreservesSignedZero() throws {
        let negativeZero = -Float.zero
        let result = try Self.mix(
            RoutingRow(terms: [7], isBitCopy: true), operation: .copy,
            slots: [7: [negativeZero]], frames: 1
        )
        #expect(result[0].bitPattern == negativeZero.bitPattern)
    }

    static func twoLineFeedbackPlan() throws -> RoutingSchedule {
        try RoutingScheduleBuilder.build(twoLineFeedbackGraph(), request: Self.request(frames: 2))
    }

    static func twoLineFeedbackGraph() throws -> GraphDocument {
        let nodeA = Self.gain(id: Self.nodeAID, input: Self.nodeAInput, output: Self.nodeAOutput)
        let nodeB = Self.gain(id: Self.nodeBID, input: Self.nodeBInput, output: Self.nodeBOutput)
        let edgeA = GraphEdge(
            id: EdgeID(validated: "plan.feed.a"),
            from: PortAddress(node: Self.inputID, port: Self.inputPort),
            to: PortAddress(node: Self.nodeAID, port: Self.nodeAInput)
        )
        let edgeB = GraphEdge(
            id: EdgeID(validated: "plan.feed.b"),
            from: PortAddress(node: Self.inputID, port: Self.inputPort),
            to: PortAddress(node: Self.nodeBID, port: Self.nodeBInput)
        )
        let edges = [
            edgeA, edgeB,
            GraphEdge(
                id: Self.feedbackB, from: PortAddress(node: Self.nodeBID, port: Self.nodeBOutput),
                to: PortAddress(node: Self.nodeBID, port: Self.nodeBInput),
                feedback: EdgeFeedback(delayBlocks: 3, gainCeilingDb: 0)
            ),
            GraphEdge(
                id: Self.feedbackA, from: PortAddress(node: Self.nodeAID, port: Self.nodeAOutput),
                to: PortAddress(node: Self.nodeAID, port: Self.nodeAInput),
                feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)
            ),
            try Self.edge(
                "plan.out.a", from: Self.nodeAID, Self.nodeAOutput, to: Self.outputID, Self.outputPort
            )
        ]
        let graph = GraphDocument(
            id: Self.graphID, nodes: [Self.roleInput(), Self.roleOutput(), nodeA, nodeB],
            edges: edges, requiredFeatures: [GraphDocument.constantGainFeature]
        )
        return graph
    }

    static func evaluateFeedback(
        _ schedule: RoutingSchedule, inputs: [[Float]]
    ) throws -> [NodeID: [[Float]]] {
        var storage = Dictionary(uniqueKeysWithValues: schedule.delayLines.map {
            ($0.cut.edge, Array(repeating: Float.zero, count: $0.cut.channels * $0.cut.delayFrames))
        })
        var cursors = Dictionary(uniqueKeysWithValues: schedule.delayLines.map { ($0.cut.edge, 0) })
        var results: [NodeID: [[Float]]] = [:]
        for inputBlock in inputs {
            var slots: [Int: [Float]] = [schedule.inputs[0].slot.offset: inputBlock]
            try readDelayLines(schedule, storage: storage, cursors: cursors, into: &slots)
            try renderSteps(schedule, slots: &slots, results: &results)
            try writeDelayLines(schedule, slots: slots, storage: &storage, cursors: &cursors)
        }
        return results
    }

    static func readDelayLines(
        _ schedule: RoutingSchedule, storage: [EdgeID: [Float]], cursors: [EdgeID: Int],
        into slots: inout [Int: [Float]]
    ) throws {
        for line in schedule.delayLines {
            let cursor = try #require(cursors[line.cut.edge])
            let delayed = try #require(storage[line.cut.edge])
            for channel in 0..<line.cut.channels {
                let start = channel * line.cut.delayFrames + cursor * schedule.blockFrames
                slots[line.delayed.offset + channel * line.delayed.frames] =
                    Array(delayed[start..<(start + schedule.blockFrames)])
            }
        }
    }

    static func renderSteps(
        _ schedule: RoutingSchedule, slots: inout [Int: [Float]], results: inout [NodeID: [[Float]]]
    ) throws {
        for step in schedule.steps {
            for (channel, row) in step.rows.enumerated() {
                let mixed = try mix(
                    row, operation: step.operation, slots: slots, frames: schedule.blockFrames
                )
                slots[step.output.offset + channel * step.output.frames] = mixed
            }
            results[step.node, default: []].append(try #require(slots[step.output.offset]))
        }
    }

    static func mix(
        _ row: RoutingRow, operation: RoutingOperation, slots: [Int: [Float]], frames: Int
    ) throws -> [Float] {
        var mixed = Array(repeating: Float.zero, count: frames)
        if row.isBitCopy {
            let term = try #require(row.terms.first)
            mixed = try #require(slots[term])
        } else {
            for term in row.terms {
                let source = try #require(slots[term])
                for frame in mixed.indices {
                    mixed[frame] += source[frame]
                }
            }
        }
        switch operation {
        case .copy: break
        case .zero: mixed = Array(repeating: Float.zero, count: frames)
        case .scale(let gain): mixed = mixed.map { $0 * gain }
        }
        return mixed
    }

    static func writeDelayLines(
        _ schedule: RoutingSchedule, slots: [Int: [Float]],
        storage: inout [EdgeID: [Float]], cursors: inout [EdgeID: Int]
    ) throws {
        for line in schedule.delayLines {
            let cursor = try #require(cursors[line.cut.edge])
            let startRegion = cursor * schedule.blockFrames
            var ring = try #require(storage[line.cut.edge])
            for channel in 0..<line.cut.channels {
                let sourceOffset = line.source.offset + channel * line.source.frames
                let source = try #require(slots[sourceOffset])
                let start = channel * line.cut.delayFrames + startRegion
                for frame in source.indices {
                    ring[start + frame] = source[frame]
                }
            }
            storage[line.cut.edge] = ring
            cursors[line.cut.edge] = (cursor + 1) % line.cut.delayBlocks
        }
    }

    @Test
    func feedbackBoundariesAndGainCeilingAreTyped() throws {
        let edge = EdgeID(validated: "plan.feedback.boundary")
        #expect(try FeedbackCut.make(
            edge: edge, feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: -0.0),
            channels: 1, blockFrames: 3
        ).delayFrames == 3)
        #expect(try FeedbackCut.make(
            edge: edge, feedback: EdgeFeedback(delayBlocks: 3, gainCeilingDb: -9),
            channels: 1, blockFrames: 3
        ).delayFrames == 9)
        #expect(throws: RoutingScheduleRefusal.inconsistentSchedule(.delayLine)) {
            try FeedbackCut.make(
                edge: edge, feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: 0),
                channels: 0, blockFrames: 1
            )
        }
        #expect(throws: RoutingScheduleRefusal.feedbackDelayTooShort(edge, 0)) {
            try FeedbackCut.make(
                edge: edge, feedback: EdgeFeedback(delayBlocks: 0, gainCeilingDb: 0),
                channels: 1, blockFrames: 1
            )
        }
        #expect(throws: RoutingScheduleRefusal.feedbackGainNotCapped(edge)) {
            try FeedbackCut.make(
                edge: edge, feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: 0.1),
                channels: 1, blockFrames: 1
            )
        }
        #expect(try FeedbackCut.make(
            edge: edge, feedback: EdgeFeedback(delayBlocks: Int.max / 2, gainCeilingDb: 0),
            channels: 1, blockFrames: 2
        ).delayFrames == Int.max - 1)
        #expect(throws: RoutingScheduleRefusal.arithmeticOverflow(.delayFrames)) {
            try FeedbackCut.make(
                edge: edge, feedback: EdgeFeedback(delayBlocks: Int.max / 2 + 1, gainCeilingDb: 0),
                channels: 1, blockFrames: 2
            )
        }
    }

    static func gain(id: NodeID, input: PortID, output: PortID) -> GraphNode {
        GraphNode(
            id: id, kind: .audioGain, label: "Gain",
            ports: [
                GraphPort(id: input, direction: .input, signal: .audio, channels: 1),
                GraphPort(id: output, direction: .output, signal: .audio, channels: 1)
            ], linearGain: 1
        )
    }

    static func edge(
        _ id: String, from source: NodeID, _ sourcePort: PortID,
        to destination: NodeID, _ destinationPort: PortID
    ) throws -> GraphEdge {
        GraphEdge(
            id: try EdgeID(id),
            from: PortAddress(node: source, port: sourcePort),
            to: PortAddress(node: destination, port: destinationPort)
        )
    }
}
