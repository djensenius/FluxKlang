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
    case missingAdmission(HostPrepare)
    case unexpectedDelivery(HostPrepare)
    case terminalAfterCleanup(HostPrepare, HostAuthorityRefusal)
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
