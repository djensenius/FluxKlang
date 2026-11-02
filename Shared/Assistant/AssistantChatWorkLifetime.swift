import Foundation

/// Retains owned tasks independently of any current-task cancellation handle.
@MainActor
final class AssistantChatWorkLifetime {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Call synchronously at creation, before the main-actor task can run.
    @discardableResult
    func register(_ task: Task<Void, Never>, id: UUID) -> Task<Void, Never> {
        tasks[id] = task
        return task
    }

    /// Called by the task's defer on every closure exit, including cancellation.
    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }

    func snapshot() -> [Task<Void, Never>] {
        Array(tasks.values)
    }
}
