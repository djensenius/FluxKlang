/// Identity of one checkpoint; any value is legal and the ordinal, not the id, orders records.
struct CheckpointID: Hashable, Sendable {
    let rawValue: UInt64

    init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Why a checkpoint was taken. Retention pins the newest `manual` and the newest `preMigration` record.
enum CheckpointReason: String, CaseIterable, Sendable {
    case manual
    case autosave
    case preMigration
    case preRestore

    var isPinEligible: Bool {
        self == .manual || self == .preMigration
    }
}

/// Which limit field a `CheckpointLimits` refusal names, checked in this order.
enum CheckpointLimitField: Equatable, Sendable {
    case maxRecords
    case maxTotalBytes
    case maxRecordBytes
    case recordExceedsTotal
}

/// Why a journal that is being loaded is not valid.
enum CheckpointJournalFault: Equatable, Sendable {
    case tooManyRecords(Int)
    case recordOverLimit(CheckpointID)
    case duplicateID(CheckpointID)
    case ordinalNotIncreasing(index: Int)
    case totalOverCap(Int)
}

/// Every typed refusal of the checkpoint types.
enum CheckpointRefusal: Error, Equatable, Sendable {
    case invalidLimits(CheckpointLimitField)
    case invalidDigestLength(Int)
    case labelTooLong(Int)
    case invalidByteCount(Int)
    case ordinalNotIncreasing(ordinal: UInt64, newest: UInt64)
    case duplicateID(CheckpointID)
    case recordTooLarge(byteCount: Int, limit: Int)
    case cannotMakeRoom
    case ordinalOverflow
    case invalidJournal(CheckpointJournalFault)
    case recordNotInJournal
    case confirmationMismatch(expected: CheckpointID, found: CheckpointID)
    case preRestoreMissing
}

/// Caller-supplied caps for one journal. Built only by `make`, which refuses values outside the hard ceilings.
struct CheckpointLimits: Equatable, Sendable {
    static let hardMaximumRecords = 256
    static let hardMaximumTotalBytes = 1 << 40
    static let hardMaximumRecordBytes = 1 << 32

    private let storedMaxRecords: Int
    private let storedMaxTotalBytes: Int
    private let storedMaxRecordBytes: Int

    var maxRecords: Int { storedMaxRecords }
    var maxTotalBytes: Int { storedMaxTotalBytes }
    var maxRecordBytes: Int { storedMaxRecordBytes }

    private init(maxRecords: Int, maxTotalBytes: Int, maxRecordBytes: Int) {
        storedMaxRecords = maxRecords
        storedMaxTotalBytes = maxTotalBytes
        storedMaxRecordBytes = maxRecordBytes
    }

    static func make(
        maxRecords: Int,
        maxTotalBytes: Int,
        maxRecordBytes: Int
    ) throws(CheckpointRefusal) -> CheckpointLimits {
        guard (1...hardMaximumRecords).contains(maxRecords) else { throw .invalidLimits(.maxRecords) }
        guard (1...hardMaximumTotalBytes).contains(maxTotalBytes) else { throw .invalidLimits(.maxTotalBytes) }
        guard (1...hardMaximumRecordBytes).contains(maxRecordBytes) else { throw .invalidLimits(.maxRecordBytes) }
        guard maxRecordBytes <= maxTotalBytes else { throw .invalidLimits(.recordExceedsTotal) }
        return CheckpointLimits(maxRecords: maxRecords, maxTotalBytes: maxTotalBytes, maxRecordBytes: maxRecordBytes)
    }

    /// Point-of-use re-validation for code that receives a limits value from elsewhere.
    func revalidated() throws(CheckpointRefusal) -> CheckpointLimits {
        try Self.make(
            maxRecords: storedMaxRecords,
            maxTotalBytes: storedMaxTotalBytes,
            maxRecordBytes: storedMaxRecordBytes
        )
    }
}

/// An immutable description of one stored checkpoint. The digest is supplied bytes and is never computed here.
struct CheckpointRecord: Equatable, Sendable {
    static let digestByteCount = 32
    static let maximumLabelBytes = 64

    let id: CheckpointID
    let ordinal: UInt64
    let revision: ContractRevision
    let reason: CheckpointReason
    let byteCount: Int
    let label: String
    private let storedDigest: [UInt8]

    var digest: [UInt8] { storedDigest }

    private init(
        id: CheckpointID,
        ordinal: UInt64,
        revision: ContractRevision,
        reason: CheckpointReason,
        digest: [UInt8],
        byteCount: Int,
        label: String
    ) {
        self.id = id
        self.ordinal = ordinal
        self.revision = revision
        self.reason = reason
        self.byteCount = byteCount
        self.label = label
        storedDigest = digest
    }

    // Refusals are checked in order: digest length, label bytes, byte count. A zero byte count is legal.
    // swiftlint:disable:next function_parameter_count
    static func make(
        id: CheckpointID,
        ordinal: UInt64,
        revision: ContractRevision,
        reason: CheckpointReason,
        digest: [UInt8],
        byteCount: Int,
        label: String
    ) throws(CheckpointRefusal) -> CheckpointRecord {
        guard digest.count == digestByteCount else { throw .invalidDigestLength(digest.count) }
        let labelBytes = label.utf8.count
        guard labelBytes <= maximumLabelBytes else { throw .labelTooLong(labelBytes) }
        guard (0...CheckpointLimits.hardMaximumRecordBytes).contains(byteCount) else {
            throw .invalidByteCount(byteCount)
        }
        return CheckpointRecord(
            id: id,
            ordinal: ordinal,
            revision: revision,
            reason: reason,
            digest: digest,
            byteCount: byteCount,
            label: label
        )
    }

    /// Content comparison: the digest and the byte count only, never the id, ordinal, label, revision or reason.
    func isSameContent(as other: CheckpointRecord) -> Bool {
        storedDigest == other.storedDigest && byteCount == other.byteCount
    }

    static func == (lhs: CheckpointRecord, rhs: CheckpointRecord) -> Bool {
        lhs.id == rhs.id && lhs.ordinal == rhs.ordinal && lhs.revision == rhs.revision
            && lhs.reason == rhs.reason && lhs.isSameContent(as: rhs) && lhs.label.utf8.elementsEqual(rhs.label.utf8)
    }
}
