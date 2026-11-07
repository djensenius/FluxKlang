//
//  KeyValueLimits.swift
//  FluxKlang
//
//  The size and count bounds of the key-value allowlist (#124). Every number lives here and nowhere else.
//  The standard values and the hard ceilings are conservative defaults taken from the published limits of
//  `NSUbiquitousKeyValueStore` (1 MB in total, 1024 keys, 64-byte keys). They are UNVERIFIED against Apple's
//  documentation: this lane could not fetch it. A validated value is built only by the throwing `init`.
//

struct KeyValueLimits: Equatable, Sendable {
    static let hardMaximumKeyBytes = 64
    static let hardMaximumEntries = 1_024
    static let hardMaximumValueBytes = 1_048_576
    static let hardMaximumTotalBytes = 1_048_576

    static let standardMaximumKeyBytes = 64
    static let standardMaximumEntries = 64
    static let standardMaximumValueBytes = 131_072
    static let standardMaximumTotalBytes = 1_048_576

    let maximumKeyBytes: Int
    let maximumEntries: Int
    let maximumValueBytes: Int
    let maximumTotalBytes: Int

    /// Each number must be in 1...its hard ceiling, and one value must fit in the total.
    init(
        maximumKeyBytes: Int,
        maximumEntries: Int,
        maximumValueBytes: Int,
        maximumTotalBytes: Int
    ) throws(KeyValueRefusal) {
        guard (1...Self.hardMaximumKeyBytes).contains(maximumKeyBytes) else {
            throw .invalidLimits(.maximumKeyBytes)
        }
        guard (1...Self.hardMaximumEntries).contains(maximumEntries) else {
            throw .invalidLimits(.maximumEntries)
        }
        guard (1...Self.hardMaximumValueBytes).contains(maximumValueBytes) else {
            throw .invalidLimits(.maximumValueBytes)
        }
        guard (1...Self.hardMaximumTotalBytes).contains(maximumTotalBytes) else {
            throw .invalidLimits(.maximumTotalBytes)
        }
        guard maximumValueBytes <= maximumTotalBytes else { throw .invalidLimits(.valueExceedsTotal) }
        self.maximumKeyBytes = maximumKeyBytes
        self.maximumEntries = maximumEntries
        self.maximumValueBytes = maximumValueBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    private init(validated: Void) {
        maximumKeyBytes = Self.standardMaximumKeyBytes
        maximumEntries = Self.standardMaximumEntries
        maximumValueBytes = Self.standardMaximumValueBytes
        maximumTotalBytes = Self.standardMaximumTotalBytes
    }

    /// The standard values, which are inside the hard ceilings (a test pins that).
    static let standard = KeyValueLimits(validated: ())
}
