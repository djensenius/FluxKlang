import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantPreferenceOwnershipTests {
    // Verified against AssistantChatController.spokenRepliesKey, not a new test-only key.
    private let spokenRepliesKey = "assistant.spokenReplies"

    @Test func controllersReadAndWriteOnlyTheirInjectedPreferenceSuites() async throws {
        try await withFixture { fixture in
            let firstDefaults = try fixture.makeDefaults("first")
            let secondDefaults = try fixture.makeDefaults("second")
            firstDefaults.set(true, forKey: spokenRepliesKey)
            secondDefaults.set(false, forKey: spokenRepliesKey)

            let first = fixture.makeChat(owner: "first", defaults: firstDefaults)
            let second = fixture.makeChat(owner: "second", defaults: secondDefaults)

            verifyPreferenceOwnership(
                first: first, second: second, firstDefaults: firstDefaults, secondDefaults: secondDefaults)
            #expect(fixture.speechFactoriesMade == 0)
            #expect(fixture.speechCalls == 0)
        }
    }

    @Test(arguments: [true, false])
    func appModelForwardsPreferencesWithEitherConversationStoreBranch(
        explicitConversationStore: Bool
    ) async throws {
        try await withFixture { fixture in
            let firstDefaults = try fixture.makeDefaults("first")
            let secondDefaults = try fixture.makeDefaults("second")
            firstDefaults.set(true, forKey: spokenRepliesKey)
            secondDefaults.set(false, forKey: spokenRepliesKey)

            let first = try fixture.makeModel(
                owner: "first", defaults: firstDefaults, explicitConversationStore: explicitConversationStore)
            let second = try fixture.makeModel(
                owner: "second", defaults: secondDefaults, explicitConversationStore: explicitConversationStore)

            verifyPreferenceOwnership(
                first: first.assistantChat, second: second.assistantChat,
                firstDefaults: firstDefaults, secondDefaults: secondDefaults)
            // Constructor/default-path coverage only: no loadStores, history operations,
            // responses, drafts, or hardware operations. AppIcon/reconnect preferences
            // remain process-scoped and are neither exercised nor mutated here.
        }
    }

    private func verifyPreferenceOwnership(
        first: AssistantChatController, second: AssistantChatController,
        firstDefaults: UserDefaults, secondDefaults: UserDefaults
    ) {
        #expect(first.spokenRepliesEnabled)
        #expect(!second.spokenRepliesEnabled)
        #expect(firstDefaults.bool(forKey: spokenRepliesKey))
        #expect(!secondDefaults.bool(forKey: spokenRepliesKey))

        first.spokenRepliesEnabled = false
        #expect(!firstDefaults.bool(forKey: spokenRepliesKey))
        #expect(!secondDefaults.bool(forKey: spokenRepliesKey))
        #expect(!second.spokenRepliesEnabled)

        second.spokenRepliesEnabled = true
        #expect(secondDefaults.bool(forKey: spokenRepliesKey))
        #expect(!firstDefaults.bool(forKey: spokenRepliesKey))
        #expect(!first.spokenRepliesEnabled)

        second.spokenRepliesEnabled = false
        #expect(!secondDefaults.bool(forKey: spokenRepliesKey))
        #expect(!firstDefaults.bool(forKey: spokenRepliesKey))
        #expect(!first.spokenRepliesEnabled)

        first.spokenRepliesEnabled = true
        #expect(firstDefaults.bool(forKey: spokenRepliesKey))
        #expect(!secondDefaults.bool(forKey: spokenRepliesKey))
        #expect(!second.spokenRepliesEnabled)
    }

    private func withFixture(
        _ body: @MainActor (PreferenceOwnershipFixture) throws -> Void
    ) async throws {
        // Require literal opt-out flags as well as the actual process-selected policy.
        // No app/service/defaults fixture construction occurs before these guards.
        let environment = ProcessInfo.processInfo.environment
        try #require(AppPersistence.isTesting)
        try #require(environment["FLUXKLANG_ISOLATED_TESTING"] == "1")
        try #require(environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "0")
        try #require(environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "0")
        try #require(AssistantServiceIsolation.deniesLiveServices)

        let fixture = PreferenceOwnershipFixture()
        do {
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try body(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }
}

@MainActor
private final class PreferenceOwnershipFixture {
    let root = URL.temporaryDirectory.appendingPathComponent(
        "assistant-preference-ownership-\(UUID().uuidString)", isDirectory: true)
    private var suites: [(name: String, defaults: UserDefaults)] = []
    private var chats: [AssistantChatController] = []
    private var models: [AppModel] = []
    private(set) var speechFactoriesMade = 0
    private(set) var speechCalls = 0

    func makeDefaults(_ owner: String) throws -> UserDefaults {
        let name = "\(root.lastPathComponent).\(owner)"
        let defaults = try #require(UserDefaults(suiteName: name))
        suites.append((name, defaults))
        return defaults
    }

    func makeChat(owner: String, defaults: UserDefaults) -> AssistantChatController {
        let coordinator = AssistantCoordinator(draftStore: PreferenceOwnershipDraftStore())
        let chat = AssistantChatController(
            coordinator: coordinator,
            store: makeHistory(owner: owner),
            generator: AssistantFallbackGenerator(coordinator: coordinator),
            actionInterpreter: AssistantUnavailableActionInterpreter(reason: "Preference-only test"),
            spokenRepliesDefaults: defaults
        ) { [weak self] in
            self?.speechFactoriesMade += 1
            return { [weak self] _ in self?.speechCalls += 1 }
        }
        chats.append(chat)
        return chat
    }

    func makeModel(
        owner: String, defaults: UserDefaults, explicitConversationStore: Bool
    ) throws -> AppModel {
        let directory = root.appendingPathComponent(owner, isDirectory: true)
        let domain = JSONFileStore(directory: directory.appendingPathComponent("domain"), cloud: nil)
        let launch = JSONFileStore(directory: directory.appendingPathComponent("launch-control-xl"), cloud: nil)
        let coordinator = AssistantCoordinator(draftStore: PreferenceOwnershipDraftStore())
        let settings = AssistantProviderSettings(
            defaults: try makeDefaults("provider-\(owner)"), credentials: MemoryAssistantCredentialStore())
        settings.provider = .deterministic
        let model: AppModel
        if explicitConversationStore {
            model = AppModel(
                assistant: coordinator, assistantProviderSettings: settings,
                hardware: .inert, launchControlXLStore: launch, domainStore: domain,
                assistantConversationStore: makeHistory(owner: owner),
                assistantSpokenRepliesDefaults: defaults)
        } else {
            // Deliberately omit assistantConversationStore. Its process-selected default
            // history path is NOT fixture-unique; never load or mutate that history.
            model = AppModel(
                assistant: coordinator, assistantProviderSettings: settings,
                hardware: .inert, launchControlXLStore: launch, domainStore: domain,
                assistantSpokenRepliesDefaults: defaults)
        }
        models.append(model)
        chats.append(model.assistantChat)
        return model
    }

    private func makeHistory(owner: String) -> AssistantConversationStore {
        let directory = root.appendingPathComponent(owner, isDirectory: true)
        return AssistantConversationStore(
            local: LocalAssistantHistoryBackend(
                directory: directory.appendingPathComponent("history", isDirectory: true),
                legacyFileURL: directory.appendingPathComponent("absent-legacy-history.json")),
            cloud: nil)
    }

    func cleanUp() async {
        // No chat work is submitted. These are finite sequential owner snapshots,
        // not barriers for future/global work or guarantees of durable persistence.
        for chat in chats {
            await chat.awaitOwnedWorkSnapshot()
        }
        for model in models {
            await model.awaitDomainScheduledSaveSnapshots()
            await model.awaitSiriEntityIndexingSnapshot()
        }
        chats.removeAll()
        models.removeAll()
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        suites.removeAll()
        if FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record(error, "Could not remove owned preference fixture directory")
            }
        }
    }
}

private actor PreferenceOwnershipDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?

    func load() async -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) async { self.draft = draft }
}
