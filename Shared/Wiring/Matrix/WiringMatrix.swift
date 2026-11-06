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
//  list and the port picker make. The active graph is only read.
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
    /// changed, when it has more than `maximumRows` rows or `maximumColumns` columns (`windowTooLarge`) or the
    /// draft does not check against `active` (`preview`). A row whose whole destination list would be refused
    /// gets that refusal in every cell (`.uncheckable`).
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
            graph = try WiringDraftGraph.make(active: active, draft: draft).graph
            markers = WiringMatrixMarkers(try WiringReviewDiff.make(active: active, draft: draft))
        } catch { throw .preview(error) }
        var cells: [WiringMatrixCell] = []
        cells.reserveCapacity(rows.count * columns.count)
        for source in rows {
            let batch = Result { () throws(WiringPreviewRefusal) in
                try WiringCandidateBatch(from: source, in: graph, onValidate: onValidate)
            }
            cells += WiringMatrixCellBuilder.row(source, columns: columns, batch: batch, markers: markers)
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
    /// on). The cell is not re-checked: a cell from an older window is toggled by what it showed, and the
    /// composers refuse what no longer applies. A draft-removed active edge is put back by
    /// `WiringRemoveComposer.restore`, not by a toggle on, which composes a new edge.
    static func toggle(
        _ cell: WiringMatrixCell, request: WiringMatrixConnect, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        if let edge = cell.existingEdge {
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
