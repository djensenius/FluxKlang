//
//  JSONFileStore.swift
//  FluxKlang
//
//  Tiny actor that persists Codable values as JSON. Files on the shipped
//  `KeyValueAllowlist` are mirrored to iCloud via a `CloudKeyValueStore` so they
//  sync across the user's devices; other files stay local. A copy in the app's
//  Application Support directory provides an offline cache and first-run
//  migration. Keeps file I/O off the main actor.
//

import Foundation

/// Test hosts must never read user files or mirror seeded state to iCloud.
enum AppPersistence {
    struct Storage: Sendable {
        let directory: URL
        let cloud: (any CloudKeyValueStore)?
        let preferencesSuiteName: String?

        var defaults: UserDefaults {
            guard let preferencesSuiteName else { return .standard }
            guard let defaults = UserDefaults(suiteName: preferencesSuiteName) else {
                preconditionFailure("Unable to create isolated test preferences")
            }
            return defaults
        }
    }

    static let isTesting = detectsTesting(
        environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)

    static func detectsTesting(environment: [String: String], arguments: [String]) -> Bool {
        if environment["FLUXKLANG_ISOLATED_TESTING"] == "1" { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        #if DEBUG
        return arguments.contains("-ui-testing")
        #else
        return false
        #endif
    }

    /// Selected once, before any default store or preference access.
    static let storage = makeStorage(
        isTesting: isTesting, productionDirectory: productionDirectory(), productionCloud: UbiquitousCloudStore())

    static var directory: URL { storage.directory }
    static var defaultCloud: (any CloudKeyValueStore)? { storage.cloud }
    static var defaults: UserDefaults { storage.defaults }

    /// Production inputs are lazy: test selection never constructs a cloud
    /// backend or accesses the normal Application Support directory.
    static func makeStorage(
        isTesting: Bool,
        productionDirectory: @autoclosure () -> URL,
        productionCloud: @autoclosure () -> (any CloudKeyValueStore)?,
        productionPreferencesSuiteName: String? = nil
    ) -> Storage {
        if isTesting {
            let name = "FluxKlang-tests-\(UUID().uuidString)"
            return Storage(directory: URL.temporaryDirectory.appendingPathComponent(name, isDirectory: true),
                           cloud: nil, preferencesSuiteName: name)
        }
        return Storage(directory: productionDirectory(), cloud: productionCloud(),
                       preferencesSuiteName: productionPreferencesSuiteName)
    }

    private static func productionDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        return base.appendingPathComponent("FluxKlang", isDirectory: true)
    }
}

/// Why an observed load refused to produce a value. Positively bad data only; cloud `nil` is never a failure.
enum JSONLoadFailure: Equatable, Sendable {
    case unreadableLocal
    case nonRegularLocal
    case malformedLocal
    case malformedCloud
}

enum JSONLoadObservation<Value: Sendable>: Sendable {
    case absent
    /// `cloudSeed` holds local bytes to submit with `seedCloud` once the caller publishes.
    case loaded(Value, cloudSeed: Data?)
    case failed(JSONLoadFailure)
}

extension JSONLoadObservation {
    /// The value, or `nil` when known-absent. Positively bad data throws a hold naming `fileName`.
    func usableValue(_ fileName: String) throws(EnvironmentLoadHold) -> Value? {
        switch self {
        case .absent: return nil
        case .loaded(let value, _): return value
        case .failed(let failure): throw EnvironmentLoadHold(fileName: fileName, failure: failure)
        }
    }

    var cloudSeed: Data? {
        guard case .loaded(_, let seed) = self else { return nil }
        return seed
    }
}

/// Why environment loading stopped (#943). Nothing is copied or restored automatically; only an explicit,
/// user-confirmed start-fresh (#947) moves a held local item, unchanged, into `Preserved`.
struct EnvironmentLoadHold: Error, Equatable, Sendable {
    let fileName: String
    let failure: JSONLoadFailure

    /// Whether the bad data is a local item that start-fresh may preserve; an iCloud copy never is.
    var isLocal: Bool { failure != .malformedCloud }

    var message: String {
        let problem = switch failure {
        case .unreadableLocal: "couldn't be read"
        case .nonRegularLocal: "isn't a regular file"
        case .malformedLocal: "is damaged or from an unsupported version"
        case .malformedCloud: "has a damaged or unsupported iCloud copy"
        }
        return "Saved environments stopped: \(fileName) \(problem). "
            + "Environment and Home changes aren't saved until they reload."
    }
}

/// Single-flight load with a latched hold (#943). Loads join one in-flight read; reloads coalesce. A hold thrown by
/// a read survives ordinary reloads and clears only when `reloadClearingHold` succeeds. No automatic retry.
@MainActor
@Observable
final class HeldLoadGate {
    enum Phase { case notLoaded, loading, ready, held }
    typealias Read = @MainActor () async throws(EnvironmentLoadHold) -> Void

    private(set) var hold: EnvironmentLoadHold?
    private(set) var phase = Phase.notLoaded
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// A reload asked for during a read: exactly one follow-up read runs after it, unless it held.
    @ObservationIgnored private var reloadRequested = false

