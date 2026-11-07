/// Overflow-checked integer arithmetic for sizes, offsets, counts and work. Every overflow is a typed refusal naming
/// the resource; nothing wraps, clamps or traps.
enum ReferenceChecked {
    static func add(
        _ lhs: Int, _ rhs: Int, _ resource: ReferenceResource
    ) throws(ReferenceEvaluatorRefusal) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw .arithmeticOverflow(resource) }
        return value
    }

    static func multiply(
        _ lhs: Int, _ rhs: Int, _ resource: ReferenceResource
    ) throws(ReferenceEvaluatorRefusal) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw .arithmeticOverflow(resource) }
        return value
    }
}

/// Non-real-time reference evaluator for a verified `RoutingSchedule`: the golden model the real-time executor
/// must match bit for bit. It allocates, is deterministic and pure (no clock, randomness, threads or globals) and
/// accepts only FULL blocks (`input.count == inputFloatsPerBlock`); short blocks, meters and peaks are out of scope.
/// Float32 only, no fused multiply-add: results are bit-identical in Debug and Release. It consumes the plan's steps
/// in array order and never re-sorts them. Feedback is passed through at unity; `gainCeilingDb` is a planner
/// guarantee that is not enforced here. Work is CHARGED from the plan, not measured. Refusals are atomic.
struct GraphReferenceEvaluator: Sendable {
    let graph: GraphID
    let revision: ContractRevision
    let blockFrames: Int
    let inputFloatsPerBlock: Int
    let outputFloatsPerBlock: Int
    let schedule: RoutingSchedule
    let limits: ReferenceEvaluatorLimits

    /// All delay lines at `+0.0` and zero blocks processed.
    var initialState: ReferenceEvaluatorState {
        ReferenceEvaluatorState(
            blocksProcessed: 0,
            lines: schedule.delayLines.map { [Float](repeating: 0, count: $0.cut.channels * $0.cut.delayFrames) }
        )
    }

    init(
        schedule: RoutingSchedule, limits: ReferenceEvaluatorLimits = .standard
    ) throws(ReferenceEvaluatorRefusal) {
        let scratchFloats = schedule.accounting.scratchFloats
        try Self.checkScratchCount(scratchFloats)
        guard scratchFloats <= limits.maximumScratchFloats else {
            throw .resourceLimit(.scratchFloats, required: scratchFloats, maximum: limits.maximumScratchFloats)
        }
        let inputFloats = try Self.endpointFloats(schedule.inputs, schedule.blockFrames, .inputFloats)
        let outputFloats = try Self.endpointFloats(schedule.outputs, schedule.blockFrames, .outputFloats)
        var stateFloats = 0
        for line in schedule.delayLines {
            let lineFloats = try ReferenceChecked.multiply(line.cut.channels, line.cut.delayFrames, .stateFloats)
            stateFloats = try ReferenceChecked.add(stateFloats, lineFloats, .stateFloats)
        }
        guard stateFloats <= limits.maximumStateFloats else {
            throw .resourceLimit(.stateFloats, required: stateFloats, maximum: limits.maximumStateFloats)
        }
        let sampleWork = schedule.accounting.sampleWork
        guard sampleWork <= limits.maximumRunWork else {
            throw .resourceLimit(.sampleWork, required: sampleWork, maximum: limits.maximumRunWork)
        }
        try ReferenceSchedulePreflight.walk(schedule)
        graph = schedule.graph
        revision = schedule.revision
        blockFrames = schedule.blockFrames
        inputFloatsPerBlock = inputFloats
        outputFloatsPerBlock = outputFloats
        self.schedule = schedule
        self.limits = limits
    }

    /// Accepted scratch counts are `0...Int.max`: a graph with no nodes or edges legitimately needs no scratch. A
    /// negative count is an accounting defect (unreachable through GC2) and is `.scheduleDefect(.accountingMismatch)`.
    static func checkScratchCount(_ scratchFloats: Int) throws(ReferenceEvaluatorRefusal) {
        guard scratchFloats >= 0 else { throw .scheduleDefect(.accountingMismatch) }
    }

