//
//  WiringStaleDraft.swift
//  FluxKlang
//
//  A draft of the active graph is stale when its base revision is not the active
//  revision. It is only reported ("Based on rev 42; active is 43"); it is never
//  rebased. The composer and the review diff refuse such a draft with
//  `WiringPreviewRefusal.draftBaseMismatch`; this is its display form.
//

/// The report that a draft of the active graph was based on a revision other than the active one.
struct WiringStaleDraft: Hashable, Sendable, CustomStringConvertible {
    private(set) var draft: DraftID
    /// The revision the draft's edits were made against.
    private(set) var baseRevision: ContractRevision
    /// The active graph's revision.
    private(set) var activeRevision: ContractRevision

    private init(draft: DraftID, baseRevision: ContractRevision, activeRevision: ContractRevision) {
        self.draft = draft
        self.baseRevision = baseRevision
        self.activeRevision = activeRevision
    }

    /// "Based on rev 42; active is 43".
    var description: String { "Based on rev \(baseRevision); active is \(activeRevision)" }

    /// The refusal the composer and the review diff give this draft.
    var refusal: WiringPreviewRefusal { .draftBaseMismatch(draft: baseRevision, active: activeRevision) }

    /// The stale report for `draft` against `active`, or `nil` when its base revision is exactly the
    /// active revision. A draft of another graph is `nil` too: it is a graph mismatch (refused as
    /// `draftGraphMismatch`), and the revisions of two graphs are not comparable.
    static func check(_ draft: DraftEdits, active: GraphDocument) -> WiringStaleDraft? {
        guard draft.graph == active.id, draft.baseRevision != active.revision else { return nil }
        return WiringStaleDraft(draft: draft.id, baseRevision: draft.baseRevision, activeRevision: active.revision)
    }
}
