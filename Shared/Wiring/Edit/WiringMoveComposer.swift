//
//  WiringMoveComposer.swift
//  FluxKlang
//
//  Every move path (a drag end point, keyboard nudges, numeric x/y entry) ends
//  in one `GraphEdit.moveNode` folded into the draft by `DraftEditFold.fold`,
//  so N nudges are one move and a move back to the base position drops it. A
//  move changes only x and y: the extension bag and unknown members of the
//  node's current position are kept, so the paths agree and a return to the
//  base position compares equal. The active graph is only read.
//

/// The caller's grid: one nudge moves `step`, a fine (Shift) nudge `fineStep`. The UI owner (#99/#101)
/// picks the values; both must be finite and greater than zero.
struct WiringMoveGrid: Hashable, Sendable {
    private(set) var step: Double
    private(set) var fineStep: Double

    private init(step: Double, fineStep: Double) {
        self.step = step
        self.fineStep = fineStep
    }

    /// The grid, or `invalidGrid` when either step is NaN, infinite, zero or negative.
    static func make(step: Double, fineStep: Double) throws(WiringEditRefusal) -> WiringMoveGrid {
        guard step.isFinite, step > 0, fineStep.isFinite, fineStep > 0 else { throw .invalidGrid }
        return WiringMoveGrid(step: step, fineStep: fineStep)
    }

    /// The step of one nudge: `fineStep` when `fine`, `step` otherwise.
    func distance(fine: Bool) -> Double { fine ? fineStep : step }
}

/// A keyboard nudge direction in layout space, where x grows to the right and y grows downward.
enum WiringNudgeDirection: Hashable, Sendable, CaseIterable {
    case leftward
    case rightward
    case upward
    case downward

    /// The (dx, dy) unit offset.
    var offset: (dx: Double, dy: Double) {
        switch self {
        case .leftward: (-1, 0)
        case .rightward: (1, 0)
        case .upward: (0, -1)
        case .downward: (0, 1)
        }
    }
}

/// One keyboard nudge: an arrow key, with Shift for a fine step.
struct WiringNudge: Hashable, Sendable {
    var direction: WiringNudgeDirection
    /// Shift: move one `fineStep` instead of one `step`.
    var fine: Bool

    init(_ direction: WiringNudgeDirection, fine: Bool = false) {
        self.direction = direction
        self.fine = fine
    }
}

/// Moves nodes in drafts. Pure and deterministic; the result is a new `DraftEdits` value.
enum WiringMoveComposer {
    /// `draft` with `node` moved to (`x`, `y`): the drag end point and the numeric x/y entry path. Refused, with
    /// nothing changed, when a coordinate is not finite (`nonFinitePosition`), the draft does not check against
    /// `active` (`preview`), the node is not in the draft's graph (`unknownNode`) or the fold refuses (`fold`).
    static func move(
        _ node: NodeID, x horizontal: Double, y vertical: Double, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        guard horizontal.isFinite, vertical.isFinite else { throw .nonFinitePosition(node) }
        let current = try currentPosition(of: node, in: draft, active: active)
        return try commit(node, to: placed(current, horizontal, vertical), in: draft, active: active)
    }

    /// `draft` with `node` moved one grid step (one `fineStep` for a fine nudge, the Shift path) in the nudge's
    /// direction from its position in the draft's graph. Refused like `move`, and with `unplacedNode` when the
    /// node has no position, or `nonFinitePosition` when the step overflows a coordinate.
    static func nudge(
        _ node: NodeID, _ nudge: WiringNudge, grid: WiringMoveGrid, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        guard let current = try currentPosition(of: node, in: draft, active: active) else {
            throw .unplacedNode(node)
        }
        let distance = grid.distance(fine: nudge.fine)
        let horizontal = current.x + nudge.direction.offset.dx * distance
        let vertical = current.y + nudge.direction.offset.dy * distance
        guard horizontal.isFinite, vertical.isFinite else { throw .nonFinitePosition(node) }
        return try commit(node, to: placed(current, horizontal, vertical), in: draft, active: active)
    }

    /// The node's position in the draft's graph (`nil` when unplaced), after checking the draft.
    private static func currentPosition(
        of node: NodeID, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> GraphPoint? {
        let graph: GraphDocument
        do { graph = try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
        guard let found = graph.node(node) else { throw .unknownNode(node) }
        return found.position
    }

    /// `current` with only x and y replaced (a new point when the node is unplaced).
    private static func placed(_ current: GraphPoint?, _ horizontal: Double, _ vertical: Double) -> GraphPoint {
        var point = current ?? GraphPoint(x: horizontal, y: vertical)
        point.x = horizontal
        point.y = vertical
        return point
    }

    /// Folds the one move into the draft's edits.
    private static func commit(
        _ node: NodeID, to position: GraphPoint, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        let edits: [GraphEdit]
        do {
            edits = try DraftEditFold.fold([.moveNode(node, to: position)], onto: draft.edits, base: active)
        } catch { throw .fold(error) }
        var moved = draft
        moved.edits = edits
        return moved
    }
}
