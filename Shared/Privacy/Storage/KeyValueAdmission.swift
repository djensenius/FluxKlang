//
//  KeyValueAdmission.swift
//  FluxKlang
//
//  Atomic admission of key-value writes (#124). `evaluate` is a pure function over value inputs: it returns one
//  plan or throws one typed refusal, and it never returns a partial plan. A request carries byte COUNTS only, never
//  a payload or a name of what the bytes are.
//

struct KeyValueRequest: Equatable, Sendable {
    let key: KeyValueKey
    let storageClass: StorageClass
    let valueBytes: Int

    /// Key bytes first; the other fields only make the order total, so equal requests in any input order sort alike.
    fileprivate func precedes(_ other: KeyValueRequest) -> Bool {
        if key != other.key { return key < other.key }
        if valueBytes != other.valueBytes { return valueBytes < other.valueBytes }
        return storageClass.rawValue < other.storageClass.rawValue
    }
}

/// The accepted writes, sorted by key bytes, and what the store would hold afterwards. Only `evaluate` builds one.
struct KeyValuePlan: Equatable, Sendable {
    private(set) var writes: [KeyValueRequest]
    /// Bytes of every distinct key after the writes (a rewritten resident key counts once).
    private(set) var totalBytes: Int
    /// Number of distinct keys after the writes.
    private(set) var keyCount: Int

    fileprivate init(writes: [KeyValueRequest], totalBytes: Int, keyCount: Int) {
        self.writes = writes
        self.totalBytes = totalBytes
        self.keyCount = keyCount
    }
}

enum KeyValueAdmission {
    /// Key-value storage permits `storageClass`, or `.classNotKeyValueEligible`.
    static func requireEligible(_ storageClass: StorageClass) throws(KeyValueRefusal) {
        guard StoragePolicy.isKeyValueEligible(storageClass) else { throw .classNotKeyValueEligible(storageClass) }
    }

    /// Checks run stage by stage over all writes in key-byte order, so an earlier stage always wins and the
    /// reported key is the first in byte order: (a) negative size, (b) key not allowlisted, then, for the same
    /// key, longer than `limits.maximumKeyBytes` (`.invalidKey(.tooLong)`), (c) class mismatch,
    /// (d) class not eligible, (e) duplicate key, (f) value above the cap; then the resident entries (a resident
    /// key longer than the limit is `.residentInvalid`); then (g) too many distinct keys and (h) too many bytes,
    /// both counting a rewritten resident key once.
    static func evaluate(
        _ writes: [KeyValueRequest],
        against allowlist: KeyValueAllowlist,
        limits: KeyValueLimits,
        resident: [KeyValueRequest]
    ) throws(KeyValueRefusal) -> KeyValuePlan {
        let ordered = writes.sorted { $0.precedes($1) }
        try checkWrites(ordered, allowlist: allowlist, limits: limits)
        let kept = try residentKept(resident, replacedBy: ordered, allowlist: allowlist, limits: limits)
        let count = ordered.count + kept.count
        guard count <= limits.maximumEntries else { throw .tooManyKeys(count: count, limit: limits.maximumEntries) }
        var total = 0
        for request in ordered + kept {
            let (sum, overflow) = total.addingReportingOverflow(request.valueBytes)
            total = overflow ? Int.max : sum
        }
        guard total <= limits.maximumTotalBytes else {
            throw .totalTooLarge(bytes: total, limit: limits.maximumTotalBytes)
        }
        return KeyValuePlan(writes: ordered, totalBytes: total, keyCount: count)
    }

    private static func checkWrites(
        _ ordered: [KeyValueRequest],
        allowlist: KeyValueAllowlist,
        limits: KeyValueLimits
    ) throws(KeyValueRefusal) {
        if let negative = ordered.first(where: { $0.valueBytes < 0 }) { throw .negativeSize(negative.key) }
        let matched = try matchEntries(ordered, allowlist: allowlist, limits: limits)
        for (request, entry) in zip(ordered, matched) where request.storageClass != entry.storageClass {
            throw .classMismatch(key: request.key, expected: entry.storageClass, got: request.storageClass)
        }
        for request in ordered { try requireEligible(request.storageClass) }
        for index in ordered.indices.dropFirst() where ordered[index - 1].key == ordered[index].key {
            throw .duplicateRequest(ordered[index].key)
        }
        for (request, entry) in zip(ordered, matched) {
            let limit = min(entry.maxValueBytes, limits.maximumValueBytes)
            if request.valueBytes > limit { throw .valueTooLarge(key: request.key, limit: limit) }
        }
    }

    /// Stage (b), per write in key order: the allowlist entry of the key, or `.keyNotAllowlisted`, then the key
    /// length against the evaluation limit, or `.invalidKey(.tooLong)` (the allowlist `init` throws the same).
    private static func matchEntries(
        _ ordered: [KeyValueRequest],
        allowlist: KeyValueAllowlist,
        limits: KeyValueLimits
    ) throws(KeyValueRefusal) -> [KeyValueAllowlistEntry] {
        var matched: [KeyValueAllowlistEntry] = []
        for request in ordered {
            guard let entry = allowlist.entry(for: request.key) else { throw .keyNotAllowlisted(request.key) }
            let keyBytes = request.key.rawValue.utf8.count
            guard keyBytes <= limits.maximumKeyBytes else { throw .invalidKey(.tooLong(bytes: keyBytes)) }
            matched.append(entry)
        }
        return matched
    }

    /// Returns the resident entries no write replaces, after validating them by the rules (a) to (d) and (f)
    /// and the key length of stage (b), all as `.residentInvalid`. A replaced resident is judged through the write
    /// that replaces it, so a write can shrink an over-limit value. Every resident row whose key a write names is
    /// dropped, duplicate rows included and unvalidated: the plan keeps
    /// only the write's row for that key, which checks (a) to (f) have already validated.
    private static func residentKept(
        _ resident: [KeyValueRequest],
        replacedBy ordered: [KeyValueRequest],
        allowlist: KeyValueAllowlist,
        limits: KeyValueLimits
    ) throws(KeyValueRefusal) -> [KeyValueRequest] {
        let replaced = Set(ordered.map(\.key))
        let sorted = resident.sorted { $0.precedes($1) }
        let kept = sorted.filter { !replaced.contains($0.key) }
        try requireValidResidents(kept, allowlist: allowlist, limits: limits)
        return kept
    }

    private static func requireValidResidents(
        _ sorted: [KeyValueRequest],
        allowlist: KeyValueAllowlist,
        limits: KeyValueLimits
    ) throws(KeyValueRefusal) {
        for index in sorted.indices {
            let duplicate = index > 0 && sorted[index - 1].key == sorted[index].key
            if duplicate || !isValidResident(sorted[index], allowlist: allowlist, limits: limits) {
                throw .residentInvalid(sorted[index].key)
            }
        }
    }

    private static func isValidResident(
        _ request: KeyValueRequest,
        allowlist: KeyValueAllowlist,
        limits: KeyValueLimits
    ) -> Bool {
        guard request.valueBytes >= 0, let entry = allowlist.entry(for: request.key),
              request.key.rawValue.utf8.count <= limits.maximumKeyBytes,
              entry.storageClass == request.storageClass,
              StoragePolicy.isKeyValueEligible(request.storageClass) else { return false }
        return request.valueBytes <= min(entry.maxValueBytes, limits.maximumValueBytes)
    }
}
