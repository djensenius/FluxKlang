import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantChatLifetimeTests {
    @Test func completedResponseStillOwnsHeldFinalHistorySave() async throws {
        try await withFixture { fixture in
            await fixture.history.hold(at: fixture.historyGate) { record in
                record.conversation?.messages.last?.state == .complete
                    && record.conversation?.messages.last?.role == .assistant
            }
            fixture.send("route Atlas to mains")
            try #require(await fixture.historyGate.waitForEntries())
            let terminal = try #require(fixture.chat.selectedConversation?.messages.last)
            #expect(terminal.state == .complete)
            #expect(!terminal.text.isEmpty)
            #expect(!fixture.chat.isStreaming)

            let waiter = fixture.startSnapshot()
            await waiter.waitForStart()
            #expect(!waiter.finished)
            #expect(await fixture.history.saved.contains {
                $0.conversation?.messages.contains(terminal) == true
            } == false)

            await fixture.historyGate.releaseAll()
            await waiter.join()
            #expect(waiter.finished)
            #expect(await fixture.history.saved.contains {
                $0.conversation?.messages.contains(terminal) == true
            })
        }
    }

    @Test func supersededInterpreterAndItsLateHistoryRemainOwned() async throws {
        try await withFixture { fixture in
            let oldQuestion = "route Old Atlas to mains"
            await fixture.interpreter.hold(question: oldQuestion)
            fixture.send(oldQuestion)
            try #require(await fixture.interpreterGate.waitForEntries())
            let oldID = try #require(fixture.chat.selectedConversation?.messages.last?.id)
            await fixture.history.hold(at: fixture.historyGate) { record in
                record.conversation?.messages.contains {
                    $0.id == oldID && $0.state == .cancelled
                } == true
            }
            await fixture.history.hold(at: fixture.newerHistoryGate) { record in
                record.conversation?.messages.last?.state == .complete
                    && record.conversation?.messages.last?.role == .assistant
                    && record.conversation?.messages.last?.id != oldID
            }
            fixture.chat.cancel()
            fixture.send("route New Atlas to mains")
            try #require(await fixture.newerHistoryGate.waitForEntries())
            let newer = try #require(fixture.chat.selectedConversation?.messages.last)
            let selectedID = fixture.chat.selectedConversationID
            #expect(newer.state == .complete)
            #expect(!fixture.chat.isStreaming)

            await fixture.newerHistoryGate.releaseAll()
            let waiter = fixture.startSnapshot()
            await waiter.waitForStart()
            #expect(!waiter.finished)
            #expect(fixture.chat.selectedConversation?.messages.first { $0.id == oldID }?.state == .streaming)

            await fixture.interpreterGate.releaseAll()
            try #require(await fixture.historyGate.waitForEntries())
            #expect(!waiter.finished)
            #expect(fixture.chat.selectedConversationID == selectedID)
            #expect(fixture.chat.selectedConversation?.messages.last == newer)
            #expect(!fixture.chat.isStreaming)
            #expect(fixture.chat.selectedConversation?.messages.first { $0.id == oldID }?.state == .cancelled)

            await fixture.historyGate.releaseAll()
            await waiter.join()
            #expect(waiter.finished)
            #expect(fixture.chat.selectedConversation?.messages.last == newer)
            #expect(await fixture.history.saved.contains { record in
                record.conversation?.messages.contains { $0.id == oldID && $0.state == .cancelled } == true
            })
        }
    }

    @Test func wiringSnapshotCoversDraftPersistenceThenHistory() async throws {
        try await withFixture { fixture in
            let source = Equipment(name: "Lifetime Synth", outputs: ["Out"])
            let context = AssistantBackendFixture.context(
                equipment: [source],
                inputs: [StudioInputConnection(connector: 1, equipmentID: source.id, outputPort: 0)]
            )
            await fixture.drafts.hold(sourceID: source.id)
            fixture.chat.createWiringDraft(
                sourceIDs: [source.id], effectIDs: [], destination: .finalMix, context: context
            )
            try #require(await fixture.draftGate.waitForEntries())
            let draft = try #require(fixture.coordinator.pendingStudioDraft)
            #expect(await fixture.drafts.load() == nil)
            await fixture.history.hold(at: fixture.historyGate) { record in
                record.conversation?.messages.contains { message in
                    message.cards.contains { card in
                        if case .pendingDraft(let id, _, _) = card { return id == draft.id }
                        return false
                    }
                } == true
            }
            let waiter = fixture.startSnapshot()
            await waiter.waitForStart()
            #expect(!waiter.finished)

            await fixture.draftGate.releaseAll()
            try #require(await fixture.historyGate.waitForEntries())
            #expect(await fixture.drafts.load() == draft)
            #expect(!waiter.finished)
            #expect(fixture.coordinator.pendingStudioDraft == draft)
            #expect(fixture.chat.selectedConversation?.messages.last?.role == .assistant)

            await fixture.historyGate.releaseAll()
            await waiter.join()
            #expect(waiter.finished)
            #expect(await fixture.history.saved.contains {
                $0.conversation?.messages.last?.cards.contains {
                    if case .pendingDraft(let id, _, _) = $0 { return id == draft.id }
                    return false
                } == true
            })
        }
    }

    @Test(arguments: [false, true])
    func removalWaitsForLocalTombstones(clearAll: Bool) async throws {
        try await withFixture { fixture in
            if clearAll {
                fixture.chat.newConversation()
                await fixture.chat.awaitOwnedWorkSnapshot()
            }
            let removedIDs = Set(fixture.chat.conversations.map(\.id))
            #expect(removedIDs.count == (clearAll ? 2 : 1))
            await fixture.history.hold(at: fixture.historyGate) { record in
                removedIDs.contains(record.id) && record.deletedAt != nil
            }
            if clearAll {
                fixture.chat.clearAll()
            } else {
                fixture.chat.deleteConversation(id: try #require(removedIDs.first))
            }
            #expect(fixture.chat.conversations.isEmpty)
            #expect(fixture.chat.selectedConversationID == nil)
            try #require(await fixture.historyGate.waitForEntries())
            let waiter = fixture.startSnapshot()
            await waiter.waitForStart()
            #expect(!waiter.finished)
            #expect(await fixture.history.saved.filter { $0.deletedAt != nil }.isEmpty)

            if clearAll {
                await fixture.historyGate.releaseOne()
                try #require(await fixture.historyGate.waitForEntries(2))
                #expect(!waiter.finished)
                #expect(await fixture.history.saved.filter { $0.deletedAt != nil }.count == 1)
            }
            await fixture.historyGate.releaseAll()
            await waiter.join()
            #expect(waiter.finished)
            let records = try await fixture.history.loadRecords()
            #expect(Set(records.filter { $0.deletedAt != nil }.map(\.id)) == removedIDs)
        }
    }

    private func withFixture(
        _ body: @MainActor (ChatLifetimeFixture) async throws -> Void
    ) async throws {
        let fixture = try ChatLifetimeFixture()
        await fixture.chat.load()
        fixture.chat.newConversation()
        await fixture.chat.awaitOwnedWorkSnapshot()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }
}

