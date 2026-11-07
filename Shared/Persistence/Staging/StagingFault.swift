/// The classified failure of one `StagingFileSystem` primitive. No OS error text or path is retained.
enum StagingIOFault: Error, Sendable, Equatable {
    case noSpace
    case denied
    case notFound
    case exists
    case crossVolume
    /// A directory listing exceeded the limit it was given.
    case tooManyEntries
    case ioError
    /// The process or volume went away mid-operation; nothing after it ran.
    case interrupted

    var saveFaultCategory: SaveFaultCategory {
        switch self {
        case .noSpace: .diskFull
        case .denied: .permissionDenied
        case .notFound, .exists, .crossVolume, .tooManyEntries, .ioError, .interrupted: .unknown
        }
    }
}

/// The pipeline stage a failure belongs to.
enum StagingStep: Sendable, Equatable {
    case preflight
    case readSource
    case createStagingRoot
    case writeManifest
    case writeEntry
    case syncStaging
    case verifyReread
    case retireExisting
    case promote
    case syncParent
    case retireBackup
    case cleanup
    case restorePrevious
}

/// What happened to the staging tree after a failure.
enum StagingCleanup: Sendable, Equatable {
    /// Nothing had been created, or the staging tree was already promoted.
    case notNeeded
    /// Cleanup was deliberately not attempted (an interruption, or a rollback that failed).
    case notAttempted
    case removed
    case leftBehind
}

/// A typed refusal or failure. Cases carry no paths, payloads or error text.
enum StagingRefusal: Error, Sendable, Equatable {
    case invalidToken
    case invalidOperationCeiling
    case invalidChunkSize
    case operationBudgetExceeded
    case overlappingPaths
    case destinationExists
    case destinationMissing
    case destinationNotDirectory
    case destinationRefused
    case stagingNameInUse
    case invalidManifest
    case package(ProjectPackageError)
    case manifest(ProjectPackageManifestError)
    case packageIO(ProjectPackageIOError)
    case verificationFailed(cleanup: StagingCleanup)
    case ioFailed(step: StagingStep, fault: StagingIOFault, cleanup: StagingCleanup)
    case promotionFailed(fault: StagingIOFault, rolledBack: Bool, cleanup: StagingCleanup)

    /// Wraps any error thrown by the P1 value layer; an unknown error is an invalid manifest.
    static func wrapping(_ error: any Error) -> StagingRefusal {
        if let refusal = error as? StagingRefusal { return refusal }
        if let error = error as? ProjectPackageError { return .package(error) }
        if let error = error as? ProjectPackageManifestError { return .manifest(error) }
        if let error = error as? ProjectPackageIOError { return .packageIO(error) }
        return .invalidManifest
    }
}
