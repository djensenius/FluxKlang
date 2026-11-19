import Foundation

/// In-memory merge acknowledgement. Local-write completion is not cloud durability or a document commit.
/// Removal is this invocation's historical nil-snapshot outcome, not current disk state.
enum StudioDraftAcceptanceResult: Sendable, Equatable {
    case notAccepted
    case accepted(merge: StudioPatchMergeResult, removalOutcome: PendingStudioPatchMutationOutcome)
    case acceptedLocalWriteUnconfirmed(merge: StudioPatchMergeResult, retainedPublicationID: UUID?)
    case acceptedWithoutRetirement(merge: StudioPatchMergeResult)

    var merge: StudioPatchMergeResult? {
        switch self {
        case .notAccepted: nil
        case .accepted(let merge, _), .acceptedLocalWriteUnconfirmed(let merge, _),
             .acceptedWithoutRetirement(let merge): merge
        }
    }

    var removalOutcome: PendingStudioPatchMutationOutcome? {
        guard case .accepted(_, let outcome) = self else { return nil }
        return outcome
    }
}
