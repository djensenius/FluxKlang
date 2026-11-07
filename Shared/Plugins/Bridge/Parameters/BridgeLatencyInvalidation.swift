/// A plan that must be recomputed or re-prepared after a capability generation change.
enum InvalidatedPlan: String, CaseIterable, Sendable, Hashable {
    case delayCompensation
    case preparedRender
}

/// Which plans a capability generation change invalidates. Pure and total; generations are compared by equality only.
///
/// A `resources` or `sampleRate` difference invalidates both plans, reported in the fixed order delay compensation then
/// prepared render. A `latency` difference alone invalidates only the delay-compensation plan: it never forces a
/// reprepare and never silences (this agrees with `ReprepareLedger.observing(.latency)`). Identical generations
/// invalidate nothing. Computing the new plans is out of scope.
enum BridgeLatencyInvalidation {
    static func decide(previous: CapabilityGeneration, live: CapabilityGeneration) -> [InvalidatedPlan] {
        if previous.resources != live.resources || previous.sampleRate != live.sampleRate {
            return [.delayCompensation, .preparedRender]
        }
        if previous.latency != live.latency { return [.delayCompensation] }
        return []
    }
}
