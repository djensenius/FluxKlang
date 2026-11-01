//
//  ProjectDocument.swift
//  FluxKlang
//
//  The versioned `fluxklang.project` document and its cross-document checks:
//  every role, asset, patch and shared-graph reference must resolve, and role
//  nodes must match their role's direction and signal. Drafts are #62's and
//  spatial layouts #114's; both round-trip as unknown or extension data.
//

import Foundation

/// A portable project: roles, the graphs it uses, patches and assets.
struct ProjectDocument: Codable, Hashable, Sendable, Identifiable {
    static let currentVersion = ContractVersion(contract: "fluxklang.project", version: 1)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contract, version, id, revision, name, graphs, roles, patches, assets, actions, extensions
        case requiredFeatures
    }

    var id: ProjectID
    var revision: ContractRevision
    var name: String
    var graphs: [ProjectGraphReference]
    var roles: [ProjectRole]
    var patches: [ProjectPatch]
    var assets: [ProjectAsset]
    var actions: [ProjectMediaAction]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: ProjectID,
        revision: ContractRevision = .initial,
        name: String,
        graphs: [ProjectGraphReference] = [],
        roles: [ProjectRole] = [],
        patches: [ProjectPatch] = [],
        assets: [ProjectAsset] = [],
        actions: [ProjectMediaAction] = [],
        extensions: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.graphs = graphs
        self.roles = roles
        self.patches = patches
        self.assets = assets
        self.actions = actions
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        try ProjectGraphEnvelope.requireCurrent(from: decoder, supported: Self.currentVersion)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectID.self, forKey: .id)
        revision = try container.decode(ContractRevision.self, forKey: .revision)
        name = try container.decode(String.self, forKey: .name)
        graphs = try container.decode([ProjectGraphReference].self, forKey: .graphs)
        roles = try container.decode([ProjectRole].self, forKey: .roles)
        patches = try container.decodeIfPresent([ProjectPatch].self, forKey: .patches) ?? []
        assets = try container.decodeIfPresent([ProjectAsset].self, forKey: .assets) ?? []
        actions = try container.decodeIfPresent([ProjectMediaAction].self, forKey: .actions) ?? []
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
        try checkCollectionBounds()
    }

    func encode(to encoder: any Encoder) throws {
        try checkCollectionBounds()
        try ProjectGraphEnvelope.encode(Self.currentVersion, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encode(name, forKey: .name)
        try container.encode(graphs, forKey: .graphs)
        try container.encode(roles, forKey: .roles)
        if !patches.isEmpty { try container.encode(patches, forKey: .patches) }
        if !assets.isEmpty { try container.encode(assets, forKey: .assets) }
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    /// Decodes a project document, rejecting duplicate member names.
    static func decode(from data: Data) throws -> ProjectDocument {
        try ProjectGraphLimits.checkBytes(data)
        return try ContractCoding.decode(ProjectDocument.self, from: data)
    }

    func encoded() throws -> Data {
        let data = try ContractCoding.makeEncoder().encode(self)
        try ProjectGraphLimits.checkBytes(data)
        return data
    }
}

/// Why a project, or a graph in its context, is rejected.
enum ProjectValidationError: Error, Hashable, Sendable {
    case duplicateRole(RoleID)
    case duplicateGraph(GraphID)
    case duplicatePatch(PatchID)
    case duplicateAsset(AssetID)
    case duplicateAction(ActionID)
    case missingActionAsset(ActionID, AssetID)
    case actionMediaMismatch(ActionID)
    case invalidByteCount(AssetID)
    case duplicateSuppliedGraph(GraphID, revision: ContractRevision)
    case recursiveSharedGraphs([GraphID])
    case bounds(ProjectGraphLimitError)
    case invalidRoleChannels(RoleID)
    case missingPatchGraph(PatchID, GraphID)
    case invalidContentDigest(AssetID)
    case invalidTimePolicy(AssetID)
    case invalidTiming(AssetID)
    /// A referenced graph was not supplied, or not at the pinned revision.
    case graphNotSupplied(GraphID, revision: ContractRevision)
    case graph(GraphID, GraphValidationError)
    case missingRole(GraphID, node: NodeID, RoleID)
    case roleMismatch(GraphID, node: NodeID, RoleID)
    case missingAsset(GraphID, node: NodeID, AssetID)
    /// A media player needs audio/MIDI media matching its audio/MIDI output ports.
    case assetMediaMismatch(GraphID, node: NodeID, AssetID)
    case missingSharedGraph(GraphID, node: NodeID, GraphID)
    case unknownFields(path: String)
}

extension ProjectDocument {
    /// Every reason this project is rejected, given the graphs it references.
    func validationErrors(graphs supplied: [GraphDocument], strict: Bool = false) -> [ProjectValidationError] {
        do {
            try checkCollectionBounds()
            try ProjectGraphLimits.check(
                supplied.count, maximum: ProjectGraphLimits.projectRecords, path: "$supplied"
            )
        } catch { return [.bounds(error)] }
        // Preserve first-occurrence lookup semantics; diagnostics still follow document order.
        let rolesByID = Dictionary(roles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var errors = recordErrors(assetsByID: assetsByID, strict: strict)
        var suppliedByRevision: [GraphID: [ContractRevision: GraphDocument]] = [:]
        for graph in supplied {
            if suppliedByRevision[graph.id]?[graph.revision] != nil {
                errors.append(.duplicateSuppliedGraph(graph.id, revision: graph.revision))
            } else {
                suppliedByRevision[graph.id, default: [:]][graph.revision] = graph
            }
        }
        let referenced = Set(graphs.map(\.graph))
        var validated: [GraphID: Set<ContractRevision>] = [:]
        var sharedLinks: [(GraphID, GraphID)] = []
        for reference in graphs {
            guard validated[reference.graph, default: []].insert(reference.revision).inserted else { continue }
            guard let graph = suppliedByRevision[reference.graph]?[reference.revision] else {
                errors.append(.graphNotSupplied(reference.graph, revision: reference.revision))
                continue
            }
            do { try graph.checkCollectionBounds() } catch {
                errors.append(.graph(graph.id, .bounds(error)))
                continue
            }
            errors += graph.validationErrors(strict: strict).map { .graph(graph.id, $0) }
            for node in graph.nodes {
                errors += referenceErrors(
                    node, in: graph.id, graphs: referenced, rolesByID: rolesByID, assetsByID: assetsByID
                )
                if node.kind == .sharedGraph, let shared = node.graph { sharedLinks.append((graph.id, shared)) }
            }
        }
        let cycles = GraphDocument.nodesOnCycles(sharedLinks)
        if !cycles.isEmpty { errors.append(.recursiveSharedGraphs(cycles)) }
        return errors
    }

    func checkCollectionBounds() throws(ProjectGraphLimitError) {
        for (path, count) in [("graphs", graphs.count), ("roles", roles.count),
                              ("patches", patches.count), ("assets", assets.count), ("actions", actions.count)] {
            try ProjectGraphLimits.check(count, maximum: ProjectGraphLimits.projectRecords, path: "$.\(path)")
        }
    }

    /// Throws the first validation error.
    func validate(graphs: [GraphDocument], strict: Bool = false) throws(ProjectValidationError) {
        if let first = validationErrors(graphs: graphs, strict: strict).first { throw first }
    }

    private func recordErrors(assetsByID: [AssetID: ProjectAsset], strict: Bool) -> [ProjectValidationError] {
        var errors: [ProjectValidationError] = []
        errors += duplicates(roles.map(\.id)).map(ProjectValidationError.duplicateRole)
        errors += duplicates(graphs.map(\.graph)).map(ProjectValidationError.duplicateGraph)
        errors += duplicates(patches.map(\.id)).map(ProjectValidationError.duplicatePatch)
        errors += duplicates(assets.map(\.id)).map(ProjectValidationError.duplicateAsset)
        errors += duplicates(actions.map(\.id)).map(ProjectValidationError.duplicateAction)
        errors += actionErrors(assetsByID: assetsByID)
        errors += assetErrors()
        for role in roles {
            let valid = role.signal == .audio
                ? role.channels.map(GraphPort.channelRange.contains) ?? false : role.channels == nil
            if !valid { errors.append(.invalidRoleChannels(role.id)) }
        }
        let graphIDs = Set(graphs.map(\.graph))
        for patch in patches where !graphIDs.contains(patch.graph) {
            errors.append(.missingPatchGraph(patch.id, patch.graph))
        }
        if strict { errors += unknownFieldErrors() }
        return errors
    }

    private func actionErrors(assetsByID: [AssetID: ProjectAsset]) -> [ProjectValidationError] {
        var errors: [ProjectValidationError] = []
        for action in actions {
            guard let asset = assetsByID[action.asset] else {
                errors.append(.missingActionAsset(action.id, action.asset))
                continue
            }
            if !((asset.media == .audio && action.policy.media == .audio)
                || (asset.media == .midi && action.policy.media == .midi)) {
                errors.append(.actionMediaMismatch(action.id))
            }
        }
        return errors
    }

    private func assetErrors() -> [ProjectValidationError] {
        var errors: [ProjectValidationError] = []
        for asset in assets {
            if !Self.isContentDigest(asset.contentDigest) { errors.append(.invalidContentDigest(asset.id)) }
            let allowed = asset.media.allowedTimePolicies
            if let bytes = asset.byteCount, bytes < 0 { errors.append(.invalidByteCount(asset.id)) }
            // Audio and MIDI must state an allowed policy; documents state none.
            if !(asset.timePolicy.map(allowed.contains) ?? allowed.isEmpty) {
                errors.append(.invalidTimePolicy(asset.id))
            }
            if asset.media == .document ? asset.timing != nil : asset.timing?.isEmpty == true {
                errors.append(.invalidTiming(asset.id))
            }
        }
        return errors
    }

    private func referenceErrors(
        _ node: GraphNode, in graphID: GraphID, graphs referenced: Set<GraphID>,
        rolesByID: [RoleID: ProjectRole], assetsByID: [AssetID: ProjectAsset]
    ) -> [ProjectValidationError] {
        var errors: [ProjectValidationError] = []
        if node.kind.requiresRole, let roleID = node.role {
            if let role = rolesByID[roleID] {
                let direction: PortDirection = node.kind == .roleInput ? .input : .output
                // A role input feeds the graph through output ports, and vice versa.
                let matches = role.direction == direction && node.ports.allSatisfy {
                    $0.direction != direction && $0.signal == role.signal && $0.channels == role.channels
                }
                if !matches { errors.append(.roleMismatch(graphID, node: node.id, roleID)) }
            } else {
                errors.append(.missingRole(graphID, node: node.id, roleID))
            }
        }
        errors += mediaPlayerErrors(node, in: graphID, assetsByID: assetsByID)
        if node.kind == .sharedGraph, let shared = node.graph, !referenced.contains(shared) || shared == graphID {
            errors.append(.missingSharedGraph(graphID, node: node.id, shared))
        }
        return errors
    }

    private func mediaPlayerErrors(
        _ node: GraphNode, in graphID: GraphID, assetsByID: [AssetID: ProjectAsset]
    ) -> [ProjectValidationError] {
        guard node.kind == .mediaPlayer, let assetID = node.asset else { return [] }
        guard let asset = assetsByID[assetID] else { return [.missingAsset(graphID, node: node.id, assetID)] }
        let expected: PortSignal
        switch asset.media {
        case .audio: expected = .audio
        case .midi: expected = .midi
        case .document: return [.assetMediaMismatch(graphID, node: node.id, assetID)]
        }
        let incompatible = node.ports.contains { port in
            port.direction == .output && (port.signal == .audio || port.signal == .midi) && port.signal != expected
        }
        return incompatible ? [.assetMediaMismatch(graphID, node: node.id, assetID)] : []
    }

    private func unknownFieldErrors() -> [ProjectValidationError] {
        var found: [(String, [String: JSONValue])] = [("$", unknownFields)]
        found += roles.map { ("$.roles[\($0.id)]", $0.unknownFields) }
        found += graphs.map { ("$.graphs[\($0.graph)]", $0.unknownFields) }
        found += patches.map { ("$.patches[\($0.id)]", $0.unknownFields) }
        found += assets.map { ("$.assets[\($0.id)]", $0.unknownFields) }
        found += assets.map { ("$.assets[\($0.id)].timing", $0.timing?.unknownFields ?? [:]) }
        found += actions.map { ("$.actions[\($0.id)]", $0.unknownFields) }
        let policyErrors: [ProjectValidationError] = actions.filter { $0.policy.hasUnknownFields }
            .map { .unknownFields(path: "$.actions[\($0.id)].policy") }
        return found.filter { !$0.1.isEmpty }.map { .unknownFields(path: $0.0) } + policyErrors
    }

    private func duplicates<ID: Hashable>(_ ids: [ID]) -> [ID] {
        var seen: Set<ID> = []
        return ids.filter { !seen.insert($0).inserted }
    }

    static func isContentDigest(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else { return false }
        let hex = value.utf8.dropFirst(prefix.utf8.count)
        return hex.count == 64 && hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
