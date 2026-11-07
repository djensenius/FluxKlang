//
//  KeyValueKey.swift
//  FluxKlang
//
//  A key of the iCloud key-value store, validated (#124). The namespace prefix `store.` is the only dot: the
//  existing file mirror maps a file name to `"store." + name with "." replaced by "_"`, and `storeFile(named:)`
//  re-implements that mapping without touching the mirror. Keys compare and sort by UTF-8 bytes.
//

struct KeyValueKey: Hashable, Comparable, Sendable {
    static let namespacePrefix = "store."

    let rawValue: String

    /// A key is valid when its UTF-8 length is 1...`KeyValueLimits.hardMaximumKeyBytes`, it starts with
    /// `store.`, and the rest is non-empty ASCII `[a-z0-9_-]`.
    init(_ rawValue: String) throws(KeyValueRefusal) {
        if let fault = Self.fault(in: rawValue) { throw .invalidKey(fault) }
        self.rawValue = rawValue
    }

    /// The key the file mirror uses for `name`: the prefix, then the name with every "." replaced by "_".
    static func storeFile(named name: String) throws(KeyValueRefusal) -> KeyValueKey {
        try KeyValueKey(namespacePrefix + String(name.map { $0 == "." ? "_" : $0 }))
    }

    static func < (lhs: KeyValueKey, rhs: KeyValueKey) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    /// The first thing wrong with `candidate`, or nil when it is a valid key.
    static func fault(in candidate: String) -> KeyValueKeyFault? {
        let bytes = Array(candidate.utf8)
        if bytes.isEmpty { return .empty }
        if bytes.count > KeyValueLimits.hardMaximumKeyBytes { return .tooLong(bytes: bytes.count) }
        let prefix = Array(namespacePrefix.utf8)
        if !bytes.starts(with: prefix) { return .missingNamespace }
        if bytes.count == prefix.count { return .emptyName }
        if let offset = bytes.indices.dropFirst(prefix.count).first(where: { !isNameByte(bytes[$0]) }) {
            return .invalidCharacter(offset: offset)
        }
        return nil
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}
