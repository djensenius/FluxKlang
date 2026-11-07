extension GraphReferenceEvaluator {
    struct BlockOutcome {
        let output: [Float]
        let lines: [ReferenceDelayLine]
        let blocksProcessed: Int
        let executedNodes: [NodeID]
    }

    /// Evaluates one full block as block 0 of its own call. Order of checks: state (`.stateMismatch`), input
    /// length, block counter, first non-finite input, first failing step. Nothing is returned on refusal.
    func evaluate(
        _ input: [Float], state: ReferenceEvaluatorState
    ) throws(ReferenceEvaluatorRefusal) -> ReferenceBlockResult {
        let lines = try restoreLines(state)
        do throws(ReferenceBlockFault) {
            let outcome = try evaluateBlock(input, lines: lines, blocksProcessed: state.blocksProcessed)
            return ReferenceBlockResult(
                output: outcome.output,
                state: ReferenceEvaluatorState(
                    blocksProcessed: outcome.blocksProcessed, lines: outcome.lines.map(\.storage)
                ),
                executedNodes: outcome.executedNodes,
                chargedWork: schedule.accounting.sampleWork
            )
        } catch {
            throw .blockFailed(block: 0, fault: error)
        }
    }

    func restoreLines(_ state: ReferenceEvaluatorState) throws(ReferenceEvaluatorRefusal) -> [ReferenceDelayLine] {
        guard state.blocksProcessed >= 0, state.lines.count == schedule.delayLines.count else {
            throw .stateMismatch
        }
        var lines: [ReferenceDelayLine] = []
        for (plan, storage) in zip(schedule.delayLines, state.lines) {
            lines.append(try ReferenceDelayLine(
                restoring: storage, channels: plan.cut.channels, blockFrames: blockFrames,
                delayBlocks: plan.cut.delayBlocks
            ))
        }
        return lines
    }

    func evaluateBlock(
        _ input: [Float], lines: [ReferenceDelayLine], blocksProcessed: Int
    ) throws(ReferenceBlockFault) -> BlockOutcome {
        guard input.count == inputFloatsPerBlock else {
            throw .inputSizeMismatch(expected: inputFloatsPerBlock, actual: input.count)
        }
        let (next, overflow) = blocksProcessed.addingReportingOverflow(1)
        guard !overflow else { throw .blockCounterOverflow }
        var scratch = [Float](repeating: 0, count: schedule.accounting.scratchFloats)
        try stage(input, into: &scratch)
        for (plan, line) in zip(schedule.delayLines, lines) {
            writePlanar(line.block(at: blocksProcessed), to: plan.delayed, in: &scratch)
        }
        let executed = try execute(&scratch)
        var stored: [ReferenceDelayLine] = []
        for (plan, line) in zip(schedule.delayLines, lines) {
            stored.append(line.storing(readPlanar(plan.source, from: scratch), at: blocksProcessed))
        }
        return BlockOutcome(
            output: gather(scratch), lines: stored, blocksProcessed: next, executedNodes: executed
        )
    }

    private func stage(_ input: [Float], into scratch: inout [Float]) throws(ReferenceBlockFault) {
        for endpoint in schedule.inputs {
            for channel in 0..<endpoint.endpoint.channels {
                let sourceChannel = endpoint.endpoint.firstChannel + channel
                for frame in 0..<blockFrames {
                    let value = input[sourceChannel * blockFrames + frame]
                    guard value.isFinite else { throw .nonFiniteInput(channel: sourceChannel, frame: frame) }
                    scratch[endpoint.slot.offset + channel * blockFrames + frame] = value
                }
            }
        }
    }

    private func execute(_ scratch: inout [Float]) throws(ReferenceBlockFault) -> [NodeID] {
        var executed: [NodeID] = []
        for step in schedule.steps {
            try run(step, scratch: &scratch)
            executed.append(step.node)
        }
        return executed
    }

    private func run(_ step: RoutingStep, scratch: inout [Float]) throws(ReferenceBlockFault) {
        for (channel, row) in step.rows.enumerated() {
            let base = step.output.offset + channel * step.output.frames
            for frame in 0..<blockFrames {
                guard let value = ReferenceKernels.mapRow(row, scratch: scratch, frame: frame) else {
                    throw .nonFiniteSum(node: step.node, channel: channel, frame: frame)
                }
                switch step.operation {
                case .copy:
                    scratch[base + frame] = value
                case .zero:
                    scratch[base + frame] = ReferenceKernels.mute(value)
                case .scale(let factor):
                    guard let scaled = ReferenceKernels.gain(value, by: factor) else {
                        throw .nonFiniteGain(node: step.node, channel: channel, frame: frame)
                    }
                    scratch[base + frame] = scaled
                }
            }
        }
    }

    private func gather(_ scratch: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: outputFloatsPerBlock)
        for endpoint in schedule.outputs {
            for channel in 0..<endpoint.endpoint.channels {
                let destination = (endpoint.endpoint.firstChannel + channel) * blockFrames
                let source = endpoint.slot.offset + channel * endpoint.slot.frames
                for frame in 0..<blockFrames {
                    output[destination + frame] = scratch[source + frame]
                }
            }
        }
        return output
    }

    private func readPlanar(_ slot: RoutingSlot, from scratch: [Float]) -> [Float] {
        var block: [Float] = []
        block.reserveCapacity(slot.channels * slot.frames)
        for channel in 0..<slot.channels {
            let start = slot.offset + channel * slot.frames
            block.append(contentsOf: scratch[start..<(start + slot.frames)])
        }
        return block
    }

    private func writePlanar(_ block: [Float], to slot: RoutingSlot, in scratch: inout [Float]) {
        for index in 0..<block.count {
            scratch[slot.offset + index] = block[index]
        }
    }
}
