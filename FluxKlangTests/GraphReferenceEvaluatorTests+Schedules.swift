import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    private static func once(_ graph: GraphDocument, _ input: [Float], frames: Int = 4) throws -> ReferenceBlockResult {
        let evaluator = try makeEvaluator(graph, frames: frames)
        return try evaluator.evaluate(input, state: evaluator.initialState)
    }

    @Test("GC3 a direct plan is a bit copy that keeps negative zero and subnormals")
    func referenceEvaluatorDirectPlanIsABitCopy() throws {
        let graph = Self.directGraph()
        let plan = try Self.schedule(graph)
        #expect(plan.steps.map(\.operation) == [.copy])
        #expect(plan.steps.map { $0.rows.map(\.isBitCopy) } == [[true]])
        let input: [Float] = [0.5, -0.0, .leastNonzeroMagnitude, -3]
        let result = try Self.once(graph, input)
        #expect(Self.bits(result.output) == Self.bits(input))
        #expect(result.executedNodes == [NodeID(validated: "gc3.out.z")])
        #expect(result.chargedWork == plan.accounting.sampleWork)
        #expect(result.chargedWork == 20)
        #expect(result.state == ReferenceEvaluatorState(blocksProcessed: 1, lines: []))
    }

    @Test("GC3 gain 0.5 and 2.0 give exact values")
    func referenceEvaluatorGainPlansGiveExactValues() throws {
        let input: [Float] = [1, -2, 3, 0.25]
        let half = try Self.once(Self.gainChainGraph([0.5]), input)
        #expect(half.output == [0.5, -1, 1.5, 0.125])
        let double = try Self.once(Self.gainChainGraph([2]), input)
        #expect(double.output == [2, -4, 6, 0.5])
        let plan = try Self.schedule(Self.gainChainGraph([0.5]))
        #expect(plan.steps.map(\.operation) == [.scale(0.5), .copy])
        let largest = try Self.once(Self.gainChainGraph([16]), [1, 2, 3, 4])
        #expect(largest.output == [16, 32, 48, 64])
    }

    @Test("GC3 a gain chain of 0.5 then 2.0 restores a power-of-two vector bit for bit")
    func referenceEvaluatorGainChainRestoresInput() throws {
        let input: [Float] = [1, -2, 4, 0.125]
        let result = try Self.once(Self.gainChainGraph([0.5, 2]), input)
        #expect(Self.bits(result.output) == Self.bits(input))
        let names = ["gc3.gain.g0", "gc3.gain.g1", "gc3.out.z"].map { Self.nodeID($0) }
        #expect(result.executedNodes == names)
        let reversed = try Self.once(Self.gainChainGraph([2, 0.5]), input)
        #expect(Self.bits(reversed.output) == Self.bits(input))
    }

    @Test("GC3 gain 16 refuses a finite input that overflows and names the first failure")
    func referenceEvaluatorLargestGainRefusesOverflow() throws {
        let evaluator = try Self.makeEvaluator(Self.gainChainGraph([16]))
        let node = NodeID(validated: "gc3.gain.g0")
        #expect(throws: ReferenceEvaluatorRefusal.blockFailed(
            block: 0, fault: .nonFiniteGain(node: node, channel: 0, frame: 1)
        )) {
            try evaluator.evaluate([1, 2e38, 3, 2e38], state: evaluator.initialState)
        }
        let edge = try evaluator.evaluate([1, 2e37, 3, 4], state: evaluator.initialState)
        #expect(edge.output == [16, 3.2e38, 48, 64])
    }

    @Test("GC3 a gain of exactly one plans a copy and keeps every bit pattern")
    func referenceEvaluatorUnityGainKeepsBitPatterns() throws {
        let graph = Self.gainChainGraph([1])
        let plan = try Self.schedule(graph)
        #expect(plan.steps.map(\.operation) == [.copy, .copy])
        let input: [Float] = [-0.0, 0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude]
        #expect(Self.bits(try Self.once(graph, input).output) == Self.bits(input))
    }

    @Test("GC3 fan-in of three sources sums in edge order and the reversed order differs")
    func referenceEvaluatorFanInSumsInEdgeOrder() throws {
        let input: [Float] = [
            16_777_216, 1, 0.5, -1,
            1, 2, 0.25, 0,
            -16_777_216, 3, 0.125, 1
        ]
        let forward = try Self.once(Self.fanInGraph(sources: 3), input)
        #expect(Self.bits(forward.output) == Self.bits([0, 6, 0.875, 0]))
        let reversed = try Self.once(Self.fanInGraph(sources: 3, reversedEdges: true), input)
        #expect(Self.bits(reversed.output) == Self.bits([1, 6, 0.875, 0]))
        let pair = try Self.once(Self.fanInGraph(sources: 2), [1, 2, 3, 4, 10, 20, 30, 40])
        #expect(pair.output == [11, 22, 33, 44])
    }

    @Test("GC3 mixOrder matches the term order of the fan-in rows")
    func referenceEvaluatorMixOrderMatchesTermOrder() throws {
        let forward = try Self.schedule(Self.fanInGraph(sources: 3))
        let step = try #require(forward.steps.first)
        let edges = ["fan0", "fan1", "fan2"].map { Self.edgeID("gc3.edge.\($0)") }
        #expect(step.mixOrder == edges)
        let offsets = forward.inputs.map(\.slot.offset)
        #expect(step.rows.map(\.terms) == [offsets])
        let reversed = try #require(try Self.schedule(Self.fanInGraph(sources: 3, reversedEdges: true)).steps.first)
        #expect(reversed.mixOrder == edges.reversed())
        #expect(reversed.rows.map(\.terms) == [offsets.reversed()])
    }

    @Test("GC3 a shared node runs once per block and both consumers read the same values")
    func referenceEvaluatorSharedNodeRunsOnce() throws {
        let graph = Self.sharedGraph(gain: 2)
        let plan = try Self.schedule(graph)
        let result = try Self.once(graph, [1, 2, 3, 4])
        #expect(result.output == [2, 4, 6, 8, 2, 4, 6, 8])
        let expected = ["gc3.gain.s", "gc3.out.y", "gc3.out.z"].map { Self.nodeID($0) }
        #expect(result.executedNodes == expected)
        #expect(result.executedNodes == plan.steps.map(\.node))
        #expect(Set(result.executedNodes).count == result.executedNodes.count)
        #expect(result.executedNodes.filter { $0 == NodeID(validated: "gc3.gain.s") }.count == 1)
    }

    @Test("GC3 a one-block feedback loop feeds back the previous source block")
    func referenceEvaluatorOneBlockFeedbackUsesThePreviousBlock() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 1))
        let blocks: [[Float]] = [[1, 2, 3, 4], [10, 20, 30, 40], [100, 200, 300, 400]]
        let folded = try Self.fold(evaluator, blocks)
        #expect(folded.outputs == [[1, 2, 3, 4], [11, 22, 33, 44], [111, 222, 333, 444]])
        #expect(folded.state.blocksProcessed == 3)
        #expect(folded.state.lines == [[111, 222, 333, 444]])
        let first = try evaluator.evaluate(blocks[0], state: evaluator.initialState)
        #expect(first.state.lines == [[1, 2, 3, 4]])
    }

    @Test("GC3 a three-block feedback loop consumes the source of block k minus three")
    func referenceEvaluatorThreeBlockFeedbackUsesBlockKMinusThree() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 3))
        let blocks: [[Float]] = [1, 2, 4, 8, 16, 32].map { [Float](repeating: $0, count: 4) }
        let folded = try Self.fold(evaluator, blocks)
        let expected: [Float] = [1, 2, 4, 9, 18, 36]
        #expect(folded.outputs == expected.map { [Float](repeating: $0, count: 4) })
        let early = try Self.fold(evaluator, Array(blocks.prefix(3)))
        #expect(early.state.lines == [[1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4]])
        #expect(try #require(folded.state.lines.first).count == 12)
    }

    @Test("GC3 two independent loops of one and three blocks keep separate rings")
    func referenceEvaluatorTwoLoopsKeepSeparateRings() throws {
        let evaluator = try Self.makeEvaluator(Self.twoLoopGraph(), frames: 2)
        let blocks: [[Float]] = [[1, 10], [2, 20], [3, 30], [4, 40], [5, 50]]
        let folded = try Self.fold(evaluator, blocks)
        #expect(folded.outputs == [[1, 10], [3, 30], [6, 60], [10, 100], [15, 150]])
        #expect(folded.state.lines.map(\.count) == [6, 2])
    }

    @Test("GC3 a two-channel two-block feedback loop keeps each channel in its own ring row")
    func referenceEvaluatorTwoChannelFeedbackKeepsChannelsApart() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 2, channels: 2), frames: 2)
        let blocks: [[Float]] = [[1, 2, 10, 20], [3, 4, 30, 40], [5, 6, 50, 60], [7, 8, 70, 80]]
        let folded = try Self.fold(evaluator, blocks)
        #expect(folded.outputs == [[1, 2, 10, 20], [3, 4, 30, 40], [6, 8, 60, 80], [10, 12, 100, 120]])
        #expect(folded.state.lines == [[6, 8, 10, 12, 60, 80, 100, 120]])
        #expect(evaluator.initialState.lines.map(\.count) == [8])
    }

    @Test("GC3 zero-input blocks give positive zero and zero-endpoint graphs use empty arrays")
    func referenceEvaluatorZeroInputBlocksAndEmptyEndpoints() throws {
        let zeros = try Self.once(Self.gainChainGraph([0.5]), [0, 0, 0, 0])
        #expect(Self.bits(zeros.output) == Self.bits([0, 0, 0, 0]))
        let sourceless = try Self.makeEvaluator(Self.graph([Self.outputNode("z")], []))
        #expect(sourceless.inputFloatsPerBlock == 0)
        #expect(sourceless.outputFloatsPerBlock == 4)
        let silent = try sourceless.evaluate([], state: sourceless.initialState)
        #expect(Self.bits(silent.output) == Self.bits([0, 0, 0, 0]))
        #expect(throws: ReferenceEvaluatorRefusal.blockFailed(
            block: 0, fault: .inputSizeMismatch(expected: 0, actual: 1)
        )) { try sourceless.evaluate([0], state: sourceless.initialState) }
        let sinkless = try Self.makeEvaluator(Self.graph([Self.inputNode("a")], []))
        #expect(sinkless.outputFloatsPerBlock == 0)
        let none = try sinkless.evaluate([1, 2, 3, 4], state: sinkless.initialState)
        #expect(none.output.isEmpty)
        #expect(none.executedNodes.isEmpty)
    }

    @Test("GC3 the builder's empty graph has zero scratch and runs through evaluate and run")
    func referenceEvaluatorEmptyGraphHasZeroScratch() throws {
        let plan = try Self.schedule(Self.graph([], []))
        #expect(plan.accounting.scratchFloats == 0)
        #expect(plan.accounting.sampleWork == 0)
        let tightest = try ReferenceEvaluatorLimits(
            maximumScratchFloats: 1, maximumStateFloats: 1, maximumBlocksPerRun: 1,
            maximumRunWork: 1, maximumRunOutputFloats: 1
        )
        let evaluator = try GraphReferenceEvaluator(schedule: plan, limits: tightest)
        #expect(evaluator.inputFloatsPerBlock == 0)
        #expect(evaluator.outputFloatsPerBlock == 0)
        #expect(evaluator.initialState == ReferenceEvaluatorState(blocksProcessed: 0, lines: []))
        let block = try evaluator.evaluate([], state: evaluator.initialState)
        #expect(block.output.isEmpty)
        #expect(block.executedNodes.isEmpty)
        #expect(block.chargedWork == 0)
        #expect(block.state == ReferenceEvaluatorState(blocksProcessed: 1, lines: []))
        let run = try evaluator.run([[]], from: evaluator.initialState)
        #expect(run.outputs == [[]])
        #expect(run.chargedWork == 0)
        #expect(run.state == block.state)
        #expect(throws: ReferenceEvaluatorRefusal.invalidBlockCount(0)) {
            try evaluator.run([], from: evaluator.initialState)
        }
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.blocks, required: 2, maximum: 1)) {
            try evaluator.run([[], []], from: evaluator.initialState)
        }
        #expect(throws: ReferenceEvaluatorRefusal.blockFailed(
            block: 0, fault: .inputSizeMismatch(expected: 0, actual: 1)
        )) {
            try evaluator.evaluate([0], state: evaluator.initialState)
        }
        let stray = ReferenceEvaluatorState(blocksProcessed: 0, lines: [[]])
        #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) { try evaluator.evaluate([], state: stray) }
    }

    @Test("GC3 the scratch count guard accepts zero and refuses a negative count")
    func referenceEvaluatorScratchCountGuardBoundary() throws {
        try GraphReferenceEvaluator.checkScratchCount(0)
        try GraphReferenceEvaluator.checkScratchCount(1)
        try GraphReferenceEvaluator.checkScratchCount(Int.max)
        let defect = ReferenceEvaluatorRefusal.scheduleDefect(.accountingMismatch)
        #expect(throws: defect) { try GraphReferenceEvaluator.checkScratchCount(-1) }
        #expect(throws: defect) { try GraphReferenceEvaluator.checkScratchCount(Int.min) }
    }

    @Test("GC3 an input endpoint of sixty-four channels keeps every sample in place")
    func referenceEvaluatorSixtyFourChannelInput() throws {
        let input = (0..<256).map { Float($0) - 100 }
        let result = try Self.once(Self.directGraph(channels: 64), input)
        #expect(Self.bits(result.output) == Self.bits(input))
    }

    @Test("GC3 two output endpoints keep first-channel order and input staging follows first channels")
    func referenceEvaluatorOutputEndpointsKeepFirstChannelOrder() throws {
        let first = Self.inputNode("a")
        let second = Self.inputNode("b")
        let early = Self.outputNode("y")
        let late = Self.outputNode("z")
        let graph = Self.graph(
            [first, second, early, late],
            [Self.edge("aToZ", first, late), Self.edge("bToY", second, early)]
        )
        let plan = try Self.schedule(graph)
        #expect(plan.outputs.map(\.endpoint.firstChannel) == [0, 1])
        #expect(plan.inputs.map(\.endpoint.firstChannel) == [0, 1])
        let result = try Self.once(graph, [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(result.output == [5, 6, 7, 8, 1, 2, 3, 4])
    }
}
