/// Why the reader refused a legacy file before handing its bytes to the split. No path, bytes or OS text.
enum LegacySourceIORefusal: Sendable, Equatable {
    /// The app directory is a link or not a directory; nothing beneath it is read.
    case directoryRefused
    /// The file is a link, a directory or another non-regular node; a link is never followed.
    case notRegularFile
    /// The file has more than one hard link.
    case hardLinked
    /// The file is on another volume than the app directory.
    case otherVolume
    /// The file changed between its first status and the end of its read.
    case changed
    /// A status or read primitive failed.
    case failed(StagingIOFault)
}

/// A refused legacy file: either the read itself, or the split's verdict on its bytes.
enum LegacySourceRefusal: Error, Sendable, Equatable {
    // swiftlint:disable:next identifier_name
    case io(LegacySourceIORefusal)
    case migration(ProjectMigrationRefusal)
}

/// One legacy file's result. `missing` means no file of that name exists; it is never a refusal.
enum LegacySourceOutcome<Adopted: Sendable & Equatable>: Sendable, Equatable {
    case adopted(Adopted)
    case refused(LegacySourceRefusal)
    case missing
}

/// The reader's result for the three legacy files, one independent outcome each.
struct LegacySourceReport: Sendable, Equatable {
    /// `studio-connections.json`.
    let homeWiring: LegacySourceOutcome<ProjectMigrationPart>
    /// `launch-control-xl.json`.
    let hostLocal: LegacySourceOutcome<ProjectMigrationPart>
    /// `assistant-pending-studio-draft.json`, inert.
    let draft: LegacySourceOutcome<MigratedDraft>

    /// Every source refused with `refusal`, or every source missing when it is nil.
    static func uniform(_ refusal: LegacySourceRefusal?) -> LegacySourceReport {
        func outcome<Value: Sendable & Equatable>() -> LegacySourceOutcome<Value> {
            refusal.map { .refused($0) } ?? .missing
        }
        return LegacySourceReport(homeWiring: outcome(), hostLocal: outcome(), draft: outcome())
    }
}
