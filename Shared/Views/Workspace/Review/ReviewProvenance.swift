//
//  ReviewProvenance.swift
//  FluxKlang
//
//  Who made the draft under review (#99 RV1). Provenance shows as a badge on the review sheet; a draft the assistant
//  made needs one more confirmation, so it never becomes the default action.
//

/// Who made the draft the review sheet shows.
enum ReviewProvenance: Hashable, Sendable, CaseIterable {
    case human
    case controller
    case assistant

    /// The badge the sheet shows.
    var badgeText: String {
        switch self {
        case .human: "Made by you"
        case .controller: "Made from a controller"
        case .assistant: "Suggested by the assistant"
        }
    }

    /// True when activating needs one more explicit confirmation (the assistant's drafts).
    var needsExtraConfirmation: Bool {
        switch self {
        case .human, .controller: false
        case .assistant: true
        }
    }
}
