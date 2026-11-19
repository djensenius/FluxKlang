import Foundation
import Observation

/// View-local intent ordering only; this does not own the draft or storage lifetime.
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
        let invocation = UUID()
        latestInvocation = invocation
        warning = nil
        // Accepted storage work survives supersession and outer-view disappearance.
        let task = Task {
            defer { work[invocation] = nil }
            let outcome = await coordinator.discardPendingStudioDraftResult()
            guard latestInvocation == invocation, coordinator.pendingStudioDraft == nil,
                  !outcome.completed else { return }
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
