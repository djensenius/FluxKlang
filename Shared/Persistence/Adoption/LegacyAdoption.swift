import Foundation

/// Adopts legacy StudioGraph (and optional StudioEndpoint) bytes into a verified v1 project package:
/// the adapter's graph, a minimal project with roles derived from that graph, inert provenance and
/// the exact original bytes as opaque state. Adoption grants no authority; the graph stays
/// `requiresReview`. Entry point: `LegacyAdoption.adopt(...)` (in `LegacyAdoptionResult.swift`).
enum LegacyAdoption {
    static let projectPath = "project.json"
    static let graphPath = "graphs/legacy-studio.json"
    /// Fixed opaque-state members holding the original bytes, never re-encoded.
    static let originalGraphPath = "legacy/StudioGraph.json"
    static let originalEndpointsPath = "legacy/StudioEndpoints.json"
    static let provenanceKey = "provenance"
    static let provenance: JSONValue = .object([
        "source": .string("StudioGraph"), "authority": .string("invalidated"), "reviewRequired": .bool(true)
    ])

    /// Byte bounds from the caller's package limits and the 4 MiB document ceiling, checked before
    /// any decoding or assembly. Each input is one package entry; together they share the total.
    static func preflight(
        graphData: Data, endpointsData: Data?, limits: ProjectPackageLimits
    ) throws(LegacyAdoptionRefusal) {
        let entryLimit = min(limits.maxEntryBytes, ProjectGraphLimits.documentBytes)
        guard graphData.count <= entryLimit else { throw .oversizedInput(.graph) }
        guard (endpointsData?.count ?? 0) <= entryLimit else { throw .oversizedInput(.endpoints) }
        let (total, overflow) = graphData.count.addingReportingOverflow(endpointsData?.count ?? 0)
        guard !overflow, total <= limits.maxTotalBytes else { throw .oversizedInput(.combined) }
        for data in [graphData, endpointsData].compactMap(\.self) {
            let value: JSONValue
            do {
                value = try ContractCoding.decode(JSONValue.self, from: data)
            } catch {
                throw .undecodableInput
            }
            if case .object(let fields) = value, fields["contract"] != nil || fields["version"] != nil {
                throw .versionedInput
            }
        }
    }

    /// Runs the neutral adapter, mapping its errors to typed refusals without Foundation text.
    static func adapt(
        graphData: Data, endpointsData: Data?, graphID: GraphID
    ) throws(LegacyAdoptionRefusal) -> StudioGraphImport {
        do {
            return try StudioGraphNeutralAdapter.adapt(graphData: graphData, endpointsData: endpointsData, id: graphID)
        } catch let error as ProjectGraphLimitError {
            throw .legacyBounds(error)
        } catch StudioGraphNeutralAdapter.ImportError.versionedInput {
            throw .versionedInput
        } catch StudioGraphNeutralAdapter.ImportError.duplicateEndpoint {
            throw .duplicateEndpoint
        } catch StudioGraphNeutralAdapter.ImportError.unsupportedKind {
            throw .unsupportedLegacyKind
        } catch {
            throw .undecodableInput
        }
    }

    /// The minimal project: one pinned graph, its derived roles (sorted by `RoleID`) and provenance.
    static func project(
        id: ProjectID, name: String, graph: GraphDocument
    ) throws(LegacyAdoptionRefusal) -> ProjectDocument {
        ProjectDocument(
            id: id, name: name,
            graphs: [ProjectGraphReference(graph: graph.id, revision: graph.revision)],
            roles: try LegacyAdoptionRoles.derive(from: graph),
            extensions: [provenanceKey: provenance]
        )
    }

    /// The original byte sequences at fixed paths, graph first; endpoints only when supplied.
    static func originals(_ imported: StudioGraphImport) -> [ProjectPackageFile] {
        var files = [ProjectPackageFile(path: originalGraphPath, role: .opaqueState, bytes: imported.originalGraph)]
        if let endpoints = imported.originalEndpoints {
            files.append(ProjectPackageFile(path: originalEndpointsPath, role: .opaqueState, bytes: endpoints))
        }
        return files
    }
}
