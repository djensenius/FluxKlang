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
    private let store: NSUbiquitousKeyValueStore?
    private let mirror: ProductionAccessAudit?

    /// Default acquisition is guarded; an explicit argument is already evaluated by the caller.
    init(_ store: NSUbiquitousKeyValueStore? = nil, mirroring mirror: ProductionAccessAudit? = nil) {
        self.mirror = mirror
        ProductionAccessAudit.shared.record(.attempted, for: .ubiquitousCloudStore, mirroring: mirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .ubiquitousCloudStore, mirroring: mirror)
            self.store = nil
            return
        }
        ProductionAccessAudit.shared.record(.factoryEvaluated, for: .ubiquitousCloudStore, mirroring: mirror)
        if let store {
            self.store = store
        } else {
            ProductionAccessAudit.shared.record(.apiEntered, for: .ubiquitousCloudStore, mirroring: mirror)
            self.store = .default
        }
    }

    func data(forKey key: String) -> Data? {
        ProductionAccessAudit.shared.record(.attempted, for: .ubiquitousCloudStore, mirroring: mirror)
        guard !AppPersistence.isTesting, let store else {
            ProductionAccessAudit.shared.record(.denied, for: .ubiquitousCloudStore, mirroring: mirror)
            // Unavailable, not evidence that remote data is absent.
            return nil
        }
        ProductionAccessAudit.shared.record(.apiEntered, for: .ubiquitousCloudStore, mirroring: mirror)
        return store.data(forKey: key)
    }

    func setData(_ data: Data, forKey key: String) {
        ProductionAccessAudit.shared.record(.attempted, for: .ubiquitousCloudStore, mirroring: mirror)
        guard !AppPersistence.isTesting, let store else {
            ProductionAccessAudit.shared.record(.denied, for: .ubiquitousCloudStore, mirroring: mirror)
            // The Void protocol cannot report denial; returning does not imply persistence.
            return
        }
        ProductionAccessAudit.shared.record(.apiEntered, for: .ubiquitousCloudStore, mirroring: mirror)
        store.set(data, forKey: key)
    }

    @discardableResult
    func synchronize() -> Bool {
        ProductionAccessAudit.shared.record(.attempted, for: .ubiquitousCloudStore, mirroring: mirror)
        guard !AppPersistence.isTesting, let store else {
            ProductionAccessAudit.shared.record(.denied, for: .ubiquitousCloudStore, mirroring: mirror)
            return false
        }
        ProductionAccessAudit.shared.record(.apiEntered, for: .ubiquitousCloudStore, mirroring: mirror)
        return store.synchronize()
    }
}
