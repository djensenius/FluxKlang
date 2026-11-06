//
//  WiringStaleDraft.swift
//  FluxKlang
//
//  A draft is stale when its base revision is not the active revision. It is
//  only reported ("Based on rev 42; active is 43"); it is never rebased.
//

/// The report that a draft was based on a revision other than the active one.
struct WiringStaleDraft: Hashable, Sendable, CustomStringConvertible {
    private(set) var draft: DraftID
    /// The revision the draft's edits were made against.
    private(set) var baseRevision: ContractRevision
    /// The caller-supplied active revision.
    private(set) var activeRevision: ContractRevision

    private init(draft: DraftID, baseRevision: ContractRevision, activeRevision: ContractRevision) {
        self.draft = draft
        self.baseRevision = baseRevision
        self.activeRevision = activeRevision
    }

    /// "Based on rev 42; active is 43".
    var description: String { "Based on rev \(baseRevision); active is \(activeRevision)" }

    /// The stale report for `draft`, or `nil` when its base revision is exactly `activeRevision`.
    static func check(_ draft: DraftEdits, activeRevision: ContractRevision) -> WiringStaleDraft? {
        guard draft.baseRevision != activeRevision else { return nil }
        return WiringStaleDraft(draft: draft.id, baseRevision: draft.baseRevision, activeRevision: activeRevision)
    }
}
