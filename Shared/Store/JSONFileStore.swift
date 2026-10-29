//
//  JSONFileStore.swift
//  FluxKlang
//
//  Tiny actor that persists Codable values as JSON. Values are mirrored to
//  iCloud via a `CloudKeyValueStore` so every store syncs across the user's
//  devices, while a copy in the app's Application Support directory provides an
//  offline cache and first-run migration. Keeps file I/O off the main actor.
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

    static let isTesting: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        return false
        #endif
    }()

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

    func save(_ value: some Encodable, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        // Mirror to iCloud and let the system flush changes automatically. We
        // deliberately avoid calling `synchronize()` per write: stores persist on
        // high-frequency interactions (e.g. dragging a spatial source), and the
        // app already synchronises on launch / iCloud change notifications.
        cloud?.setData(data, forKey: cloudKey(for: name))
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
