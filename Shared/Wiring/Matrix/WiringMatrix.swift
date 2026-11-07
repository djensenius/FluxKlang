//
//  WiringMatrix.swift
//  FluxKlang
//
//  A windowed projection of the wiring matrix of a draft: output ports as
//  rows, input ports as columns. Each row is classified through one shared
//  `WiringCandidateBatch` (the per-source context the destination list uses,
//  so one baseline validation per row) and each cell gets the list's heading
//  for its pair; draft markers come from `WiringReviewDiff`. A toggle on goes
//  through `WiringDraftComposer.compose`, a toggle off through
//  `WiringRemoveComposer.remove`, so the matrix makes exactly the edits the
//  list and the port picker make. Cells are built only here: the cell's init
//  and the row builder are fileprivate to this file. The active graph is only
//  read.
//

/// The connect a matrix toggle on asks for; the pair is the cell's.
struct WiringMatrixConnect: Hashable, Sendable {
    /// The ID the new edge gets.
    var edge: EdgeID
    /// The caller's explicit conversion, required exactly when the pair needs one.
    var conversion: EdgeConversion?
    /// The caller's explicit feedback, required exactly when the wire closes a cycle.
    var feedback: EdgeFeedback?

    init(edge: EdgeID, conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil) {
        self.edge = edge
        self.conversion = conversion
        self.feedback = feedback
    }
}

/// One window of the wiring matrix.
struct WiringMatrix: Hashable, Sendable {
    /// The most rows (and, separately, columns) one window may have.
    static let maximumRows = 64
    static let maximumColumns = 64

    /// The window's output ports, in the caller's order.
    private(set) var rows: [PortAddress]
    /// The window's input ports, in the caller's order.
    private(set) var columns: [PortAddress]
    /// Row-major: the cell of row `r` and column `c` is at `r * columns.count + c`.
    private(set) var cells: [WiringMatrixCell]

    private init(rows: [PortAddress], columns: [PortAddress], cells: [WiringMatrixCell]) {
        self.rows = rows
        self.columns = columns
        self.cells = cells
    }

    /// The cell of `row` and `column`, or `nil` outside the window.
    func cell(row: Int, column: Int) -> WiringMatrixCell? {
        guard rows.indices.contains(row), columns.indices.contains(column) else { return nil }
        return cells[row * columns.count + column]
    }

    /// The window `rows` × `columns` of the draft's graph, `active.applying(draft.edits)`. Refused, with nothing
    /// changed, when it has more than `maximumRows` rows or `maximumColumns` columns (`windowTooLarge`, checked
    /// first) or the draft does not check against `active` (`preview`). A graph- or source-level row refusal is
    /// repeated in each cell (`.uncheckable`). At exactly 16,384 edges wired pairs keep their classification;
    /// every non-wired cell is `.uncheckable(.bounds)`. `classify` differs only for non-wired pairs with
    /// uncheckable or unknown endpoints. A wired cell that remains uncheckable knows its first wire (`wiredEdge`),
    /// so it shows on and toggles off. Rows and columns are not orientation-checked: an input port as a row or an
    /// output port as a column gives `notOffered` cells.
    static func window(
        rows: [PortAddress], columns: [PortAddress], active: GraphDocument, draft: DraftEdits
    ) throws(WiringEditRefusal) -> WiringMatrix {
        try window(rows: rows, columns: columns, active: active, draft: draft) {}
    }

    /// `window(rows:columns:active:draft:)`, calling `onValidate` just before each row's one baseline validation.
    /// A test seam that only observes.
    static func window(
        rows: [PortAddress], columns: [PortAddress], active: GraphDocument, draft: DraftEdits,
        onValidate: () -> Void
    ) throws(WiringEditRefusal) -> WiringMatrix {
        guard rows.count <= maximumRows, columns.count <= maximumColumns else {
            throw .windowTooLarge(rows: rows.count, columns: columns.count)
        }
        let graph: GraphDocument
        let markers: WiringMatrixMarkers
        do {
            // The review diff builds the draft's graph again internally; it does not expose it, and the second
            // build is one O(graph) pass per window.
            graph = try WiringDraftGraph.make(active: active, draft: draft).graph
            markers = WiringMatrixMarkers(try WiringReviewDiff.make(active: active, draft: draft), graph: graph)
        } catch { throw .preview(error) }
        var cells: [WiringMatrixCell] = []
        cells.reserveCapacity(rows.count * columns.count)
        for source in rows {
            let batch = Result { () throws(WiringPreviewRefusal) in
                try WiringCandidateBatch(
                    from: source, in: graph, onValidate: onValidate, allowsExistingAtEdgeBound: true
                )
            }
            cells += WiringMatrixCellBuilder.row(
                source, columns: columns, batch: batch, markers: markers
            )
        }
        return WiringMatrix(rows: rows, columns: columns, cells: cells)
    }

    /// Every output port of a routable node of `graph` (each address once), sorted by (node ID, port ID): the
    /// rows a caller windows over.
    static func outputs(in graph: GraphDocument) -> [PortAddress] { ports(.output, in: graph) }

