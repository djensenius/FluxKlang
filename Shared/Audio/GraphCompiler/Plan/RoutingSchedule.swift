/// Immutable, structurally checked routing plan. Validation does not prove
/// equivalence to the graph document or correctness of later execution.
struct RoutingSchedule: Equatable, Sendable {
    private struct BudgetCheck {
        let resource: RoutingResource
        let required: Int
        let maximum: Int
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
        try verify(draft, blockFrames: request.blockFrames)
        let accounting = try account(draft, blockFrames: request.blockFrames)
        try enforce(accounting, request: request)
        return RoutingSchedule(draft: draft, request: request, accounting: accounting)
    }

    private static func verify(
        _ draft: RoutingScheduleDraft, blockFrames: Int
    ) throws(RoutingScheduleRefusal) {
        let inputIDs = draft.inputs.map(\.endpoint.node)
        let stepIDs = draft.steps.map(\.node)
        guard Set(inputIDs + stepIDs).count == inputIDs.count + stepIDs.count else {
            throw .inconsistentSchedule(.duplicateNode)
        }
        var cursor = try verifySlotLayout(draft, blockFrames: blockFrames)
        let readers = readableSlots(draft)
        try verifyCausality(draft, readers: readers)
        let inputByNode = Dictionary(uniqueKeysWithValues: draft.inputs.map { ($0.endpoint.node, $0.slot) })
        let outputByNode = Dictionary(uniqueKeysWithValues: draft.steps.map { ($0.node, $0.output) })
        try verifyEndpoints(draft.inputs, expected: inputByNode, resource: .inputChannels)
        try verifyEndpoints(draft.outputs, expected: outputByNode, resource: .outputChannels)
        try verifyDelayLines(
            draft, sources: writableSources(draft), blockFrames: blockFrames, cursor: &cursor
        )
        guard cursor >= 0 else { throw .inconsistentSchedule(.endpoint) }
    }

    private static func verifySlotLayout(
        _ draft: RoutingScheduleDraft, blockFrames: Int
    ) throws(RoutingScheduleRefusal) -> Int {
        var cursor = 0
        for endpoint in draft.inputs {
            try verifySlot(endpoint.slot, channels: endpoint.endpoint.channels, frames: blockFrames, cursor: &cursor)
        }
        var previous: (Int, NodeID)?
        for step in draft.steps {
            guard step.level >= 0 else { throw .inconsistentSchedule(.stepOrder) }
            if let previous, (step.level, step.node) <= previous {
                throw .inconsistentSchedule(.stepOrder)
            }
            previous = (step.level, step.node)
            guard step.rows.count == step.output.channels,
                  step.rows.allSatisfy({ !$0.isBitCopy || $0.terms.count == 1 }) else {
                throw .inconsistentSchedule(.rowShape)
            }
            try verifySlot(step.output, channels: step.rows.count, frames: blockFrames, cursor: &cursor)
        }
        return cursor
    }

    private static func verifyCausality(
        _ draft: RoutingScheduleDraft, readers: [Int: Producer]
    ) throws(RoutingScheduleRefusal) {
        var channelProducers: [Int: Producer] = [:]
        for producer in readers.values {
            for channel in 0..<producer.slot.channels {
                channelProducers[producer.slot.offset + channel * producer.slot.frames] = producer
            }
        }
        for step in draft.steps {
            for term in step.rows.flatMap(\.terms) {
                guard let producer = channelProducers[term] else { throw .inconsistentSchedule(.termSource) }
                guard producer.level < step.level else { throw .inconsistentSchedule(.causality) }
            }
        }
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
        _ draft: RoutingScheduleDraft, blockFrames: Int
    ) throws(RoutingScheduleRefusal) -> RoutingAccounting {
        let inputChannels = try sum(draft.inputs.map(\.endpoint.channels), resource: .inputChannels)
        let outputChannels = try sum(draft.outputs.map(\.endpoint.channels), resource: .outputChannels)
        var terms = 0
        var outputs = 0
        for step in draft.steps {
            for row in step.rows {
                terms = try RoutingMath.add(terms, row.terms.count, resource: .terms)
            }
            outputs = try RoutingMath.add(outputs, step.output.channels, resource: .sampleWork)
        }
        var floats = 0
        for slot in draft.inputs.map(\.slot) + draft.steps.map(\.output)
            + draft.delayLines.flatMap({ [$0.delayed, $0.storage] }) {
            floats = try RoutingMath.add(
                floats, RoutingMath.multiply(slot.channels, slot.frames, resource: .slotSamples),
                resource: .scratchFloats
            )
        }
        let bytes = try RoutingMath.multiply(floats, MemoryLayout<Float>.stride, resource: .scratchBytes)
        let delays = try sum(draft.delayLines.map(\.cut.channels), resource: .sampleWork)
        let perFrame = try sum(
            [try RoutingMath.multiply(2, inputChannels, resource: .sampleWork), terms,
             outputs, outputChannels, try RoutingMath.multiply(2, delays, resource: .sampleWork)],
            resource: .sampleWork
        )
        let work = try RoutingMath.multiply(blockFrames, perFrame, resource: .sampleWork)
        return RoutingAccounting(
            inputChannels: inputChannels, outputChannels: outputChannels, termCount: terms,
            scratchFloats: floats, scratchBytes: bytes, sampleWork: work
        )
    }

    private static func sum(_ values: [Int], resource: RoutingResource) throws(RoutingScheduleRefusal) -> Int {
        var total = 0
        for value in values {
            total = try RoutingMath.add(total, value, resource: resource)
        }
        return total
    }

    private static func enforce(
        _ accounting: RoutingAccounting, request: RoutingScheduleRequest
    ) throws(RoutingScheduleRefusal) {
        let limits = request.limits
        let checks = [
            BudgetCheck(resource: .inputChannels, required: accounting.inputChannels, maximum: limits.maxInputChannels),
            BudgetCheck(
                resource: .outputChannels, required: accounting.outputChannels, maximum: limits.maxOutputChannels
            ),
            BudgetCheck(resource: .terms, required: accounting.termCount, maximum: limits.maxTerms),
            BudgetCheck(resource: .scratchBytes, required: accounting.scratchBytes, maximum: limits.maxScratchBytes),
            BudgetCheck(resource: .sampleWork, required: accounting.sampleWork, maximum: limits.maxSampleWork)
        ]
        for check in checks where check.required > check.maximum {
            throw .resourceLimit(check.resource, required: check.required, maximum: check.maximum)
        }
    }
}
