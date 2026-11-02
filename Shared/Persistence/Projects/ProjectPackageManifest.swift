import Foundation

/// Caller-selected finite declaration limits, not an IO or allocation guarantee.
struct ProjectPackageManifestPolicy: Sendable, Equatable {
    let packageLimits: ProjectPackageLimits
    let maxManifestBytes: Int

    init(packageLimits: ProjectPackageLimits, maxManifestBytes: Int) throws(ProjectPackageError) {
        guard maxManifestBytes > 0, maxManifestBytes <= packageLimits.maxEntryBytes else {
            throw .invalidLimits
        }
        self.packageLimits = packageLimits
        self.maxManifestBytes = maxManifestBytes
    }
}

enum ProjectPackageManifestError: Error, Sendable, Equatable {
    case manifestBytesExceeded
    case duplicateGraph
    case duplicateResource
    case emptyResource
    case invalidContentDigest
    case projectMismatch
    case graphMismatch
    case conflictingAssetByteCount
}

/// Pure package declarations. Paths are explicit, root-relative names, never derived from IDs.
/// Unknown fields round-trip semantically; a future reader must retain original member bytes
/// separately, including unsupported/failed and unlisted members, within its refusal limits.
struct ProjectPackageManifest: Codable, Hashable, Sendable {
    static let currentVersion = ContractVersion(contract: "fluxklang.project-package", version: 1)
    static let manifestMemberPath = "manifest.json"

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contract, version, requiredFeatures, project, graphs, resources, opaqueState, extensions
    }

    var project: ProjectPackageProjectReference
    var graphs: [ProjectPackageGraphReference]
    var resources: [ProjectPackageResource]
    var opaqueState: [ProjectPackageMember]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        project: ProjectPackageProjectReference,
        graphs: [ProjectPackageGraphReference],
        resources: [ProjectPackageResource],
        opaqueState: [ProjectPackageMember],
        extensions: [String: JSONValue]? = nil
    ) {
        self.project = project
        self.graphs = graphs
        self.resources = resources
        self.opaqueState = opaqueState
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        try ProjectGraphEnvelope.requireCurrent(from: decoder, supported: Self.currentVersion)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(ProjectPackageProjectReference.self, forKey: .project)
        graphs = try container.decode([ProjectPackageGraphReference].self, forKey: .graphs)
        resources = try container.decode([ProjectPackageResource].self, forKey: .resources)
        opaqueState = try container.decode([ProjectPackageMember].self, forKey: .opaqueState)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try ProjectGraphEnvelope.encode(Self.currentVersion, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(graphs, forKey: .graphs)
        try container.encode(resources, forKey: .resources)
        try container.encode(opaqueState, forKey: .opaqueState)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    /// Bounds input before Core's uniqueness scan/decoder; not a bound on their internal allocations.
    static func decode(from data: Data, policy: ProjectPackageManifestPolicy) throws -> Self {
        guard data.count <= policy.maxManifestBytes else {
            throw ProjectPackageManifestError.manifestBytesExceeded
        }
        let manifest = try ContractCoding.decode(Self.self, from: data)
        let declaredBytes = try manifest.validateDeclarations(policy: policy)
        try checkTotal(declaredBytes: declaredBytes, manifestBytes: data.count, policy: policy)
        return manifest
    }

    /// Checks output size after encoding; does not promise bounded encoder allocation or original bytes.
    func encoded(policy: ProjectPackageManifestPolicy) throws -> Data {
        let declaredBytes = try validateDeclarations(policy: policy)
        let data = try ContractCoding.makeEncoder().encode(self)
        guard data.count <= policy.maxManifestBytes else {
            throw ProjectPackageManifestError.manifestBytesExceeded
        }
        try Self.checkTotal(declaredBytes: declaredBytes, manifestBytes: data.count, policy: policy)
        return data
    }

    private static func checkTotal(
        declaredBytes: Int, manifestBytes: Int, policy: ProjectPackageManifestPolicy
    ) throws {
        let (total, overflow) = declaredBytes.addingReportingOverflow(manifestBytes)
        guard !overflow else { throw ProjectPackageError.byteCountOverflow }
        guard total <= policy.packageLimits.maxTotalBytes else { throw ProjectPackageError.totalBytesExceeded }
    }
}
