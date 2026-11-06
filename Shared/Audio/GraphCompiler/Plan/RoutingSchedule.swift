/// Immutable, structurally checked routing plan. Validation does not prove
/// equivalence to the graph document or correctness of later execution.
struct RoutingSchedule: Equatable, Sendable {
    private struct BudgetCheck {
        let resource: RoutingResource
        let required: Int
        let maximum: Int
    }

    private struct AccountResult {
        let accounting: RoutingAccounting
        let overflow: RoutingResource?
    }

    let graph: GraphID
    let revision: ContractRevision
    let sampleRate: Int
    let blockFrames: Int
    let inputs: [RoutingEndpoint]
    let steps: [RoutingStep]
    let outputs: [RoutingEndpoint]
    let delayLines: [RoutingDelayLine]
    let accounting: RoutingAccounting

    private init(draft: RoutingScheduleDraft, request: RoutingScheduleRequest, accounting: RoutingAccounting) {
        graph = draft.graph
        revision = draft.revision
        sampleRate = request.sampleRate
        blockFrames = request.blockFrames
        inputs = draft.inputs
        steps = draft.steps
        outputs = draft.outputs
        delayLines = draft.delayLines
        self.accounting = accounting
    }

    static func make(
        draft: RoutingScheduleDraft, request: RoutingScheduleRequest
    ) throws(RoutingScheduleRefusal) -> RoutingSchedule {
        let accounting = try verify(draft, request: request)
        return RoutingSchedule(draft: draft, request: request, accounting: accounting)
    }

    private static func verify(
        _ draft: RoutingScheduleDraft, request: RoutingScheduleRequest
    ) throws(RoutingScheduleRefusal) -> RoutingAccounting {
        try verifyUniqueNodes(draft)
        let cursor = try verifySlotGeometry(draft, blockFrames: request.blockFrames)
        let result = try account(draft, blockFrames: request.blockFrames, scratchFloats: cursor)
        try enforce(result, request: request)
        try verifyStepShapes(draft)
        try verifyCausality(draft, readers: readableSlots(draft))
        let inputByNode = Dictionary(uniqueKeysWithValues: draft.inputs.map { ($0.endpoint.node, $0.slot) })
        let outputByNode = Dictionary(uniqueKeysWithValues: draft.steps.map { ($0.node, $0.output) })
        try verifyEndpoints(draft.inputs, expected: inputByNode, resource: .inputChannels)
        try verifyEndpoints(draft.outputs, expected: outputByNode, resource: .outputChannels)
        return result.accounting
    }

    private static func verifyUniqueNodes(_ draft: RoutingScheduleDraft) throws(RoutingScheduleRefusal) {
        var seen: Set<NodeID> = []
        for endpoint in draft.inputs {
            guard seen.insert(endpoint.endpoint.node).inserted else {
                throw .inconsistentSchedule(.duplicateNode)
            }
        }
        for step in draft.steps {
            guard seen.insert(step.node).inserted else {
                throw .inconsistentSchedule(.duplicateNode)
            }
        }
    }

    private static func verifySlotGeometry(
        _ draft: RoutingScheduleDraft, blockFrames: Int
    ) throws(RoutingScheduleRefusal) -> Int {
        var cursor = 0
        for endpoint in draft.inputs {
            try verifySlot(endpoint.slot, channels: endpoint.endpoint.channels, frames: blockFrames, cursor: &cursor)
        }
        for step in draft.steps {
            try verifySlot(step.output, channels: step.output.channels, frames: blockFrames, cursor: &cursor)
        }
        try verifyDelayLines(draft, sources: writableSources(draft), blockFrames: blockFrames, cursor: &cursor)
        return cursor
    }

    private static func verifyStepShapes(_ draft: RoutingScheduleDraft) throws(RoutingScheduleRefusal) {
        var previous: (Int, NodeID)?
        for step in draft.steps {
            guard step.level >= 0 else { throw .inconsistentSchedule(.stepOrder) }
            if let previous, (step.level, step.node) <= previous {
                throw .inconsistentSchedule(.stepOrder)
            }
            guard step.rows.count == step.output.channels else { throw .inconsistentSchedule(.rowShape) }
            guard step.rows.allSatisfy({ !$0.isBitCopy || $0.terms.count == 1 }) else {
                throw .inconsistentSchedule(.rowShape)
            }
            previous = (step.level, step.node)
        }
    }

