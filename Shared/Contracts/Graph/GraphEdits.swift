//
//  GraphEdits.swift
//  FluxKlang
//
//  Normalized payloads for every structural graph edit, a pure candidate-graph
//  apply, and the op-for-op check that a draft-edit command restates an op of
//  the draft it names. Draft lifecycle, authorization and activation are #62's;
//  `DraftEdits` is only the minimal op list those checks need.
//

import Foundation

/// One structural edit. Its typed value is the normalized payload: two edits
/// are the same op exactly when they decode to equal values, whatever the JSON
/// member order or number spelling. Unknown top-level edit members and operation
/// names reject; embedded graph records preserve optional members.
enum GraphEdit: Codable, Hashable, Sendable {
    case connect(GraphEdge)
    case disconnect(EdgeID)
    case addNode(GraphNode)
    /// Removes the node and every edge touching it.
    case removeNode(NodeID)
    /// Moves (or, with nil, unplaces) a node; geometry only.
    case moveNode(NodeID, to: GraphPoint?)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case operation = "op"
        case edge
        case node
        case position
    }

    private enum Operation: String, Codable {
        case connect, disconnect, addNode, removeNode, moveNode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(Operation.self, forKey: .operation)
        let allowed: Set<CodingKeys>
        switch operation {
        case .connect:
            self = .connect(try container.decode(GraphEdge.self, forKey: .edge))
            allowed = [.operation, .edge]
        case .disconnect:
            self = .disconnect(try container.decode(EdgeID.self, forKey: .edge))
            allowed = [.operation, .edge]
        case .addNode:
            self = .addNode(try container.decode(GraphNode.self, forKey: .node))
            allowed = [.operation, .node]
        case .removeNode:
            self = .removeNode(try container.decode(NodeID.self, forKey: .node))
            allowed = [.operation, .node]
        case .moveNode:
            let position = try container.decodeIfPresent(GraphPoint.self, forKey: .position)
            self = .moveNode(try container.decode(NodeID.self, forKey: .node), to: position)
            allowed = [.operation, .node, .position]
        }
        let members = try decoder.container(keyedBy: DynamicCodingKey.self).allKeys.map(\.stringValue)
        if let stray = members.first(where: { CodingKeys(rawValue: $0).map(allowed.contains) != true }) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected member \"\(stray)\" in \(operation.rawValue)"
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connect(let edge):
            try container.encode(Operation.connect, forKey: .operation)
            try container.encode(edge, forKey: .edge)
        case .disconnect(let edge):
            try container.encode(Operation.disconnect, forKey: .operation)
            try container.encode(edge, forKey: .edge)
        case .addNode(let node):
            try container.encode(Operation.addNode, forKey: .operation)
            try container.encode(node, forKey: .node)
        case .removeNode(let node):
            try container.encode(Operation.removeNode, forKey: .operation)
            try container.encode(node, forKey: .node)
        case .moveNode(let node, let position):
            try container.encode(Operation.moveNode, forKey: .operation)
            try container.encode(node, forKey: .node)
            try container.encodeIfPresent(position, forKey: .position)
        }
    }
}

/// Why an edit cannot apply to a graph.
enum GraphEditError: Error, Hashable, Sendable {
    case edgeExists(EdgeID)
    case missingEdge(EdgeID)
    case nodeExists(NodeID)
    case missingNode(NodeID)
    case contradictoryNode(NodeID)
    case contradictoryEdge(EdgeID)
    case bounds(ProjectGraphLimitError)
}

extension GraphEdit {
    static func validateBatch(_ edits: [GraphEdit]) throws(GraphEditError) {
        do {
            try ProjectGraphLimits.check(edits.count, maximum: ProjectGraphLimits.edits, path: "$.edits")
        } catch { throw .bounds(error) }
        var added: Set<NodeID> = [], removed: Set<NodeID> = [], moved: Set<NodeID> = []
        var connected: Set<EdgeID> = [], disconnected: Set<EdgeID> = []
        for edit in edits {
            switch edit {
            case .connect(let edge):
                try insert(edge.id, into: &connected, error: .contradictoryEdge(edge.id))
            case .disconnect(let id):
                try insert(id, into: &disconnected, error: .contradictoryEdge(id))
            case .addNode(let node):
                try insert(node.id, into: &added, error: .contradictoryNode(node.id))
            case .removeNode(let id):
                try insert(id, into: &removed, error: .contradictoryNode(id))
            case .moveNode(let id, _):
                try insert(id, into: &moved, error: .contradictoryNode(id))
            }
        }
        if let id = added.union(moved).intersection(removed).sorted().first { throw .contradictoryNode(id) }
        if let id = connected.intersection(disconnected).sorted().first { throw .contradictoryEdge(id) }
        try validateRemovedReferences(edits, removed: removed)
    }

