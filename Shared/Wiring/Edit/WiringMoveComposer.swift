//
//  WiringMoveComposer.swift
//  FluxKlang
//
//  Every move path (a drag end point, keyboard nudges, numeric x/y entry) ends
//  in one `GraphEdit.moveNode` folded into the draft by `DraftEditFold.fold`,
//  so N nudges are one move and a move back to the base position drops it. A
//  move changes only x and y: the extension bag and unknown members of the
//  node's current position are kept, so the paths agree and a return to the
//  base position compares equal. `WiringMoveState` retains each keyboard
//  gesture's decimal offset across calls, so sub-ULP steps are not lost when an
//  intermediate graph point is converted back to Double. Each target goes
//  through one normalization: it is quantized to 1e-12 layout unit, and a
//  coordinate landing on the base position's grid point is the base value.
//  The active graph is only read.
//

import Foundation

/// The caller's grid: one nudge moves `step`, a fine (Shift) nudge `fineStep`. The UI owner (#99/#101)
/// picks the values; both must be finite and greater than zero. Each nudge target lands on the `resolution` grid
/// (`WiringMoveComposer.resolution`), while `WiringMoveState` retains the unrounded accumulated offset.
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

/// Explicit per-gesture precision state for repeated keyboard nudges.
///
/// The accumulated offsets are separate from `DraftEdits`: the draft remains
/// its normalized graph edit list, while callers retain this value for the
/// duration of a nudge sequence and use `draft` for review or history.
struct WiringMoveState: Hashable, Sendable {
    private(set) var draft: DraftEdits
    private var anchors: [NodeID: WiringMoveAnchor] = [:]

    init(draft: DraftEdits) {
        self.draft = draft
    }

    func anchor(for node: NodeID) -> WiringMoveAnchor? { anchors[node] }

    mutating func replaceDraft(_ draft: DraftEdits, anchor: WiringMoveAnchor?, for node: NodeID) {
        self.draft = draft
        anchors[node] = anchor
    }
}

struct WiringMoveAnchor: Hashable, Sendable {
    var horizontal: Double
    var vertical: Double
    var offsetX: Decimal = .zero
    var offsetY: Decimal = .zero
}

/// Moves nodes in drafts. Pure and deterministic; the result is a new `DraftEdits` value.
enum WiringMoveComposer {
    /// The fixed decimal resolution every move target lands on: 1e-12 layout unit. Each coordinate is rounded to
    /// the nearest multiple; a value exactly halfway rounds away from zero, and -0 becomes +0. From 2^42 up every
    /// finite value is already a multiple, so it is kept as is. A coordinate whose grid point is the grid point of
    /// the node's base position (its position in the active graph) is the base value exactly, even when that is off
    /// the grid, so a return to base by any path drops the move. The finer decimal grid keeps successive 0.1 nudges
    /// equivalent to a numeric 0.3 entry.
    static let resolution: Double = 1e-12

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

    /// Numeric entry or drag in a stateful sequence. This resets the node's nudge anchor to the entered target.
    static func move(
        _ node: NodeID, x horizontal: Double, y vertical: Double, in state: WiringMoveState, active: GraphDocument
    ) throws(WiringEditRefusal) -> WiringMoveState {
        let draft = try move(node, x: horizontal, y: vertical, in: state.draft, active: active)
        var moved = state
        let (current, _) = try positions(of: node, in: draft, active: active)
        if let current {
            moved.replaceDraft(
                draft, anchor: WiringMoveAnchor(horizontal: current.x, vertical: current.y), for: node
            )
        } else {
            moved.replaceDraft(draft, anchor: nil, for: node)
        }
        return moved
    }

    /// `state` with `node` moved one grid step (one `fineStep` for a fine nudge, the Shift path) in the nudge's
    /// direction, normalized as `move` normalizes. The retained anchor makes repeated sub-ULP steps accumulate.
    /// Refused like `move`, with `unplacedNode` when the node has no position, or `nonFinitePosition` on overflow.
    static func nudge(
        _ node: NodeID, _ nudge: WiringNudge, grid: WiringMoveGrid, in state: WiringMoveState, active: GraphDocument
    ) throws(WiringEditRefusal) -> WiringMoveState {
        let (found, base) = try positions(of: node, in: state.draft, active: active)
        guard let current = found else { throw .unplacedNode(node) }
        let distance = grid.distance(fine: nudge.fine)
        var anchor = state.anchor(for: node) ?? WiringMoveAnchor(horizontal: current.x, vertical: current.y)
        guard
            let horizontalOffset = accumulated(
                anchor.offsetX, distance: distance, direction: nudge.direction.offset.dx
            ),
            let verticalOffset = accumulated(
                anchor.offsetY, distance: distance, direction: nudge.direction.offset.dy
            ),
            let horizontal = translated(anchor.horizontal, by: horizontalOffset),
            let vertical = translated(anchor.vertical, by: verticalOffset),
            horizontal.isFinite, vertical.isFinite
        else {
            // Outside Decimal's range, fall back to coordinate arithmetic and start a fresh anchor.
            let horizontal = current.x + distance * nudge.direction.offset.dx
            let vertical = current.y + distance * nudge.direction.offset.dy
            guard horizontal.isFinite, vertical.isFinite else { throw .nonFinitePosition(node) }
            let point = placed(current, base: base, horizontal, vertical)
            var moved = state
            let draft = try commit(node, to: point, in: state.draft, active: active)
            moved.replaceDraft(draft, anchor: WiringMoveAnchor(horizontal: point.x, vertical: point.y), for: node)
            return moved
        }
        anchor.offsetX = horizontalOffset
        anchor.offsetY = verticalOffset
        let point = placed(current, base: base, horizontal, vertical)
        var moved = state
        let draft = try commit(node, to: point, in: state.draft, active: active)
        moved.replaceDraft(draft, anchor: anchor, for: node)
        return moved
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
        // From 2^42 up the spacing of doubles already exceeds `resolution`; preserve the exact value there.
        guard value.magnitude < 0x1p42 else { return value }
        guard var decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
            return value
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 12, .plain)
        let result = Double(rounded.description) ?? value
        return result == 0 ? 0 : result
    }

    /// Accumulates one signed nudge without converting the intermediate result to Double.
    private static func accumulated(_ offset: Decimal, distance: Double, direction: Double) -> Decimal? {
        guard direction != 0 else { return offset }
        guard let step = Decimal(string: String(direction * distance), locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var result = Decimal()
        var previous = offset
        var delta = step
        guard NSDecimalAdd(&result, &previous, &delta, .plain) == .noError else { return nil }
        return result
    }

    /// Adds a retained decimal offset to its anchor, converting only the final target to Double.
    private static func translated(_ coordinate: Double, by offset: Decimal) -> Double? {
        guard let origin = Decimal(string: String(coordinate), locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var result = Decimal()
        var base = origin
        var delta = offset
        guard NSDecimalAdd(&result, &base, &delta, .plain) == .noError else { return nil }
        guard let translated = Double(result.description), translated.isFinite else { return nil }
        return translated
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
