//
//  DraftEditFold.swift
//  FluxKlang
//
//  Folds user gestures into the normalized edit list of one draft. The folded
//  list always passes `GraphEdit.validateBatch`, and applying it to the base
//  gives the graph that applying every gesture edit one at a time would give,
//  except for edge order: an identical reconnect keeps the base edge in its
//  original slot, where one-at-a-time application appends it. Compare drafts
//  and candidate graphs by content (edges keyed by ID), never by bytes (#62).
//

/// Folds gestures into a draft's normalized edit list.
///
/// - A second move of a node replaces the first; a move back to the base
///   position drops the move. Moving a draft-added node rewrites its `addNode`.
/// - Removing a draft-added node drops its add, its moves and the draft
///   connects touching it (and disconnects base edges that dangled onto it).
///   Removing a base node drops its move and the draft connects touching it,
///   and records the removal.
/// - Disconnecting a draft-added edge drops its connect.
/// - Reconnecting a base edge with its identical value cancels the disconnect;
///   any other value under a base edge ID is refused (`edgeIDReuse`).
/// - A position with a NaN or infinite coordinate is refused (`invalidPosition`), as is
///   an added node's NaN or infinite `linearGain` (`nonFiniteNodeValue`) or a connected
///   edge's NaN or infinite `gainCeilingDb` (`nonFiniteEdgeValue`): a NaN never equals
///   itself, so such a draft would record an undo entry for every later gesture.
/// - A NaN or infinite number nested anywhere in an extension bag or unknown member of an
///   added node (or its ports or position), a moved position or a connected edge (or its
///   endpoints, conversion or feedback) is refused (`nonFiniteNodeExtension`,
///   `nonFiniteEdgeExtension`). A NaN because `JSONValue` equality never matches it with
///   itself, which would lock the history; ±∞ (which does equal itself) because `JSONValue`
///   cannot encode a non-finite number (encoding throws), and for consistency with the
///   position and gain rules.
/// - Node and edge counts, and an added node's ports and combined required and advisory
///   capabilities (`GraphNode.checkCollectionBounds()`), are checked against
///   `ProjectGraphLimits` (`bounds`) as each edit folds, so a later edit that normalizes the
///   add or connect away cannot admit it.
///
/// The IDs of draft-added nodes and edges are not reserved: once an add or a
/// connect folds away, the same ID may be added or connected again with other
/// content. ID-keyed selection (#101, the UI) can therefore name a different
/// item after an undo or redo and must be revalidated against the draft.
enum DraftEditFold {
    /// The edit list after folding `gesture`, in order, onto `edits`. A gesture
    /// is atomic: if any of its edits is refused, nothing is folded.
    static func fold(
        _ gesture: [GraphEdit], onto edits: [GraphEdit], base: GraphDocument
    ) throws(DraftHistoryRefusal) -> [GraphEdit] {
        do {
            try ProjectGraphLimits.check(gesture.count, maximum: ProjectGraphLimits.edits, path: "$.gesture")
        } catch { throw .bounds(error) }
        let candidate = try Self.candidate(of: edits, on: base)
        var state = try FoldState(base: base, candidate: candidate, edits: edits)
        for (index, edit) in gesture.enumerated() {
            try state.fold(edit, index: index)
        }
        _ = try Self.candidate(of: state.edits, on: base)
        return state.edits
    }

    /// Whether `position` is absent or has finite coordinates, as `GraphDocument.validate()` requires.
    static func isFinite(_ position: GraphPoint?) -> Bool {
        guard let position else { return true }
        return position.x.isFinite && position.y.isFinite
    }

    /// Whether `value` is absent or finite.
    static func isFiniteValue(_ value: Double?) -> Bool {
        value?.isFinite ?? true
    }

    /// The JSON path, relative to `node`, of the first NaN or infinite number in an extension bag or unknown
    /// member of its ports, its position or the node itself, or nil.
    ///
    /// Ports are addressed by index (`.ports[1]`), unlike `GraphValidation`, which uses the port ID. This is
    /// deliberate: neither `DraftHistory.make` nor the fold validates port-ID uniqueness (`applying` does not
    /// run `GraphDocument.validate()`), so an ID could name two ports while the index names exactly one.
    static func nonFiniteNumber(in node: GraphNode) -> String? {
        for (index, port) in node.ports.enumerated() {
            if let path = nonFiniteNumber(port.extensions, port.unknownFields) { return ".ports[\(index)]" + path }
        }
        return nonFiniteNumber(in: node.position) ?? nonFiniteNumber(node.extensions, node.unknownFields)
    }

    /// The JSON path, relative to the node, of the first NaN or infinite number in `position`, or nil.
    static func nonFiniteNumber(in position: GraphPoint?) -> String? {
        guard let position, let path = nonFiniteNumber(position.extensions, position.unknownFields) else { return nil }
        return ".position" + path
    }

