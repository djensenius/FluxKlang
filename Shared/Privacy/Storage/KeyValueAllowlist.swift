//
//  KeyValueAllowlist.swift
//  FluxKlang
//
//  The finite allowlist of key-value keys (#124). Default deny: a key is admitted only when an entry names it
//  exactly (byte equality; no wildcard, prefix or pattern entries) and the entry's class is one that key-value
//  storage permits. The list is immutable, sorted by key bytes and unique, and only the throwing `init` builds it.
//

struct KeyValueAllowlistEntry: Equatable, Sendable {
    let key: KeyValueKey
    let storageClass: StorageClass
    let maxValueBytes: Int

    /// Key bytes first; the other fields only make the order total, so a refusal never depends on input order.
    fileprivate func precedes(_ other: KeyValueAllowlistEntry) -> Bool {
        if key != other.key { return key < other.key }
        if maxValueBytes != other.maxValueBytes { return maxValueBytes < other.maxValueBytes }
        return storageClass.rawValue < other.storageClass.rawValue
    }
}

struct KeyValueAllowlist: Equatable, Sendable {
    /// Sorted by key bytes, one entry per key.
    private(set) var entries: [KeyValueAllowlistEntry]

    /// Refuses, in this order: no entries, too many entries; then per entry in key order a key longer than
    /// `limits.maximumKeyBytes`, a class that key-value storage does not permit, a size outside
    /// 1...`limits.maximumValueBytes`, a duplicate key; finally a sum above `limits.maximumTotalBytes`.
    init(
        entries: [KeyValueAllowlistEntry],
        limits: KeyValueLimits = .standard
    ) throws(KeyValueRefusal) {
        guard !entries.isEmpty else { throw .emptyAllowlist }
        guard entries.count <= limits.maximumEntries else {
            throw .tooManyEntries(count: entries.count, limit: limits.maximumEntries)
        }
        let ordered = entries.sorted { $0.precedes($1) }
        var total = 0
        for (index, entry) in ordered.enumerated() {
            try Self.validate(entry, limits: limits)
            if index > 0, ordered[index - 1].key == entry.key { throw .duplicateEntry(entry.key) }
            let (sum, overflow) = total.addingReportingOverflow(entry.maxValueBytes)
            total = overflow ? Int.max : sum
        }
        guard total <= limits.maximumTotalBytes else {
            throw .allowlistExceedsTotal(bytes: total, limit: limits.maximumTotalBytes)
        }
        self.entries = ordered
    }

    private init(denyAll: Void) {
        entries = []
    }

    private static func validate(
        _ entry: KeyValueAllowlistEntry,
        limits: KeyValueLimits
    ) throws(KeyValueRefusal) {
        let keyBytes = entry.key.rawValue.utf8.count
        guard keyBytes <= limits.maximumKeyBytes else { throw .invalidKey(.tooLong(bytes: keyBytes)) }
        try KeyValueAdmission.requireEligible(entry.storageClass)
        guard (1...limits.maximumValueBytes).contains(entry.maxValueBytes) else {
            throw .invalidEntrySize(key: entry.key, bytes: entry.maxValueBytes)
        }
    }

    /// The entry that names `key` exactly, or nil.
    func entry(for key: KeyValueKey) -> KeyValueAllowlistEntry? {
        entries.first { $0.key == key }
    }

    /// Whether `rawKey` is an allowlisted key. Any string that is not a valid key (every `UserDefaults` key,
    /// for one) is not on the list.
    func contains(rawKey: String) -> Bool {
        guard let key = try? KeyValueKey(rawKey) else { return false }
        return entry(for: key) != nil
    }

    /// The seven store files that stay mirrored (ruling 5). Built by the same throwing `init`. If that ever
    /// failed (unreachable: a test builds the same entries), the value is an empty list that admits nothing.
    static let shipped: KeyValueAllowlist = {
        let entries = ShippedKeys.all.compactMap { file in
            (try? KeyValueKey.storeFile(named: file.fileName)).map {
                KeyValueAllowlistEntry(key: $0, storageClass: file.storageClass, maxValueBytes: ShippedKeys.valueBytes)
            }
        }
        guard entries.count == ShippedKeys.all.count, let list = try? KeyValueAllowlist(entries: entries) else {
            return KeyValueAllowlist(denyAll: ())
        }
        return list
    }()

    private enum ShippedKeys {
        static let valueBytes = 131_072
        static let all: [(fileName: String, storageClass: StorageClass)] = [
            ("environments.json", .environment),
            ("studio-connections.json", .homeWiring),
            ("equipment.json", .catalog),
            ("presets.json", .catalog),
            ("spatial.json", .catalog),
            ("fader-layout.json", .catalog),
            ("routing_snapshots.json", .catalog)
        ]
    }
}
