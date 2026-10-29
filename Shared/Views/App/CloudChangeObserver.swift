import Foundation

/// Owns the iCloud key-value change observer without retaining its AppModel.
final class CloudChangeObserver {
    private var token: (any NSObjectProtocol)?

    init(onChange: @escaping @Sendable () -> Void) {
        guard !AppPersistence.isTesting else { return }
        let store = NSUbiquitousKeyValueStore.default
        token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in onChange() }
        store.synchronize()
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
