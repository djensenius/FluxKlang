/// One-shot, control-only preparation for a ready `KernelCycle`. Reference model; not RT-certified.
///
/// Every call through every alias must be strictly serialized on control, including final destruction.
/// This reference deliberately is not Sendable: independent candidates arbitrate through the ownership CAS,
/// but aliases of one candidate have no concurrent bind/cancel contract. Preparation does not claim or inspect
/// inheritance. Cancel/abandon spends the acknowledgement identity and releases only unclaimed storage.
final class KernelCycleCandidate {
    /// Only the designated binding initializer extracts this payload; no claim or ready cycle is stored here.
    struct Payload: ~Copyable {
        let parts: KernelCycleParts
        let pulses: ClockPulseGate
        let blockCapacity: Int
        let perLaneQuota: Int
        let checked: KernelCyclePreparation
        let ackRequests: KernelAckRequests
        let reservation: KernelReadmissionReservation
    }

    private enum State: ~Copyable {
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
                                 perLaneQuota: perLaneQuota, checked: checked, ackRequests: ackRequests,
                                 reservation: KernelReadmissionReservation(
                                    capacity: min(KernelRetirementCarry.capacity, blockCapacity))))
    }

    /// Control only; absent after cancellation/extraction. No pre-ready report or backing access.
    var storageInfo: KernelReadmissionStorageInfo? {
        switch state {
        case .pending(let payload): payload.reservation.storageInfo
        case .cancelled: nil
        case .consumed: nil
        }
    }

    /// Clears pending storage synchronously on control. After binding, cannot revoke or release cycle custody.
    @discardableResult
    func cancel() -> Bool {
        var extracted = State.cancelled
        swap(&state, &extracted)
        switch consume extracted {
        case .pending:
            return true
        case .cancelled:
            return false
        case .consumed:
            state = .consumed
            return false
        }
    }

    /// Module-internal solely so `KernelCycle.init(binding:)` can extract across files. No payload-adopting
    /// cycle initializer exists. Consumption precedes its single exact-snapshot CAS, even when that CAS refuses.
    func consumeForBinding() throws(KernelCycle.PreparationError) -> Payload {
        var extracted = State.consumed
        swap(&state, &extracted)
        switch consume extracted {
        case .pending(let payload):
            return consume payload
        case .cancelled:
            state = .cancelled
            throw .candidateCancelled
        case .consumed:
            throw .candidateConsumed
        }
    }
}
