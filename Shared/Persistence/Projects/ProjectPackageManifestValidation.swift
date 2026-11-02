extension ProjectPackageManifest {
    /// Checks declarations only. Missing lengths stay unknown; no P1 consumption is simulated.
    /// The caller adds actual input/output manifest bytes only when it has them.
    func validateDeclarations(policy: ProjectPackageManifestPolicy) throws -> Int {
        let limits = policy.packageLimits
        try checkMemberCounts(limits: limits)
        let declaredBytes = try checkDeclaredBytes(limits: limits)
        var namespace = ManifestNamespace(limits: limits)
        try namespace.insert(Self.manifestMemberPath)
        try namespace.insert(project.member.path)
        var graphIDs = Set<GraphID>()
        for reference in graphs {
            guard graphIDs.insert(reference.graph).inserted else { throw ProjectPackageManifestError.duplicateGraph }
            try namespace.insert(reference.member.path)
        }
        var digests = Set<String>()
        for resource in resources {
            guard ProjectDocument.isContentDigest(resource.contentDigest) else {
                throw ProjectPackageManifestError.invalidContentDigest
            }
            guard digests.insert(resource.contentDigest).inserted else {
                throw ProjectPackageManifestError.duplicateResource
            }
            if let media = resource.media {
                try namespace.insert(media.path)
            }
            for bookmark in resource.bookmarks {
                try namespace.insert(bookmark.path)
            }
        }
        for member in opaqueState {
            try namespace.insert(member.path)
        }
        return declaredBytes
    }

    /// Complete count preflight before growing any namespace, ID or digest lookup.
    private func checkMemberCounts(limits: ProjectPackageLimits) throws {
        var files = 0
        try addCount(2, to: &files, maximum: limits.maxEntries) // Manifest and project.
        try addCount(graphs.count, to: &files, maximum: limits.maxEntries)
        try addCount(opaqueState.count, to: &files, maximum: limits.maxEntries)
        guard resources.count <= limits.maxEntries else { throw ProjectPackageError.entryLimitExceeded }
        for resource in resources {
            guard resource.media != nil || !resource.bookmarks.isEmpty else {
                throw ProjectPackageManifestError.emptyResource
            }
            try addCount(resource.bookmarks.count, to: &files, maximum: limits.maxEntries)
            if resource.media != nil { try addCount(1, to: &files, maximum: limits.maxEntries) }
        }
    }

    private func addCount(_ count: Int, to total: inout Int, maximum: Int) throws {
        let (sum, overflow) = total.addingReportingOverflow(count)
        guard !overflow else { throw ProjectPackageError.byteCountOverflow }
        guard sum <= maximum else { throw ProjectPackageError.entryLimitExceeded }
        total = sum
    }

    private func checkDeclaredBytes(limits: ProjectPackageLimits) throws -> Int {
        var total = 0
        try addBytes(project.member, document: true, limits: limits, total: &total)
        for reference in graphs {
            try addBytes(reference.member, document: true, limits: limits, total: &total)
        }
        for resource in resources {
            if let media = resource.media {
                try addBytes(media, document: false, limits: limits, total: &total)
            }
            for bookmark in resource.bookmarks {
                try addBytes(bookmark, document: false, limits: limits, total: &total)
            }
        }
        for member in opaqueState {
            try addBytes(member, document: false, limits: limits, total: &total)
        }
        return total
    }

    private func addBytes(
        _ member: ProjectPackageMember, document: Bool, limits: ProjectPackageLimits, total: inout Int
    ) throws {
        if let bytes = member.byteCount {
            guard bytes >= 0 else { throw ProjectPackageError.negativeByteCount }
            guard bytes <= limits.maxEntryBytes else { throw ProjectPackageError.entryBytesExceeded }
            if document {
                try ProjectGraphLimits.check(bytes, maximum: ProjectGraphLimits.documentBytes, path: "$memberBytes")
            }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw ProjectPackageError.byteCountOverflow }
            guard sum <= limits.maxTotalBytes else { throw ProjectPackageError.totalBytesExceeded }
            total = sum
        }
    }
}

/// Case-sensitive lexical namespace only; no filesystem alias or confinement proof.
private struct ManifestNamespace {
    let limits: ProjectPackageLimits
    private var entries: [String: ProjectPackageEntryKind] = [:]

    init(limits: ProjectPackageLimits) {
        self.limits = limits
    }

    mutating func insert(_ path: String) throws {
        let name = try ProjectPackagePath(path, limits: limits)
        if let existing = entries[name.value] {
            throw existing == .directory ? ProjectPackageError.parentNotDirectory : ProjectPackageError.duplicatePath
        }
        try insertNew(name.value, kind: .regularFile)
        var parent = name.parent
        while let value = parent {
            if let existing = entries[value] {
                guard existing == .directory else { throw ProjectPackageError.parentNotDirectory }
                break // Its ancestors were already counted.
            }
            try insertNew(value, kind: .directory)
            parent = try ProjectPackagePath(value, limits: limits).parent
        }
    }

    private mutating func insertNew(_ path: String, kind: ProjectPackageEntryKind) throws {
        guard entries.count < limits.maxEntries else { throw ProjectPackageError.entryLimitExceeded }
        entries[path] = kind
    }
}
