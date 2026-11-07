//
//  StoragePolicy.swift
//  FluxKlang
//
//  Default-deny policy from storage class to location (#124). The switch has no `default`, so adding a class
//  fails to compile until its row is written. Key-value storage is permitted for exactly three classes; plugin
//  state, media, trust and credentials can never enter it, whatever the key is called.
//

enum StoragePolicy {
    /// The locations `storageClass` may live in, in `StorageLocation` declaration order.
    static func permittedLocations(for storageClass: StorageClass) -> [StorageLocation] {
        switch storageClass {
        case .preference, .draft, .pluginState, .media, .hostLocalRoute, .cache: [.localFile]
        case .homeWiring, .environment, .catalog: [.keyValue, .localFile]
        case .history: [.localFile, .privateCloudDatabase]
        case .trust, .credential: [.keychainThisDeviceOnly]
        }
    }

    /// An unknown class name has no permitted location: default deny.
    static func permittedLocations(forClassNamed name: String) -> [StorageLocation] {
        guard let storageClass = StorageClass(rawValue: name) else { return [] }
        return permittedLocations(for: storageClass)
    }

    static func permits(_ storageClass: StorageClass, _ location: StorageLocation) -> Bool {
        permittedLocations(for: storageClass).contains(location)
    }

    static func isKeyValueEligible(_ storageClass: StorageClass) -> Bool {
        permits(storageClass, .keyValue)
    }
}
