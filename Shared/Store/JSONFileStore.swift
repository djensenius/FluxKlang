//
//  JSONFileStore.swift
//  FluxKlang
//
//  Tiny actor that persists Codable values as JSON in the app's Application
//  Support directory. Keeps file I/O off the main actor.
//

import Foundation

actor JSONFileStore {
    static let shared = JSONFileStore()

    private let directory: URL
    private let fileManager = FileManager.default

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        directory = base.appendingPathComponent("FluxKlang", isDirectory: true)
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: some Encodable, to name: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
