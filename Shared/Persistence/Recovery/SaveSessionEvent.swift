/// A validated, byte-exact opaque content version with bounded textual digest.
struct SaveContentVersion: Equatable, Hashable, Sendable {
    static let maximumDigestUTF8Bytes = 128

    let digest: String

    private init(digest: String) {
        self.digest = digest
    }

    static func make(digest: String) throws(SaveSessionRefusal) -> SaveContentVersion {
        let count = digest.utf8.count
        guard (1...maximumDigestUTF8Bytes).contains(count) else {
            throw .invalidVersionDigestLength(count)
        }
        return SaveContentVersion(digest: digest)
    }

    static func == (lhs: SaveContentVersion, rhs: SaveContentVersion) -> Bool {
        lhs.digest.utf8.elementsEqual(rhs.digest.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(digest.utf8.count)
        for byte in digest.utf8 {
            hasher.combine(byte)
        }
    }
}

/// Inputs to the pure save-session reducer. Versions are caller supplied content digests.
enum SaveSessionEvent: Equatable, Sendable {
    case edit(local: SaveContentVersion)
    case saveRequested
    case saveCompleted(attempt: SaveAttemptID, version: SaveContentVersion)
    case saveFailed(attempt: SaveAttemptID, fault: SaveFault)
    case externalChange(remote: SaveContentVersion)
    case conflictResolved(choice: SaveConflictChoice)
    case saveConfirmedAfterInterruption(attempt: SaveAttemptID, version: SaveContentVersion)
    case reload(version: SaveContentVersion)
    /// The caller's statement that no unresolved attempt can still land; frees a failed save.
    /// The caller must re-deliver any external change it saw while the save was failed.
    case saveAbandoned(attempt: SaveAttemptID)
}
