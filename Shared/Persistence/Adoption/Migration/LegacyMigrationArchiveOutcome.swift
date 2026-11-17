/// Why no receipt was minted. Carries no bytes, paths or OS text. Nothing was replaced or retired in any case.
enum LegacyMigrationArchiveRefusal: Error, Sendable, Equatable {
    /// Removing a leftover staging tree from an earlier run failed; nothing else was attempted.
    case recovery(StagingRefusal)
    /// The adopted parts could not be assembled into a package under the caller's policy.
    case assembly(ProjectPackageDocumentError)
    /// The volume could not be opened, or the staged write, its verification, promotion or a re-read failed.
    case staging(StagingRefusal)
    /// An archive already exists with other members. It is left exactly as it is.
    case archiveDiffers
    /// The legacy files changed while the archive was written. The archive stays; a later launch retries.
    case sourcesChanged
}

/// The result of one `LegacyMigrationArchive.archive` run.
enum LegacyMigrationArchiveOutcome: Sendable, Equatable {
    /// No source was adopted; nothing was written.
    case nothingToArchive(LegacySourceReport)
    /// The archive was written, re-read and matched, and the sources were unchanged afterwards.
    case archived(LegacyMigrationReceipt)
    /// An equal archive was already in place and the sources were unchanged; nothing was written.
    case alreadyArchived(LegacyMigrationReceipt)
    case refused(LegacyMigrationArchiveRefusal)
}
