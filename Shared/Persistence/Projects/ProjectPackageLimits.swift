/// Explicit, finite policy for one import attempt. No global media-size policy is implied.
struct ProjectPackageLimits: Sendable, Equatable {
    let maxEntries: Int
    let maxDepth: Int
    let maxPathUTF8Bytes: Int
    let maxEntryBytes: Int
    let maxTotalBytes: Int

    init(
        maxEntries: Int,
        maxDepth: Int,
        maxPathUTF8Bytes: Int,
        maxEntryBytes: Int,
        maxTotalBytes: Int
    ) throws(ProjectPackageError) {
        guard maxEntries > 0, maxDepth > 0, maxPathUTF8Bytes > 0,
              maxEntryBytes >= 0, maxTotalBytes >= 0, maxEntryBytes <= maxTotalBytes else {
            throw .invalidLimits
        }
        self.maxEntries = maxEntries
        self.maxDepth = maxDepth
        self.maxPathUTF8Bytes = maxPathUTF8Bytes
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
    }
}

enum ProjectPackageEntryKind: Sendable, Equatable {
    case directory
    case regularFile
    case symbolicLink
    case unsupported
}

/// Bounded diagnostics: never retain an untrusted path, payload, or arbitrary error text.
enum ProjectPackageError: Error, Sendable, Equatable {
    case invalidLimits
    case pathTooLong
    case pathTooDeep
    case invalidPath
    case nonNFCPath
    case unsupportedKind
    case directoryByteCount
    case negativeByteCount
    case entryLimitExceeded
    case duplicatePath
    case missingParent
    case parentNotDirectory
    case fileAlreadyOpen
    case noOpenFile
    case entryBytesExceeded
    case totalBytesExceeded
    case declaredBytesExceeded
    case declaredByteCountMismatch
    case byteCountOverflow
}
