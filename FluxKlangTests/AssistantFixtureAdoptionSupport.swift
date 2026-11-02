import Foundation
import Synchronization
import Testing
@testable import FluxKlang

final class AssistantFixtureWorkers: Sendable {
    private struct State: Sendable {
        var closed = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        state.withLock { state in
            guard !state.closed else { return nil }
            let task = Task(operation: operation)
            state.tasks.append(task)
            return task
        }
    }

    func close() {
        let tasks = state.withLock { state in
            state.closed = true
            return state.tasks
        }
        // Cancellation handlers may reenter the owner, so cancel outside the lock.
        for task in tasks { task.cancel() }
    }

    func join() async {
        close()
        let tasks = state.withLock { $0.tasks }
        for task in tasks { await task.value }
        state.withLock { $0.tasks.removeAll() }
    }
}

@MainActor
final class AssistantFixtureReplyGenerator: AssistantGenerating {
    nonisolated private let workers = AssistantFixtureWorkers()
    private let reply: String
    private(set) var calls = 0

    init(reply: String = "provider reply") {
        self.reply = reply
    }

    func availability() async -> AssistantModelAvailability { .ready }

    nonisolated func stream(_ request: AssistantGenerationRequest) -> AsyncThrowingStream<
        AssistantStreamEvent, any Error
    > {
        AsyncThrowingStream { continuation in
            guard let worker = workers.start({ @MainActor [self] in
                calls += 1
                continuation.yield(.text(reply))
                continuation.finish()
            }) else {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    func close() { workers.close() }
    func join() async { await workers.join() }
}

@MainActor
final class AssistantFixtureResources {
    let root = URL.temporaryDirectory.appendingPathComponent(
        "assistant-fixture-\(UUID().uuidString)", isDirectory: true)
    private var suites: [(name: String, defaults: UserDefaults)] = []
    private var cleanupActions: [@MainActor () async -> Void] = []

    func defaults(_ label: String) throws -> UserDefaults {
        let name = "\(root.lastPathComponent).\(label)"
        let defaults = try #require(UserDefaults(suiteName: name))
        suites.append((name, defaults))
        return defaults
    }

    // Register a complete, ordered fixture cleanup before its first throwing or async setup step.
    func onFinish(_ cleanup: @escaping @MainActor () async -> Void) {
        cleanupActions.append(cleanup)
    }

    fileprivate func finish() async {
        for cleanup in cleanupActions.reversed() { await cleanup() }
        cleanupActions.removeAll()
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        suites.removeAll()
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            Issue.record(error, "Could not remove owned assistant fixture directory")
        }
    }
}

@MainActor
func withAssistantFixtureResources(
    _ body: @MainActor (AssistantFixtureResources) async throws -> Void
) async throws {
    let environment = ProcessInfo.processInfo.environment
    try #require(AppPersistence.isTesting)
    try #require(environment["FLUXKLANG_ISOLATED_TESTING"] == "1")
    try #require(environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "0")
    try #require(environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "0")
    try #require(AssistantServiceIsolation.deniesLiveServices)
    let resources = AssistantFixtureResources()
    do {
        try await body(resources)
    } catch {
        await resources.finish()
        throw error
    }
    await resources.finish()
}
