import Foundation

/// A verified v1 package adopted from legacy StudioGraph bytes. Only `LegacyAdoption.adopt` mints one,
/// after assembly and a full re-decode of the assembled package. Grants no readiness or authority:
/// the graph still requires review and `ProjectDocument.validate(graphs:)` reports it.
struct LegacyAdoptionResult: Equatable, Sendable {
    /// The assembled package, re-decoded from its own member bytes.
    var documents: ProjectPackageDocuments { storedDocuments }
    /// Audio roles whose channel count the legacy data did not confirm, sorted by `RoleID`.
    var unconfirmedChannelRoles: [RoleID] { storedUnconfirmedChannelRoles }
    var contents: ProjectPackageContents { storedDocuments.contents }

    private let storedDocuments: ProjectPackageDocuments
    private let storedUnconfirmedChannelRoles: [RoleID]

    private init(documents: ProjectPackageDocuments) {
        storedDocuments = documents
        storedUnconfirmedChannelRoles = documents.project.roles
            .filter { $0.signal == .audio && $0.channels == nil }.map(\.id)
    }

    fileprivate static func assemble(
        project: ProjectDocument, graph: GraphDocument, originals: [ProjectPackageFile],
        policy: ProjectPackageManifestPolicy
    ) throws(LegacyAdoptionRefusal) -> LegacyAdoptionResult {
        do {
            let contents = try ProjectPackageContents.make(
                project: (LegacyAdoption.projectPath, project), graphs: [(LegacyAdoption.graphPath, graph)],
                extraFiles: originals, policy: policy
            )
            return try LegacyAdoptionResult(documents: ProjectPackageDocuments(contents: contents))
        } catch {
            throw .assembly(error)
        }
    }
}

extension LegacyAdoption {
    /// Adopts legacy bytes, or refuses with nothing produced. Order: byte bounds, versioned/undecodable
    /// probe, adapter, role derivation, then assembly. The same input always yields identical bytes.
    static func adopt(
        graphData: Data, endpointsData: Data? = nil, projectID: ProjectID, graphID: GraphID, name: String,
        policy: ProjectPackageManifestPolicy
    ) throws(LegacyAdoptionRefusal) -> LegacyAdoptionResult {
        try preflight(graphData: graphData, endpointsData: endpointsData, limits: policy.packageLimits)
        let imported = try adapt(graphData: graphData, endpointsData: endpointsData, graphID: graphID)
        let project = try project(id: projectID, name: name, graph: imported.graph)
        return try LegacyAdoptionResult.assemble(
            project: project, graph: imported.graph, originals: originals(imported), policy: policy
        )
    }
}
