/// Legacy in-memory merge acknowledgement, not an environment save or document commit.
/// Removal is this invocation's historical nil-snapshot outcome, not current disk state.
enum StudioDraftAcceptanceResult: Sendable, Equatable {
    case notAccepted
    case accepted(merge: StudioPatchMergeResult, removalOutcome: PendingStudioPatchMutationOutcome)

    var merge: StudioPatchMergeResult? {
        guard case .accepted(let merge, _) = self else { return nil }
        return merge
    }

    var removalOutcome: PendingStudioPatchMutationOutcome? {
        guard case .accepted(_, let outcome) = self else { return nil }
        return outcome
    }
}
