//
//  CloudSyncTests+KeyValueAllowlist.swift
//  FluxKlangTests
//
//  `JSONFileStore` mirrors only files on the shipped key-value allowlist (#124, #735). Host-local and legacy
//  files stay plain local files: no cloud write, read or seed, and a stale cloud key is left untouched.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CloudSyncTests {
    /// Store files that go through `JSONFileStore` but are not on the allowlist.
    static let localOnlyFileNames = ["launch-control-xl.json", "effects.json", "chain.json"]

    /// The shipped allowlist, restated as file names.
    static let syncedFileNames = [
        "environments.json", "studio-connections.json", "equipment.json", "presets.json", "spatial.json",
        "fader-layout.json", "routing_snapshots.json"
    ]

    func uniqueDirectory() -> URL {
        AppPersistence.directory.appendingPathComponent("cloud-sync-\(UUID().uuidString)", isDirectory: true)
    }

    private func cloudKey(for name: String) -> String {
        "store." + name.replacingOccurrences(of: ".", with: "_")
    }

    @Test func failedLocalWriteStillSubmitsEncodedValueToCloud() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("environments.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("block replacement".utf8).write(to: destination.appendingPathComponent("blocker"))
        let cloud = MemoryCloudStore()
        let store = JSONFileStore(directory: directory, cloud: cloud)

        #expect(await store.saveReportingLocalWrite(Model(value: 42), to: "environments.json") == false)
        let data = try #require(cloud.data(forKey: "store.environments_json"))
        #expect(try JSONDecoder().decode(Model.self, from: data) == Model(value: 42))
        #expect(cloud.synchronizeCount == 0)
    }

    @Test func encodingFailureDoesNotSubmitToCloud() async {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let store = JSONFileStore(directory: directory, cloud: cloud)
        #expect(await store.saveReportingLocalWrite(Double.nan, to: "environments.json") == false)
        #expect(cloud.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("environments.json").path))
    }

    @Test func fileNameListsMatchTheShippedAllowlist() {
        let allowlisted = KeyValueAllowlist.shipped.entries.map(\.key.rawValue)
        #expect(Set(Self.syncedFileNames.map(cloudKey(for:))) == Set(allowlisted))
        #expect(Self.localOnlyFileNames.allSatisfy { !KeyValueAllowlist.shipped.contains(rawKey: cloudKey(for: $0)) })
        // Every shipped store file must be listed here, so a new store file forces a sync decision.
        let storeFiles = StorageInventory.shipped.filter { $0.surface.kind == .storeFile }.map(\.surface.name)
        #expect(Set(storeFiles) == Set(Self.syncedFileNames + Self.localOnlyFileNames))
    }

    @Test(arguments: localOnlyFileNames)
    func localOnlyFileSaveNeverWritesToCloud(name: String) async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()

        await JSONFileStore(directory: directory, cloud: cloud).save(Model(value: 5), to: name)

        #expect(cloud.writeCount == 0)
        #expect(cloud.readCount == 0)
        let local = try Data(contentsOf: directory.appendingPathComponent(name))
        #expect(try JSONDecoder().decode(Model.self, from: local) == Model(value: 5))
        #expect(cloud.data(forKey: cloudKey(for: name)) == nil)
    }

    @Test(arguments: localOnlyFileNames)
    func localOnlyFileLoadPrefersLocalAndLeavesStaleCloudValue(name: String) async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await JSONFileStore(directory: directory, cloud: nil).save(Model(value: 1), to: name)
        let cloud = MemoryCloudStore()
        let stale = try JSONEncoder().encode(Model(value: 99))
        cloud.setData(stale, forKey: cloudKey(for: name))
        let writes = cloud.writeCount

        let loaded = await JSONFileStore(directory: directory, cloud: cloud).load(Model.self, from: name)

        #expect(loaded == Model(value: 1))
        #expect(cloud.readCount == 0)
        #expect(cloud.writeCount == writes)
        #expect(cloud.data(forKey: cloudKey(for: name)) == stale, "The stale key stays in place")
    }

    @Test(arguments: localOnlyFileNames)
    func localOnlyFileLoadNeverResurrectsStaleCloudValue(name: String) async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        cloud.setData(try JSONEncoder().encode(Model(value: 99)), forKey: cloudKey(for: name))
        let writes = cloud.writeCount

        let loaded = await JSONFileStore(directory: directory, cloud: cloud).load(Model.self, from: name)

        #expect(loaded == nil)
        #expect(cloud.readCount == 0)
        #expect(cloud.writeCount == writes)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }

    @Test(arguments: syncedFileNames)
    func allowlistedFileStillSyncs(name: String) async throws {
        let cloud = MemoryCloudStore()
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore(directory: directory, cloud: cloud)

        await store.save(Model(value: 3), to: name)
        #expect(cloud.writeCount == 1)
        let local = try Data(contentsOf: directory.appendingPathComponent(name))
        #expect(cloud.data(forKey: cloudKey(for: name)) == local)

        cloud.setData(try JSONEncoder().encode(Model(value: 77)), forKey: cloudKey(for: name))
        #expect(await store.load(Model.self, from: name) == Model(value: 77), "The cloud copy is preferred")

        let seededDirectory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: seededDirectory) }
        await JSONFileStore(directory: seededDirectory, cloud: nil).save(Model(value: 8), to: name)
        let emptyCloud = MemoryCloudStore()
        let seeded = JSONFileStore(directory: seededDirectory, cloud: emptyCloud)
        #expect(await seeded.load(Model.self, from: name) == Model(value: 8))
        #expect(emptyCloud.readCount == 1)
        #expect(emptyCloud.writeCount == 1, "A missing cloud value is seeded from the local copy")
        let uploaded = try #require(emptyCloud.data(forKey: cloudKey(for: name)))
        #expect(try JSONDecoder().decode(Model.self, from: uploaded) == Model(value: 8))
    }
}
