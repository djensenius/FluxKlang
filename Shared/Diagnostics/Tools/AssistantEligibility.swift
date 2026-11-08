//
//  AssistantEligibility.swift
//  FluxKlang
//
//  Whether the local assistant may be offered, as a pure function of four facts.
//  A cloud provider is never eligible, whatever the other facts say.
//

/// The facts `AssistantEligibility.evaluate` decides from.
struct AssistantFacts: Equatable, Sendable {
    /// The user switched the assistant on.
    var userEnabled: Bool
    /// The on-device model is ready to answer.
    var modelReady: Bool
    /// The assistant is already working on a request.
    var busy: Bool
    /// The provider would send text off the device.
    var providerIsCloud: Bool
}

enum AssistantEligibility: Equatable, Sendable {
    /// Why an enabled assistant cannot be offered.
    enum Reason: Equatable, Sendable {
        case cloudProvider
        case modelUnavailable
    }

    case eligible
    case notEligible(Reason)
    case off
    case busy

    /// Precedence: not enabled is `off`; then a cloud provider is `notEligible(.cloudProvider)`; then a model
    /// that is not ready is `notEligible(.modelUnavailable)`; then `busy`; otherwise `eligible`.
    static func evaluate(_ facts: AssistantFacts) -> AssistantEligibility {
        if !facts.userEnabled { return .off }
        if facts.providerIsCloud { return .notEligible(.cloudProvider) }
        if !facts.modelReady { return .notEligible(.modelUnavailable) }
        if facts.busy { return .busy }
        return .eligible
    }
}