    /// Writes only after a completed, usable read: never before loading, while held, or around a read.
    var admitsSaves: Bool { hold == nil && phase == .ready }

    func load(_ read: @escaping Read) async {
        if inFlight == nil, phase == .notLoaded { start(read) }
        _ = await inFlight?.value
    }

    /// Coalesces: a reload during a read requests one follow-up read (so newer data, such as an iCloud change
    /// arriving mid-read, is seen), shared by every caller that asked during that read.
    func reload(_ read: @escaping Read) async {
        if let current = inFlight {
            reloadRequested = true
            await current.value
            if let followUp = inFlight { await followUp.value }
            return
        }
        guard hold == nil else { return }
        await start(read).value
    }

    /// Returns whether the read succeeded and nothing is held. Joins a read already in flight; `beforeStart`
    /// runs only when this call starts a new read.
    func reloadClearingHold(_ read: @escaping Read, beforeStart: () -> Void) async -> Bool {
        if let current = inFlight {
            await current.value
            if let followUp = inFlight { await followUp.value } // A coalesced reload may follow it.
        } else {
            beforeStart()
            await start(read).value
        }
        return hold == nil && phase == .ready
    }

    /// Called by a read once every source is usable, immediately before it publishes.
    func markReady() {
        hold = nil
        phase = .ready
    }

    @discardableResult
    private func start(_ read: @escaping Read) -> Task<Void, Never> {
        phase = .loading
        let task = Task {
            do throws(EnvironmentLoadHold) {
                try await read()
                if phase == .loading { markReady() }
            } catch {
                hold = error
                phase = .held
            }
            inFlight = nil
            if reloadRequested {
                reloadRequested = false
                if hold == nil { start(read) }
            }
        }
        inFlight = task
        return task
    }
}

/// Serial local saves (#943): each runs after its predecessor. A save queued behind a failure, refused by
/// `admits`, or scheduled before `invalidateQueued()` is refused, never retried. Local writes only.
@MainActor
@Observable
final class OrderedLocalSaves {
    /// The most recent save was refused or failed; cleared by the next completed local write.
    private(set) var lastSaveFailed = false
    @ObservationIgnored private var tail: Task<Bool, Never>?
    @ObservationIgnored private var generation = 0
    /// Counts writes that actually returned false; refusals never cascade to later saves.
    @ObservationIgnored private var failures = 0
    /// Request order: a write clears the warning only if it was requested after the latest refused request,
    /// so its snapshot includes that edit. `settledRefusal` is the latest refusal already reported to a load.
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var latestRefusal = 0
    @ObservationIgnored private var settledRefusal = 0

    func enqueue(
        admitting admits: @escaping @MainActor @Sendable () -> Bool,
        write: @escaping @Sendable () async -> Bool
    ) -> Task<Bool, Never> {
        let previous = tail
        let scheduledGeneration = generation
        let scheduledFailures = failures
        sequence += 1
        let request = sequence
        let save = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return false } // The owner is gone: refuse rather than write unowned state.
            guard admits(), scheduledGeneration == generation, scheduledFailures == failures else {
                markRefused(request)
                return false
            }
            let completed = await write()
            if !completed {
                failures += 1
                lastSaveFailed = true
            } else if request > latestRefusal {
                lastSaveFailed = false
                settledRefusal = latestRefusal
            }
            return completed
        }
        tail = save
        return save
    }

    func refuse() -> Task<Bool, Never> {
        sequence += 1
        markRefused(sequence)
        return Task { false }
    }

    func invalidateQueued() { generation += 1 }

    /// After a load replaces in-memory state: clears a write failure, but keeps the warning when an edit was
    /// refused since the previous settle (before or during this load), because that edit was never saved.
    func settleAfterLoad() {
        if latestRefusal == settledRefusal { lastSaveFailed = false }
        settledRefusal = latestRefusal
    }

    /// Awaits the tail captured now, including its predecessors; not later saves or durability.
    func awaitTailSnapshot() async {
        let tail = tail
        _ = await tail?.value
    }

    private func markRefused(_ request: Int) {
        lastSaveFailed = true
        latestRefusal = max(latestRefusal, request)
    }
}

