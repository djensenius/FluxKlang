//
//  CloudSyncTests.swift
//  FluxKlangTests
//
//  Verifies that `JSONFileStore` mirrors persisted state to a cloud key-value
//  store (iCloud in the app), prefers the synced value over a stale local copy,
//  and migrates pre-existing local state up to the cloud on first sync.
//

import Foundation
import Testing
@testable import FluxKlang

struct CloudSyncTests {
    /// In-memory stand-in for iCloud's key-value store.
    private final class MemoryCloudStore: CloudKeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]
        private(set) var readCount = 0
        private(set) var writeCount = 0
        private(set) var synchronizeCount = 0

        func data(forKey key: String) -> Data? {
            lock.withLock { readCount += 1; return storage[key] }
        }
        func setData(_ data: Data, forKey key: String) {
            lock.withLock { writeCount += 1; storage[key] = data }
        }
        @discardableResult func synchronize() -> Bool {
            lock.withLock { synchronizeCount += 1 }
            return true
        }
    }

    private struct Model: Codable, Equatable { var value: Int }

    private func uniqueName() -> String { "test-\(UUID().uuidString).json" }

    @Test func defaultTestPersistenceIsLocalAndIsolated() async throws {
        #expect(AppPersistence.isTesting)
        #expect(AppPersistence.defaultCloud == nil)
        #expect(AppPersistence.directory.lastPathComponent.hasPrefix("FluxKlang-tests-"))
        #expect(AppPersistence.directory.path.hasPrefix(URL.temporaryDirectory.path))

        let name = uniqueName()
        await JSONFileStore.shared.save(Model(value: 13), to: name)
        let data = try Data(contentsOf: AppPersistence.directory.appendingPathComponent(name))
        #expect(try JSONDecoder().decode(Model.self, from: data) == Model(value: 13))
    }

    @Test func saveMirrorsToCloudAndLoads() async {
        let cloud = MemoryCloudStore()
        let store = JSONFileStore(cloud: cloud)
        let name = uniqueName()

        await store.save(Model(value: 7), to: name)
        let key = "store." + name.replacingOccurrences(of: ".", with: "_")
        #expect(cloud.data(forKey: key) != nil)

        let loaded = await store.load(Model.self, from: name)
        #expect(loaded == Model(value: 7))
    }

    @MainActor
    @Test func testStorageFactoryNeverLoadsOrChangesProductionSentinels() async throws {
        let productionDirectory = URL.temporaryDirectory.appendingPathComponent("sentinel-\(UUID().uuidString)")
        let productionSuite = "sentinel-\(UUID().uuidString)"
        let cloud = MemoryCloudStore()
        let production = AppPersistence.makeStorage(isTesting: false, productionDirectory: productionDirectory,
            productionCloud: cloud, productionPreferencesSuiteName: productionSuite)
        let isolated = AppPersistence.makeStorage(isTesting: true,
            productionDirectory: { Issue.record("Test accessed production files"); return productionDirectory }(),
            productionCloud: { Issue.record("Test selection constructed production cloud"); return cloud }(),
            productionPreferencesSuiteName: productionSuite)
        defer {
            try? FileManager.default.removeItem(at: productionDirectory)
            try? FileManager.default.removeItem(at: isolated.directory)
            production.defaults.removePersistentDomain(forName: productionSuite)
            if let suite = isolated.preferencesSuiteName { isolated.defaults.removePersistentDomain(forName: suite) }
        }
        let normalJSON = JSONFileStore(directory: production.directory, cloud: production.cloud)
        await normalJSON.save(Model(value: 41), to: "sentinel.json")
        production.defaults.set("untouched", forKey: "sentinel.preference")
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        _ = await coordinator.perform(.buildStudioDraft(.init(sourceInstrumentIDs: [])),
                                      context: AssistantBackendFixture.context())
        let draft = try #require(coordinator.pendingStudioDraft)
        await PendingStudioPatchStore(directory: production.directory).save(draft)
        let conversation = AssistantConversation(title: "Production sentinel")
        let historyDirectory = production.directory.appendingPathComponent("AssistantHistory")
        try await LocalAssistantHistoryBackend(directory: historyDirectory).save(.init(conversation: conversation))
        let draftURL = production.directory.appendingPathComponent("assistant-pending-studio-draft.json")
        let jsonURL = production.directory.appendingPathComponent("sentinel.json")
        let historyURL = historyDirectory.appendingPathComponent("\(conversation.id.uuidString).json")
        let originalFiles = try [jsonURL, draftURL, historyURL].map { try Data(contentsOf: $0) }
        let originalCloud = cloud.data(forKey: "store.sentinel_json")
        let reads = cloud.readCount
        let writes = cloud.writeCount

        let isolatedJSON = JSONFileStore(directory: isolated.directory, cloud: isolated.cloud)
        let isolatedPending = PendingStudioPatchStore(directory: isolated.directory)
        let isolatedHistory = LocalAssistantHistoryBackend(
            directory: isolated.directory.appendingPathComponent("AssistantHistory"))
        #expect(await isolatedJSON.load(Model.self, from: "sentinel.json") == nil)
        #expect(await isolatedPending.load() == nil, "Never load the production pending draft")
        #expect(try await isolatedHistory.loadRecords().isEmpty)
        #expect(isolated.defaults.string(forKey: "sentinel.preference") == nil)
        await isolatedJSON.save(Model(value: 99), to: "sentinel.json")
        await isolatedPending.save(draft)
        try await isolatedHistory.save(.init(conversation: AssistantConversation(title: "Test only")))
        isolated.defaults.set("test only", forKey: "sentinel.preference")
        #expect(await isolatedJSON.load(Model.self, from: "sentinel.json") == Model(value: 99))
        #expect(await isolatedPending.load()?.id == draft.id)
        #expect(isolated.cloud == nil)
        #expect(cloud.readCount == reads)
        #expect(cloud.writeCount == writes)
        #expect(cloud.synchronizeCount == 0)
        #expect(cloud.data(forKey: "store.sentinel_json") == originalCloud)
        #expect(try [jsonURL, draftURL, historyURL].map { try Data(contentsOf: $0) } == originalFiles)
        #expect(production.defaults.string(forKey: "sentinel.preference") == "untouched")
    }

    @Test func eachTestStorageSelectionStartsWithFreshFilesAndPreferences() throws {
        let first = AppPersistence.makeStorage(isTesting: true,
            productionDirectory: URL.temporaryDirectory, productionCloud: nil)
        let second = AppPersistence.makeStorage(isTesting: true,
            productionDirectory: URL.temporaryDirectory, productionCloud: nil)
        defer {
            for storage in [first, second] {
                if let suite = storage.preferencesSuiteName { storage.defaults.removePersistentDomain(forName: suite) }
            }
        }
        #expect(first.directory != second.directory)
        #expect(first.preferencesSuiteName != second.preferencesSuiteName)
        #expect(first.cloud == nil && second.cloud == nil)
        first.defaults.set("first launch", forKey: "sentinel.preference")
        #expect(second.defaults.string(forKey: "sentinel.preference") == nil)
        #expect(AppPersistence.storage.preferencesSuiteName != nil)
    }

    @Test func cloudValueIsPreferredOverLocal() async throws {
        let cloud = MemoryCloudStore()
        let store = JSONFileStore(cloud: cloud)
        let name = uniqueName()

        await store.save(Model(value: 1), to: name)
        // Simulate another device syncing a newer value into iCloud.
        let key = "store." + name.replacingOccurrences(of: ".", with: "_")
        cloud.setData(try JSONEncoder().encode(Model(value: 99)), forKey: key)

        let loaded = await store.load(Model.self, from: name)
        #expect(loaded == Model(value: 99))
    }

    @Test func existingLocalStateMigratesIntoCloud() async {
        let name = uniqueName()
        // Save with no cloud backend so only a local file exists.
        await JSONFileStore(cloud: nil).save(Model(value: 42), to: name)

        let cloud = MemoryCloudStore()
        let store = JSONFileStore(cloud: cloud)
        let key = "store." + name.replacingOccurrences(of: ".", with: "_")
        #expect(cloud.data(forKey: key) == nil)

        let loaded = await store.load(Model.self, from: name)
        #expect(loaded == Model(value: 42))
        #expect(cloud.data(forKey: key) != nil)
    }

    @Test func missingDataReturnsNil() async {
        let store = JSONFileStore(cloud: MemoryCloudStore())
        let loaded = await store.load(Model.self, from: uniqueName())
        #expect(loaded == nil)
    }
}
