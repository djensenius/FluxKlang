/// The bounded category and caller-supplied diagnostic for one save failure.
struct SaveFault: Equatable, Sendable {
    static let maximumDetailUTF8Bytes = 256

    let category: SaveFaultCategory
    let detail: String?

    private init(category: SaveFaultCategory, detail: String?) {
        self.category = category
        self.detail = detail
    }

    static func make(
        category: SaveFaultCategory,
        detail: String? = nil
    ) throws(SaveSessionRefusal) -> SaveFault {
        if let detail, detail.utf8.count > maximumDetailUTF8Bytes {
            throw .invalidFaultDetailLength(detail.utf8.count)
        }
        return SaveFault(category: category, detail: detail)
    }
}

/// Why a save failed; no underlying OS error or unbounded error text is retained.
enum SaveFaultCategory: Equatable, Sendable {
    case diskFull
    case permissionDenied
    case coordinationDenied
    case unknown
}

/// A reducer refusal. A refused event leaves the complete session unchanged.
enum SaveSessionRefusal: Error, Equatable, Sendable {
    case invalidVersionDigestLength(Int)
    case invalidFaultDetailLength(Int)
    case noChangesToSave
    case saveAlreadyPending
    case savePending
    case unresolvedConflict
    case noConflictToResolve
    case noPendingSave
    case staleCompletion
    case reloadWouldDiscardLocal
    case retainedCopyLimitExceeded
    case attemptLimitExceeded
    case attemptIdentifierExhausted
}
