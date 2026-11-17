/// Why no receipt was minted. Carries no bytes, paths or OS text. Nothing was replaced or retired in any case.
enum LegacyMigrationArchiveRefusal: Error, Sendable, Equatable {
    /// Removing a leftover staging tree from an earlier run failed; nothing else was attempted.
    case recovery(StagingRefusal)
    /// The adopted parts could not be assembled into a package under the caller's policy.
    case assembly(ProjectPackageDocumentError)
    /// The volume could not be opened, or the staged write, its verification, promotion or a re-read failed.
    case staging(StagingRefusal)
    /// An archive already exists but is not a valid commit record: not a readable package of ours, its record or
    /// provenance is missing or wrong, its member set disagrees with the record, or a member no longer splits; or
    /// the draft names disagree with its draft member (another draft at the original name, other bytes at the retired
    /// name, or the archived draft at neither). It is left exactly as it is. Home or USB changes never cause this.
    case archiveDiffers
    /// The legacy files changed while the archive was written or validated. The archive stays; a later launch retries.
    case sourcesChanged
}

/// The result of one `LegacyMigrationArchive.archive` run.
enum LegacyMigrationArchiveOutcome: Sendable, Equatable {
    /// No archive exists and no source was adopted; nothing was written.
    case nothingToArchive(LegacySourceReport)
    /// The archive was written, re-read and matched, and the sources were unchanged afterwards.
    case archived(LegacyMigrationReceipt)
    /// A valid archive was already in place and the draft names agree with it; nothing was written, and Home and the
    /// USB map were not read. The receipt describes the archive's contents, not the live files.
    case alreadyArchived(LegacyMigrationReceipt)
    case refused(LegacyMigrationArchiveRefusal)
}
