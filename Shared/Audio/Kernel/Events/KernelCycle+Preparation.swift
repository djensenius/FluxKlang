// #360 E5bf: the control-side checks `KernelCycle.init` runs before it makes anything or claims the ownership, in the
// order `PreparationError` reports them. They sit in this file because `KernelCycle.swift` is at the file-length
// cap; they read only `KernelCycleParts` and change nothing, so a refusal here has claimed nothing.
// Reference model; not RT-certified.

/// What the preparation checks established and `KernelCycle.init` still needs: the deadline policy, whether the
/// start is `.freshFanIn`, and the claim word as read, which the final claim compare-exchanges from.
struct KernelCyclePreparation {
    let deadline: DeadlinePolicy
    let fresh: Bool
    let claimState: NoteOwnership.CycleClaimState
}

extension KernelCycle {
    /// Why `KernelCycle.init` refused (moved here from `KernelCycle.swift`, which is at the file-length cap).
    enum PreparationError: Error, Equatable, Sendable {
        /// The fan-in is not `.events` consumed on `.render`.
        case notRenderEvents
        /// The fan-in's policy does not give a deadline policy.
        case deadline(DeadlinePolicy.PreparationError)
        /// `blockCapacity` is outside `1...maximumBlockCapacity`.
        case blockCapacityOutOfRange(Int)
        /// `perLaneQuota` is outside `1...KernelLimits.maximumCapacity`.
        case perLaneQuotaOutOfRange(Int)
        /// `ownership` and `safety` do not cover the same scopes.
        case scopeCountMismatch(ownership: Int, safety: Int)
        /// The telemetry output's `slot` is outside its slots.
        case telemetrySlotOutOfRange(Int)
        /// Every `KernelAckRequests` identity was issued.
        case ackIdentitiesExhausted
        /// `parts.admissionRefusals` belongs to another fan-in (identity or lane count differ).
        case admissionRefusalsMismatch
        /// `ownership` cannot be claimed for this start (see `KernelCycleStart`); checked after the wiring checks and
        /// before `.admissionRefusalsRequired`. A refusal from the final claim (only when another preparation raced
        /// this one) has used one `KernelAckRequests` identity.
        case ownershipClaim(NoteOwnership.CycleClaimRefusal)
        /// `parts.admissionRefusals` is `nil` over an ownership an earlier cycle used and retired (claim word
        /// nonzero and even): a new table would leave producers admitted earlier counting elsewhere. Checked
        /// after `.ownershipClaim`; refuses with nothing claimed. A first cycle may omit it.
        case admissionRefusalsRequired
    }

    /// Checks, in this order: the shape (`.notRenderEvents`, `.deadline`, `.blockCapacityOutOfRange`,
    /// `.perLaneQuotaOutOfRange`), the wiring (`.scopeCountMismatch`, `.telemetrySlotOutOfRange`,
    /// `.admissionRefusalsMismatch`), then the ownership (`.ownershipClaim`, `.admissionRefusalsRequired`). `init`
    /// then issues the acknowledgement identity (`.ackIdentitiesExhausted`) and makes the claim itself. The first
    /// defect found is the one reported; nothing is claimed or issued here.
    static func prepare(_ parts: KernelCycleParts, blockCapacity: Int,
                        perLaneQuota: Int) throws(PreparationError) -> KernelCyclePreparation {
        let deadline = try checkShape(parts, blockCapacity: blockCapacity, perLaneQuota: perLaneQuota)
        try checkWiring(parts)
        let claimState = try checkOwnership(parts)
        return KernelCyclePreparation(deadline: deadline, fresh: parts.start == .freshFanIn, claimState: claimState)
    }

    private static func checkShape(_ parts: KernelCycleParts, blockCapacity: Int,
                                   perLaneQuota: Int) throws(PreparationError) -> DeadlinePolicy {
        let policy = parts.events.policy
        guard policy.purpose == .events, policy.consumer == .render else { throw .notRenderEvents }
        let deadline: DeadlinePolicy
        do {
            deadline = try DeadlinePolicy(policy: policy)
        } catch {
            throw .deadline(error)
        }
        guard blockCapacity >= 1, blockCapacity <= Self.maximumBlockCapacity else {
            throw .blockCapacityOutOfRange(blockCapacity)
        }
        guard perLaneQuota >= 1, perLaneQuota <= KernelLimits.maximumCapacity else {
            throw .perLaneQuotaOutOfRange(perLaneQuota)
        }
        return deadline
    }

    private static func checkWiring(_ parts: KernelCycleParts) throws(PreparationError) {
        guard parts.ownership.scopeCount == parts.safety.scopeCount else {
            throw .scopeCountMismatch(ownership: parts.ownership.scopeCount, safety: parts.safety.scopeCount)
        }
        if let output = parts.telemetry, output.slot < 0 || output.slot >= output.slots.slotCount {
            throw .telemetrySlotOutOfRange(output.slot)
        }
        if let refusals = parts.admissionRefusals,
           refusals.handoff != parts.events.identity || refusals.laneCount != parts.events.laneCount {
            throw .admissionRefusalsMismatch
        }
    }

    /// The claim refusal comes first: an odd word (a live cycle) is `.predecessorNotRetired` and a used word under
    /// `.freshFanIn` is `.alreadyUsed`, whether or not the table is missing. Only a replacement over a word an
    /// earlier cycle retired (nonzero, even) can then lack the table: a new one would leave producers admitted
    /// before it counting into the retired cycle's table. A first cycle (word 0) may omit it under either start.
    private static func checkOwnership(_ parts: KernelCycleParts)
        throws(PreparationError) -> NoteOwnership.CycleClaimState {
        let claimState = parts.ownership.cycleClaimState()
        if let refusal = NoteOwnership.cycleClaimRefusal(claimState, fresh: parts.start == .freshFanIn) {
            throw .ownershipClaim(refusal)
        }
        if parts.admissionRefusals == nil, claimState.hasRetiredCycle { throw .admissionRefusalsRequired }
        return claimState
    }
}