@MainActor
private final class ChatLifetimeFixture {
    let historyGate = AssistantLifetimeGate()
    let newerHistoryGate = AssistantLifetimeGate()
    let interpreterGate = AssistantLifetimeGate()
    let draftGate = AssistantLifetimeGate()
    let history: ChatLifetimeHistory
    let interpreter: ChatLifetimeInterpreter
    let drafts: ChatLifetimeDrafts
    let coordinator: AssistantCoordinator
    let chat: AssistantChatController
    private let store: AssistantConversationStore
    private let directory: URL
    private let suite: String
    private let defaults: UserDefaults
    private var waiters: [ChatLifetimeSnapshotWaiter] = []
    private var acceptingSubmissions = true

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(AppPersistence.isTesting)
        try #require(environment["FLUXKLANG_ISOLATED_TESTING"] == "1")
        try #require(environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "0")
        try #require(environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "0")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let suite = "AssistantChatLifetime-\(UUID().uuidString)"
        self.suite = suite
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        history = ChatLifetimeHistory(local: LocalAssistantHistoryBackend(
            directory: directory.appendingPathComponent("history", isDirectory: true),
            legacyFileURL: directory.appendingPathComponent("absent-legacy-\(UUID().uuidString).json")
        ))
        store = AssistantConversationStore(local: history, cloud: nil)
        drafts = ChatLifetimeDrafts(gate: draftGate)
        interpreter = ChatLifetimeInterpreter(gate: interpreterGate)
        coordinator = AssistantCoordinator(draftStore: drafts)
        // Direct inert injection bypasses provider settings and all credential factories.
        chat = AssistantChatController(
            coordinator: coordinator, store: store, generator: ChatLifetimeGenerator(),
            actionInterpreter: interpreter, spokenRepliesDefaults: defaults,
            makeSpeech: {
                Issue.record("Lifetime fixtures must not construct speech")
                return { _ in Issue.record("Lifetime fixtures must not speak") }
            }
        )
    }

    func send(_ question: String) {
        guard acceptingSubmissions else {
            Issue.record("Submission after cleanup started")
            return
        }
        chat.composer = question
        chat.send(context: AssistantBackendFixture.context())
    }

    func startSnapshot() -> ChatLifetimeSnapshotWaiter {
        let waiter = ChatLifetimeSnapshotWaiter(chat: chat)
        waiters.append(waiter)
        return waiter
    }

    func cleanup() async {
        acceptingSubmissions = false
        chat.cancel()
        // Disarm future entries too: cancelled producers may still enqueue history saves.
        for gate in [historyGate, newerHistoryGate, interpreterGate, draftGate] {
            await gate.releaseAll()
        }
        // Fakes run inline in owned producers; there are no detached fake workers to join.
        for waiter in waiters { await waiter.join() }
        await chat.awaitOwnedWorkSnapshot()
        #expect(await store.diagnostics.isEmpty)
        // If a captured task cannot finish, execution never reaches resource deletion.
        defaults.removePersistentDomain(forName: suite)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            Issue.record("Could not remove owned lifetime history: \(error)")
        }
    }
}

