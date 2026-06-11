//
//  CloudKeyValueStore.swift
//  FluxKlang
//
//  Abstraction over a synchronising key-value store so persistence can mirror to
//  iCloud in the app while tests inject an in-memory double. iCloud syncing uses
//  `NSUbiquitousKeyValueStore`, which propagates small values across all of a
//  user's signed-in devices automatically.
//

import Foundation

/// A key-value store whose contents sync between a user's devices.
protocol CloudKeyValueStore: Sendable {
    /// The data stored for `key`, or `nil` if there is none.
    func data(forKey key: String) -> Data?

    /// Stores `data` for `key`, replacing any existing value.
    func setData(_ data: Data, forKey key: String)

    /// Flushes pending changes so they upload as soon as possible.
    @discardableResult
    func synchronize() -> Bool
}

/// iCloud-backed store using `NSUbiquitousKeyValueStore`. Thread-safe per Apple's
/// documentation, so it is safe to use from the `JSONFileStore` actor.
struct UbiquitousCloudStore: CloudKeyValueStore, @unchecked Sendable {
    private let store: NSUbiquitousKeyValueStore

    init(_ store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    func data(forKey key: String) -> Data? { store.data(forKey: key) }

    func setData(_ data: Data, forKey key: String) { store.set(data, forKey: key) }

    @discardableResult
    func synchronize() -> Bool { store.synchronize() }
}
