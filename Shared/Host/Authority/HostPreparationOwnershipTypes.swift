/// Inert results only. Retention is NOT a successful preparation answer,
/// installation, readiness or quiescence attestation.
enum OwnedPreparationStep: Equatable, Sendable {
    case refused(OwnedPreparationRefusal)
    case empty
    case retained(HostPrepare, AudioRoutingLayout)
    case terminated(HostPrepare, PrepareFailure, PrepareAnswerOutcome)
    case faulted(OwnedPreparationFault)
}

enum OwnedPreparationRefusal: Error, Equatable, Sendable {
    case legacyMode
    case faulted
    case blocked
    case occupied
    case missing
    case identityMismatch
    case unwanted
    case invalidFrames
    case invalidInputGeometry
}

/// One bounded permanent diagnostic, never a retry token or rollback claim.
enum OwnedPreparationFault: Equatable, Sendable {
    /// Canonical admission changed state, but no exact association was established.
    case unassociatedAdmission
    case missingAdmission(HostPrepare)
    case unexpectedDelivery(HostPrepare)
    /// Accounting was refused or unexpected. Do not retain collection-bearing refusals.
    case terminalAfterCleanup(HostPrepare)
}

/// Inert disposition of the actor's one private lifetime, not a second resource
/// owner or ledger. The terminal seam exposes neither resources nor book mutation.
enum OwnedPreparationLifetime: Equatable, Sendable {
    case vacant
    case provisional
    case queued(HostPrepare)
    case held(HostPrepare)
    case cleaned(HostPrepare)
    case faulted(OwnedPreparationFault)

    var fault: OwnedPreparationFault? {
        if case .faulted(let fault) = self { return fault }
        return nil
    }

    var admissionRefusal: HostAuthorityRefusal? {
        switch self {
        case .vacant: nil
        case .faulted: .preparationOwnerFaulted
        case .provisional, .queued, .held, .cleaned: .preparationOccupied
        }
    }

    /// Production checks this before submitting its one terminal failure answer.
    /// Only completed consuming cleanup (or no construction) may enter `.cleaned`.
    var terminalIdentity: HostPrepare? {
        if case .cleaned(let identity) = self { return identity }
        return nil
    }

    mutating func finishTerminal(
        _ result: Result<PrepareAnswerOutcome, HostAuthorityRefusal>
    ) -> OwnedPreparationDisposal {
        guard let identity = terminalIdentity else { return .refused(.faulted) }
        switch result {
        case .success(let outcome) where outcome == .routed || outcome == .dropped:
            self = .vacant
            return .disposed(outcome)
        case .failure, .success:
            let fault = OwnedPreparationFault.terminalAfterCleanup(identity)
            self = .faulted(fault)
            return .faultAfterCleanup(fault)
        }
    }
}

enum OwnedPreparationDisposal: Equatable, Sendable {
    case refused(OwnedPreparationRefusal)
    case disposed(PrepareAnswerOutcome)
    /// The resource is already destroyed; canonical bookkeeping refused.
    case faultAfterCleanup(OwnedPreparationFault)
}

struct OwnedPreparationBlock: Equatable, Sendable {
    let layout: AudioRoutingLayout
    let result: AudioRoutingProcessResult
    let output: [Float]
    let peaks: [Float]
}
