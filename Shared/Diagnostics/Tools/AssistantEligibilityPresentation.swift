//
//  AssistantEligibilityPresentation.swift
//  FluxKlang
//
//  What the assistant controls show for an `AssistantEligibility`, as the "Assistant eligibility" table in
//  docs/transformation/workspace-ux/status-diagnostics.md describes. Pure values with fixed English text.
//

/// The assistant controls for one eligibility, following the "Assistant eligibility" table in
/// docs/transformation/workspace-ux/status-diagnostics.md. It only describes the assistant's own buttons and text.
/// It has nothing that could hide or disable a manual diagnostics path; the doc keeps those "Unaffected" throughout.
///
/// A cloud provider gets the same text as an unready model: the doc has one "Not eligible" row and says
/// "There is no cloud fallback", so the local assistant is simply unavailable here. While busy, "Explaining..."
/// with Cancel takes the place of the "Explain" buttons.
struct AssistantEligibilityPresentation: Equatable, Sendable {
    static let unavailableMessage = "Assistant unavailable on this device"
    static let busyMessage = "Explaining..."

    /// Whether the "Explain" buttons are shown.
    let showsExplainButtons: Bool
    /// The assistant's status text, if any.
    let message: String?
    /// Whether a Cancel button for the running request is shown.
    let showsCancel: Bool

    init(_ eligibility: AssistantEligibility) {
        switch eligibility {
        case .eligible:
            self.init(showsExplainButtons: true, message: nil, showsCancel: false)
        case .notEligible(.cloudProvider), .notEligible(.modelUnavailable):
            self.init(showsExplainButtons: false, message: Self.unavailableMessage, showsCancel: false)
        case .off:
            self.init(showsExplainButtons: false, message: nil, showsCancel: false)
        case .busy:
            self.init(showsExplainButtons: false, message: Self.busyMessage, showsCancel: true)
        }
    }

    private init(showsExplainButtons: Bool, message: String?, showsCancel: Bool) {
        self.showsExplainButtons = showsExplainButtons
        self.message = message
        self.showsCancel = showsCancel
    }
}
