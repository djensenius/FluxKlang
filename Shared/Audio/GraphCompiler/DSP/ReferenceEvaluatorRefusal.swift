/// Evaluator-local limit field that failed validation, in validation order.
enum ReferenceLimitKind: CaseIterable, Equatable, Sendable {
    case scratchFloats, stateFloats, blocksPerRun, runWork, runOutputFloats
}

/// Resource named by an overflow or limit refusal. Counts are floats, blocks or sample operations, never time.
enum ReferenceResource: String, CaseIterable, Equatable, Sendable {
    case scratchFloats, stateFloats, inputFloats, outputFloats, sampleWork, blocks
}

/// Structural defect found by the evaluator's defense-in-depth walk of a schedule. A verified `RoutingSchedule`
/// cannot produce these, so they are unreachable through the public API.
enum ReferenceScheduleDefect: String, CaseIterable, Equatable, Sendable {
    case slotOutOfRange, termOutOfRange, endpointShape, delayGeometry, accountingMismatch
}

/// Failure of one block. Carries indices and counts only, never sample values.
enum ReferenceBlockFault: Error, Equatable, Sendable {
    case inputSizeMismatch(expected: Int, actual: Int)
    case nonFiniteInput(channel: Int, frame: Int)
    case nonFiniteSum(node: NodeID, channel: Int, frame: Int)
    case nonFiniteGain(node: NodeID, channel: Int, frame: Int)
    case blockCounterOverflow
}

/// Typed refusal of every evaluator entry point. A refusal returns no result and leaves all inputs unchanged.
enum ReferenceEvaluatorRefusal: Error, Equatable, Sendable {
    case invalidLimits(ReferenceLimitKind)
    case arithmeticOverflow(ReferenceResource)
    case resourceLimit(ReferenceResource, required: Int, maximum: Int)
    case scheduleDefect(ReferenceScheduleDefect)
    case stateMismatch
    case invalidBlockCount(Int)
    case blockFailed(block: Int, fault: ReferenceBlockFault)
}
