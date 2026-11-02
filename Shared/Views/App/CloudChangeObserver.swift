import Foundation

/// Owns the iCloud key-value change observer without retaining its AppModel.
final class CloudChangeObserver {
    private var token: (any NSObjectProtocol)?
    private let mirror: ProductionAccessAudit?

    init(mirroring mirror: ProductionAccessAudit? = nil, onChange: @escaping @Sendable () -> Void) {
        self.mirror = mirror
        ProductionAccessAudit.shared.record(.attempted, for: .cloudChangeObserver, mirroring: mirror)
        guard !AppPersistence.isTesting else {
            ProductionAccessAudit.shared.record(.denied, for: .cloudChangeObserver, mirroring: mirror)
            return
        }
        ProductionAccessAudit.shared.record(.apiEntered, for: .cloudChangeObserver, mirroring: mirror)
        let store = NSUbiquitousKeyValueStore.default
        ProductionAccessAudit.shared.record(.apiEntered, for: .cloudChangeObserver, mirroring: mirror)
        let center = NotificationCenter.default
        ProductionAccessAudit.shared.record(.apiEntered, for: .cloudChangeObserver, mirroring: mirror)
        token = center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in onChange() }
        ProductionAccessAudit.shared.record(.apiEntered, for: .cloudChangeObserver, mirroring: mirror)
        store.synchronize()
    }

    deinit {
        if let token {
            ProductionAccessAudit.shared.record(.attempted, for: .cloudChangeObserver, mirroring: mirror)
            ProductionAccessAudit.shared.record(.apiEntered, for: .cloudChangeObserver, mirroring: mirror)
            let center = NotificationCenter.default
            ProductionAccessAudit.shared.record(.apiEntered, for: .cloudChangeObserver, mirroring: mirror)
            center.removeObserver(token)
        }
    }
}
