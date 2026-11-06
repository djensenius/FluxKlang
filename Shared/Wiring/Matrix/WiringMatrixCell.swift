//
//  WiringMatrixCell.swift
//  FluxKlang
//
//  One cell of the wiring matrix window: the bare class of the wire from the
//  row's output port to the column's input port in the draft's graph, under
//  the headings of the destination list, and the draft markers from the
//  review diff. The cell struct, its fileprivate init and the row builder are
//  in WiringMatrix.swift, so cells are built only by `WiringMatrix.window`.
//

/// What a cell's pair classifies as: a connection class, or the refusal of that pair (or of its whole row).
enum WiringMatrixCellState: Hashable, Sendable {
    case classified(WiringConnection)
    /// The pair alone is refused (listed under `.uncheckable` in the destination list), or the row's whole list is
    /// refused (the documented whole-list deviations of `WiringDestinationList.make` apply).
    case uncheckable(WiringPreviewRefusal)
}

/// What a cell shows; the cell itself and its builder are in WiringMatrix.swift.
extension WiringMatrixCell {
    /// The heading the destination list gives this pair.
    var connectionClass: WiringDestinationClass {
        switch state {
        case .classified(let connection): WiringDestinationClass(connection)
        case .uncheckable: .uncheckable
        }
    }

    /// The edge a toggle off removes: the classified `existing` edge (the first wire on this pair in the draft's
    /// graph), or, for an `.uncheckable` cell (for example a row refused at the edge bound), `wiredEdge`, the same
    /// first wire found by node and port IDs; `nil` for every other cell.
    var existingEdge: EdgeID? {
        switch state {
        case .classified(.existing(let edge)): edge
        case .classified: nil
        case .uncheckable: wiredEdge
        }
    }

    /// Whether the cell is on (`existingEdge` is set).
    var isOn: Bool { existingEdge != nil }
}

/// The review diff's edge rows and the draft graph's first wire, by (from, to) pair.
struct WiringMatrixMarkers {
    /// A pair by node and port IDs only, as the classifier resolves endpoints (extension bags are ignored).
    struct Pair: Hashable {
        let fromNode: NodeID
        let fromPort: PortID
        let toNode: NodeID
        let toPort: PortID

        init(from: PortAddress, to: PortAddress) {
            fromNode = from.node
            fromPort = from.port
            toNode = to.node
            toPort = to.port
        }
    }

    private(set) var added: [Pair: [EdgeID]] = [:]
    private(set) var removed: [Pair: [EdgeID]] = [:]
    /// The first edge of `graph` on each pair, in graph order (the first-wins rule of `WiringCandidateContext`).
    private(set) var wired: [Pair: EdgeID] = [:]

    /// The markers of `diff`, and the first wires of `graph` (the draft's graph) in one O(edges) pass.
    init(_ diff: WiringReviewDiff, graph: GraphDocument) {
        for edge in graph.edges {
            let pair = Pair(from: edge.from, to: edge.to)
            if wired[pair] == nil { wired[pair] = edge.id }
        }
        for change in diff.changes {
            switch change {
            case .addedEdge(let edge): added[Pair(from: edge.from, to: edge.to), default: []].append(edge.id)
            case .removedEdge(let edge): removed[Pair(from: edge.from, to: edge.to), default: []].append(edge.id)
            case .addedNode, .movedNode, .removedNode: continue
            }
        }
        added = added.mapValues { $0.sorted() }
        removed = removed.mapValues { $0.sorted() }
    }
}