actor JSONFileStore {
    static let shared = JSONFileStore()

    private let directory: URL
    private let fileManager = FileManager.default
    private let cloud: (any CloudKeyValueStore)?

    init(directory: URL = AppPersistence.directory, cloud: (any CloudKeyValueStore)? = AppPersistence.defaultCloud) {
        self.directory = directory
        self.cloud = cloud
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let cloud = syncedCloud(for: name)
        let cloudData = cloud?.data(forKey: cloudKey(for: name))
        let localData = localData(for: name)
        // Prefer the synced value; on first sync (cloud empty) seed it from any
        // existing local copy so previously saved state isn't lost.
        if cloudData == nil, let localData, let cloud {
            cloud.setData(localData, forKey: cloudKey(for: name))
        }
        let decoder = JSONDecoder()
        // Prefer the synced value, but fall back to the local cache when the
        // cloud copy is missing or fails to decode (e.g. schema drift or a
        // partial/corrupt sync) so the app stays usable offline.
        if let cloudData, let decoded = try? decoder.decode(T.self, from: cloudData) {
            return decoded
        }
        if let localData, let decoded = try? decoder.decode(T.self, from: localData) {
            return decoded
        }
        return nil
    }

    /// Distinguishes a known-absent value from positively bad local or cloud data (#943). A configured cloud
    /// store returning `nil` is not evidence of absence, so it falls back to local exactly like `load`.
    /// Unlike `load`, this never seeds the cloud: a `cloudSeed` is returned for the caller to submit only once
    /// it has decided to publish, via `seedCloud(_:for:)`.
    func loadObserving<T: Decodable & Sendable>(_ type: T.Type, from name: String) -> JSONLoadObservation<T> {
        let decoder = JSONDecoder()
        var local: (value: T, data: Data)?
        switch localObservation(for: name) {
        case .absent:
            break
        case .failed(let failure):
            return .failed(failure)
        case .present(let data):
            guard let decoded = try? decoder.decode(T.self, from: data) else { return .failed(.malformedLocal) }
            local = (decoded, data)
        }
        let cloud = syncedCloud(for: name)
        if let cloudData = cloud?.data(forKey: cloudKey(for: name)) {
            guard let decoded = try? decoder.decode(T.self, from: cloudData) else { return .failed(.malformedCloud) }
            return .loaded(decoded, cloudSeed: nil)
        }
        guard let local else { return .absent }
        return .loaded(local.value, cloudSeed: cloud == nil ? nil : local.data)
    }

    /// Seeds the synced copy from already-decoded local bytes, only while the cloud value is still missing.
    func seedCloud(_ data: Data, for name: String) {
        guard let cloud = syncedCloud(for: name), cloud.data(forKey: cloudKey(for: name)) == nil else { return }
        cloud.setData(data, forKey: cloudKey(for: name))
    }

    func save(_ value: some Encodable, to name: String) {
        _ = saveReportingLocalWrite(value, to: name)
    }

    /// Reports only completion of the local atomic write, not cloud persistence or fsync.
    /// `mirrorsAfterLocalFailure: false` skips the cloud submission when the local write failed.
    func saveReportingLocalWrite(
        _ value: some Encodable, to name: String, mirrorsAfterLocalFailure: Bool = true
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let localWriteCompleted: Bool
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            localWriteCompleted = true
        } catch {
            localWriteCompleted = false
        }
        // Mirror to iCloud and let the system flush changes automatically. We
        // deliberately avoid calling `synchronize()` per write: stores persist on
        // high-frequency interactions (e.g. dragging a spatial source), and the
        // app already synchronises on launch / iCloud change notifications.
        if localWriteCompleted || mirrorsAfterLocalFailure {
            syncedCloud(for: name)?.setData(data, forKey: cloudKey(for: name))
        }
        return localWriteCompleted
    }

    /// The local folder that start-fresh (#947) moves held items into; never read, synced or cleaned up.
    static let preservedDirectoryName = "Preserved"

    /// Moves the local item `name` (file, directory or symlink, readable or not) unchanged into
    /// `Preserved/<name>-<timestamp>-<uuid>` (#947). Never overwrites, deletes, copies or touches the cloud; on any
    /// error the item stays where it was. Runs on this actor, so it is ordered after writes already submitted.
    func preserveLocalItem(named name: String, at date: Date = .now) throws -> URL {
        let preserved = directory.appendingPathComponent(Self.preservedDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: preserved, withIntermediateDirectories: true)
        let stamp = date.formatted(Date.ISO8601FormatStyle(
            dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .gmt))
        let destination = preserved.appendingPathComponent("\(name)-\(stamp)-\(UUID().uuidString)")
        try fileManager.moveItem(at: directory.appendingPathComponent(name), to: destination)
        return destination
    }

    private enum LocalObservation {
        case absent
        case present(Data)
        case failed(JSONLoadFailure)
    }

    /// Only a missing entry is absence; any other entry or read error is a failure, never "absent".
    private func localObservation(for name: String) -> LocalObservation {
        let url = directory.appendingPathComponent(name)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .failed(.unreadableLocal)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .failed(.nonRegularLocal) }
        guard let data = try? Data(contentsOf: url) else { return .failed(.unreadableLocal) }
        return .present(data)
    }

    /// The cloud store, only for a file whose key is on the shipped key-value allowlist (#124). Any other file,
    /// such as the host-local Launch Control XL map, stays a plain local file: never written, read or seeded.
    private func syncedCloud(for name: String) -> (any CloudKeyValueStore)? {
        guard let cloud, KeyValueAllowlist.shipped.contains(rawKey: cloudKey(for: name)) else { return nil }
        return cloud
    }

    private func localData(for name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The iCloud key for a file name. Dots aren't valid in key-value-store keys,
    /// so the extension separator is normalised away.
    private func cloudKey(for name: String) -> String {
        "store." + name.replacingOccurrences(of: ".", with: "_")
    }
}
