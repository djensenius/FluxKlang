//
//  CloudSyncTests+KeyValueAllowlist.swift
//  FluxKlangTests
//
//  `JSONFileStore` mirrors only files on the shipped key-value allowlist (#124, #735). Host-local and legacy
//  files stay plain local files: no cloud write, read or seed, and a stale cloud key is left untouched.
//  Observed environment loads (#943) distinguish known-absent from positively bad local/cloud data and hold.
//

import Foundation
import Testing
@testable import FluxKlang

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

    // MARK: - Observed loads and the environment hold (#943)

    /// "absent" | "malformed" | "unsupported" | "nonRegular" | "unreadable" local entries, cloud not configured.
    @Test(arguments: ["absent", "malformed", "unsupported", "nonRegular", "unreadable"])
    func observedLoadDistinguishesAbsentFromBadLocalData(kind: String) async throws {
        let directory = uniqueDirectory()
        let file = directory.appendingPathComponent("observed.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeObservedFixture(kind, to: file)
        let store = JSONFileStore(directory: directory, cloud: nil)
        let observed = await store.loadObserving(Model.self, from: "observed.json")
        let expected: JSONLoadFailure? = [
            "malformed": .malformedLocal, "unsupported": .malformedLocal,
            "nonRegular": .nonRegularLocal, "unreadable": .unreadableLocal
        ][kind]
        switch observed {
        case .absent: #expect(expected == nil)
        case .failed(let failure): #expect(failure == expected)
        case .loaded: Issue.record("Bad or missing local data must never load")
        }
    }

    private static func writeObservedFixture(_ kind: String, to file: URL) throws {
        switch kind {
        case "malformed": try Data("{ not json".utf8).write(to: file)
        case "unsupported": try Data(#"{"value":"future"}"#.utf8).write(to: file)
        case "nonRegular": try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        case "unreadable":
            try JSONEncoder().encode(Model(value: 1)).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        default: break
        }
    }

    @Test func observedLoadHoldsOnInvalidCloudWithValidLocalAndDefersSeeding() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await JSONFileStore(directory: directory, cloud: nil).save(Model(value: 4), to: "environments.json")
        let local = try Data(contentsOf: directory.appendingPathComponent("environments.json"))
        let cloud = MemoryCloudStore()
        let store = JSONFileStore(directory: directory, cloud: cloud)

        // Cloud nil is not a failure: local loads, and seeding waits for the caller.
        guard case .loaded(let value, let seed) = await store.loadObserving(Model.self, from: "environments.json")
        else {
            Issue.record("Valid local data with an empty cloud must load")
            return
        }
        #expect(value == Model(value: 4) && seed == local)
        #expect(cloud.writeCount == 0)

        let invalid = Data("{ damaged cloud".utf8)
        cloud.setData(invalid, forKey: "store.environments_json")
        let writes = cloud.writeCount
        guard case .failed(.malformedCloud) = await store.loadObserving(Model.self, from: "environments.json") else {
            Issue.record("Invalid cloud data must hold even when local is valid")
            return
        }
        #expect(cloud.writeCount == writes && cloud.data(forKey: "store.environments_json") == invalid)
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == local)
    }

    /// Bad environment, legacy effects or required legacy chain data: nothing published, migrated, seeded or
    /// written, including later mutations and ordinary reloads, until an explicit reload succeeds.
    @MainActor
    @Test(arguments: ["environments.json", "effects.json", "chain.json"])
    func environmentHoldPublishesMigratesAndWritesNothing(badFile: String) async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bad = Data("{ damaged".utf8)
        try bad.write(to: directory.appendingPathComponent(badFile))
        if badFile == "chain.json" {
            let effects = try JSONEncoder().encode([Effect(name: "Legacy")])
            try effects.write(to: directory.appendingPathComponent("effects.json"))
        }
        let cloud = MemoryCloudStore()
        let owner = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: cloud))

        await owner.load()
        #expect(owner.hold == EnvironmentLoadHold(fileName: badFile, failure: .malformedLocal))
        #expect(owner.environments.isEmpty && owner.activeID == nil)
        owner.migrateEffectEquipmentLinks(using: [])
        owner.addEnvironment(named: "Edited while held")
        await owner.reload()
        await owner.awaitScheduledSavesSnapshot()
        #expect(owner.hold?.fileName == badFile, "An ordinary reload never clears the hold")
        #expect(owner.lastSaveFailed)
        #expect(try Data(contentsOf: directory.appendingPathComponent(badFile)) == bad)
        if badFile != "environments.json" {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("environments.json").path))
        }
        #expect(cloud.writeCount == 0)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(badFile))
        #expect(await owner.reloadClearingHold())
        await owner.awaitScheduledSavesSnapshot()
        #expect(owner.hold == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("environments.json").path))
    }

    @MainActor
    @Test func environmentReloadHoldRetainsPriorStateAndInvalidCloudKeepsLocal() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let writer = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: cloud))
        await writer.load()
        writer.addEnvironment(named: "Saved")
        await writer.awaitScheduledSavesSnapshot()
        let local = try Data(contentsOf: directory.appendingPathComponent("environments.json"))
        let owner = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: cloud))
        await owner.load()
        let prior = owner.environments
        try #require(owner.hold == nil && prior.map(\.name) == ["Saved"])

        let invalid = Data("{ damaged cloud".utf8)
        cloud.setData(invalid, forKey: "store.environments_json")
        let writes = cloud.writeCount
        await owner.reload()
        #expect(owner.hold == EnvironmentLoadHold(fileName: "environments.json", failure: .malformedCloud))
        #expect(owner.environments == prior)
        owner.renameActive(to: "Refused")
        await owner.awaitScheduledSavesSnapshot()
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == local)
        #expect(cloud.writeCount == writes && cloud.data(forKey: "store.environments_json") == invalid)
    }

    @MainActor
    @Test func concurrentEnvironmentLoadsJoinOneReadAndRefuseWritesAroundIt() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: nil))
        await writer.load()
        writer.addEnvironment(named: "Saved")
        await writer.awaitScheduledSavesSnapshot()
        let local = try Data(contentsOf: directory.appendingPathComponent("environments.json"))
        let owner = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: nil))

        let first = Task { await owner.load() }
        let second = Task {
            await owner.load()
            return owner.environments.map(\.name)
        }
        let edit = Task { owner.addEnvironment(named: "Written around the load") }
        await first.value
        await edit.value
        #expect(await second.value == ["Saved"], "A joining caller never returns before the read publishes")
        await owner.awaitScheduledSavesSnapshot()
        #expect(owner.environments.map(\.name) == ["Saved"])
        #expect(owner.lastSaveFailed, "The load replaced a refused edit, so the unsaved warning stays")
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == local)
    }

    @MainActor
    @Test func environmentEditBeforeLoadIsRefusedAndKeepsSavedBytes() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: nil))
        await writer.load()
        writer.addEnvironment(named: "Saved")
        await writer.awaitScheduledSavesSnapshot()
        let local = try Data(contentsOf: directory.appendingPathComponent("environments.json"))
        let owner = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: nil))

        owner.addEnvironment(named: "Early edit")
        owner.migrateEffectEquipmentLinks(using: [])
        await owner.awaitScheduledSavesSnapshot()
        #expect(owner.lastSaveFailed)
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == local)
        await owner.load()
        #expect(owner.environments.map(\.name) == ["Saved"])
        #expect(owner.lastSaveFailed, "The early edit was never saved")
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == local)
    }

    @MainActor
    @Test func orderedSavesRefuseQueuedSuccessorsWithoutRetry() async {
        let saves = OrderedLocalSaves()
        let writes = WriteLog()
        let failed = saves.enqueue(admitting: { true }, write: { false })
        let queued = saves.enqueue(admitting: { true }, write: { await writes.record("queued") })
        #expect(await failed.value == false)
        #expect(await queued.value == false)
        #expect(saves.lastSaveFailed)

        let later = saves.enqueue(admitting: { true }, write: { await writes.record("later") })
        #expect(await later.value)
        #expect(!saves.lastSaveFailed)

        let invalidated = saves.enqueue(admitting: { true }, write: { await writes.record("invalidated") })
        saves.invalidateQueued()
        let held = saves.enqueue(admitting: { false }, write: { await writes.record("held") })
        #expect(await invalidated.value == false)
        #expect(await held.value == false)
        #expect(await writes.entries == ["later"], "Refused saves never write and are never retried")
    }

    /// A save enqueued after a failure resolves, while a refused successor is still pending, is not cascaded.
    @MainActor
    @Test func refusalsDoNotCountAsFailuresForLaterSaves() async {
        let saves = OrderedLocalSaves()
        let writes = WriteLog()
        let later = SaveBox()
        let failed = saves.enqueue(admitting: { true }, write: { false })
        let refused = saves.enqueue(admitting: {
            // Runs after `failed` resolved and before this queued save's refusal is decided.
            later.task = saves.enqueue(admitting: { true }, write: { await writes.record("later") })
            return true
        }, write: { await writes.record("refused") })
        #expect(await failed.value == false)
        #expect(await refused.value == false)
        #expect(await later.task?.value == true)
        #expect(await writes.entries == ["later"])
        #expect(!saves.lastSaveFailed)
    }

    @MainActor
    @Test func loadSettleKeepsWarningOnlyForRefusedEdits() async {
        let saves = OrderedLocalSaves()
        _ = await saves.refuse().value
        saves.settleAfterLoad()
        #expect(saves.lastSaveFailed, "A refused edit stays unsaved after a load")
        saves.settleAfterLoad()
        #expect(!saves.lastSaveFailed)
        #expect(await saves.enqueue(admitting: { true }, write: { false }).value == false)
        saves.settleAfterLoad()
        #expect(!saves.lastSaveFailed, "A loaded snapshot supersedes a failed write")
    }

    @MainActor
    @Test func savesOutlivingTheirOwnerAreRefused() async {
        var saves: OrderedLocalSaves? = OrderedLocalSaves()
        let writes = WriteLog()
        let first = saves?.enqueue(admitting: { true }, write: { await writes.record("first") })
        let orphan = saves?.enqueue(admitting: { true }, write: { await writes.record("orphan") })
        saves = nil
        _ = await first?.value
        #expect(await orphan?.value == false)
        #expect(await writes.entries.contains("orphan") == false)
    }

    @Test func environmentSaveFailureDoesNotMirrorToCloud() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("environments.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let cloud = MemoryCloudStore()
        let store = JSONFileStore(directory: directory, cloud: cloud)
        #expect(await store.saveReportingLocalWrite(
            Model(value: 42), to: "environments.json", mirrorsAfterLocalFailure: false) == false)
        #expect(cloud.writeCount == 0)
    }
}

@MainActor
private final class SaveBox {
    var task: Task<Bool, Never>?
}

private actor WriteLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) -> Bool {
        entries.append(entry)
        return true
    }
}
