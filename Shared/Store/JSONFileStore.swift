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
    private let cloud: CloudKeyValueStore?

    init(cloud: CloudKeyValueStore? = UbiquitousCloudStore()) {
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
            cloud.synchronize()
        }
        guard let data = cloudData ?? localData else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: some Encodable, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        if let cloud {
            cloud.setData(data, forKey: cloudKey(for: name))
            cloud.synchronize()
        }
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