    private static func verifyCausality(
        _ draft: RoutingScheduleDraft, readers: [Int: Producer]
    ) throws(RoutingScheduleRefusal) {
        var channelProducers: [Int: Producer] = [:]
        for producer in readers.values {
            for channel in 0..<producer.slot.channels {
                let offset = try channelStart(producer.slot, channel: channel)
                channelProducers[offset] = producer
            }
        }
        for step in draft.steps {
            for term in step.rows.flatMap(\.terms) {
                guard let producer = channelProducers[term] else { throw .inconsistentSchedule(.termSource) }
                guard producer.level < step.level else { throw .inconsistentSchedule(.causality) }
            }
        }
    }

    static func channelStart(
        _ slot: RoutingSlot, channel: Int
    ) throws(RoutingScheduleRefusal) -> Int {
        let channelOffset = try RoutingMath.multiply(channel, slot.frames, resource: .slotSamples)
        return try RoutingMath.add(slot.offset, channelOffset, resource: .slotSamples)
    }

    private static func verifyDelayLines(
        _ draft: RoutingScheduleDraft, sources: [Int: RoutingSlot], blockFrames: Int, cursor: inout Int
    ) throws(RoutingScheduleRefusal) {
        for line in draft.delayLines {
            let (expectedDelayFrames, delayOverflow) =
                line.cut.delayBlocks.multipliedReportingOverflow(by: blockFrames)
            guard line.cut.channels == line.source.channels,
                  line.cut.channels == line.delayed.channels,
                  line.cut.channels == line.storage.channels,
                  line.cut.channels > 0,
                  !delayOverflow, line.cut.delayFrames == expectedDelayFrames,
                  line.cut.delayFrames == line.storage.frames,
                  line.cut.delayBlocks >= 1,
                  line.cut.gainCeilingDb.isFinite, line.cut.gainCeilingDb <= 0,
                  line.delayed.frames == blockFrames,
                  line.source.frames == blockFrames,
                  sources[line.source.offset] == line.source else {
                throw .inconsistentSchedule(.delayLine)
            }
            try verifySlot(line.delayed, channels: line.cut.channels, frames: blockFrames, cursor: &cursor)
            try verifySlot(line.storage, channels: line.cut.channels, frames: line.cut.delayFrames, cursor: &cursor)
        }
        guard cursor >= 0 else { throw .inconsistentSchedule(.endpoint) }
    }

    private struct Producer {
        let slot: RoutingSlot
        let level: Int
    }

    private static func readableSlots(_ draft: RoutingScheduleDraft) -> [Int: Producer] {
        var result: [Int: Producer] = [:]
        for input in draft.inputs {
            result[input.slot.offset] = Producer(slot: input.slot, level: 0)
        }
        for step in draft.steps {
            result[step.output.offset] = Producer(slot: step.output, level: step.level)
        }
        for line in draft.delayLines {
            result[line.delayed.offset] = Producer(slot: line.delayed, level: -1)
        }
        return result
    }

    private static func writableSources(_ draft: RoutingScheduleDraft) -> [Int: RoutingSlot] {
        var result: [Int: RoutingSlot] = [:]
        for input in draft.inputs {
            result[input.slot.offset] = input.slot
        }
        for step in draft.steps {
            result[step.output.offset] = step.output
        }
        return result
    }

    private static func verifySlot(
        _ slot: RoutingSlot, channels: Int, frames: Int, cursor: inout Int
    ) throws(RoutingScheduleRefusal) {
        guard slot.offset == cursor, slot.channels == channels, channels > 0,
              slot.frames == frames, frames > 0 else { throw .inconsistentSchedule(.slotLayout) }
        let samples = try RoutingMath.multiply(channels, frames, resource: .slotSamples)
        cursor = try RoutingMath.add(cursor, samples, resource: .scratchFloats)
    }

    private static func verifyEndpoints(
        _ endpoints: [RoutingEndpoint], expected: [NodeID: RoutingSlot], resource: RoutingResource
    ) throws(RoutingScheduleRefusal) {
        var channel = 0
        var previous: NodeID?
        for item in endpoints {
            guard previous.map({ $0 < item.endpoint.node }) ?? true,
                  item.endpoint.channels == item.slot.channels,
                  item.endpoint.firstChannel == channel,
                  expected[item.endpoint.node] == item.slot else {
                throw .inconsistentSchedule(.endpoint)
            }
            previous = item.endpoint.node
            channel = try RoutingMath.add(channel, item.endpoint.channels, resource: resource)
        }
    }