    /// The JSON path, relative to `edge`, of the first NaN or infinite number in an extension bag or unknown
    /// member of its endpoints, conversion, feedback or the edge itself, or nil.
    static func nonFiniteNumber(in edge: GraphEdge) -> String? {
        if let path = nonFiniteNumber(edge.from.extensions, edge.from.unknownFields) { return ".from" + path }
        if let path = nonFiniteNumber(edge.to.extensions, edge.to.unknownFields) { return ".to" + path }
        if let conversion = edge.conversion,
           let path = nonFiniteNumber(conversion.extensions, conversion.unknownFields) {
            return ".conversion" + path
        }
        if let feedback = edge.feedback, let path = nonFiniteNumber(feedback.extensions, feedback.unknownFields) {
            return ".feedback" + path
        }
        return nonFiniteNumber(edge.extensions, edge.unknownFields)
    }

    /// The path of the first NaN or infinite number in `value`, relative to it, or nil. Object members are
    /// visited in ascending key order and array elements in ascending index order, depth first, so the path is
    /// deterministic. The path is diagnostic only: object keys are written verbatim (`.key`, not escaped or
    /// quoted), as in the other contract paths, so a key containing `.` or `[` reads ambiguously.
    ///
    /// Decoding never produces such a number (JSON has no literal for one and `JSONDecoder` refuses
    /// out-of-range numbers); only a value built in memory can hold one, and it is not held to the 512-level
    /// nesting limit of `ContractCoding.decode`, so this walks an explicit stack instead of recursing. Each
    /// value is visited once.
    static func nonFiniteNumber(in value: JSONValue) -> String? {
        // One frame per open container: its path segment and its unvisited children, the next one last.
        var stack: [(segment: String, children: [(String, JSONValue)])] = [("", [("", value)])]
        while !stack.isEmpty {
            guard let (segment, child) = stack[stack.count - 1].children.popLast() else {
                stack.removeLast()
                continue
            }
            switch child {
            case .double(let number) where !number.isFinite:
                return stack.map { $0.segment }.joined() + segment
            case .array(let elements):
                stack.append((segment, elements.indices.reversed().map { ("[\($0)]", elements[$0]) }))
            case .object(let members):
                stack.append((segment, members.sorted { $0.key > $1.key }.map { (".\($0.key)", $0.value) }))
            default:
                continue
            }
        }
        return nil
    }

    /// The path of the first NaN or infinite number in one object's extension bag (under `.extensions`), then
    /// in its unknown members (encoded beside its known members).
    private static func nonFiniteNumber(
        _ extensions: [String: JSONValue]?, _ unknown: [String: JSONValue]
    ) -> String? {
        if let extensions, let path = nonFiniteNumber(in: .object(extensions)) { return ".extensions" + path }
        return nonFiniteNumber(in: .object(unknown))
    }

    private static func candidate(
        of edits: [GraphEdit], on base: GraphDocument
    ) throws(DraftHistoryRefusal) -> GraphDocument {
        do {
            return try base.applying(edits)
        } catch {
            if case .bounds(let limit) = error { throw .bounds(limit) }
            throw .invalidDraft(error)
        }
    }
}

/// The candidate graph's IDs while one gesture folds, plus the edit list.
private struct FoldState {
    let baseNodes: [NodeID: GraphNode]
    let baseEdges: [EdgeID: GraphEdge]
    /// Node IDs of the candidate graph.
    var nodes: Set<NodeID>
    /// Edges of the candidate graph.
    var edges: [EdgeID: GraphEdge]
    /// Nodes added by this draft.
    var added: Set<NodeID>
    /// Edges connected by this draft.
    var connected: Set<EdgeID>
    var edits: [GraphEdit]

