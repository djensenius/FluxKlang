//
//  ReviewDefaultAction.swift
//  FluxKlang
//
//  The default action of the review sheet and what its keys resolve to (#99 RV1). The default is `keepAsDraft`
//  unless every safety condition holds; Escape never activates.
//

/// What the sheet does when its default is taken.
enum ReviewDefaultAction: Hashable, Sendable {
    /// Leave the draft as it is; nothing is activated.
    case keepAsDraft
    /// Start the activation of the draft.
    case activate

    /// `activate` only for a review that can be activated, has no hazard at all, is not the assistant's and is
    /// awaiting review; every other combination is `keepAsDraft`.
    static func choose(
        canActivate: Bool, hasHazards: Bool, provenance: ReviewProvenance, phase: ActivationPhase
    ) -> ReviewDefaultAction {
        guard canActivate else { return .keepAsDraft }
        guard !hasHazards else { return .keepAsDraft }
        guard !provenance.needsExtraConfirmation else { return .keepAsDraft }
        guard phase == .awaitingReview else { return .keepAsDraft }
        return .activate
    }
}

/// The two keys that resolve the sheet.
enum ReviewKeyBinding: Hashable, Sendable, CaseIterable {
    case returnKey
    case escapeKey

    /// Return takes the default; Escape always keeps the draft.
    func resolve(defaultAction: ReviewDefaultAction) -> ReviewDefaultAction {
        switch self {
        case .returnKey: defaultAction
        case .escapeKey: .keepAsDraft
        }
    }
}
