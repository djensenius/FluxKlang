extension ProjectPackageManifest {
    /// Identity/declaration agreement only, not readiness, activation, physical membership or IO proof.
    /// No original manifest byte length is available here, so its byte-inclusive total is not rechecked.
    /// Unreferenced resources remain intact; assets without resources remain unresolved, not usable.
    func validateReferences(
        project document: ProjectDocument,
        projectPath: String,
        graphs supplied: [(path: String, document: GraphDocument)],
        policy: ProjectPackageManifestPolicy
    ) throws {
        try document.checkCollectionBounds()
        try ProjectGraphLimits.check(
            supplied.count, maximum: ProjectGraphLimits.projectRecords, path: "$supplied"
        )
        _ = try validateDeclarations(policy: policy)
        _ = try ProjectPackagePath(projectPath, limits: policy.packageLimits)
        guard document.id == project.id, document.revision == project.revision,
              projectPath == project.member.path else { throw ProjectPackageManifestError.projectMismatch }
        guard graphs.count == document.graphs.count, graphs.count == supplied.count else {
            throw ProjectPackageManifestError.graphMismatch
        }
        let mappings = Dictionary(uniqueKeysWithValues: graphs.map { ($0.graph, $0) })
        var projectIDs = Set<GraphID>()
        for reference in document.graphs {
            guard projectIDs.insert(reference.graph).inserted,
                  let mapping = mappings[reference.graph], mapping.revision == reference.revision else {
                throw ProjectPackageManifestError.graphMismatch
            }
        }
        var suppliedIDs = Set<GraphID>()
        for (path, graph) in supplied {
            _ = try ProjectPackagePath(path, limits: policy.packageLimits)
            guard suppliedIDs.insert(graph.id).inserted,
                  let mapping = mappings[graph.id],
                  mapping.revision == graph.revision, mapping.member.path == path else {
                throw ProjectPackageManifestError.graphMismatch
            }
        }
        // Do not call ProjectDocument.validate: requiresReview is preservable inert intent.
        try checkAssetLengths(document.assets)
    }

    private func checkAssetLengths(_ assets: [ProjectAsset]) throws {
        let resourcesByDigest = Dictionary(uniqueKeysWithValues: resources.map { ($0.contentDigest, $0) })
        var lengths: [String: Int] = [:]
        for asset in assets {
            guard ProjectDocument.isContentDigest(asset.contentDigest) else {
                throw ProjectPackageManifestError.invalidContentDigest
            }
            guard let bytes = asset.byteCount else { continue }
            guard bytes >= 0 else { throw ProjectPackageError.negativeByteCount }
            if let previous = lengths[asset.contentDigest], previous != bytes {
                throw ProjectPackageManifestError.conflictingAssetByteCount
            }
            lengths[asset.contentDigest] = bytes
            // External target bytes are neither bookmark bytes nor package consumption.
            if let mediaBytes = resourcesByDigest[asset.contentDigest]?.media?.byteCount, mediaBytes != bytes {
                throw ProjectPackageManifestError.conflictingAssetByteCount
            }
        }
    }
}