    private static func account(
        _ draft: RoutingScheduleDraft, blockFrames: Int, scratchFloats: Int
    ) throws(RoutingScheduleRefusal) -> AccountResult {
        let inputChannels = try sum(draft.inputs.map(\.slot.channels), resource: .inputChannels)
        let stepSlots = Dictionary(uniqueKeysWithValues: draft.steps.map { ($0.node, $0.output) })
        var seenOutputs: Set<NodeID> = []
        var outputChannels = 0
        for endpoint in draft.outputs where seenOutputs.insert(endpoint.endpoint.node).inserted {
            if let slot = stepSlots[endpoint.endpoint.node] {
                outputChannels = try RoutingMath.add(
                    outputChannels, slot.channels, resource: .outputChannels
                )
            }
        }
        var terms = 0
        var outputs = 0
        var outputSumOverflow = false
        for step in draft.steps {
            for row in step.rows {
                terms = try RoutingMath.add(terms, row.terms.count, resource: .terms)
            }
            if !outputSumOverflow {
                let (total, overflow) = outputs.addingReportingOverflow(step.output.channels)
                outputs = overflow ? Int.max : total
                outputSumOverflow = overflow
            }
        }
        let (bytes, bytesOverflow) = scratchFloats.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        if bytesOverflow {
            return AccountResult(
                accounting: RoutingAccounting(
                    inputChannels: inputChannels, outputChannels: outputChannels, termCount: terms,
                    scratchFloats: scratchFloats, scratchBytes: Int.max, sampleWork: 0
                ),
                overflow: .scratchBytes
            )
        }
        var delays = 0
        var delaySumOverflow = false
        for line in draft.delayLines {
            let (total, overflow) = delays.addingReportingOverflow(line.cut.channels)
            if overflow {
                delays = Int.max
                delaySumOverflow = true
                break
            }
            delays = total
        }
        let (inputWork, inputOverflow) = inputChannels.multipliedReportingOverflow(by: 2)
        let (delayWork, delayOverflow) = delays.multipliedReportingOverflow(by: 2)
        let (firstWork, firstOverflow) = inputWork.addingReportingOverflow(terms)
        let (secondWork, secondOverflow) = firstWork.addingReportingOverflow(outputs)
        let (thirdWork, thirdOverflow) = secondWork.addingReportingOverflow(outputChannels)
        let (perFrame, fourthOverflow) = thirdWork.addingReportingOverflow(delayWork)
        let (work, workOverflow) = blockFrames.multipliedReportingOverflow(by: perFrame)
        let accounting = RoutingAccounting(
            inputChannels: inputChannels, outputChannels: outputChannels, termCount: terms,
            scratchFloats: scratchFloats, scratchBytes: bytes, sampleWork: work
        )
        let overflow = outputSumOverflow || delaySumOverflow || inputOverflow || delayOverflow || firstOverflow
            || secondOverflow || thirdOverflow || fourthOverflow || workOverflow
        return AccountResult(accounting: accounting, overflow: overflow ? .sampleWork : nil)
    }

    private static func sum(_ values: [Int], resource: RoutingResource) throws(RoutingScheduleRefusal) -> Int {
        var total = 0
        for value in values {
            total = try RoutingMath.add(total, value, resource: resource)
        }
        return total
    }

    private static func enforce(
        _ result: AccountResult, request: RoutingScheduleRequest
    ) throws(RoutingScheduleRefusal) {
        let limits = request.limits
        let accounting = result.accounting
        let primaryChecks = [
            BudgetCheck(resource: .inputChannels, required: accounting.inputChannels, maximum: limits.maxInputChannels),
            BudgetCheck(
                resource: .outputChannels, required: accounting.outputChannels, maximum: limits.maxOutputChannels
            ),
            BudgetCheck(resource: .terms, required: accounting.termCount, maximum: limits.maxTerms)
        ]
        try enforce(primaryChecks)
        if let overflow = result.overflow { throw .arithmeticOverflow(overflow) }
        let finalChecks = [
            BudgetCheck(resource: .scratchBytes, required: accounting.scratchBytes, maximum: limits.maxScratchBytes),
            BudgetCheck(resource: .sampleWork, required: accounting.sampleWork, maximum: limits.maxSampleWork)
        ]
        try enforce(finalChecks)
    }

    private static func enforce(_ checks: [BudgetCheck]) throws(RoutingScheduleRefusal) {
        for check in checks where check.required > check.maximum {
            throw .resourceLimit(check.resource, required: check.required, maximum: check.maximum)
        }
    }
}
