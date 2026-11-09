//
//  SetupApplyRefusal.swift
//  FluxKlang
//
//  Why a requested setup apply is refused before it produces a candidate mapping change. A refusal returns no value:
//  the state, the review, the decisions and the document are values and stay as they were.
//

/// Why `SetupApplyGuard.apply` produced no change. Equality follows the cases and their payloads;
/// `RigReviewRefusal` compares by value.
enum SetupApplyRefusal: Error, Equatable, Sendable {
    /// The flow is running or suspended: no apply was requested.
    case flowNotEnded
    /// The operator stayed manual: there is nothing to apply.
    case manualChosen
    /// The facts the apply was requested under no longer match the current facts.
    case factsChanged
    /// `RigMappingReview.apply` refused (a stale document, a decision or a channel conflict).
    case review(RigReviewRefusal)
}