    init(base: GraphDocument, candidate: GraphDocument, edits: [GraphEdit]) throws(DraftHistoryRefusal) {
        var baseNodes: [NodeID: GraphNode] = [:]
        for node in base.nodes {
            guard baseNodes.updateValue(node, forKey: node.id) == nil else { throw .duplicateBaseNode(node.id) }
        }
        var baseEdges: [EdgeID: GraphEdge] = [:]
        for edge in base.edges {
            guard baseEdges.updateValue(edge, forKey: edge.id) == nil else { throw .duplicateBaseEdge(edge.id) }
        }
        self.baseNodes = baseNodes
        self.baseEdges = baseEdges
        nodes = Set(candidate.nodes.map(\.id))
        self.edges = Dictionary(candidate.edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        added = []
        connected = []
        for edit in edits {
            if case .addNode(let node) = edit { added.insert(node.id) }
            if case .connect(let edge) = edit { connected.insert(edge.id) }
        }
        self.edits = edits
    }

    mutating func fold(_ edit: GraphEdit, index: Int) throws(DraftHistoryRefusal) {
        switch edit {
        case .addNode(let node): try add(node, index: index)
        case .moveNode(let id, let position): try move(id, to: position, index: index)
        case .removeNode(let id): try remove(id, index: index)
        case .connect(let edge): try connect(edge, index: index)
        case .disconnect(let id): try disconnect(id, index: index)
        }
    }

    private mutating func add(_ node: GraphNode, index: Int) throws(DraftHistoryRefusal) {
        guard DraftEditFold.isFinite(node.position) else { throw .invalidPosition(node.id) }
        guard DraftEditFold.isFiniteValue(node.linearGain) else { throw .nonFiniteNodeValue(node.id) }
        if let path = DraftEditFold.nonFiniteNumber(in: node) {
            throw .nonFiniteNodeExtension(node.id, path: "$.nodes[\(node.id)]" + path)
        }
        guard !nodes.contains(node.id) else { throw .edit(index: index, .nodeExists(node.id)) }
        guard baseNodes[node.id] == nil else { throw .nodeIDReuse(node.id) }
        try Self.check(nodes.count + 1, maximum: ProjectGraphLimits.nodes, path: "$.nodes")
        // The per-node limits `applying` checks, checked now so a later remove cannot erase them.
        do { try node.checkCollectionBounds() } catch { throw .bounds(error) }
        nodes.insert(node.id)
        added.insert(node.id)
        edits.append(.addNode(node))
    }

    private mutating func move(_ id: NodeID, to position: GraphPoint?, index: Int) throws(DraftHistoryRefusal) {
        guard DraftEditFold.isFinite(position) else { throw .invalidPosition(id) }
        if let path = DraftEditFold.nonFiniteNumber(in: position) {
            throw .nonFiniteNodeExtension(id, path: "$.nodes[\(id)]" + path)
        }
        guard nodes.contains(id) else { throw .edit(index: index, .missingNode(id)) }
        if added.contains(id) {
            if let addIndex = edits.firstIndex(where: { Self.adds($0, id) }),
               case .addNode(var node) = edits[addIndex] {
                node.position = position
                edits[addIndex] = .addNode(node)
            }
            edits.removeAll { Self.moves($0, id) }
            return
        }
        // A later move replaces the earlier one in place; a move back to the base position is no move.
        let earlier = edits.firstIndex { Self.moves($0, id) }
        edits.removeAll { Self.moves($0, id) }
        guard baseNodes[id]?.position != position else { return }
        edits.insert(.moveNode(id, to: position), at: earlier ?? edits.endIndex)
    }

    private mutating func remove(_ id: NodeID, index: Int) throws(DraftHistoryRefusal) {
        guard nodes.contains(id) else { throw .edit(index: index, .missingNode(id)) }
        let touching = edges.values.filter { $0.from.node == id || $0.to.node == id }.map(\.id)
        let dropped = Set(touching.filter { connected.contains($0) })
        edits.removeAll { edit in
            switch edit {
            case .addNode(let node): node.id == id
            case .moveNode(let node, _): node == id
            case .connect(let edge): dropped.contains(edge.id)
            default: false
            }
        }
        connected.subtract(dropped)
        if added.remove(id) != nil {
            // A base edge can dangle onto an ID only the draft adds; removing the node removes it too.
            edits += touching.filter { !dropped.contains($0) }.sorted().map(GraphEdit.disconnect)
        } else {
            edits.append(.removeNode(id))
        }
        nodes.remove(id)
        for edge in touching { edges[edge] = nil }
    }

    private mutating func connect(_ edge: GraphEdge, index: Int) throws(DraftHistoryRefusal) {
        guard DraftEditFold.isFiniteValue(edge.feedback?.gainCeilingDb) else { throw .nonFiniteEdgeValue(edge.id) }
        if let path = DraftEditFold.nonFiniteNumber(in: edge) {
            throw .nonFiniteEdgeExtension(edge.id, path: "$.edges[\(edge.id)]" + path)
        }
        guard edges[edge.id] == nil else { throw .edit(index: index, .edgeExists(edge.id)) }
        for node in [edge.from.node, edge.to.node] where baseNodes[node] != nil && !nodes.contains(node) {
            throw .endpointRemoved(edge: edge.id, node: node)
        }
        try Self.check(edges.count + 1, maximum: ProjectGraphLimits.edges, path: "$.edges")
        if let baseEdge = baseEdges[edge.id] {
            guard baseEdge == edge else { throw .edgeIDReuse(edge.id) }
            edits.removeAll { $0 == .disconnect(edge.id) }
        } else {
            connected.insert(edge.id)
            edits.append(.connect(edge))
        }
        edges[edge.id] = edge
    }

    private mutating func disconnect(_ id: EdgeID, index: Int) throws(DraftHistoryRefusal) {
        guard edges[id] != nil else { throw .edit(index: index, .missingEdge(id)) }
        if connected.remove(id) != nil {
            edits.removeAll { if case .connect(let edge) = $0 { edge.id == id } else { false } }
        } else {
            edits.append(.disconnect(id))
        }
        edges[id] = nil
    }

    private static func adds(_ edit: GraphEdit, _ id: NodeID) -> Bool {
        if case .addNode(let node) = edit { node.id == id } else { false }
    }

    private static func moves(_ edit: GraphEdit, _ id: NodeID) -> Bool {
        if case .moveNode(let node, _) = edit { node == id } else { false }
    }

    private static func check(_ count: Int, maximum: Int, path: String) throws(DraftHistoryRefusal) {
        do { try ProjectGraphLimits.check(count, maximum: maximum, path: path) } catch { throw .bounds(error) }
    }
}
