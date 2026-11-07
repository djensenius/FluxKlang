import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    private static func permutations(_ count: Int) -> [[Int]] {
        guard count > 1 else { return [Array(0..<count)] }
        var all: [[Int]] = []
        for head in 0..<count {
            var rest = Array(0..<count)
            rest.remove(at: head)
            for tail in permutations(count - 1) {
                all.append([head] + tail.map { rest[$0] })
            }
        }
        return all
    }

    private static func reordered(
        _ document: GraphDocument, nodes nodeOrder: [Int], edges edgeOrder: [Int]
    ) -> GraphDocument {
        graph(nodeOrder.map { document.nodes[$0] }, edgeOrder.map { document.edges[$0] })
    }

    private static let blocks: [[Float]] = [[1, 2, 3, 4], [-5, 6, -7, 8], [0.5, 0.25, 0.125, 0.0625]]

    @Test("GC3 evaluating the same block twice gives identical results")
    func referenceEvaluatorEvaluateIsRepeatable() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 3))
        let first = try Self.fold(evaluator, Self.blocks)
        let second = try Self.fold(evaluator, Self.blocks)
        #expect(first.outputs == second.outputs)
        #expect(first.state == second.state)
        let again = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 3))
        #expect(try Self.fold(again, Self.blocks).outputs == first.outputs)
        let single = try evaluator.evaluate(Self.blocks[0], state: evaluator.initialState)
        #expect(single == (try evaluator.evaluate(Self.blocks[0], state: evaluator.initialState)))
    }

    @Test("GC3 a run equals the fold of evaluate for outputs, state and charged work")
    func referenceEvaluatorRunEqualsTheFold() throws {
        for graph in [Self.feedbackGraph(delayBlocks: 1), Self.feedbackGraph(delayBlocks: 3), Self.sharedGraph()] {
            let evaluator = try Self.makeEvaluator(graph)
            let folded = try Self.fold(evaluator, Self.blocks)
            let run = try evaluator.run(Self.blocks, from: evaluator.initialState)
            #expect(run.outputs == folded.outputs)
            #expect(run.state == folded.state)
            #expect(run.chargedWork == Self.blocks.count * evaluator.schedule.accounting.sampleWork)
        }
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 3))
        let head = try evaluator.run([Self.blocks[0]], from: evaluator.initialState)
        let tail = try evaluator.run(Array(Self.blocks.dropFirst()), from: head.state)
        let whole = try evaluator.run(Self.blocks, from: evaluator.initialState)
        #expect(head.outputs + tail.outputs == whole.outputs)
        #expect(tail.state == whole.state)
    }

    @Test("GC3 every node order of the shared and feedback graphs gives the same bits")
    func referenceEvaluatorNodeOrderDoesNotChangeResults() throws {
        let orders = Self.permutations(4)
        #expect(orders.count == 24)
        #expect(Set(orders).count == 24)
        let shared = Self.sharedGraph()
        let loop = Self.feedbackGraph(delayBlocks: 3)
        let sharedBase = try Self.fold(Self.makeEvaluator(shared), Self.blocks)
        let loopBase = try Self.fold(Self.makeEvaluator(loop), Self.blocks)
        for order in orders {
            let edges = Array(0..<shared.edges.count)
            let permuted = Self.reordered(shared, nodes: order, edges: edges)
            let result = try Self.fold(Self.makeEvaluator(permuted), Self.blocks)
            #expect(result.outputs.map(Self.bits) == sharedBase.outputs.map(Self.bits))
            #expect(result.state == sharedBase.state)
        }
        for order in Self.permutations(3) {
            let permuted = Self.reordered(loop, nodes: order, edges: [0, 1, 2])
            let result = try Self.fold(Self.makeEvaluator(permuted), Self.blocks)
            #expect(result.outputs.map(Self.bits) == loopBase.outputs.map(Self.bits))
            #expect(result.state == loopBase.state)
        }
    }

    @Test("GC3 a fixed table of edge shuffles keeps the shared and feedback results")
    func referenceEvaluatorEdgeOrderDoesNotChangeResults() throws {
        let table = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let shared = Self.sharedGraph()
        let loop = Self.feedbackGraph(delayBlocks: 1)
        let sharedBase = try Self.fold(Self.makeEvaluator(shared), Self.blocks).outputs
        let loopBase = try Self.fold(Self.makeEvaluator(loop), Self.blocks).outputs
        for edges in table {
            let sharedResult = try Self.fold(
                Self.makeEvaluator(Self.reordered(shared, nodes: [3, 2, 1, 0], edges: edges)), Self.blocks
            )
            #expect(sharedResult.outputs.map(Self.bits) == sharedBase.map(Self.bits))
            let loopResult = try Self.fold(
                Self.makeEvaluator(Self.reordered(loop, nodes: [2, 0, 1], edges: edges)), Self.blocks
            )
            #expect(loopResult.outputs.map(Self.bits) == loopBase.map(Self.bits))
        }
    }

    @Test("GC3 the executed node list is the plan step order for every graph")
    func referenceEvaluatorExecutedNodesAreTheStepOrder() throws {
        let graphs = [
            Self.directGraph(), Self.gainChainGraph([2, 0.5]), Self.sharedGraph(),
            Self.feedbackGraph(delayBlocks: 3), Self.fanInGraph(sources: 3)
        ]
        for graph in graphs {
            let plan = try Self.schedule(graph)
            let evaluator = try GraphReferenceEvaluator(schedule: plan)
            let input = [Float](repeating: 1, count: evaluator.inputFloatsPerBlock)
            let result = try evaluator.evaluate(input, state: evaluator.initialState)
            #expect(result.executedNodes == plan.steps.map(\.node))
            #expect(!result.executedNodes.isEmpty)
        }
    }
}
