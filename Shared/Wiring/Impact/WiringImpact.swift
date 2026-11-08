//
//  WiringImpact.swift
//  FluxKlang
//
//  What one prospective wiring gesture would change before it is committed (#101 WPV1). The gesture is composed
//  onto the draft by the existing composer; the review diff and the validation errors of the draft graph before and
//  after are compared. Nothing is drawn, committed, sent or activated, the input draft is a value and never mutated,
//  and the active graph is only read. A caller who commits uses `after`, the composer's own value.
//

/// The impact of one gesture on a draft. Built only by `make`.
struct WiringImpact: Equatable, Sendable {
    /// The draft after the gesture: the exact value the composer returned, or the input draft for `.none`.
    private(set) var after: DraftEdits
    /// The review rows the gesture adds, cancels or revises, sorted by kind and ID bytes.
    private(set) var rows: [WiringImpactRow]
    /// The problems the draft graph has after the gesture and did not have before, sorted by key bytes.
    private(set) var introduced: [WiringImpactProblem]
    /// The problems the draft graph had before the gesture and no longer has, sorted by key bytes.
    private(set) var resolved: [WiringImpactProblem]
    /// One fixed English sentence of the counts above.
    private(set) var summary: String

    /// True when the gesture changes no row and no problem.
    var isEmpty: Bool { rows.isEmpty && introduced.isEmpty && resolved.isEmpty }

    private init(
        after: DraftEdits, rows: [WiringImpactRow], problems: WiringImpactProblems.Delta
    ) {
        self.after = after
        self.rows = rows
        introduced = problems.introduced
        resolved = problems.resolved
        summary = WiringImpactSummary.make(
            rows: rows, introduced: problems.introduced.count, resolved: problems.resolved.count
        )
    }

    /// Previews `gesture` on `draft`. Refused, with nothing changed and in this order: the draft does not check
    /// against `active` (`preview`); the draft graph's validation stops before checking wires
    /// (`baselineUncheckable`); the composer refuses the gesture (`compose`, `edit` or `node`, its own refusal
    /// unchanged); the graph after the gesture cannot be checked (`resultUncheckable`). `.none` runs the first two
    /// checks and returns an empty impact. A gesture the composer accepts that changes nothing also returns an empty
    /// impact, because the delta is computed from the two graphs and not from the edit lists.
    static func make(
        _ gesture: WiringImpactGesture, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> WiringImpact {
        let baseline = try draftGraph(draft, active: active)
        let beforeErrors = baseline.validationErrors()
        if let blocking = uncheckable(beforeErrors) { throw .baselineUncheckable(blocking) }
        if case .none = gesture {
            return WiringImpact(after: draft, rows: [], problems: WiringImpactProblems.unchanged)
        }
        let composed = try compose(gesture, draft: draft, active: active)
        let afterErrors = try draftGraph(composed, active: active).validationErrors()
        if let blocking = uncheckable(afterErrors) { throw .resultUncheckable(blocking) }
        let rows = WiringImpactRowDelta.rows(
            before: try reviewRows(draft, active: active), after: try reviewRows(composed, active: active)
        )
        let problems = WiringImpactProblems.delta(before: beforeErrors, after: afterErrors)
        return WiringImpact(after: composed, rows: rows, problems: problems)
    }

    private static func draftGraph(
        _ draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> GraphDocument {
        do { return try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
    }

    private static func reviewRows(
        _ draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> [WiringReviewChange] {
        do { return try WiringReviewDiff.make(active: active, draft: draft).changes } catch { throw .preview(error) }
    }

    /// The first error whose scope the inspector's classifier calls `.uncheckable`.
    private static func uncheckable(_ errors: [GraphValidationError]) -> GraphValidationError? {
        errors.first { error in
            if case .uncheckable = WiringInspectorProblem.classify(error).scope { return true }
            return false
        }
    }

    /// `.none` is answered by `make` before this runs; its case is listed so the switch needs no fallback. The
    /// `.preview` mapping in `reviewRows` and in the second `draftGraph` call is likewise unreachable (the same
    /// draft and active graph already formed once); it exists because typed throws need a mapping for the error.
    private static func compose(
        _ gesture: WiringImpactGesture, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        switch gesture {
        case .none:
            return draft
        case .connect(let request): return try connect(request, draft: draft, active: active)
        case .removeEdge(let edge): return try removeEdge(edge, draft: draft, active: active)
        case .restoreEdge(let edge): return try restoreEdge(edge, draft: draft, active: active)
        case .moveNode(let node, let horizontal, let vertical):
            return try moveNode(node, x: horizontal, y: vertical, draft: draft, active: active)
        case .addNode(let node): return try addNode(node, draft: draft, active: active)
        case .removeNode(let node): return try removeNode(node, draft: draft, active: active)
        }
    }

    private static func connect(
        _ request: WiringConnectRequest, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        do { return try WiringDraftComposer.compose(request, into: draft, active: active) } catch {
            throw .compose(error)
        }
    }

    private static func removeEdge(
        _ edge: EdgeID, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        do { return try WiringRemoveComposer.remove(edge: edge, from: draft, active: active) } catch {
            throw .edit(error)
        }
    }

    private static func restoreEdge(
        _ edge: EdgeID, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        do { return try WiringRemoveComposer.restore(edge: edge, into: draft, active: active) } catch {
            throw .edit(error)
        }
    }

    private static func moveNode(
        _ node: NodeID, x horizontal: Double, y vertical: Double, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        do { return try WiringMoveComposer.move(node, x: horizontal, y: vertical, in: draft, active: active) } catch {
            throw .edit(error)
        }
    }

    private static func addNode(
        _ node: GraphNode, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        do { return try WiringNodeComposer.add(node, to: draft, active: active) } catch { throw .node(error) }
    }

    private static func removeNode(
        _ node: NodeID, draft: DraftEdits, active: GraphDocument
    ) throws(WiringImpactRefusal) -> DraftEdits {
        do { return try WiringNodeComposer.remove(node: node, from: draft, active: active) } catch {
            throw .node(error)
        }
    }
}
