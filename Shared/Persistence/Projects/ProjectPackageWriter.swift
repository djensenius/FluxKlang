import Foundation

/// Writes a verified package into a new directory using exclusive, no-follow, descriptor-relative
/// creation. It writes the original manifest bytes and every retained member byte unchanged.
/// Every path is re-admitted through P1 before the destination is created, so a refusal there
/// writes nothing. A later IO refusal leaves partial output in the new destination, which the
/// caller must discard; this is not an atomic replace, staged export, file-coordination or iCloud step.
enum ProjectPackageWriter {
    static func write(_ contents: ProjectPackageContents, to destination: URL) throws {
        try write(
            manifestBytes: contents.manifestBytes, entries: contents.entries, limits: contents.limits, to: destination
        )
    }

    /// Lexical backstop over already-verified contents: refuses `..`, absolute, duplicate, parentless
    /// or oversized entries before any IO. Private so no caller can bypass manifest/membership/digest checks.
    private static func write(
        manifestBytes: Data, entries: [ProjectPackageEntry], limits: ProjectPackageLimits, to destination: URL
    ) throws {
        let ordered = try ProjectPackageContents.admit(
            manifestBytes: manifestBytes, entries: entries, declared: [:], limits: limits
        )
        let root = try ProjectPackageFileSystem.createRoot(destination)
        defer { close(root) }
        try ProjectPackageFileSystem.createFile(
            at: root, ProjectPackageManifest.manifestMemberPath, bytes: manifestBytes
        )
        // Byte order places every parent before its descendants.
        for entry in ordered {
            var components = entry.path.unicodeScalars.split(separator: "/").map {
                String(String.UnicodeScalarView($0))
            }
            let name = components.removeLast()
            let parent = try ProjectPackageFileSystem.openDirectory(at: root, components)
            defer { close(parent) }
            if let bytes = entry.bytes {
                try ProjectPackageFileSystem.createFile(at: parent, name, bytes: bytes)
            } else {
                try ProjectPackageFileSystem.createDirectory(at: parent, name)
            }
        }
    }
}
