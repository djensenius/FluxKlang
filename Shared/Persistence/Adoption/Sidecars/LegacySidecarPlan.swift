import Foundation

/// The legacy sidecars to carry into a project package: the original bytes of the pending studio draft and the
/// studio connections file, each optional, at fixed paths with the inert `.opaqueState` role. A plan holds only
/// sidecars that are within the byte caps, non-empty, valid UTF-8 and one JSON value with an object at the top;
/// the retained bytes are the caller's original bytes, never a re-encoding. The content is not interpreted,
/// migrated or given any authority. Only `make` mints a plan.
struct LegacySidecarPlan: Equatable, Sendable {
    static let draftPath = "legacy/PendingStudioDraft.json"
    static let connectionsPath = "legacy/StudioConnections.json"

    /// The draft first, then the connections; only the sidecars that were supplied; all `.opaqueState`.
    let files: [ProjectPackageFile]

    var isEmpty: Bool { files.isEmpty }

    private init(files: [ProjectPackageFile]) {
        self.files = files
    }

    /// Validates the supplied bytes and plans their files, or refuses with nothing produced. `nil` is an absent
    /// sidecar, not an error; a zero-byte `Data` is `empty`. Refusals follow the order documented on
    /// `LegacySidecarRefusal`, and the byte caps and emptiness are checked before any decoding. Each count is
    /// `Data.count`. Only the sidecars are counted; the later composition counts the whole package.
    static func make(
        draft: Data?, connections: Data?, limits: ProjectPackageLimits
    ) throws(LegacySidecarRefusal) -> LegacySidecarPlan {
        try refuseOversized(draft: draft, connections: connections, limits: limits)
        let candidates = LegacySidecarCandidate.present(draft: draft, connections: connections)
        try refuseEmpty(candidates)
        try refuseInvalidUTF8(candidates)
        let values = try decodeValues(candidates)
        try refuseNonObjects(candidates, values: values)
        return LegacySidecarPlan(files: candidates.map {
            ProjectPackageFile(path: $0.path, role: .opaqueState, bytes: $0.data)
        })
    }

    /// Each source within `min(maxEntryBytes, 4 MiB)`, then the two together within `maxTotalBytes`.
    private static func refuseOversized(
        draft: Data?, connections: Data?, limits: ProjectPackageLimits
    ) throws(LegacySidecarRefusal) {
        let entryLimit = min(limits.maxEntryBytes, ProjectGraphLimits.documentBytes)
        let draftBytes = byteCount(draft)
        let connectionBytes = byteCount(connections)
        guard draftBytes <= entryLimit else { throw .oversized(.draft) }
        guard connectionBytes <= entryLimit else { throw .oversized(.connections) }
        let (total, overflow) = draftBytes.addingReportingOverflow(connectionBytes)
        guard !overflow, total <= limits.maxTotalBytes else { throw .oversized(.combined) }
    }

    private static func byteCount(_ data: Data?) -> Int {
        data?.count ?? 0
    }
}
