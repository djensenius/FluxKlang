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
        private(set) var synchronizeCount = 0

        func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
        func setData(_ data: Data, forKey key: String) { lock.withLock { storage[key] = data } }
        @discardableResult func synchronize() -> Bool {
            lock.withLock { synchronizeCount += 1 }
            return true
        }
    }

    private struct Model: Codable, Equatable { var value: Int }

    private func uniqueName() -> String { "test-\(UUID().uuidString).json" }

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
