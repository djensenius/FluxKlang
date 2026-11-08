/// Why the provider is being replaced, as a fixed set of cases the user can be told about.
enum AssistantFallbackReason: CaseIterable, Equatable, Sendable {
    case deviceNotEligible
    case turnedOff
    case modelNotReady
    case osUnsupported
    case providerUnavailable
    case generationFailed
    case emptyResponse
}

/// What the user is told about one allowed fallback, tied to the exact (from, to) pair. The policy builds it; the
/// initializer is internal so the three files can share it, which also means other code in the module could build
/// one, and `matches(from:to:)` is the check a caller makes before showing it for a pair.
struct AssistantFallbackDisclosure: Equatable, Sendable {
    let from: AssistantProvider
    let to: AssistantProvider
    let reason: AssistantFallbackReason
    /// True when the destination is the cloud provider.
    let dataLeavesDevice: Bool
    /// True only for an on-device to cloud fallback that carried the exact consent.
    let consentUsed: Bool

    /// Whether this disclosure was made for exactly this pair, in this direction.
    func matches(from candidateFrom: AssistantProvider, to candidateTo: AssistantProvider) -> Bool {
        guard from == candidateFrom else { return false }
        return to == candidateTo
    }

    /// A fixed English sentence built only from literals chosen by exhaustive switches over the fields.
    var message: String {
        let cause = Self.reasonText(reason)
        let source = Self.providerName(from)
        let destination = Self.providerName(to)
        let exposure = Self.exposureText(dataLeavesDevice: dataLeavesDevice, consentUsed: consentUsed)
        return "\(cause) Falling back from \(source) to \(destination). \(exposure)"
    }

    private static func reasonText(_ reason: AssistantFallbackReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device is not eligible for on-device generation."
        case .turnedOff: "Apple Intelligence is turned off."
        case .modelNotReady: "The on-device model is not ready."
        case .osUnsupported: "This operating system does not support on-device generation."
        case .providerUnavailable: "The assistant provider is unavailable."
        case .generationFailed: "The assistant provider failed to generate a reply."
        case .emptyResponse: "The assistant provider returned an empty reply."
        }
    }

    private static func providerName(_ provider: AssistantProvider) -> String {
        switch provider {
        case .appleIntelligence: "Apple Intelligence"
        case .githubCopilot: "GitHub Copilot"
        case .deterministic: "the built-in assistant"
        }
    }

    private static func exposureText(dataLeavesDevice: Bool, consentUsed: Bool) -> String {
        guard dataLeavesDevice else { return "The request is handled on this device." }
        guard consentUsed else { return "The request is sent off this device." }
        return "The request is sent off this device with your consent."
    }
}
