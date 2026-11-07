/// Result of one evaluated block. `chargedWork` is CHARGED by the plan (`accounting.sampleWork`), not measured.
struct ReferenceBlockResult: Equatable, Sendable {
    let output: [Float]
    let state: ReferenceEvaluatorState
    let executedNodes: [NodeID]
    let chargedWork: Int
}

/// Result of a run of blocks, the exact fold of `evaluate`. `chargedWork` is `blocks * accounting.sampleWork`,
/// CHARGED by the plan, not measured.
struct ReferenceRunResult: Equatable, Sendable {
    let outputs: [[Float]]
    let state: ReferenceEvaluatorState
    let chargedWork: Int
}
