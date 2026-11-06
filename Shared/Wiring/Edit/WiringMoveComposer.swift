//
//  WiringMoveComposer.swift
//  FluxKlang
//
//  Every move path (a drag end point, keyboard nudges, numeric x/y entry) ends
//  in one `GraphEdit.moveNode` folded into the draft by `DraftEditFold.fold`,
//  so N nudges are one move and a move back to the base position drops it. A
//  move changes only x and y: the extension bag and unknown members of the
//  node's current position are kept, so the paths agree and a return to the
//  base position compares equal. Every target coordinate goes through one
//  normalization (`WiringMoveComposer.resolution`): it is quantized to 1/1024
//  layout unit, and a coordinate that lands on the base position's grid point
//  is the base value exactly, so floating-point drift cannot keep a move alive.
//  The active graph is only read.
//

/// The caller's grid: one nudge moves `step`, a fine (Shift) nudge `fineStep`. The UI owner (#99/#101)
/// picks the values; both must be finite and greater than zero. Nudge targets land on the 1/1024 resolution
/// (`WiringMoveComposer.resolution`), so a step below half of it does not move a node, and N nudges of a step that
/// is not a multiple of it can differ from one move by N steps (each nudge rounds).
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
    /// The fixed binary resolution every move target lands on: 1/1024 layout unit (a power of two, so the grid
    /// points and the scaling are exact). Each coordinate is rounded to the nearest multiple; a value exactly
    /// halfway rounds away from zero, and -0 becomes +0. From 2^42 up every finite value is already a multiple, so
    /// it is kept as is. A coordinate whose grid point is the grid point of the node's base position (its position
    /// in the active graph) is the base value exactly, even when that is off the grid (such as 0.1), so a return
    /// to base by any path drops the move.
    static let resolution: Double = 0x1p-10

    /// `draft` with `node` moved to (`x`, `y`), normalized to `resolution` (snapped to the base position when it
    /// lands on its grid point): the drag end point and the numeric x/y entry path. Refused, with
    /// nothing changed, when a coordinate is not finite (`nonFinitePosition`), the draft does not check against
    /// `active` (`preview`), the node is not in the draft's graph (`unknownNode`) or the fold refuses (`fold`).
    static func move(
        _ node: NodeID, x horizontal: Double, y vertical: Double, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        guard horizontal.isFinite, vertical.isFinite else { throw .nonFinitePosition(node) }
        let (current, base) = try positions(of: node, in: draft, active: active)
        return try commit(node, to: placed(current, base: base, horizontal, vertical), in: draft, active: active)
    }

    /// `draft` with `node` moved one grid step (one `fineStep` for a fine nudge, the Shift path) in the nudge's
    /// direction from its position in the draft's graph, normalized as `move` normalizes. Refused like `move`, and
    /// with `unplacedNode` when the
    /// node has no position, or `nonFinitePosition` when the step overflows a coordinate.
    static func nudge(
        _ node: NodeID, _ nudge: WiringNudge, grid: WiringMoveGrid, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        let (found, base) = try positions(of: node, in: draft, active: active)
        guard let current = found else { throw .unplacedNode(node) }
        let distance = grid.distance(fine: nudge.fine)
        let horizontal = current.x + nudge.direction.offset.dx * distance
        let vertical = current.y + nudge.direction.offset.dy * distance
        guard horizontal.isFinite, vertical.isFinite else { throw .nonFinitePosition(node) }
        return try commit(node, to: placed(current, base: base, horizontal, vertical), in: draft, active: active)
    }

    /// The node's position in the draft's graph (`nil` when unplaced), after checking the draft, and its base
    /// position in the active graph (`nil` when the active graph has no such node or it is unplaced there).
    private static func positions(
        of node: NodeID, in draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> (current: GraphPoint?, base: GraphPoint?) {
        let graph: GraphDocument
        do { graph = try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
        guard let found = graph.node(node) else { throw .unknownNode(node) }
        return (found.position, active.node(node)?.position)
    }

    /// `current` with only x and y replaced (a new point when the node is unplaced), each normalized: the one
    /// normalization of all three paths.
    private static func placed(
        _ current: GraphPoint?, base: GraphPoint?, _ horizontal: Double, _ vertical: Double
    ) -> GraphPoint {
        var point = current ?? GraphPoint(x: horizontal, y: vertical)
        point.x = normalized(horizontal, base: base?.x)
        point.y = normalized(vertical, base: base?.y)
        return point
    }

    /// `value` on the `resolution` grid, or exactly `base` when both land on the same grid point.
    private static func normalized(_ value: Double, base: Double?) -> Double {
        let target = quantized(value)
        if let base, quantized(base) == target { return base }
        return target
    }

    /// The nearest multiple of `resolution` (halfway away from zero; -0 becomes +0). Finite in, finite out.
    private static func quantized(_ value: Double) -> Double {
        // From 2^42 up the spacing of doubles is at least 2^-10, and scaling up could overflow.
        guard value.magnitude < 0x1p42 else { return value }
        return (value / resolution).rounded(.toNearestOrAwayFromZero) * resolution + 0
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
