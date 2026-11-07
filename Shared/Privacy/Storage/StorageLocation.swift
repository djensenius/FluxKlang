//
//  StorageLocation.swift
//  FluxKlang
//
//  Where a stored value may live (#124). The case order is the declaration order, which is also the order
//  `StoragePolicy.permittedLocations(for:)` lists them in.
//

enum StorageLocation: String, CaseIterable, Sendable {
    /// The iCloud key-value store: small, synced, and shared with every device of the user.
    case keyValue
    /// A file in the app's own directory on this device.
    case localFile
    /// The user's private CloudKit database.
    case privateCloudDatabase
    /// The Keychain with `ThisDeviceOnly` accessibility.
    case keychainThisDeviceOnly
}
