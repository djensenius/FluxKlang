import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    private static let block: [Float] = [1, 2, 3, 4]

    private static func fault(_ block: Int, _ fault: ReferenceBlockFault) -> ReferenceEvaluatorRefusal {
        .blockFailed(block: block, fault: fault)
    }

    private static func fault(_ fault: ReferenceBlockFault) -> ReferenceEvaluatorRefusal {
        .blockFailed(block: 0, fault: fault)
    }

    @Test("GC3 a state with the wrong shape is refused and the same call then gives the same result")
    func referenceEvaluatorStateMismatchIsRefused() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 3))
        let good = evaluator.initialState
        #expect(good.lines.map(\.count) == [12])
        let baseline = try evaluator.evaluate(Self.block, state: good)
        let shapes = [
            ReferenceEvaluatorState(blocksProcessed: 0, lines: []),
            ReferenceEvaluatorState(blocksProcessed: 0, lines: [[Float](repeating: 0, count: 11)]),
            ReferenceEvaluatorState(blocksProcessed: 0, lines: [[Float](repeating: 0, count: 13)]),
            ReferenceEvaluatorState(blocksProcessed: 0, lines: good.lines + good.lines),
            ReferenceEvaluatorState(blocksProcessed: -1, lines: good.lines),
            ReferenceEvaluatorState(blocksProcessed: Int.min, lines: good.lines)
        ]
        for bad in shapes {
            #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) { try evaluator.evaluate(Self.block, state: bad) }
            #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) { try evaluator.run([Self.block], from: bad) }
        }
        let again = try evaluator.evaluate(Self.block, state: good)
        #expect(again.output == baseline.output)
        #expect(again.state == baseline.state)
        let accepted = ReferenceEvaluatorState(blocksProcessed: 0, lines: good.lines)
        #expect(try evaluator.evaluate(Self.block, state: accepted).state.blocksProcessed == 1)
        let stateless = try Self.makeEvaluator(Self.gainChainGraph([0.5]))
        let extra = ReferenceEvaluatorState(blocksProcessed: 0, lines: [[0]])
        #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) { try stateless.evaluate(Self.block, state: extra) }
    }

    @Test("GC3 input length is exact: one fewer or one more float is refused")
    func referenceEvaluatorInputSizeIsExact() throws {
        let evaluator = try Self.makeEvaluator(Self.gainChainGraph([0.5]))
        let state = evaluator.initialState
        #expect(try evaluator.evaluate(Self.block, state: state).output == [0.5, 1, 1.5, 2])
        #expect(throws: Self.fault(.inputSizeMismatch(expected: 4, actual: 3))) {
            try evaluator.evaluate([1, 2, 3], state: state)
        }
        #expect(throws: Self.fault(.inputSizeMismatch(expected: 4, actual: 5))) {
            try evaluator.evaluate([1, 2, 3, 4, 5], state: state)
        }
        #expect(throws: Self.fault(.inputSizeMismatch(expected: 4, actual: 0))) {
            try evaluator.evaluate([], state: state)
        }
        let wide = try Self.makeEvaluator(Self.fanInGraph(sources: 2))
        #expect(wide.inputFloatsPerBlock == 8)
        #expect(throws: Self.fault(.inputSizeMismatch(expected: 8, actual: 4))) {
            try wide.evaluate(Self.block, state: wide.initialState)
        }
    }

    @Test("GC3 the block counter refuses at the largest value and accepts one below it")
    func referenceEvaluatorBlockCounterOverflow() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 3))
        let lines = evaluator.initialState.lines
        let last = ReferenceEvaluatorState(blocksProcessed: Int.max, lines: lines)
        #expect(throws: Self.fault(.blockCounterOverflow)) { try evaluator.evaluate(Self.block, state: last) }
        #expect(throws: Self.fault(.blockCounterOverflow)) { try evaluator.run([Self.block], from: last) }
        let near = ReferenceEvaluatorState(blocksProcessed: Int.max - 1, lines: lines)
        let result = try evaluator.evaluate(Self.block, state: near)
        #expect(result.state.blocksProcessed == Int.max)
        #expect(throws: Self.fault(1, .blockCounterOverflow)) {
            try evaluator.run([Self.block, Self.block], from: near)
        }
        #expect(last.blocksProcessed == Int.max)
    }

    @Test("GC3 the first non-finite input in endpoint, channel and frame order is reported")
    func referenceEvaluatorFirstNonFiniteInputWins() throws {
        let evaluator = try Self.makeEvaluator(Self.directGraph(channels: 2))
        let state = evaluator.initialState
        var input = [Float](repeating: 1, count: 8)
        input[5] = .infinity
        #expect(throws: Self.fault(.nonFiniteInput(channel: 1, frame: 1))) {
            try evaluator.evaluate(input, state: state)
        }
        input[3] = .nan
        #expect(throws: Self.fault(.nonFiniteInput(channel: 0, frame: 3))) {
            try evaluator.evaluate(input, state: state)
        }
        input[0] = -.infinity
        #expect(throws: Self.fault(.nonFiniteInput(channel: 0, frame: 0))) {
            try evaluator.evaluate(input, state: state)
        }
        var largest = [Float](repeating: 1, count: 8)
        largest[7] = .greatestFiniteMagnitude
        #expect(try evaluator.evaluate(largest, state: state).output == largest)
    }

    @Test("GC3 a fan-in sum that overflows names the node, channel and frame")
    func referenceEvaluatorSumOverflowNamesTheFirstFrame() throws {
        let evaluator = try Self.makeEvaluator(Self.fanInGraph(sources: 2))
        let output = NodeID(validated: "gc3.out.z")
        let big: Float = 3e38
        let input: [Float] = [1, 1, big, 1, 1, 1, big, 1]
        #expect(throws: Self.fault(.nonFiniteSum(node: output, channel: 0, frame: 2))) {
            try evaluator.evaluate(input, state: evaluator.initialState)
        }
        let cancels: [Float] = [1, 1, big, 1, 1, 1, -big, 1]
        #expect(try evaluator.evaluate(cancels, state: evaluator.initialState).output == [2, 2, 0, 2])
    }

    @Test("GC3 faults in a later channel or endpoint name that channel, not channel zero")
    func referenceEvaluatorFaultsNameTheLaterChannel() throws {
        let twoInputs = try Self.makeEvaluator(Self.fanInGraph(sources: 2))
        var input = [Float](repeating: 1, count: 8)
        input[7] = .infinity
        #expect(throws: Self.fault(.nonFiniteInput(channel: 1, frame: 3))) {
            try twoInputs.evaluate(input, state: twoInputs.initialState)
        }
        let output = NodeID(validated: "gc3.out.z")
        let stereoSum = try Self.makeEvaluator(Self.fanInGraph(sources: 2, channels: 2))
        var wide = [Float](repeating: 1, count: 16)
        wide[5] = 3e38
        wide[13] = 3e38
        #expect(throws: Self.fault(.nonFiniteSum(node: output, channel: 1, frame: 1))) {
            try stereoSum.evaluate(wide, state: stereoSum.initialState)
        }
        let stereoGain = try Self.makeEvaluator(Self.gainChainGraph([16], channels: 2))
        var loud = [Float](repeating: 1, count: 8)
        loud[6] = 1e38
        let gainNode = NodeID(validated: "gc3.gain.g0")
        #expect(throws: Self.fault(.nonFiniteGain(node: gainNode, channel: 1, frame: 2))) {
            try stereoGain.evaluate(loud, state: stereoGain.initialState)
        }
    }

    @Test("GC3 the first failing gain step is reported in step order")
    func referenceEvaluatorGainFailureNamesTheFirstStep() throws {
        let evaluator = try Self.makeEvaluator(Self.gainChainGraph([16, 16]))
        let second = NodeID(validated: "gc3.gain.g1")
        let first = NodeID(validated: "gc3.gain.g0")
        #expect(throws: Self.fault(.nonFiniteGain(node: second, channel: 0, frame: 0))) {
            try evaluator.evaluate([1e37, 1, 1, 1], state: evaluator.initialState)
        }
        #expect(throws: Self.fault(.nonFiniteGain(node: first, channel: 0, frame: 2))) {
            try evaluator.evaluate([1, 1, 3e37, 1e37], state: evaluator.initialState)
        }
    }

    @Test("GC3 block checks run in order: state, input size, counter, input values")
    func referenceEvaluatorBlockCheckOrder() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 1))
        let lines = evaluator.initialState.lines
        let badState = ReferenceEvaluatorState(blocksProcessed: Int.max, lines: [])
        #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) { try evaluator.evaluate([1], state: badState) }
        let last = ReferenceEvaluatorState(blocksProcessed: Int.max, lines: lines)
        #expect(throws: Self.fault(.inputSizeMismatch(expected: 4, actual: 1))) {
            try evaluator.evaluate([1], state: last)
        }
        #expect(throws: Self.fault(.blockCounterOverflow)) {
            try evaluator.evaluate([.nan, 1, 1, 1], state: last)
        }
        #expect(throws: Self.fault(.nonFiniteInput(channel: 0, frame: 0))) {
            try evaluator.evaluate([.nan, 1, 1, 1], state: evaluator.initialState)
        }
    }

    @Test("GC3 evaluator construction checks scratch, then state, then per-block work")
    func referenceEvaluatorConstructionCheckOrder() throws {
        let plan = try Self.schedule(Self.feedbackGraph(delayBlocks: 3))
        let scratch = plan.accounting.scratchFloats
        let work = plan.accounting.sampleWork
        #expect(scratch > 1 && work > 1)
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.scratchFloats, required: scratch, maximum: 1)) {
            try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(scratch: 1, state: 1, work: 1))
        }
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.stateFloats, required: 12, maximum: 1)) {
            try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(scratch: scratch, state: 1, work: 1))
        }
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.sampleWork, required: work, maximum: 1)) {
            try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(scratch: scratch, state: 12, work: 1))
        }
    }

    @Test("GC3 run checks run in order: count, blocks, work, output, state, blocks")
    func referenceEvaluatorRunCheckOrder() throws {
        let plan = try Self.schedule(Self.gainChainGraph([0.5]))
        let work = plan.accounting.sampleWork
        let blocks = [[Float]](repeating: Self.block, count: 3)
        let badState = ReferenceEvaluatorState(blocksProcessed: 0, lines: [[0]])
        func run(blocks count: Int, work limit: Int, output: Int) throws -> ReferenceEvaluatorRefusal? {
            let evaluator = try GraphReferenceEvaluator(
                schedule: plan, limits: Self.limits(blocks: count, work: limit, output: output)
            )
            do {
                _ = try evaluator.run([[.nan, 0, 0, 0]] + blocks, from: badState)
                return nil
            } catch {
                return error
            }
        }
        #expect(try run(blocks: 3, work: work, output: 4) == .resourceLimit(.blocks, required: 4, maximum: 3))
        #expect(try run(blocks: 4, work: work, output: 4) == .resourceLimit(
            .sampleWork, required: work * 4, maximum: work
        ))
        #expect(try run(blocks: 4, work: work * 4, output: 4) == .resourceLimit(
            .outputFloats, required: 16, maximum: 4
        ))
        #expect(try run(blocks: 4, work: work * 4, output: 16) == .stateMismatch)
        let fine = try GraphReferenceEvaluator(schedule: plan, limits: .standard)
        let nanFault = ReferenceEvaluatorRefusal.blockFailed(
            block: 0, fault: .nonFiniteInput(channel: 0, frame: 0)
        )
        #expect(throws: nanFault) {
            try fine.run([[.nan, 0, 0, 0]], from: fine.initialState)
        }
        #expect(throws: ReferenceEvaluatorRefusal.invalidBlockCount(0)) {
            try fine.run([], from: badState)
        }
    }

    @Test("GC3 a failing second block returns no outputs and the same run then gives the same result")
    func referenceEvaluatorRunFailureIsAtomic() throws {
        let evaluator = try Self.makeEvaluator(Self.feedbackGraph(delayBlocks: 1))
        let start = try evaluator.evaluate(Self.block, state: evaluator.initialState).state
        let baseline = try evaluator.run([Self.block, Self.block], from: start)
        let bad: [Float] = [1, 2, .nan, 4]
        #expect(throws: Self.fault(1, .nonFiniteInput(channel: 0, frame: 2))) {
            try evaluator.run([Self.block, bad, Self.block], from: start)
        }
        let finished = try evaluator.run([Self.block, Self.block], from: start)
        #expect(finished.outputs == baseline.outputs)
        #expect(finished.state == baseline.state)
        #expect(finished.state.blocksProcessed == 3)
    }

    @Test("GC3 a run reports the index of the failing block and the first size mismatch")
    func referenceEvaluatorRunReportsTheFailingBlockIndex() throws {
        let evaluator = try Self.makeEvaluator(Self.gainChainGraph([16]))
        let huge: [Float] = [3e37, 1, 1, 1]
        let node = NodeID(validated: "gc3.gain.g0")
        #expect(throws: Self.fault(2, .nonFiniteGain(node: node, channel: 0, frame: 0))) {
            try evaluator.run([Self.block, Self.block, huge], from: evaluator.initialState)
        }
        #expect(throws: Self.fault(0, .inputSizeMismatch(expected: 4, actual: 2))) {
            try evaluator.run([[1, 2], Self.block], from: evaluator.initialState)
        }
    }
}
