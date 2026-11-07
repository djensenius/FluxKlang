import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    typealias Documents = AudioRoutingTestFixtures.Documents

    static let graphID = GraphID(validated: "gc3.graph")
    static let outPort = PortID(validated: "gc3.out")
    static let inPort = PortID(validated: "gc3.in")

    static func nodeID(_ value: String) -> NodeID {
        do { return try NodeID(value) } catch { preconditionFailure("invalid fixture node id \(value)") }
    }

    static func edgeID(_ value: String) -> EdgeID {
        do { return try EdgeID(value) } catch { preconditionFailure("invalid fixture edge id \(value)") }
    }

    static func roleID(_ value: String) -> RoleID {
        do { return try RoleID(value) } catch { preconditionFailure("invalid fixture role id \(value)") }
    }

    static func inputNode(_ name: String, channels: Int = 1) -> GraphNode {
        GraphNode(
            id: nodeID("gc3.in.\(name)"), kind: .roleInput, label: name,
            role: roleID("gc3.role.in.\(name)"),
            ports: [GraphPort(id: outPort, direction: .output, signal: .audio, channels: channels)]
        )
    }

    static func outputNode(_ name: String, channels: Int = 1) -> GraphNode {
        GraphNode(
            id: nodeID("gc3.out.\(name)"), kind: .roleOutput, label: name,
            role: roleID("gc3.role.out.\(name)"),
            ports: [GraphPort(id: inPort, direction: .input, signal: .audio, channels: channels)]
        )
    }

    static func gainNode(_ name: String, gain: Double, channels: Int = 1) -> GraphNode {
        GraphNode(
            id: nodeID("gc3.gain.\(name)"), kind: .audioGain, label: name,
            ports: [
                GraphPort(id: inPort, direction: .input, signal: .audio, channels: channels),
                GraphPort(id: outPort, direction: .output, signal: .audio, channels: channels)
            ], linearGain: gain
        )
    }

    static func edge(
        _ name: String, _ source: GraphNode, _ destination: GraphNode,
        map: [[Int]]? = nil, feedback: EdgeFeedback? = nil
    ) -> GraphEdge {
        GraphEdge(
            id: edgeID("gc3.edge.\(name)"),
            from: PortAddress(node: source.id, port: outPort), to: PortAddress(node: destination.id, port: inPort),
            conversion: map.map { EdgeConversion(map: $0) }, feedback: feedback
        )
    }

    static func graph(_ nodes: [GraphNode], _ edges: [GraphEdge]) -> GraphDocument {
        let features = nodes.contains { $0.kind == .audioGain } ? [GraphDocument.constantGainFeature] : []
        return GraphDocument(id: graphID, nodes: nodes, edges: edges, requiredFeatures: features)
    }

    static func directGraph(channels: Int = 1) -> GraphDocument {
        let source = inputNode("a", channels: channels)
        let sink = outputNode("z", channels: channels)
        return graph([source, sink], [edge("direct", source, sink)])
    }

    static func gainChainGraph(_ gains: [Double], channels: Int = 1) -> GraphDocument {
        let source = inputNode("a", channels: channels)
        let sink = outputNode("z", channels: channels)
        let gainNodes = gains.indices.map { gainNode("g\($0)", gain: gains[$0], channels: channels) }
        let chain = [source] + gainNodes + [sink]
        let edges = (0..<(chain.count - 1)).map { edge("chain\($0)", chain[$0], chain[$0 + 1]) }
        return graph(chain, edges)
    }

    /// `sources` inputs a, b, c ... of `channels` channels each, summed into one output in the given edge order.
    static func fanInGraph(sources: Int, reversedEdges: Bool = false, channels: Int = 1) -> GraphDocument {
        let names = ["a", "b", "c", "d"]
        let inputs = names.prefix(sources).map { inputNode($0, channels: channels) }
        let sink = outputNode("z", channels: channels)
        var edges = inputs.indices.map { edge("fan\($0)", inputs[$0], sink) }
        if reversedEdges { edges.reverse() }
        return graph(inputs + [sink], edges)
    }

    /// One mono input feeding gain node `s`, which feeds two outputs y and z (a shared node).
    static func sharedGraph(gain: Double = 2) -> GraphDocument {
        let source = inputNode("a")
        let shared = gainNode("s", gain: gain)
        let first = outputNode("y")
        let second = outputNode("z")
        return graph(
            [source, shared, first, second],
            [edge("in", source, shared), edge("toY", shared, first), edge("toZ", shared, second)]
        )
    }

    /// Mono input into unity gain node `a`, which has a feedback self loop of `delayBlocks` and feeds the output.
    static func feedbackGraph(delayBlocks: Int, gain: Double = 1, channels: Int = 1) -> GraphDocument {
        let source = inputNode("a", channels: channels)
        let loop = gainNode("a", gain: gain, channels: channels)
        let sink = outputNode("z", channels: channels)
        let cut = EdgeFeedback(delayBlocks: delayBlocks, gainCeilingDb: 0)
        return graph(
            [source, loop, sink],
            [edge("in", source, loop), edge("loop", loop, loop, feedback: cut), edge("out", loop, sink)]
        )
    }

    /// The two-loop graph of GC2: a one-block loop on `a` and a three-block loop on `b`, output reads `a`.
    static func twoLoopGraph() -> GraphDocument {
        let source = inputNode("a")
        let first = gainNode("a", gain: 1)
        let second = gainNode("b", gain: 1)
        let sink = outputNode("z")
        return graph([source, first, second, sink], [
            edge("inA", source, first), edge("inB", source, second),
            edge("loopB", second, second, feedback: EdgeFeedback(delayBlocks: 3, gainCeilingDb: 0)),
            edge("loopA", first, first, feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)),
            edge("out", first, sink)
        ])
    }

    static func routingLimits(frames: Int) -> AudioRoutingLimits {
        AudioRoutingLimits(
            maxFrames: frames, maxInputChannels: 128, maxOutputChannels: 128, maxTerms: 4_096,
            maxScratchBytes: 4_194_304, maxSampleWork: 4_194_304
        )
    }

    static func schedule(_ graph: GraphDocument, frames: Int = 4) throws -> RoutingSchedule {
        let request = try RoutingScheduleRequest(
            sampleRate: 48_000, blockFrames: frames, limits: routingLimits(frames: frames)
        )
        return try RoutingScheduleBuilder.build(graph, request: request)
    }

    static func makeEvaluator(
        _ graph: GraphDocument, frames: Int = 4, limits: ReferenceEvaluatorLimits = .standard
    ) throws -> GraphReferenceEvaluator {
        try GraphReferenceEvaluator(schedule: try schedule(graph, frames: frames), limits: limits)
    }

    /// Evaluates blocks in order through `evaluate` alone and returns every output and the final state.
    static func fold(
        _ evaluator: GraphReferenceEvaluator, _ blocks: [[Float]]
    ) throws -> (outputs: [[Float]], state: ReferenceEvaluatorState) {
        var state = evaluator.initialState
        var outputs: [[Float]] = []
        for block in blocks {
            let result = try evaluator.evaluate(block, state: state)
            outputs.append(result.output)
            state = result.state
        }
        return (outputs, state)
    }

    static func limits(
        scratch: Int = 4_194_304, state: Int = 4_194_304, blocks: Int = 1_024,
        work: Int = 1_073_741_824, output: Int = 4_194_304
    ) throws -> ReferenceEvaluatorLimits {
        try ReferenceEvaluatorLimits(
            maximumScratchFloats: scratch, maximumStateFloats: state, maximumBlocksPerRun: blocks,
            maximumRunWork: work, maximumRunOutputFloats: output
        )
    }

    /// The single mapping from the offline processor's refusals to the evaluator's block-fault kinds.
    static func processorRefusal(for fault: ReferenceBlockFault) -> AudioRoutingProcessRefusal? {
        switch fault {
        case .nonFiniteInput: .nonFiniteInput
        case .nonFiniteSum: .nonFiniteSum
        case .inputSizeMismatch, .nonFiniteGain, .blockCounterOverflow: nil
        }
    }

    struct OracleRun {
        let result: AudioRoutingProcessResult
        let output: [Float]
    }

    /// Runs `OfflineAudioRoutingProcessor` on the same documents with `maxFrames == frames`.
    static func oracle(_ documents: Documents, frames: Int, input: [Float]) throws -> OracleRun {
        var processor = try OfflineAudioRoutingProcessor(
            project: documents.project, selectedGraph: documents.graph,
            limits: AudioRoutingTestFixtures.limits(
                frames: frames, inputs: 64, outputs: 64, terms: 512, scratch: 262_144, work: 262_144
            )
        )
        var output = [Float](repeating: -37, count: processor.layout.outputSampleCount)
        var peaks = [Float](repeating: -1, count: processor.layout.peakCount)
        let result = AudioRoutingTestFixtures.process(
            &processor, frames: frames, input: input, output: &output, peaks: &peaks
        )
        return OracleRun(result: result, output: output)
    }

    /// Runs the evaluator on the same documents; the refusal is returned instead of thrown.
    static func reference(
        _ documents: Documents, frames: Int, input: [Float]
    ) throws -> Result<[Float], ReferenceEvaluatorRefusal> {
        let evaluator = try makeEvaluator(documents.graph, frames: frames)
        do {
            return .success(try evaluator.evaluate(input, state: evaluator.initialState).output)
        } catch {
            return .failure(error)
        }
    }
}
