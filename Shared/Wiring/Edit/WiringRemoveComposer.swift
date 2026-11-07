//
//  WiringRemoveComposer.swift
//  FluxKlang
//
//  Every remove path (the Delete key, the row "Remove" button, a matrix toggle
//  off and the VoiceOver "Remove from draft" action) calls `remove`, which folds
//  one `GraphEdit.disconnect` into the draft: an active edge gets a disconnect,
//  a draft-added edge has its connect folded away. "Restore" re-adds a
//  draft-removed active edge with its identical value, which cancels the
//  disconnect. The active graph is only read.
//

/// Removes and restores edges in drafts. Pure and deterministic; the result is a new `DraftEdits` value.
enum WiringRemoveComposer {
    /// `draft` without `edge`. Refused, with nothing changed, when the draft does not check against `active`
    /// (`preview`), the active edge is already removed by the draft (`notInDraftOrActive`), no graph has the ID
    /// (`unknownEdge`) or the fold refuses (`fold`).
    static func remove(
        edge: EdgeID, from draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        let graph = try draftGraph(draft, active: active)
        guard graph.edges.contains(where: { $0.id == edge }) else {
            if active.edges.contains(where: { $0.id == edge }) { throw .notInDraftOrActive(edge) }
            throw .unknownEdge(edge)
        }
        return try fold(.disconnect(edge), into: draft, active: active)
    }

    /// `draft` with the active `edge` it removes connected again, identical to the active edge, so the fold
    /// cancels its disconnect. Refused, with nothing changed, when the draft does not check (`preview`), the
    /// edge is still in the draft's graph (`notInDraftOrActive`), the active graph has no such edge
    /// (`unknownEdge`), or the fold refuses (`fold`; for example `endpointRemoved` when the draft removes one of
    /// the edge's nodes).
    static func restore(
        edge: EdgeID, into draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        let graph = try draftGraph(draft, active: active)
        guard !graph.edges.contains(where: { $0.id == edge }) else { throw .notInDraftOrActive(edge) }
        guard let original = active.edges.first(where: { $0.id == edge }) else { throw .unknownEdge(edge) }
        return try fold(.connect(original), into: draft, active: active)
    }

    private static func draftGraph(
        _ draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> GraphDocument {
        do { return try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
    }

    private static func fold(
        _ edit: GraphEdit, into draft: DraftEdits, active: GraphDocument
    ) throws(WiringEditRefusal) -> DraftEdits {
        let edits: [GraphEdit]
        do { edits = try DraftEditFold.fold([edit], onto: draft.edits, base: active) } catch { throw .fold(error) }
        var folded = draft
        folded.edits = edits
        return folded
    }
}
