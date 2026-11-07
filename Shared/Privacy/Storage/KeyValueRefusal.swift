//
//  KeyValueRefusal.swift
//  FluxKlang
//
//  Every typed refusal of the storage-class layer (#124). A refusal carries a key (at most 64 bytes of
//  `[a-z0-9_-.]`), a class, a surface name or a count: never a payload, a free-form string or a file URL.
//

/// Why a key is not a valid key-value key. Offsets and counts are UTF-8 bytes.
enum KeyValueKeyFault: Equatable, Sendable {
    case empty
    case tooLong(bytes: Int)
    case missingNamespace
    case emptyName
    case invalidCharacter(offset: Int)
}

/// The `KeyValueLimits` number that is out of range.
enum KeyValueLimitField: Equatable, Sendable {
    case maximumKeyBytes
    case maximumEntries
    case maximumValueBytes
    case maximumTotalBytes
    /// `maximumValueBytes` is larger than `maximumTotalBytes`.
    case valueExceedsTotal
}

enum KeyValueRefusal: Error, Equatable, Sendable {
    case invalidKey(KeyValueKeyFault)
    case invalidLimits(KeyValueLimitField)
    case emptyAllowlist
    case tooManyEntries(count: Int, limit: Int)
    case duplicateEntry(KeyValueKey)
    case invalidEntrySize(key: KeyValueKey, bytes: Int)
    case allowlistExceedsTotal(bytes: Int, limit: Int)
    case classNotKeyValueEligible(StorageClass)
    case negativeSize(KeyValueKey)
    case keyNotAllowlisted(KeyValueKey)
    case classMismatch(key: KeyValueKey, expected: StorageClass, got: StorageClass)
    case duplicateRequest(KeyValueKey)
    case valueTooLarge(key: KeyValueKey, limit: Int)
    case residentInvalid(KeyValueKey)
    case tooManyKeys(count: Int, limit: Int)
    case totalTooLarge(bytes: Int, limit: Int)
    case duplicateSurface(StorageSurface)
    case unclassified(StorageSurface)
}
