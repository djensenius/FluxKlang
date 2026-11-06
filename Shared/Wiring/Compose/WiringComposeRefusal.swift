//
//  WiringComposeRefusal.swift
//  FluxKlang
//
//  Why a connect cannot be composed into a draft. A refusal never changes the
//  draft or the active graph: the caller keeps exactly what it passed in.
//

/// Why `WiringDraftComposer` refuses to compose a connect (or list a draft's destinations).
enum WiringComposeRefusal: Error, Hashable, Sendable {
    /// The classifier, or the draft against the active graph, was refused (unknown endpoint,
    /// invalid supplied conversion/feedback, bounds, a foreign graph, a stale draft
    /// (`draftBaseMismatch`, never rebased; `WiringStaleDraft` words it), a draft that does not apply, …),
    /// exactly as `WiringReviewDiff.make` refuses the same draft.
    case preview(WiringPreviewRefusal)
    /// The pair needs an explicit conversion and the caller supplied none (or one that did not resolve it).
    case conversionRequired(sourceChannels: Int, destinationChannels: Int)
    /// The wire closes a cycle and the caller supplied no explicit feedback.
    case feedbackRequired(cycle: [NodeID])
    /// The caller supplied a conversion the pair does not need; it is refused, never silently dropped.
    case conversionNotNeeded(EdgeConversion)
    /// The caller supplied feedback the pair does not need; it is refused, never silently dropped.
    case feedbackNotNeeded(EdgeFeedback)
    /// The same wire already exists in the draft's graph.
    case existing(EdgeID)
    /// The destination is listed but not selectable.
    case disabled(WiringDisabledReason)
    /// The destination is not offered for this source (wrong direction).
    case notOffered
    /// An endpoint is on this observed shortcut node, which is never routable.
    case notRoutable(NodeID)
    /// `GraphEdit.validateBatch` rejected the draft's edits followed by the new connect (never for
    /// `bounds`, which is `.preview(.bounds)`).
    case batchInvalid(GraphEditError)
    /// The batch is consistent, but the connect does not apply to the draft's graph (for example its edge ID
    /// is taken; never for `bounds`, which is `.preview(.bounds)`).
    case connectDoesNotApply(GraphEditError)
}
