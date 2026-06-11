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

actor JSONFileStore {
    static let shared = JSONFileStore()

    private let directory: URL
    private let fileManager = FileManager.default
    private let cloud: (any CloudKeyValueStore)?

    init(cloud: (any CloudKeyValueStore)? = UbiquitousCloudStore()) {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        directory = base.appendingPathComponent("FluxKlang", isDirectory: true)
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
        guard let data = try? JSONEncoder().encode(value) else { return }
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
