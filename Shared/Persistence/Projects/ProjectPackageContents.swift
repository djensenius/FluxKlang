import CryptoKit
import Foundation

/// The manifest role of a retained member. Roles grant no readiness, access or activation authority.
enum ProjectPackageMemberRole: Hashable, Sendable {
    case project
    case graph(GraphID)
    case media(contentDigest: String)
    case bookmark(contentDigest: String)
    case opaqueState
    case unlisted
}

/// Original member bytes, retained whether listed, undecodable/unsupported or unlisted.
struct ProjectPackageFile: Hashable, Sendable {
    let path: String
    let role: ProjectPackageMemberRole
    let bytes: Data
}

/// One package entry; `bytes == nil` denotes a directory.
struct ProjectPackageEntry: Sendable {
    let path: String
    let bytes: Data?
}

/// A verified package value: P1 admission over exact byte counts, listed membership as regular
/// files, declared lengths and embedded media digests. Documents are not decoded here; graph
/// readiness, bookmark resolution and migration remain later obligations.
/// Only the in-memory initializer and `ProjectPackageReader` can construct one.
struct ProjectPackageContents: Equatable, Sendable {
    let manifest: ProjectPackageManifest
    /// The original manifest bytes; writing never re-encodes them.
    let manifestBytes: Data
    /// Sorted by UTF-8 bytes; includes unlisted and empty directories.
    let directories: [String]
    /// Sorted by UTF-8 bytes; excludes the manifest member.
    let files: [ProjectPackageFile]
    /// The package limits this value was admitted under; the writer re-admits with them.
    let limits: ProjectPackageLimits

    /// In-memory construction runs one complete P1 pass over exactly the supplied byte counts.
    init(
        manifestBytes: Data, directories: [String], files: [String: Data], policy: ProjectPackageManifestPolicy
    ) throws {
        let manifest = try ProjectPackageManifest.decode(from: manifestBytes, policy: policy)
        let entries = directories.map { ProjectPackageEntry(path: $0, bytes: nil) }
            + files.map { ProjectPackageEntry(path: $0.key, bytes: $0.value) }
        _ = try Self.admit(
            manifestBytes: manifestBytes, entries: entries,
            declared: manifest.declaredMemberByteCounts, limits: policy.packageLimits
        )
        try self.init(
            checked: manifest, manifestBytes: manifestBytes, directories: directories, files: files,
            limits: policy.packageLimits
        )
    }

    /// Accepts only a proof minted by the reader after its single P1 attempt completed.
    init(reading proof: ProjectPackageReadProof) throws {
        try self.init(
            checked: proof.manifest, manifestBytes: proof.manifestBytes, directories: proof.directories,
            files: proof.files, limits: proof.limits
        )
    }

    private init(
        checked manifest: ProjectPackageManifest, manifestBytes: Data, directories: [String],
        files: [String: Data], limits: ProjectPackageLimits
    ) throws {
        let roles = manifest.memberRoles
        for (path, role) in roles.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            guard let bytes = files[path] else { throw ProjectPackageIOError.missingMember }
            if case let .media(digest) = role, Self.contentDigest(of: bytes) != digest {
                throw ProjectPackageIOError.digestMismatch
            }
        }
        self.manifest = manifest
        self.manifestBytes = manifestBytes
        self.directories = directories.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        self.files = files
            .map { ProjectPackageFile(path: $0.key, role: roles[$0.key] ?? .unlisted, bytes: $0.value) }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        self.limits = limits
    }

    var entries: [ProjectPackageEntry] {
        directories.map { ProjectPackageEntry(path: $0, bytes: nil) }
            + files.map { ProjectPackageEntry(path: $0.path, bytes: $0.bytes) }
    }

    /// One complete P1 pass (manifest first, then UTF-8 byte order, which places parents first).
    /// Returns the entries in that order. Paths are lexically validated before any caller IO.
    static func admit(
        manifestBytes: Data, entries: [ProjectPackageEntry], declared: [String: Int], limits: ProjectPackageLimits
    ) throws -> [ProjectPackageEntry] {
        var admission = ProjectPackageAdmission(limits: limits)
        try admission.admit(path: ProjectPackageManifest.manifestMemberPath, kind: .regularFile)
        try admission.consume(byteCount: manifestBytes.count)
        try admission.finishFile()
        let ordered = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        for entry in ordered {
            guard let bytes = entry.bytes else {
                try admission.admit(path: entry.path, kind: .directory)
                continue
            }
            try admission.admit(path: entry.path, kind: .regularFile, declaredByteCount: declared[entry.path])
            try admission.consume(byteCount: bytes.count)
            try admission.finishFile()
        }
        try admission.validateComplete()
        return ordered
    }

    static func contentDigest(of bytes: Data) -> String {
        let hex = SHA256.hash(data: bytes).map { byte in
            let text = String(byte, radix: 16)
            return byte < 16 ? "0" + text : text
        }
        return "sha256:" + hex.joined()
    }
}

extension ProjectPackageManifest {
    /// Declared lengths of listed members; an absent length stays unknown and is never charged.
    var declaredMemberByteCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for (member, _) in roledMembers {
            counts[member.path] = member.byteCount
        }
        return counts
    }

    var memberRoles: [String: ProjectPackageMemberRole] {
        var roles: [String: ProjectPackageMemberRole] = [:]
        for (member, role) in roledMembers {
            roles[member.path] = role
        }
        return roles
    }

    private var roledMembers: [(ProjectPackageMember, ProjectPackageMemberRole)] {
        var members: [(ProjectPackageMember, ProjectPackageMemberRole)] = [(project.member, .project)]
        members += graphs.map { ($0.member, .graph($0.graph)) }
        for resource in resources {
            if let media = resource.media {
                members.append((media, .media(contentDigest: resource.contentDigest)))
            }
            members += resource.bookmarks.map { ($0, .bookmark(contentDigest: resource.contentDigest)) }
        }
        members += opaqueState.map { ($0, .opaqueState) }
        return members
    }
}