    private static func insert<ID: Hashable>(
        _ id: ID, into set: inout Set<ID>, error: GraphEditError
    ) throws(GraphEditError) {
        guard set.insert(id).inserted else { throw error }
    }

    private static func validateRemovedReferences(
        _ edits: [GraphEdit], removed: Set<NodeID>
    ) throws(GraphEditError) {
        for case .connect(let edge) in edits {
            for id in [edge.from.node, edge.to.node] where removed.contains(id) { throw .contradictoryNode(id) }
        }
    }
}

extension GraphDocument {
    /// The candidate graph after `edits`, in order. Applying never validates
    /// wiring and never changes the revision; validate the candidate, and let
    /// the transaction owner (#62) commit it.
    func applying(_ edits: [GraphEdit]) throws(GraphEditError) -> GraphDocument {
        do { try checkCollectionBounds() } catch { throw .bounds(error) }
        try GraphEdit.validateBatch(edits)
        var graph = self
        for edit in edits {
            try graph.apply(edit)
        }
        do { try graph.checkCollectionBounds() } catch { throw .bounds(error) }
        return graph
    }

    private mutating func apply(_ edit: GraphEdit) throws(GraphEditError) {
        switch edit {
        case .connect(let edge):
            guard !edges.contains(where: { $0.id == edge.id }) else { throw .edgeExists(edge.id) }
            edges.append(edge)
        case .disconnect(let id):
            guard let index = edges.firstIndex(where: { $0.id == id }) else { throw .missingEdge(id) }
            edges.remove(at: index)
        case .addNode(let node):
            guard self.node(node.id) == nil else { throw .nodeExists(node.id) }
            nodes.append(node)
        case .removeNode(let id):
            guard node(id) != nil else { throw .missingNode(id) }
            nodes.removeAll { $0.id == id }
            edges.removeAll { $0.from.node == id || $0.to.node == id }
        case .moveNode(let id, let position):
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw .missingNode(id) }
            nodes[index].position = position
        }
    }
}

/// The ordered structural ops of one draft against a base graph revision. Not
/// Codable: the persisted draft and command shapes belong to #62 and #55.
struct DraftEdits: Hashable, Sendable, Identifiable {
    var id: DraftID
    var graph: GraphID
    var baseRevision: ContractRevision
    var edits: [GraphEdit]
}

/// A command that edits a named draft. Each of its edits must equal, op for
/// op, an edit already in that draft.
struct DraftEditCommand: Hashable, Sendable {
    var draft: DraftID
    var edits: [GraphEdit]
}

/// Why a draft-edit command does not match its draft.
enum DraftEditError: Error, Hashable, Sendable {
    case unknownDraft(DraftID)
    case emptyCommand
    case ambiguousDraft(DraftID)
    case duplicateCommandEdit
    case invalidDraft(DraftID, GraphEditError)
    /// The edit at `index` of the command is not an op of the named draft.
    case editNotInDraft(DraftID, index: Int)
}

extension DraftEditCommand {
    /// Checks the command against the drafts of this session and returns the
    /// draft it names.
    @discardableResult
    func validate(against drafts: [DraftEdits]) throws(DraftEditError) -> DraftEdits {
        guard let named = drafts.first(where: { $0.id == draft }) else { throw .unknownDraft(draft) }
        guard drafts.filter({ $0.id == draft }).count == 1 else { throw .ambiguousDraft(draft) }
        guard !edits.isEmpty else { throw .emptyCommand }
        guard Set(edits).count == edits.count else { throw .duplicateCommandEdit }
        do { try GraphEdit.validateBatch(named.edits) } catch { throw .invalidDraft(draft, error) }
        if let index = edits.firstIndex(where: { !named.edits.contains($0) }) {
            throw .editNotInDraft(draft, index: index)
        }
        return named
    }
}
