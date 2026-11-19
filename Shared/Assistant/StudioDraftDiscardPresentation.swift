import Foundation
import Observation

/// Accept, Replace and Discard share view-local ordering and task ownership.
/// This does not own the draft or storage lifetime.
@MainActor
@Observable
final class StudioDraftDiscardPresentation {
    enum Warning: Equatable {
        case removalUnconfirmed
        case localWriteUnconfirmed

        var message: String {
            switch self {
            case .removalUnconfirmed:
                "Removing the saved draft was not confirmed. It may reappear after restarting."
            case .localWriteUnconfirmed:
                "Studio changed in memory, but saving it locally was not confirmed. The draft was kept."
            }
        }
    }

    private enum WarningState {
        case removalUnconfirmed
        case localWriteUnconfirmed(AssistantCoordinator, UUID)
    }

    private var warningState: WarningState?
    var warning: Warning? {
        switch warningState {
        case .removalUnconfirmed: .removalUnconfirmed
        case .localWriteUnconfirmed(let coordinator, let id):
            coordinator.pendingPublicationID == id ? .localWriteUnconfirmed : nil
        case nil: nil
        }
    }
    var localWriteWarning: String? {
        warning == .localWriteUnconfirmed ? warning?.message : nil
    }

    @ObservationIgnored private var latestInvocation: UUID?
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var acceptances: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func discard(using coordinator: AssistantCoordinator) -> Task<Void, Never> {
        start(using: coordinator) {
            let outcome = await coordinator.discardPendingStudioDraftResult()
            return outcome.completed ? nil : .removalUnconfirmed
        }
    }

    @discardableResult
    func accept(using model: AppModel) -> Task<Void, Never> {
        let coordinator = model.assistant
        let id = coordinator.pendingPublicationID
        if let id, let existing = acceptances[id] { return existing }
        guard coordinator.canAcceptPendingDraft(hasActiveEnvironment: model.environments.active != nil) else {
            return Task {}
        }
        let task = start(using: coordinator) {
            defer { if let id { self.acceptances[id] = nil } }
            guard coordinator.pendingPublicationID == id else { return nil }
            let result = await model.acceptPendingAssistantDraftResult()
            if case .acceptedLocalWriteUnconfirmed(_, let retainedID?) = result,
               coordinator.pendingPublicationID == retainedID {
                return .localWriteUnconfirmed(coordinator, retainedID)
            }
            if let outcome = result.removalOutcome, !outcome.completed {
                return .removalUnconfirmed
            }
            return nil
        }
        if let id { acceptances[id] = task }
        return task
    }

    private func start(
        using coordinator: AssistantCoordinator, operation: @escaping @MainActor () async -> WarningState?
    ) -> Task<Void, Never> {
        let invocation = UUID()
        latestInvocation = invocation
        warningState = nil
        // Accepted storage work survives supersession and outer-view disappearance.
        let task = Task {
            defer { work[invocation] = nil }
            let state = await operation()
            guard latestInvocation == invocation else { return }
            if case .removalUnconfirmed = state, coordinator.pendingStudioDraft != nil { return }
            if case .localWriteUnconfirmed(_, let id) = state, coordinator.pendingPublicationID != id { return }
            warningState = state
        }
        work[invocation] = task
        return task
    }

    func pendingDraftChanged(_ draft: StudioPatchDraft?) {
        if draft != nil, case .removalUnconfirmed = warningState { warningState = nil }
        if case .localWriteUnconfirmed = warningState, warning == nil { warningState = nil }
    }

    func dismiss() {
        warningState = nil
    }

    func disappear() {
        latestInvocation = nil
        warningState = nil
    }

    /// Joins this snapshot only, without cancelling or closing admission for later clicks.
    func awaitOwnedWorkSnapshot() async {
        let snapshot = Array(work.values)
        for task in snapshot { await task.value }
    }
}
