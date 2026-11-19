/// One-shot, control-only preparation for a ready `KernelCycle`. Reference model; not RT-certified.
///
/// Every call through every alias must be strictly serialized on control, including final destruction.
/// This reference deliberately is not Sendable: independent candidates arbitrate through the ownership CAS,
/// but aliases of one candidate have no concurrent bind/cancel contract. Preparation does not claim or inspect
/// inheritance. Cancel/abandon spends the acknowledgement identity and releases only unclaimed storage.
final class KernelCycleCandidate {
    /// Only the designated binding initializer extracts this payload; no claim or ready cycle is stored here.
    struct Payload {
        let parts: KernelCycleParts
        let pulses: ClockPulseGate
        let blockCapacity: Int
        let perLaneQuota: Int
        let checked: KernelCyclePreparation
        let ackRequests: KernelAckRequests
    }

    private enum State {
        case pending(Payload)
        case cancelled
        case consumed
    }

    private var state: State

    init(_ parts: KernelCycleParts, pulses: ClockPulseGate, blockCapacity: Int,
         perLaneQuota: Int) throws(KernelCycle.PreparationError) {
        let checked = try KernelCycle.prepare(parts, blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
        guard let ackRequests = KernelAckRequests(faults: parts.faults, criticalScope: parts.events.criticalScope)
        else { throw .ackIdentitiesExhausted }
        state = .pending(Payload(parts: parts, pulses: pulses, blockCapacity: blockCapacity,
                                 perLaneQuota: perLaneQuota, checked: checked, ackRequests: ackRequests))
    }

    /// Clears pending storage synchronously on control. After binding, cannot revoke or release cycle custody.
    @discardableResult
    func cancel() -> Bool {
        guard case .pending = state else { return false }
        state = .cancelled
        return true
    }

    /// Module-internal solely so `KernelCycle.init(binding:)` can extract across files. No payload-adopting
    /// cycle initializer exists. Consumption precedes its single exact-snapshot CAS, even when that CAS refuses.
    func consumeForBinding() throws(KernelCycle.PreparationError) -> Payload {
        switch state {
        case .pending(let payload):
            state = .consumed
            return payload
        case .cancelled:
            throw .candidateCancelled
        case .consumed:
            throw .candidateConsumed
        }
    }
}
