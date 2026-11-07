import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    private static func refusal(_ body: () throws -> Void) -> ReferenceEvaluatorRefusal? {
        do {
            try body()
            return nil
        } catch let error as ReferenceEvaluatorRefusal {
            return error
        } catch {
            return nil
        }
    }

    private static func build(
        scratch: Int = 1, state: Int = 1, blocks: Int = 1, work: Int = 1, output: Int = 1
    ) -> ReferenceEvaluatorRefusal? {
        refusal {
            _ = try ReferenceEvaluatorLimits(
                maximumScratchFloats: scratch, maximumStateFloats: state, maximumBlocksPerRun: blocks,
                maximumRunWork: work, maximumRunOutputFloats: output
            )
        }
    }

    @Test("GC3 limits accept one and the ceiling and refuse zero, minus one and ceiling plus one")
    func referenceEvaluatorLimitsBoundEveryField() throws {
        let ceilings = [
            ReferenceEvaluatorLimits.scratchFloatsCeiling, ReferenceEvaluatorLimits.stateFloatsCeiling,
            ReferenceEvaluatorLimits.blocksPerRunCeiling, ReferenceEvaluatorLimits.runWorkCeiling,
            ReferenceEvaluatorLimits.runOutputFloatsCeiling
        ]
        #expect(ceilings == [67_108_864, 67_108_864, 65_536, 1_099_511_627_776, 67_108_864])
        let kinds = ReferenceLimitKind.allCases
        #expect(kinds.count == 5)
        for (index, kind) in kinds.enumerated() {
            func values(_ value: Int) -> [Int] {
                var all = [1, 1, 1, 1, 1]
                all[index] = value
                return all
            }
            func attempt(_ value: Int) -> ReferenceEvaluatorRefusal? {
                let all = values(value)
                return Self.build(scratch: all[0], state: all[1], blocks: all[2], work: all[3], output: all[4])
            }
            #expect(attempt(1) == nil)
            #expect(attempt(ceilings[index]) == nil)
            #expect(attempt(0) == .invalidLimits(kind))
            #expect(attempt(-1) == .invalidLimits(kind))
            #expect(attempt(ceilings[index] + 1) == .invalidLimits(kind))
            #expect(attempt(Int.min) == .invalidLimits(kind))
        }
    }

    @Test("GC3 two invalid limit fields report the earlier field in validation order")
    func referenceEvaluatorLimitsReportTheEarlierFieldFirst() {
        #expect(Self.build(scratch: 0, state: 0, blocks: 0, work: 0, output: 0) == .invalidLimits(.scratchFloats))
        #expect(Self.build(state: 0, blocks: 0, work: 0, output: 0) == .invalidLimits(.stateFloats))
        #expect(Self.build(blocks: 0, work: 0, output: 0) == .invalidLimits(.blocksPerRun))
        #expect(Self.build(work: 0, output: 0) == .invalidLimits(.runWork))
        #expect(Self.build(output: 0) == .invalidLimits(.runOutputFloats))
        #expect(Self.build(scratch: 67_108_865, state: 0) == .invalidLimits(.scratchFloats))
        #expect(Self.build(state: 67_108_865, blocks: 65_537) == .invalidLimits(.stateFloats))
    }

    @Test("GC3 standard limits equal the throwing initializer on the documented literals")
    func referenceEvaluatorStandardLimitsEqualTheLiterals() throws {
        let literal = try ReferenceEvaluatorLimits(
            maximumScratchFloats: 4_194_304, maximumStateFloats: 4_194_304, maximumBlocksPerRun: 1_024,
            maximumRunWork: 1_073_741_824, maximumRunOutputFloats: 4_194_304
        )
        #expect(ReferenceEvaluatorLimits.standard == literal)
        let standard = ReferenceEvaluatorLimits.standard
        #expect(standard.maximumScratchFloats == 4_194_304)
        #expect(standard.maximumStateFloats == 4_194_304)
        #expect(standard.maximumBlocksPerRun == 1_024)
        #expect(standard.maximumRunWork == 1_073_741_824)
        #expect(standard.maximumRunOutputFloats == 4_194_304)
        let other = try Self.limits(scratch: 4_194_303)
        #expect(other != standard)
    }

    @Test("GC3 scratch floats at the limit are accepted and one more is refused")
    func referenceEvaluatorScratchBound() throws {
        let plan = try Self.schedule(Self.gainChainGraph([0.5]))
        let need = plan.accounting.scratchFloats
        #expect(need == 12)
        _ = try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(scratch: need))
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.scratchFloats, required: need, maximum: need - 1)) {
            try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(scratch: need - 1))
        }
    }

    @Test("GC3 state floats at the limit are accepted and one more is refused")
    func referenceEvaluatorStateBound() throws {
        let plan = try Self.schedule(Self.feedbackGraph(delayBlocks: 3))
        #expect(plan.delayLines.map { $0.cut.channels * $0.cut.delayFrames } == [12])
        _ = try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(state: 12))
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.stateFloats, required: 12, maximum: 11)) {
            try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(state: 11))
        }
        let two = try Self.schedule(Self.twoLoopGraph(), frames: 2)
        #expect(two.delayLines.map { $0.cut.channels * $0.cut.delayFrames } == [6, 2])
        _ = try GraphReferenceEvaluator(schedule: two, limits: Self.limits(state: 8))
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.stateFloats, required: 8, maximum: 7)) {
            try GraphReferenceEvaluator(schedule: two, limits: Self.limits(state: 7))
        }
    }

    @Test("GC3 per-block sample work at the limit is accepted and one more is refused")
    func referenceEvaluatorPerBlockWorkBound() throws {
        let plan = try Self.schedule(Self.fanInGraph(sources: 3))
        let work = plan.accounting.sampleWork
        _ = try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(work: work))
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.sampleWork, required: work, maximum: work - 1)) {
            try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(work: work - 1))
        }
    }

    @Test("GC3 blocks per run at the limit are accepted and one more is refused")
    func referenceEvaluatorBlocksPerRunBound() throws {
        let graph = Self.gainChainGraph([0.5])
        let evaluator = try Self.makeEvaluator(graph, limits: Self.limits(blocks: 3))
        let block: [Float] = [1, 2, 3, 4]
        let three = try evaluator.run([block, block, block], from: evaluator.initialState)
        #expect(three.outputs.count == 3)
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.blocks, required: 4, maximum: 3)) {
            try evaluator.run([block, block, block, block], from: evaluator.initialState)
        }
        #expect(throws: ReferenceEvaluatorRefusal.invalidBlockCount(0)) {
            try evaluator.run([], from: evaluator.initialState)
        }
    }

    @Test("GC3 run work at the limit is accepted and one more is refused")
    func referenceEvaluatorRunWorkBound() throws {
        let plan = try Self.schedule(Self.gainChainGraph([0.5]))
        let per = plan.accounting.sampleWork
        let evaluator = try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(work: per * 3))
        let block: [Float] = [1, 2, 3, 4]
        let three = try evaluator.run([block, block, block], from: evaluator.initialState)
        #expect(three.chargedWork == per * 3)
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.sampleWork, required: per * 3, maximum: per * 3 - 1)) {
            let tight = try GraphReferenceEvaluator(schedule: plan, limits: Self.limits(work: per * 3 - 1))
            return try tight.run([block, block, block], from: tight.initialState)
        }
    }

    @Test("GC3 run output floats at the limit are accepted and one more is refused")
    func referenceEvaluatorRunOutputBound() throws {
        let graph = Self.gainChainGraph([0.5])
        let block: [Float] = [1, 2, 3, 4]
        let exact = try Self.makeEvaluator(graph, limits: Self.limits(output: 12))
        #expect(try exact.run([block, block, block], from: exact.initialState).outputs.count == 3)
        let tight = try Self.makeEvaluator(graph, limits: Self.limits(output: 11))
        #expect(throws: ReferenceEvaluatorRefusal.resourceLimit(.outputFloats, required: 12, maximum: 11)) {
            try tight.run([block, block, block], from: tight.initialState)
        }
    }
}
