import Foundation

/// Bounded refusals for decoding or assembling package documents. Cases carry only manifest- or
/// caller-validated identities and typed P1/P2/P3 errors, never paths, payload bytes or Foundation text.
enum ProjectPackageDocumentError: Error, Equatable, Sendable {
    case undecodableProject
    case undecodableGraph(GraphID)
    /// A future version or unsupported `requiredFeatures`; nothing is read past the envelope's refusal.
    /// `version: 0` and wrong-contract documents are undecodable, not unsupported.
    case unsupportedProject
    case unsupportedGraph(GraphID)
    /// Unversioned or older documents need the migration/adoption slices; nothing is upgraded here.
    case legacyProject
    case legacyGraph(GraphID)
    case projectBounds
    case graphBounds(GraphID)
    /// `make` refuses documents the encoder rejects, e.g. unsupported `requiredFeatures`.
    case unencodableProject
    case unencodableGraph(GraphID)
    /// Extra files may only be opaque state or unlisted; project, graph and resource roles are refused.
    case unsupportedExtraRole
    case package(ProjectPackageError)
    case manifest(ProjectPackageManifestError)
    case packageIO(ProjectPackageIOError)
}

/// A verified package with its project and pinned graphs decoded from the original member bytes.
/// Only manifest identity/reference agreement is checked; `ProjectDocument.validate(graphs:)` is the
/// caller's job, so graphs that require review stay readable. Grants no readiness or activation.
struct ProjectPackageDocuments: Equatable, Sendable {
    /// The source package; every original member byte, including opaque and unlisted ones, is retained.
    let contents: ProjectPackageContents
    let project: ProjectDocument
    /// In manifest graph order.
    let graphs: [GraphDocument]

    init(contents: ProjectPackageContents) throws(ProjectPackageDocumentError) {
        let manifest = contents.manifest
        var bytesByPath: [String: Data] = [:]
        for file in contents.files {
            bytesByPath[file.path] = file.bytes
        }
        let projectPath = manifest.project.member.path
        // Defensive: `ProjectPackageContents` already guarantees every listed member exists.
        guard let projectBytes = bytesByPath[projectPath] else { throw .packageIO(.missingMember) }
        let project = try Self.decode(projectBytes, supported: ProjectDocument.currentVersion, ProjectDocument.decode)
            .mapError { $0.projectError }.get()
        var graphs: [GraphDocument] = []
        graphs.reserveCapacity(manifest.graphs.count)
        for reference in manifest.graphs {
            let id = reference.graph
            // Defensive, as above.
            guard let bytes = bytesByPath[reference.member.path] else { throw .packageIO(.missingMember) }
            try graphs.append(Self.decode(bytes, supported: GraphDocument.currentVersion, GraphDocument.decode)
                .mapError { $0.graphError(id) }.get())
        }
        let supplied = zip(manifest.graphs, graphs).map { (path: $0.member.path, document: $1) }
        // Reference checks read only the package limits; the admitted manifest length is a valid ceiling.
        let policy: ProjectPackageManifestPolicy
        do {
            policy = try ProjectPackageManifestPolicy(
                packageLimits: contents.limits, maxManifestBytes: contents.manifestBytes.count
            )
        } catch {
            throw .package(error)
        }
        try Self.checkReferences(manifest, project: project, projectPath: projectPath, graphs: supplied, policy: policy)
        self.contents = contents
        self.project = project
        self.graphs = graphs
    }

    static func checkReferences(
        _ manifest: ProjectPackageManifest, project: ProjectDocument, projectPath: String,
        graphs: [(path: String, document: GraphDocument)], policy: ProjectPackageManifestPolicy
    ) throws(ProjectPackageDocumentError) {
        do {
            try manifest.validateReferences(project: project, projectPath: projectPath, graphs: graphs, policy: policy)
        } catch {
            throw wrap(error, bounds: .projectBounds)
        }
    }

    /// Maps P1/P2/P3 errors to typed cases; anything else becomes the supplied fallback.
    static func wrap(_ error: any Error, bounds fallback: ProjectPackageDocumentError) -> ProjectPackageDocumentError {
        switch error {
        case let error as ProjectPackageDocumentError: error
        case let error as ProjectPackageError: .package(error)
        case let error as ProjectPackageManifestError: .manifest(error)
        case let error as ProjectPackageIOError: .packageIO(error)
        default: fallback
        }
    }

    enum DecodeFailure: Error {
        case undecodable, unsupported, legacy, bounds

        var projectError: ProjectPackageDocumentError {
            switch self {
            case .undecodable: .undecodableProject
            case .unsupported: .unsupportedProject
            case .legacy: .legacyProject
            case .bounds: .projectBounds
            }
        }

        func graphError(_ id: GraphID) -> ProjectPackageDocumentError {
            switch self {
            case .undecodable: .undecodableGraph(id)
            case .unsupported: .unsupportedGraph(id)
            case .legacy: .legacyGraph(id)
            case .bounds: .graphBounds(id)
            }
        }
    }

    /// Classifies refusals by type, or by a second envelope-only probe; Foundation text is discarded.
    static func decode<Document>(
        _ data: Data, supported: ContractVersion, _ decode: (Data) throws -> Document
    ) -> Result<Document, DecodeFailure> {
        do {
            return try .success(decode(data))
        } catch is ProjectGraphLimitError {
            return .failure(.bounds)
        } catch is ProjectGraphVersionError {
            return .failure(.unsupported)
        } catch ContractVersionError.unsupportedVersion {
            return .failure(.unsupported)
        } catch is ContractVersionError {
            return .failure(.undecodable)
        } catch {
            return .failure(probe(data, supported: supported))
        }
    }

    private static func probe(_ data: Data, supported: ContractVersion) -> DecodeFailure {
        guard let envelope = try? ContractCoding.decode(Envelope.self, from: data) else { return .undecodable }
        let compatibility = try? ContractVersion.check(
            contract: envelope.contract, version: envelope.version, supported: supported
        )
        switch compatibility {
        case .legacyUnversioned, .needsMigration: return .legacy
        case .current, nil: return .undecodable
        }
    }

    private struct Envelope: Decodable {
        let contract: String?
        let version: Int?
    }
}