    private static func endpointFloats(
        _ endpoints: [RoutingEndpoint], _ blockFrames: Int, _ resource: ReferenceResource
    ) throws(ReferenceEvaluatorRefusal) -> Int {
        var channels = 0
        for endpoint in endpoints {
            channels = try ReferenceChecked.add(channels, endpoint.endpoint.channels, resource)
        }
        return try ReferenceChecked.multiply(channels, blockFrames, resource)
    }
}

/// Defense-in-depth walk of a schedule. A `RoutingSchedule` is verified when it is made, so every branch below is
/// unreachable through the public API.
enum ReferenceSchedulePreflight {
    static func walk(_ schedule: RoutingSchedule) throws(ReferenceEvaluatorRefusal) {
        try endpointShape(schedule)
        try slotRanges(schedule)
        try termRanges(schedule)
        try delayGeometry(schedule)
        try accounting(schedule)
    }

    private static func endpointShape(_ schedule: RoutingSchedule) throws(ReferenceEvaluatorRefusal) {
        // Unreachable by construction: the schedule's request refuses blockFrames < 1.
        guard schedule.blockFrames >= 1 else { throw .scheduleDefect(.endpointShape) }
        for endpoints in [schedule.inputs, schedule.outputs] {
            var first = 0
            for item in endpoints {
                // Unreachable by construction: GC2 verifies endpoint slots and contiguous channel ranges.
                guard item.slot.channels == item.endpoint.channels, item.slot.frames == schedule.blockFrames,
                      item.endpoint.firstChannel == first else { throw .scheduleDefect(.endpointShape) }
                first = try ReferenceChecked.add(first, item.endpoint.channels, .scratchFloats)
            }
        }
    }

    private static func slotRanges(_ schedule: RoutingSchedule) throws(ReferenceEvaluatorRefusal) {
        var slots = schedule.inputs.map(\.slot) + schedule.steps.map(\.output)
        for line in schedule.delayLines { slots += [line.delayed, line.source] }
        for slot in slots {
            let floats = try ReferenceChecked.multiply(slot.channels, slot.frames, .scratchFloats)
            let end = try ReferenceChecked.add(slot.offset, floats, .scratchFloats)
            // Unreachable by construction: GC2 lays slots out contiguously inside the scratch.
            guard slot.offset >= 0, slot.channels >= 0, slot.frames >= 0,
                  end <= schedule.accounting.scratchFloats else { throw .scheduleDefect(.slotOutOfRange) }
        }
    }

    private static func termRanges(_ schedule: RoutingSchedule) throws(ReferenceEvaluatorRefusal) {
        for step in schedule.steps {
            for term in step.rows.flatMap(\.terms) {
                let end = try ReferenceChecked.add(term, schedule.blockFrames, .scratchFloats)
                // Unreachable by construction: GC2 verifies every term against a producer slot.
                guard term >= 0, end <= schedule.accounting.scratchFloats else {
                    throw .scheduleDefect(.termOutOfRange)
                }
            }
        }
    }

    private static func delayGeometry(_ schedule: RoutingSchedule) throws(ReferenceEvaluatorRefusal) {
        for line in schedule.delayLines {
            let cut = line.cut
            let expected = try ReferenceChecked.multiply(cut.delayBlocks, schedule.blockFrames, .stateFloats)
            // Unreachable by construction: GC2 verifies the delay line geometry.
            guard cut.delayBlocks >= 1, cut.delayFrames == expected, line.delayed.frames == schedule.blockFrames,
                  line.delayed.channels == line.source.channels, line.source.channels == cut.channels,
                  line.storage.channels == cut.channels, line.storage.frames == cut.delayFrames else {
                throw .scheduleDefect(.delayGeometry)
            }
        }
    }

    private static func accounting(_ schedule: RoutingSchedule) throws(ReferenceEvaluatorRefusal) {
        var inputs = 0
        for item in schedule.inputs { inputs = try ReferenceChecked.add(inputs, item.endpoint.channels, .inputFloats) }
        var outputs = 0
        for item in schedule.outputs {
            outputs = try ReferenceChecked.add(outputs, item.endpoint.channels, .outputFloats)
        }
        // Unreachable by construction: GC2 computes the accounting from the same endpoints.
        guard schedule.accounting.inputChannels == inputs, schedule.accounting.outputChannels == outputs else {
            throw .scheduleDefect(.accountingMismatch)
        }
    }
}