@MainActor
private final class ChatLifetimeSnapshotWaiter {
    private let started: AsyncStream<Void>
    private var task: Task<Void, Never>?
    private(set) var finished = false

    init(chat: AssistantChatController) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        started = stream
        task = Task { @MainActor in
            // Synchronous signal: the snapshot call starts on this actor before the observer resumes.
            continuation.yield(())
            continuation.finish()
            await chat.awaitOwnedWorkSnapshot()
            finished = true
        }
    }

    func waitForStart() async {
        for await _ in started { return }
        Issue.record("Snapshot waiter did not start")
    }

    func join() async {
        await task?.value
    }
}

private actor ChatLifetimeHistory: AssistantHistoryBackend {
    private let local: LocalAssistantHistoryBackend
    private var holds: [(AssistantLifetimeGate, @Sendable (AssistantConversationRecord) -> Bool)] = []
    private(set) var saved: [AssistantConversationRecord] = []

    init(local: LocalAssistantHistoryBackend) {
        self.local = local
    }

    func hold(
        at gate: AssistantLifetimeGate,
        matching predicate: @escaping @Sendable (AssistantConversationRecord) -> Bool
    ) {
        holds.append((gate, predicate))
    }

    func loadRecords() async throws -> [AssistantConversationRecord] {
        try await local.loadRecords()
    }

    func save(_ record: AssistantConversationRecord) async throws {
        for (gate, matches) in holds where matches(record) {
            await gate.enter()
        }
        try await local.save(record)
        // Observe successful local forwarding, not last-write order or durable storage.
        saved.append(record)
    }
}

private actor ChatLifetimeDrafts: PendingStudioPatchPersisting {
    private let gate: AssistantLifetimeGate
    private var sourceID: UUID?
    private var draft: StudioPatchDraft?

    init(gate: AssistantLifetimeGate) {
        self.gate = gate
    }

    func hold(sourceID: UUID) {
        self.sourceID = sourceID
    }

    func load() -> StudioPatchDraft? { draft }

    func save(_ draft: StudioPatchDraft?) async {
        if let sourceID, draft?.request.sourceInstrumentIDs.contains(sourceID) == true {
            await gate.enter()
        }
        self.draft = draft
    }
}

private actor ChatLifetimeInterpreter: AssistantActionInterpreting {
    private let gate: AssistantLifetimeGate
    private var heldQuestion: String?

    init(gate: AssistantLifetimeGate) {
        self.gate = gate
    }

    func hold(question: String) {
        heldQuestion = question
    }

    func availability() -> AssistantActionInterpreterAvailability { .available }

    func interpret(_ request: AssistantActionInterpretationRequest) async throws -> AssistantActionInterpretation {
        if request.text == heldQuestion {
            // Deliberately noncooperative: return even after the owning response was cancelled.
            await gate.enter()
        }
        return .clarification("Review the routing request")
    }
}

private struct ChatLifetimeGenerator: AssistantGenerating {
    func availability() async -> AssistantModelAvailability { .deterministic }

    func stream(_ request: AssistantGenerationRequest) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        Issue.record("Routing and wiring lifetime fixtures must not invoke generation")
        return AsyncThrowingStream { $0.finish() }
    }
}
