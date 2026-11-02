import Foundation
@testable import FluxKlang

@MainActor
func withInAppAssistantFixture(
    _ body: @MainActor (InAppAssistantFixture) async throws -> Void
) async throws {
    try await withAssistantFixtureResources { resources in
        let fixture = InAppAssistantFixture(resources: resources)
        resources.onFinish { await fixture.finish() }
        try await body(fixture)
    }
}

@MainActor
final class InAppAssistantFixture {
    let resources: AssistantFixtureResources
    var chat: AssistantChatController?
    var model: AppModel?
    var generator: InAppCancellableGenerator?

    init(resources: AssistantFixtureResources) {
        self.resources = resources
    }

    func finish() async {
        // The body has stopped submitting. Seal fake admission before cancelling
        // chat: an already-queued producer may still request a stream.
        generator?.close()
        let ownedChat = chat ?? model?.assistantChat
        ownedChat?.cancel()
        await generator?.join()
        // Fake workers are separate from the finite producer/history snapshots.
        await ownedChat?.awaitOwnedWorkSnapshot()
        if let model {
            await model.awaitDomainScheduledSaveSnapshots()
            await model.awaitSiriEntityIndexingSnapshot()
        }
        // No connection or hardware service is started by this family.
        chat = nil
        model = nil
        generator = nil
        // The resource wrapper removes suites/root only after this returns.
    }
}

struct InAppStubGenerator: AssistantGenerating {
    let availabilityValue: AssistantModelAvailability
    let text: String

    init(availability: AssistantModelAvailability, text: String) {
        availabilityValue = availability
        self.text = text
    }

    func availability() async -> AssistantModelAvailability {
        availabilityValue
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }
}

final class InAppCancellableGenerator: AssistantGenerating {
    private let workers = AssistantFixtureWorkers()

    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            guard let task = workers.start({
                continuation.yield(.text("partial"))
                do {
                    try await Task.sleep(for: .seconds(30))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }) else {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() { workers.close() }
    func join() async { await workers.join() }
}

final class InAppRecordingGenerator: AssistantGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AssistantGenerationRequest] = []

    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Done"))
            continuation.finish()
        }
    }

    func latestRequest() -> AssistantGenerationRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }
}

final class InAppFailingRecordingGenerator: AssistantGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        lock.lock()
        requests += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: InAppAssistantTestError.generationFailed)
        }
    }
}

private enum InAppAssistantTestError: Error {
    case generationFailed
}

actor InAppMemoryHistoryBackend: AssistantHistoryBackend {
    private var records: [UUID: AssistantConversationRecord] = [:]
    private(set) var saveCount = 0
    private(set) var loadCount = 0
    private let loadDelay: Duration?

    init(loadDelay: Duration? = nil) {
        self.loadDelay = loadDelay
    }

    func loadRecords() async -> [AssistantConversationRecord] {
        loadCount += 1
        if let loadDelay {
            try? await Task.sleep(for: loadDelay)
        }
        return Array(records.values)
    }

    func save(_ record: AssistantConversationRecord) async {
        records[record.id] = record
        saveCount += 1
    }

    func record(id: UUID) -> AssistantConversationRecord? {
        records[id]
    }
}

actor InAppMemoryDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?

    func load() async -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) async { self.draft = draft }
}

struct InAppIsolationHTTPClient: AssistantHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw AssistantServiceIsolation.AccessError.denied
    }
}
