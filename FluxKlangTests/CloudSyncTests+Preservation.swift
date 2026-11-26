//
//  CloudSyncTests+Preservation.swift
//  FluxKlangTests
//
//  User-confirmed start-fresh for held local environment data (#947): the named item moves unchanged into
//  `Preserved`, the hold clears through `reloadClearingHold`, a failed move or an iCloud hold changes nothing, and
//  nothing reaches iCloud while held.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CloudSyncTests {
    /// The local failure kinds start-fresh preserves, and the failure each fixture produces.
    static let preservableKinds: [String: JSONLoadFailure] = [
        "malformed": .malformedLocal, "nonRegular": .nonRegularLocal, "unreadable": .unreadableLocal
    ]

    /// What identifies an entry across a move: rename keeps the same inode, type, permissions and size.
    private struct EntryIdentity: Equatable {
        let inode: Int?
        let type: FileAttributeType?
        let permissions: Int?
        let size: Int?

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            inode = attributes[.systemFileNumber] as? Int
            type = attributes[.type] as? FileAttributeType
            permissions = attributes[.posixPermissions] as? Int
            size = attributes[.size] as? Int
        }
    }

    private static let fixtureBytes = Data("{ damaged".utf8)
    private static let markerBytes = Data("kept".utf8)

    /// Writes a held fixture; the bytes it contains are `fixtureBytes` (inside `marker` for a directory).
    private static func writePreservationFixture(_ kind: String, to file: URL) throws {
        switch kind {
        case "nonRegular":
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            try fixtureBytes.write(to: file.appendingPathComponent("marker"))
        case "unreadable":
            try fixtureBytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        default:
            try fixtureBytes.write(to: file)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func preservedEntries(in directory: URL) -> [String] {
        let preserved = directory.appendingPathComponent(JSONFileStore.preservedDirectoryName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: preserved.path)) ?? []).sorted()
    }

    @MainActor
    private static func heldOwner(
        badFile: String, kind: String, in directory: URL, cloud: any CloudKeyValueStore
    ) async throws -> EnvironmentStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePreservationFixture(kind, to: directory.appendingPathComponent(badFile))
        if badFile == "chain.json" {
            let effects = try JSONEncoder().encode([Effect(name: "Legacy")])
            try effects.write(to: directory.appendingPathComponent("effects.json"))
        }
        let owner = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: cloud))
        await owner.load()
        let failure = try #require(preservableKinds[kind])
        try #require(owner.hold == EnvironmentLoadHold(fileName: badFile, failure: failure))
        return owner
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)), arguments: ["environments.json", "effects.json", "chain.json"],
          ["malformed", "nonRegular", "unreadable"])
    func startFreshMovesTheHeldItemUnchangedAndClearsTheHold(badFile: String, kind: String) async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let owner = try await Self.heldOwner(badFile: badFile, kind: kind, in: directory, cloud: cloud)
        let original = directory.appendingPathComponent(badFile)
        let identity = try EntryIdentity(original)
        try #require(cloud.writeCount == 0)

        let result = try await owner.preserveHeldSourceAndStartFresh(confirmed: try #require(owner.hold))
        // The cleared reload always queues a migration save, which recreates only environments.json.
        await owner.awaitScheduledSavesSnapshot()

        #expect(result.fileName == badFile && result.cleared && result.hold == nil && owner.hold == nil)
        #expect(Self.exists(original) == (badFile == "environments.json"))
        if Self.exists(original) {
            #expect(try EntryIdentity(original) != identity, "The original entry must not remain in place")
        }
        #expect(result.preservedURL.deletingLastPathComponent().standardizedFileURL
            == directory.appendingPathComponent(JSONFileStore.preservedDirectoryName).standardizedFileURL)
        #expect(result.preservedURL.lastPathComponent.hasPrefix("\(badFile)-"))
        #expect(Self.preservedEntries(in: directory) == [result.preservedURL.lastPathComponent])
        #expect(try EntryIdentity(result.preservedURL) == identity, "Moved, never copied or rewritten")
        switch kind {
        case "nonRegular":
            #expect(try Data(contentsOf: result.preservedURL.appendingPathComponent("marker")) == Self.fixtureBytes)
        case "unreadable":
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.preservedURL.path)
            #expect(try Data(contentsOf: result.preservedURL) == Self.fixtureBytes)
        default:
            #expect(try Data(contentsOf: result.preservedURL) == Self.fixtureBytes)
        }

        owner.addEnvironment(named: "Fresh")
        await owner.awaitScheduledSavesSnapshot()
        #expect(!owner.lastSaveFailed)
        let saved = try Data(contentsOf: directory.appendingPathComponent("environments.json"))
        #expect(saved.range(of: Data("Fresh".utf8)) != nil, "The store is usable again")
    }

    /// Only the named item moves; another bad source then holds, writes nothing and can be preserved in turn.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func startFreshSurfacesADifferentHoldAndKeepsTheFirstPreserved() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let effects = directory.appendingPathComponent("effects.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let badEffects = Data("{ damaged effects".utf8)
        try badEffects.write(to: effects)
        let owner = try await Self.heldOwner(badFile: "environments.json", kind: "malformed", in: directory,
                                             cloud: cloud)

        let first = try await owner.preserveHeldSourceAndStartFresh(confirmed: try #require(owner.hold))
        let effectsHold = EnvironmentLoadHold(fileName: "effects.json", failure: .malformedLocal)
        #expect(!first.cleared && first.hold == effectsHold && owner.hold == effectsHold)
        #expect(try Data(contentsOf: first.preservedURL) == Self.fixtureBytes)
        #expect(try Data(contentsOf: effects) == badEffects)
        #expect(!Self.exists(directory.appendingPathComponent("environments.json")))
        owner.addEnvironment(named: "Refused while held")
        await owner.awaitScheduledSavesSnapshot()
        #expect(cloud.writeCount == 0, "Nothing reaches iCloud before the hold clears")
        #expect(!Self.exists(directory.appendingPathComponent("environments.json")))

        let second = try await owner.preserveHeldSourceAndStartFresh(confirmed: effectsHold)
        #expect(second.cleared && second.hold == nil && owner.hold == nil)
        #expect(try Data(contentsOf: second.preservedURL) == badEffects)
        #expect(try Data(contentsOf: first.preservedURL) == Self.fixtureBytes, "The first item stays preserved")
        #expect(Self.preservedEntries(in: directory).count == 2)
        await owner.awaitScheduledSavesSnapshot()
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func failedStartFreshKeepsTheHoldAndMovesNothing() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let owner = try await Self.heldOwner(badFile: "environments.json", kind: "malformed", in: directory,
                                             cloud: cloud)
        // A regular file where the Preserved folder belongs makes the move fail.
        let blocker = directory.appendingPathComponent(JSONFileStore.preservedDirectoryName)
        try Self.markerBytes.write(to: blocker)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let held = try #require(owner.hold)

        do throws(EnvironmentPreservationError) {
            _ = try await owner.preserveHeldSourceAndStartFresh(confirmed: held)
            Issue.record("A failed move must not report success")
        } catch {
            guard case .moveFailed(let fileName, _) = error else {
                Issue.record("Expected a move failure, got \(error)")
                return
            }
            #expect(fileName == "environments.json")
        }

        #expect(owner.hold == held && owner.loads.phase == .held)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == Self.fixtureBytes)
        #expect(try Data(contentsOf: blocker) == Self.markerBytes)
        #expect(cloud.writeCount == 0)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func startFreshRefusesCloudHoldsAndLoadedStores() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let owner = EnvironmentStore(store: JSONFileStore(directory: directory, cloud: cloud))
        await owner.load()
        owner.addEnvironment(named: "Saved")
        await owner.awaitScheduledSavesSnapshot()
        let file = directory.appendingPathComponent("environments.json")
        let local = try Data(contentsOf: file)
        let unheld = EnvironmentLoadHold(fileName: "environments.json", failure: .malformedLocal)
        await #expect(throws: EnvironmentPreservationError.holdChanged) {
            _ = try await owner.preserveHeldSourceAndStartFresh(confirmed: unheld)
        }

        let invalid = Data("{ damaged cloud".utf8)
        cloud.setData(invalid, forKey: "store.environments_json")
        let writes = cloud.writeCount
        await owner.reload()
        let hold = try #require(owner.hold)
        #expect(hold.failure == .malformedCloud && !hold.isLocal)
        await #expect(throws: EnvironmentPreservationError.notPreservable) {
            _ = try await owner.preserveHeldSourceAndStartFresh(confirmed: hold)
        }
        await #expect(throws: EnvironmentPreservationError.holdChanged) {
            _ = try await owner.preserveHeldSourceAndStartFresh(confirmed: unheld)
        }
        #expect(owner.hold == hold)
        #expect(try Data(contentsOf: file) == local)
        #expect(!Self.exists(directory.appendingPathComponent(JSONFileStore.preservedDirectoryName)))
        #expect(cloud.writeCount == writes && cloud.data(forKey: "store.environments_json") == invalid)
    }

    /// The move waits for a write already running, and a save queued before start-fresh never runs after it.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func startFreshAwaitsInFlightWritesAndInvalidatesQueuedSaves() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try await Self.heldOwner(badFile: "environments.json", kind: "malformed", in: directory,
                                             cloud: MemoryCloudStore())
        let gate = PreservationWriteGate()
        defer { Task { await gate.open() } }
        let inFlight = owner.saves.enqueue(admitting: { true }, write: {
            await gate.wait()
            return await gate.record("in flight")
        })
        let queued = owner.saves.enqueue(admitting: { true }, write: { await gate.record("queued") })
        try await boundedWait { await gate.isWaiting }

        let held = try #require(owner.hold)
        let preservation = Task { try await owner.preserveHeldSourceAndStartFresh(confirmed: held) }
        for _ in 0..<50 { await Task.yield() }
        #expect(Self.exists(directory.appendingPathComponent("environments.json")), "The move waits for the write")
        #expect(Self.preservedEntries(in: directory).isEmpty)
        await gate.open()

        let result = try await preservation.value
        #expect(await inFlight.value)
        #expect(await queued.value == false)
        #expect(await gate.entries == ["in flight"], "A queued save never runs after start-fresh")
        #expect(result.hold == nil && owner.hold == nil)
        #expect(try Data(contentsOf: result.preservedURL) == Self.fixtureBytes)
        await owner.awaitScheduledSavesSnapshot()
    }

    /// Only the hold the user confirmed is acted on: a different file or failure moves nothing.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func startFreshRefusesAHoldOtherThanTheConfirmedOne() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloudStore()
        let owner = try await Self.heldOwner(badFile: "environments.json", kind: "malformed", in: directory,
                                             cloud: cloud)
        let held = try #require(owner.hold)
        for other in [EnvironmentLoadHold(fileName: "effects.json", failure: .malformedLocal),
                      EnvironmentLoadHold(fileName: "environments.json", failure: .unreadableLocal)] {
            await #expect(throws: EnvironmentPreservationError.holdChanged) {
                _ = try await owner.preserveHeldSourceAndStartFresh(confirmed: other)
            }
        }
        #expect(owner.hold == held && owner.loads.phase == .held)
        #expect(try Data(contentsOf: directory.appendingPathComponent("environments.json")) == Self.fixtureBytes)
        #expect(!Self.exists(directory.appendingPathComponent(JSONFileStore.preservedDirectoryName)))
        #expect(cloud.writeCount == 0)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func startFreshIsRefusedAsBusyWhileAReadIsInFlight() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = GatedCloudStore()
        defer { cloud.releaseAll() }
        // Held on effects.json, so a read reaches (and blocks on) the cloud environments key first.
        let owner = try await Self.heldOwner(badFile: "effects.json", kind: "malformed", in: directory, cloud: cloud)
        let held = try #require(owner.hold)
        cloud.arm(1)
        let reading = Task { await owner.reloadClearingHold() }
        try await boundedWait { cloud.blocked == 1 }
        #expect(owner.isReading)

        await #expect(throws: EnvironmentPreservationError.busy) {
            _ = try await owner.preserveHeldSourceAndStartFresh(confirmed: held)
        }
        cloud.releaseOne()
        #expect(await reading.value == false)
        #expect(owner.hold == held && !owner.isReading)
        #expect(try Data(contentsOf: directory.appendingPathComponent("effects.json")) == Self.fixtureBytes)
        #expect(!Self.exists(directory.appendingPathComponent(JSONFileStore.preservedDirectoryName)))
    }

    /// A reload (an iCloud change) during start-fresh's read is coalesced into a follow-up read; one more during
    /// that follow-up leaves a read in flight when start-fresh returns. Nothing is held, but `cleared` is false, so
    /// `AppModel` leaves Home and Siri to the `reloadStores` call that asked for the reload.
    @MainActor
    @Test(.timeLimit(.minutes(1))) func startFreshIsNotClearedWhileACoalescedReloadKeepsAReadInFlight() async throws {
        let directory = uniqueDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = GatedCloudStore()
        defer { cloud.releaseAll() }
        let owner = try await Self.heldOwner(badFile: "environments.json", kind: "malformed", in: directory,
                                             cloud: cloud)
        let held = try #require(owner.hold)
        cloud.arm(2)
        let preservation = Task { try await owner.preserveHeldSourceAndStartFresh(confirmed: held) }
        try await boundedWait { cloud.blocked == 1 } // Start-fresh's own read.
        let first = try await Self.startReload(owner)
        cloud.releaseOne()
        try await boundedWait { cloud.blocked == 2 } // The coalesced follow-up read.
        let second = try await Self.startReload(owner)
        cloud.releaseOne()

        let result = try await preservation.value
        #expect(!result.cleared && result.hold == nil)
        #expect(try Data(contentsOf: result.preservedURL) == Self.fixtureBytes)
        await first.value
        await second.value
        #expect(owner.hold == nil && !owner.isReading)
        await owner.awaitScheduledSavesSnapshot()
    }

    /// Starts `reload()` and returns once it has registered against the read in flight.
    @MainActor
    private static func startReload(_ owner: EnvironmentStore) async throws -> Task<Void, Never> {
        let started = StartFlag()
        let task = Task {
            started.raised = true // Same job as `reload()`'s synchronous request for a follow-up read.
            await owner.reload()
        }
        try await boundedWait { started.raised }
        return task
    }
}

