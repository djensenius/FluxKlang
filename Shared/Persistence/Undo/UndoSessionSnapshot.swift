//
//  UndoSessionSnapshot.swift
//  FluxKlang
//
//  What an undo session is bound to and how full its stacks are, as plain values. The rebind policy reads these
//  and never touches a real history.
//

/// A digest and a byte count describing the content of one saved state. The digest is supplied bytes and is never
/// computed here.
struct UndoContentFingerprint: Equatable, Sendable {
    private let storedDigest: [UInt8]
    let byteCount: Int

    var digest: [UInt8] { storedDigest }

    private init(digest: [UInt8], byteCount: Int) {
        storedDigest = digest
        self.byteCount = byteCount
    }

    /// Refusals are checked in order: digest length, then byte count. A zero byte count is legal.
    static func make(digest: [UInt8], byteCount: Int) throws(UndoRebindRefusal) -> UndoContentFingerprint {
        guard digest.count == CheckpointRecord.digestByteCount else { throw .invalidDigestLength(digest.count) }
        guard (0...CheckpointLimits.hardMaximumRecordBytes).contains(byteCount) else {
            throw .invalidByteCount(byteCount)
        }
        return UndoContentFingerprint(digest: digest, byteCount: byteCount)
    }

    /// Content comparison: the byte count and the digest only.
    func isSameContent(as other: UndoContentFingerprint) -> Bool {
        isSameContent(digest: other.storedDigest, byteCount: other.byteCount)
    }

    /// Content comparison with a checkpoint record: its digest and byte count only, never its id, ordinal, label,
    /// revision or reason.
    func isSameContent(as record: CheckpointRecord) -> Bool {
        isSameContent(digest: record.digest, byteCount: record.byteCount)
    }

    private func isSameContent(digest other: [UInt8], byteCount otherByteCount: Int) -> Bool {
        guard byteCount == otherByteCount else { return false }
        guard storedDigest.count == other.count else { return false }
        return storedDigest.elementsEqual(other)
    }
}

/// The document state an undo session is bound to: a history is never replayed onto another base.
struct UndoSessionBinding: Equatable, Sendable {
    let draft: DraftID
    let graph: GraphID
    let revision: ContractRevision
    let content: UndoContentFingerprint
}

/// One undo session as the policy sees it. Built only by `make`, which refuses stack counts the depth cannot hold.
struct UndoSessionSnapshot: Equatable, Sendable {
    let binding: UndoSessionBinding
    let depth: DraftHistoryDepth
    let undoCount: Int
    let redoCount: Int
    let hasUnsavedEdits: Bool

    private init(
        binding: UndoSessionBinding,
        depth: DraftHistoryDepth,
        undoCount: Int,
        redoCount: Int,
        hasUnsavedEdits: Bool
    ) {
        self.binding = binding
        self.depth = depth
        self.undoCount = undoCount
        self.redoCount = redoCount
        self.hasUnsavedEdits = hasUnsavedEdits
    }

    /// Each count is checked alone against the depth before the two are added, so the sum cannot overflow. Undo and
    /// redo together hold at most `depth.value` entries, like a real history.
    static func make(
        binding: UndoSessionBinding,
        depth: DraftHistoryDepth,
        undoCount: Int,
        redoCount: Int,
        hasUnsavedEdits: Bool
    ) throws(UndoRebindRefusal) -> UndoSessionSnapshot {
        let counts = 0...depth.value
        guard counts.contains(undoCount), counts.contains(redoCount) else { throw .sessionInvalid }
        guard undoCount + redoCount <= depth.value else { throw .sessionInvalid }
        return UndoSessionSnapshot(
            binding: binding,
            depth: depth,
            undoCount: undoCount,
            redoCount: redoCount,
            hasUnsavedEdits: hasUnsavedEdits
        )
    }
}
