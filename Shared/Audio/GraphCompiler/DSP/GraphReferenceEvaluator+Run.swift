extension GraphReferenceEvaluator {
    /// Evaluates 1...`maximumBlocksPerRun` blocks in order, each feeding the next state; the result equals folding
    /// `evaluate`. Order of checks: block count, block budget, work budget (`blocks * sampleWork`), output budget,
    /// state, then the blocks. A failure in block `k` is `.blockFailed(block: k, ...)`; the caller receives no
    /// outputs and no state (atomic).
    func run(
        _ inputs: [[Float]], from state: ReferenceEvaluatorState
    ) throws(ReferenceEvaluatorRefusal) -> ReferenceRunResult {
        let blocks = inputs.count
        guard blocks >= 1 else { throw .invalidBlockCount(blocks) }
        guard blocks <= limits.maximumBlocksPerRun else {
            throw .resourceLimit(.blocks, required: blocks, maximum: limits.maximumBlocksPerRun)
        }
        let work = try ReferenceChecked.multiply(blocks, schedule.accounting.sampleWork, .sampleWork)
        guard work <= limits.maximumRunWork else {
            throw .resourceLimit(.sampleWork, required: work, maximum: limits.maximumRunWork)
        }
        let outputFloats = try ReferenceChecked.multiply(blocks, outputFloatsPerBlock, .outputFloats)
        guard outputFloats <= limits.maximumRunOutputFloats else {
            throw .resourceLimit(.outputFloats, required: outputFloats, maximum: limits.maximumRunOutputFloats)
        }
        var lines = try restoreLines(state)
        var counter = state.blocksProcessed
        var outputs: [[Float]] = []
        outputs.reserveCapacity(blocks)
        for (index, input) in inputs.enumerated() {
            do throws(ReferenceBlockFault) {
                let outcome = try evaluateBlock(input, lines: lines, blocksProcessed: counter)
                outputs.append(outcome.output)
                lines = outcome.lines
                counter = outcome.blocksProcessed
            } catch {
                throw .blockFailed(block: index, fault: error)
            }
        }
        return ReferenceRunResult(
            outputs: outputs,
            state: ReferenceEvaluatorState(blocksProcessed: counter, lines: lines.map(\.storage)),
            chargedWork: work
        )
    }
}
