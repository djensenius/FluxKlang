import Foundation

extension ProjectPackageContents {
    /// Assembles a verified package from documents at caller-chosen paths. Project and graphs are written
    /// in canonical encoding (unknown fields round-trip semantically, not as original bytes). Extra files
    /// keep their exact bytes: `.opaqueState` ones are listed in supplied order, `.unlisted` ones are not.
    /// Parent directories are derived from member paths. References are checked; graph readiness is not.
    /// Size checks run before path uniqueness, so input that is both oversized and has a duplicate path
    /// (a repeated extra, or an extra sharing a document's path) may report a size error instead.
    static func make(
        project: (path: String, document: ProjectDocument),
        graphs: [(path: String, document: GraphDocument)],
        extraFiles: [ProjectPackageFile],
        policy: ProjectPackageManifestPolicy
    ) throws(ProjectPackageDocumentError) -> ProjectPackageContents {
        let limits = policy.packageLimits
        // Count preflight before encoding anything: manifest, project, graphs and extras are all files.
        guard extraFiles.count <= limits.maxEntries - 2,
              graphs.count <= limits.maxEntries - 2 - extraFiles.count else {
            throw .package(.entryLimitExceeded)
        }
        // Byte preflight: extras are charged before anything is encoded, then each document as soon as
        // it is encoded, so the first member crossing a limit stops before later graphs are encoded.
        var budget = AssemblyBudget(limits: limits)
        var opaqueState: [ProjectPackageMember] = []
        for file in extraFiles {
            try budget.charge(file.bytes.count)
            switch file.role {
            case .opaqueState: opaqueState.append(ProjectPackageMember(path: file.path, byteCount: file.bytes.count))
            case .unlisted: break
            case .project, .graph, .media, .bookmark: throw .unsupportedExtraRole
            }
        }
        let projectBytes = try encode(project.document, failure: .unencodableProject, bounds: .projectBounds)
        try budget.charge(projectBytes.count)
        var graphReferences: [ProjectPackageGraphReference] = []
        var files: [(path: String, bytes: Data)] = [(project.path, projectBytes)]
        for (path, graph) in graphs {
            let bytes = try encode(graph, failure: .unencodableGraph(graph.id), bounds: .graphBounds(graph.id))
            try budget.charge(bytes.count)
            graphReferences.append(ProjectPackageGraphReference(
                graph: graph.id, revision: graph.revision,
                member: ProjectPackageMember(path: path, byteCount: bytes.count)
            ))
            files.append((path, bytes))
        }
        files += extraFiles.map { ($0.path, $0.bytes) }
        let manifest = ProjectPackageManifest(
            project: ProjectPackageProjectReference(
                id: project.document.id, revision: project.document.revision,
                member: ProjectPackageMember(path: project.path, byteCount: projectBytes.count)
            ),
            graphs: graphReferences, resources: [], opaqueState: opaqueState
        )
        do {
            let manifestBytes = try manifest.encoded(policy: policy)
            try manifest.validateReferences(
                project: project.document, projectPath: project.path, graphs: graphs, policy: policy
            )
            var byPath: [String: Data] = [:]
            for file in files {
                guard byPath.updateValue(file.bytes, forKey: file.path) == nil else {
                    throw ProjectPackageError.duplicatePath
                }
            }
            return try ProjectPackageContents(
                manifestBytes: manifestBytes, directories: derivedDirectories(of: byPath.keys, limits: limits),
                files: byPath, policy: policy
            )
        } catch {
            throw ProjectPackageDocuments.wrap(error, bounds: .projectBounds)
        }
    }

    /// Every proper ancestor of every file path, deduplicated and sorted by UTF-8 bytes.
    /// Each path is lexically admitted first, so the walk is bounded by `maxDepth`.
    static func derivedDirectories(
        of paths: some Sequence<String>, limits: ProjectPackageLimits
    ) throws(ProjectPackageError) -> [String] {
        var directories = Set<String>()
        for path in paths {
            var parent = try ProjectPackagePath(path, limits: limits).parent
            while let value = parent, directories.insert(value).inserted {
                parent = try ProjectPackagePath(value, limits: limits).parent
            }
        }
        return directories.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func encode(
        _ document: some Encodable & PackageDocumentEncoding,
        failure: ProjectPackageDocumentError, bounds: ProjectPackageDocumentError
    ) throws(ProjectPackageDocumentError) -> Data {
        do {
            return try document.encoded()
        } catch is ProjectGraphLimitError {
            throw bounds
        } catch {
            throw failure
        }
    }
}

/// Running member-byte totals for `make`; the manifest itself is charged later by the P1 pass.
private struct AssemblyBudget {
    let limits: ProjectPackageLimits
    private var total = 0

    init(limits: ProjectPackageLimits) {
        self.limits = limits
    }

    mutating func charge(_ count: Int) throws(ProjectPackageDocumentError) {
        guard count <= limits.maxEntryBytes else { throw .package(.entryBytesExceeded) }
        let (sum, overflow) = total.addingReportingOverflow(count)
        guard !overflow else { throw .package(.byteCountOverflow) }
        guard sum <= limits.maxTotalBytes else { throw .package(.totalBytesExceeded) }
        total = sum
    }
}

protocol PackageDocumentEncoding {
    func encoded() throws -> Data
}

extension ProjectDocument: PackageDocumentEncoding {}
extension GraphDocument: PackageDocumentEncoding {}
