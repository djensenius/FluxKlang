//
//  WiringPreviewRefusal.swift
//  FluxKlang
//
//  Why a wiring preview (a connection candidate or a review diff) cannot be
//  produced. A refusal is never a connection class: the caller asked about
//  something the graph cannot answer, and nothing is changed.
//

/// Why a connection candidate or a review diff is refused.
enum WiringPreviewRefusal: Error, Hashable, Sendable {
    /// An endpoint names a node the graph does not contain.
    case unknownNode(NodeID)
    /// An endpoint names a port its (routable) node does not declare.
    case unknownPort(PortAddress)
    /// The caller-supplied conversion does not fit the pair (contract `invalidConversion`).
    case invalidConversion(EdgeConversion)
    /// The caller-supplied feedback is not causal and capped (contract `invalidFeedback`).
    case invalidFeedback(EdgeFeedback)
    /// An endpoint node's ports are already rejected by the contract (an unconfirmed or
    /// invalid channel count, a gain/mute shape error, or a repeated port ID), so no class can be vouched for.
    /// Adopted legacy graphs see this until review confirms their channel counts.
    case endpointUncheckable(node: NodeID)
    /// No temporary probe edge ID could be formed (defensive; the suffix is always valid).
    case probeUnavailable(suffix: Int)
    /// The graph, or the graph with the candidate or draft applied, exceeds `ProjectGraphLimits`.
    case bounds(ProjectGraphLimitError)
    /// The contract's validation stops before checking any wire, so no class can be derived.
    case uncheckableGraph(GraphValidationError)
    /// The candidate introduced a validation error no connection class accounts for.
    case unexpectedValidation(GraphValidationError)
    /// The draft edits a different graph than the active one.
    case draftGraphMismatch(draft: GraphID, active: GraphID)
    /// The draft was made against a different revision than the active one; it is never rebased here.
    case draftBaseMismatch(draft: ContractRevision, active: ContractRevision)
    /// The active graph repeats a node ID, so a change to it cannot be attributed.
    case ambiguousNode(NodeID)
    /// The active graph repeats an edge ID, so a change to it cannot be attributed.
    case ambiguousEdge(EdgeID)
    /// `active.applying(draft.edits)` refused the draft for a reason other than bounds.
    case draftDoesNotApply(GraphEditError)
}