@MainActor
private final class StartFlag {
    var raised = false
}

/// Cloud store whose armed reads of the environments key block until released, holding a read in flight.
private final class GatedCloudStore: CloudKeyValueStore, @unchecked Sendable {
    private static let gatedKey = "store.environments_json"
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var storage: [String: Data] = [:]
    private var armed = 0
    private var blockedReads = 0
    private var released = 0

    var blocked: Int { lock.withLock { blockedReads } }

    func arm(_ count: Int) { lock.withLock { armed += count } }

    func releaseOne() {
        lock.withLock { released += 1 }
        gate.signal()
    }

    /// Teardown: never leaves a read blocked, even when a test fails early.
    func releaseAll() {
        let pending = lock.withLock { () -> Int in
            armed = 0
            defer { released = blockedReads }
            return blockedReads - released
        }
        for _ in 0..<max(pending, 0) { gate.signal() }
    }

    func data(forKey key: String) -> Data? {
        let blocks = lock.withLock { () -> Bool in
            guard key == Self.gatedKey, armed > 0 else { return false }
            armed -= 1
            blockedReads += 1
            return true
        }
        if blocks { gate.wait() }
        return lock.withLock { storage[key] }
    }

    func setData(_ data: Data, forKey key: String) {
        lock.withLock { storage[key] = data }
    }

    @discardableResult func synchronize() -> Bool { true }
}

private actor PreservationWriteGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entries: [String] = []
    var isWaiting: Bool { !continuations.isEmpty }

    func wait() async { await withCheckedContinuation { continuations.append($0) } }

    func open() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }

    func record(_ entry: String) -> Bool {
        entries.append(entry)
        return true
    }
}
