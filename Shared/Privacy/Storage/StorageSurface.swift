//
//  StorageSurface.swift
//  FluxKlang
//
//  One place the app keeps data (#124): a `UserDefaults` key, a file mirrored through the file store, a Keychain
//  account, a local file or directory, or a CloudKit zone. A surface is only an identity to look up; an unknown
//  one is not an error, it simply has no class (default deny).
//

struct StorageSurface: Hashable, Sendable {
    /// The case order is the sort rank of a kind in the inventory.
    enum Kind: Int, CaseIterable, Sendable {
        case userDefaultsKey
        case storeFile
        case keychainAccount
        case localFile
        case localDirectory
        case cloudKitZone
    }

    let kind: Kind
    let name: String

    /// Names are equal only when their UTF-8 bytes are, not when Unicode treats them as canonically equivalent.
    static func == (lhs: StorageSurface, rhs: StorageSurface) -> Bool {
        lhs.kind == rhs.kind && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        for byte in name.utf8 { hasher.combine(byte) }
    }

    /// Orders by kind rank (declaration order), then by the UTF-8 bytes of the name.
    func sortsBefore(_ other: StorageSurface) -> Bool {
        if kind != other.kind { return kind.rawValue < other.kind.rawValue }
        return name.utf8.lexicographicallyPrecedes(other.name.utf8)
    }
}

struct StorageInventoryEntry: Equatable, Sendable {
    let surface: StorageSurface
    let storageClass: StorageClass
}
