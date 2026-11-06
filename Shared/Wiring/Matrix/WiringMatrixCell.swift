//
//  WiringMatrixCell.swift
//  FluxKlang
//
//  One cell of the wiring matrix window: the bare class of the wire from the
//  row's output port to the column's input port in the draft's graph, under
//  the headings of the destination list, and the draft markers from the
//  review diff. Built only by `WiringMatrix.window`.
//

/// What a cell's pair classifies as: a connection class, or the refusal of that pair (or of its whole row).
enum WiringMatrixCellState: Hashable, Sendable {
    case classified(WiringConnection)
    /// The pair alone is refused (listed under `.uncheckable` in the destination list), or the row's whole list is
    /// refused (the documented whole-list deviations of `WiringDestinationList.make` apply).
    case uncheckable(WiringPreviewRefusal)
}

/// One matrix cell. `from` is the row's port, `to` the column's.
struct WiringMatrixCell: Hashable, Sendable {
    private(set) var from: PortAddress
    private(set) var to: PortAddress
    private(set) var state: WiringMatrixCellState
    /// The draft-added edges on this pair (review diff `addedEdge` rows), sorted by ID.
    private(set) var draftAdded: [EdgeID]
    /// The active edges on this pair the draft will remove (review diff `removedEdge` rows), sorted by ID.
    private(set) var willRemove: [EdgeID]

    fileprivate init(
        from: PortAddress, to: PortAddress, state: WiringMatrixCellState, draftAdded: [EdgeID], willRemove: [EdgeID]
    ) {
        self.from = from
        self.to = to
        self.state = state
        self.draftAdded = draftAdded
        self.willRemove = willRemove
    }

    /// The heading the destination list gives this pair.
    var connectionClass: WiringDestinationClass {
        switch state {
        case .classified(let connection): WiringDestinationClass(connection)
        case .uncheckable: .uncheckable
        }
    }

    /// The edge a toggle off removes: the first wire on this pair in the draft's graph (`existing`), or `nil`.
    var existingEdge: EdgeID? {
        if case .classified(.existing(let edge)) = state { return edge }
        return nil
    }

    /// Whether the cell is on (the pair is wired in the draft's graph).
    var isOn: Bool { existingEdge != nil }
}

/// Builds cells for `WiringMatrix.window` only.
enum WiringMatrixCellBuilder {
    /// The cells of one row: one shared batch context for the row (`batch`), or the row's whole-list refusal.
    static func row(
        _ source: PortAddress, columns: [PortAddress], batch: Result<WiringCandidateBatch, WiringPreviewRefusal>,
        markers: WiringMatrixMarkers
    ) -> [WiringMatrixCell] {
        switch batch {
        case .failure(let refusal):
            return columns.map { column in
                cell(source, column, state: .uncheckable(refusal), markers: markers)
            }
        case .success(var context):
            var cells: [WiringMatrixCell] = []
            cells.reserveCapacity(columns.count)
            for column in columns {
                let state: WiringMatrixCellState
                do { state = .classified(try context.classify(to: column).connection) } catch {
                    state = .uncheckable(error)
                }
                cells.append(cell(source, column, state: state, markers: markers))
            }
            return cells
        }
    }

    private static func cell(
        _ source: PortAddress, _ column: PortAddress, state: WiringMatrixCellState, markers: WiringMatrixMarkers
    ) -> WiringMatrixCell {
        let pair = WiringMatrixMarkers.Pair(from: source, to: column)
        return WiringMatrixCell(
            from: source, to: column, state: state,
            draftAdded: markers.added[pair] ?? [], willRemove: markers.removed[pair] ?? []
        )
    }
}

/// The review diff's edge rows, by (from, to) pair.
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

    init(_ diff: WiringReviewDiff) {
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