    /// Every input port of a routable node of `graph` (each address once), sorted by (node ID, port ID): the
    /// columns a caller windows over.
    static func inputs(in graph: GraphDocument) -> [PortAddress] { ports(.input, in: graph) }

    /// Toggles `cell` in `draft`: an on cell removes its `existingEdge` through `WiringRemoveComposer.remove`; an
    /// off cell composes `request` on the cell's pair through `WiringDraftComposer.compose` (`request` is
    /// ignored for an on cell). Refused, with nothing changed, exactly as those refuse (`compose(_)` for a toggle
    /// on). A cell from an older window is toggled by what it showed: a toggle on is classified afresh by the
    /// composer; for a toggle off, the draft is checked (`preview`) and an edge with the cell's ID on another
    /// pair of the draft's graph (from or to node or port ID differs; extension bags are ignored, as for the
    /// markers) is refused as `staleCell`, so a reused ID never removes a different wire. An edge the draft's
    /// graph no longer has is refused by `remove` (`notInDraftOrActive` or `unknownEdge`). A draft-removed active
    /// edge is put back by `WiringRemoveComposer.restore`, not by a toggle on, which composes a new edge.
    static func toggle(
        _ cell: WiringMatrixCell, request: WiringMatrixConnect, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        if let edge = cell.existingEdge {
            try refuseStale(edge, of: cell, in: draft, active: active)
            return try WiringRemoveComposer.remove(edge: edge, from: draft, active: active)
        }
        let connect = WiringConnectRequest(
            edge: request.edge, from: cell.from, to: cell.to,
            conversion: request.conversion, feedback: request.feedback
        )
        do { return try WiringDraftComposer.compose(connect, into: draft, active: active) } catch {
            throw .compose(error)
        }
    }

    /// `staleCell` when the draft's graph has `edge` on a pair other than `cell`'s (node and port IDs only; endpoint
    /// extension bags are ignored, as for the markers); `preview` when the draft does not check.
    private static func refuseStale(
        _ edge: EdgeID, of cell: WiringMatrixCell, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) {
        let graph: GraphDocument
        do { graph = try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
        guard let found = graph.edges.first(where: { $0.id == edge }) else { return }
        guard found.from.node == cell.from.node, found.from.port == cell.from.port,
              found.to.node == cell.to.node, found.to.port == cell.to.port else {
            throw .staleCell(edge)
        }
    }

    private static func ports(_ direction: PortDirection, in graph: GraphDocument) -> [PortAddress] {
        var seen: Set<PortAddress> = []
        let addresses = graph.nodes.filter(\.kind.isRoutable).flatMap { node in
            node.ports.filter { $0.direction == direction }.map { PortAddress(node: node.id, port: $0.id) }
        }
        return addresses.filter { seen.insert($0).inserted }.sorted { lhs, rhs in
            (lhs.node.rawValue, lhs.port.rawValue) < (rhs.node.rawValue, rhs.port.rawValue)
        }
    }
}

/// One matrix cell. `from` is the row's port, `to` the column's. Built only by `WiringMatrix.window` (the init is
/// fileprivate to this file).
struct WiringMatrixCell: Hashable, Sendable {
    private(set) var from: PortAddress
    private(set) var to: PortAddress
    private(set) var state: WiringMatrixCellState
    /// The first edge in the draft's graph (graph order, as `classify` picks it) on this pair, by node and port
    /// IDs; `nil` when the pair is not wired. Read through `existingEdge`.
    private(set) var wiredEdge: EdgeID?
    /// The draft-added edges on this pair (review diff `addedEdge` rows), sorted by ID.
    private(set) var draftAdded: [EdgeID]
    /// The active edges on this pair the draft will remove (review diff `removedEdge` rows), sorted by ID.
    private(set) var willRemove: [EdgeID]

    fileprivate init(
        from: PortAddress, to: PortAddress, state: WiringMatrixCellState, wiredEdge: EdgeID?,
        draftAdded: [EdgeID], willRemove: [EdgeID]
    ) {
        self.from = from
        self.to = to
        self.state = state
        self.wiredEdge = wiredEdge
        self.draftAdded = draftAdded
        self.willRemove = willRemove
    }
}

/// Builds cells for `WiringMatrix.window` only. Top-level `private` is file-private: invisible outside this file.
private enum WiringMatrixCellBuilder {
    /// The cells of one row: one shared batch context for the row (`batch`), or the row's whole-list refusal.
    static func row(
        _ source: PortAddress, columns: [PortAddress], batch: Result<WiringCandidateBatch, WiringPreviewRefusal>,
        markers: WiringMatrixMarkers
    ) -> [WiringMatrixCell] {
        switch batch {
        case .failure(let refusal):
            return columns.map { cell(source, $0, state: .uncheckable(refusal), markers: markers) }
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
            from: source, to: column, state: state, wiredEdge: markers.wired[pair],
            draftAdded: markers.added[pair] ?? [], willRemove: markers.removed[pair] ?? []
        )
    }
}
