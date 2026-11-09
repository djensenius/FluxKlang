//
//  SetupApplyGuard.swift
//  FluxKlang
//
//  Composes an ended setup flow with the rig mapping review. A flow that ended with an apply request carries the facts
//  its gates passed under. Right before the caller applies the review, the caller derives the facts again and hands
//  them in: when they differ from the request's basis the apply is refused, otherwise the result is exactly what
//  `RigMappingReview.apply` returns. The guard changes no rig, saves no document, reads no permission, registry or
//  port, starts no sound and assumes no tone, channel or interface number. Nothing calls it yet.
//

/// The candidate change an accepted apply request produced: the rig the operator picked, passed through for the commit
/// owner, and the change `RigMappingReview.apply` returned. Built only by `SetupApplyGuard`.
struct SetupApplyChange: Equatable, Sendable {
    let rig: SetupFlowRigID?
    let change: RigMappingChange

    fileprivate init(rig: SetupFlowRigID?, change: RigMappingChange) {
        self.rig = rig
        self.change = change
    }
}

enum SetupApplyGuard {
    /// Refusal order: the phase (`flowNotEnded` for a running or suspended flow, `manualChosen` for a manual ending),
    /// then `factsChanged` (`SetupFlowFacts.matches`, so a merely reordered rig list counts as a change), then the
    /// refusal of `RigMappingReview.apply`, which runs after the earlier checks passed. The flow is not advanced and
    /// the picked rig is used for no lookup.
    static func apply(
        _ state: SetupFlowState,
        currentFacts: SetupFlowFacts,
        review: RigMappingReview,
        decisions: RigMappingDecisions,
        document: DeviceCapabilityDocument
    ) throws(SetupApplyRefusal) -> SetupApplyChange {
        switch state.phase {
        case .running, .suspended:
            throw .flowNotEnded
        case .ended(.manual):
            throw .manualChosen
        case .ended(.applyRequested(let intent)):
            guard intent.basis.matches(currentFacts) else { throw .factsChanged }
            let change = try candidate(review, decisions, document)
            return SetupApplyChange(rig: intent.rig, change: change)
        }
    }

    private static func candidate(
        _ review: RigMappingReview,
        _ decisions: RigMappingDecisions,
        _ document: DeviceCapabilityDocument
    ) throws(SetupApplyRefusal) -> RigMappingChange {
        do throws(RigReviewRefusal) {
            return try review.apply(decisions, to: document)
        } catch {
            throw .review(error)
        }
    }
}
