import Foundation
import Observation

/// Accept, Replace and Discard share view-local ordering and task ownership.
/// This does not own the draft or storage lifetime.
@MainActor
@Observable
final class StudioDraftDiscardPresentation {
    enum Warning: Equatable {
        case removalUnconfirmed

        var message: String {
            "Removing the saved draft was not confirmed. It may reappear after restarting."
        }
    }

    private(set) var warning: Warning?
    @ObservationIgnored private var latestInvocation: UUID?
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func discard(using coordinator: AssistantCoordinator) -> Task<Void, Never> {
        start(using: coordinator) {
            await coordinator.discardPendingStudioDraftResult()
        }
    }

    @discardableResult
    func accept(using model: AppModel) -> Task<Void, Never> {
        start(using: model.assistant) {
            await model.acceptPendingAssistantDraftResult().removalOutcome
        }
    }

    private func start(
        using coordinator: AssistantCoordinator,
        removal: @escaping @MainActor () async -> PendingStudioPatchMutationOutcome?
    ) -> Task<Void, Never> {
        let invocation = UUID()
        latestInvocation = invocation
        warning = nil
        // Accepted storage work survives supersession and outer-view disappearance.
        let task = Task {
            defer { work[invocation] = nil }
            let outcome = await removal()
            guard latestInvocation == invocation, coordinator.pendingStudioDraft == nil,
                  let outcome, !outcome.completed else { return }
            warning = .removalUnconfirmed
        }
        work[invocation] = task
        return task
    }

    func pendingDraftChanged(_ draft: StudioPatchDraft?) {
        if draft != nil { warning = nil }
    }

    func dismiss() {
        warning = nil
    }

    func disappear() {
        latestInvocation = nil
        warning = nil
    }

    /// Joins this snapshot only, without cancelling or closing admission for later clicks.
    func awaitOwnedWorkSnapshot() async {
        let snapshot = Array(work.values)
        for task in snapshot { await task.value }
    }
}
