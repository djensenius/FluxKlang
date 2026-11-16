import Foundation

/// Where the writer's test hook fires for one entry, the manifest included.
enum ProjectPackageWriteStage: Sendable, Equatable {
    /// After the entry's parent chain is opened and verified, before the entry is created.
    case beforeCreate
    /// After the entry is created (a directory's identity already recorded), before its parent is re-checked.
    case afterCreate
}

/// Writes a verified package into a new directory using exclusive, no-follow, descriptor-relative
/// creation. It writes the original manifest bytes and every retained member byte unchanged.
/// Every path is re-admitted through P1 before the destination is created, so a refusal there
/// writes nothing. A later IO refusal leaves partial output in the new destination, which the
/// caller must discard; this is not an atomic replace, staged export, file-coordination or iCloud step.
/// Concurrent mutation of the new destination is detected, not prevented: a created directory or the
/// destination itself that is replaced, moved or swapped for a link refuses with `destinationChanged`,
/// and output already written, including into a directory moved elsewhere, stays where it is.
struct ProjectPackageWriter: Sendable {
    /// Test interleaving point around each entry's creation (stage, package path); nil in production.
    /// Lets tests mutate the destination between the writer's checks deterministically.
    var stageHookForTesting: (@Sendable (ProjectPackageWriteStage, String) -> Void)?

    static func write(_ contents: ProjectPackageContents, to destination: URL) throws {
        try ProjectPackageWriter().write(contents, to: destination)
    }

    func write(_ contents: ProjectPackageContents, to destination: URL) throws {
        try write(
            manifestBytes: contents.manifestBytes, entries: contents.entries, limits: contents.limits, to: destination
        )
    }

    /// Lexical backstop over already-verified contents: refuses `..`, absolute, duplicate, parentless
    /// or oversized entries before any IO. Private so no caller can bypass manifest/membership/digest checks.
    private func write(
        manifestBytes: Data, entries: [ProjectPackageEntry], limits: ProjectPackageLimits, to destination: URL
    ) throws {
        let ordered = try ProjectPackageContents.admit(
            manifestBytes: manifestBytes, entries: entries, declared: [:], limits: limits
        )
        let root = try ProjectPackageFileSystem.createRoot(destination)
        defer { root.close() }
        var session = ProjectPackageWriteSession(root: root, hook: stageHookForTesting)
        try session.create(ProjectPackageManifest.manifestMemberPath, bytes: manifestBytes)
        // Byte order places every parent before its descendants.
        for entry in ordered {
            try session.create(entry.path, bytes: entry.bytes)
        }
        try session.verifyComplete()
    }
}
