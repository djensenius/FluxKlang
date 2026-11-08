/// Where a provider runs: on this device, or in the cloud.
enum AssistantProviderLocality: Equatable, Sendable {
    case onDevice
    case cloud
}

/// What went wrong with the provider that is being replaced. Cancellation is not a failure kind.
enum AssistantFallbackFailure: CaseIterable, Equatable, Sendable {
    /// The provider reported that it cannot generate.
    case unavailable
    /// The provider was ready and generation failed.
    case generationFailed
    /// The provider was ready and produced no reply.
    case emptyResponse
}

/// An `AssistantModelAvailability` without its text. The text is free-form and never read by the policy.
enum AssistantFallbackCondition: CaseIterable, Equatable, Sendable {
    case ready
    case externalProviderReady
    case deterministic
    case deviceNotEligible
    case intelligenceDisabled
    case modelNotReady
    case unsupportedOS
    case failed

    init(_ availability: AssistantModelAvailability) {
        switch availability {
        case .ready: self = .ready
        case .externalProviderReady: self = .externalProviderReady
        case .deterministic: self = .deterministic
        case .deviceNotEligible: self = .deviceNotEligible
        case .intelligenceDisabled: self = .intelligenceDisabled
        case .modelNotReady: self = .modelNotReady
        case .unsupportedOS: self = .unsupportedOS
        case .failed: self = .failed
        }
    }
}

/// One request to replace `from` by `to`. `availability` describes `from`. `consent` is the consent the caller
/// attaches to this request, if any.
struct AssistantFallbackRequest: Equatable, Sendable {
    let from: AssistantProvider
    let to: AssistantProvider
    let availability: AssistantModelAvailability
    let failure: AssistantFallbackFailure
    let consent: AssistantFallbackConsent?
}

/// The pure decision of whether one provider may take over from another, and what the user is told.
enum AssistantFallbackPolicy {
    /// Classifies a provider by an exhaustive switch, never by its raw value or label.
    static func locality(of provider: AssistantProvider) -> AssistantProviderLocality {
        switch provider {
        case .appleIntelligence: .onDevice
        case .githubCopilot: .cloud
        case .deterministic: .onDevice
        }
    }

    /// Allows the fallback and returns the disclosure for the exact (from, to) pair, or throws the first refusal of:
    /// same provider, nothing to fall back from, availability mismatch, failure mismatch, then consent. A fallback
    /// from an on-device provider to the cloud provider needs a consent for exactly that pair; a consent attached to
    /// any other request is ignored. The text inside the availability is never read.
    static func decide(
        _ request: AssistantFallbackRequest
    ) throws(AssistantFallbackRefusal) -> AssistantFallbackDisclosure {
        try requireDistinct(request)
        try requireNotDeterministic(request)
        let condition = AssistantFallbackCondition(request.availability)
        try requireAvailability(condition, from: request.from)
        let reason = try fallbackReason(for: request.failure, condition: condition)
        let consentUsed = try consentUsed(by: request)
        let leaves = locality(of: request.to) == .cloud
        return AssistantFallbackDisclosure(
            from: request.from,
            to: request.to,
            reason: reason,
            dataLeavesDevice: leaves,
            consentUsed: consentUsed
        )
    }

    private static func requireDistinct(_ request: AssistantFallbackRequest) throws(AssistantFallbackRefusal) {
        guard request.from != request.to else { throw .sameProvider }
    }

    private static func requireNotDeterministic(_ request: AssistantFallbackRequest) throws(AssistantFallbackRefusal) {
        guard request.from != .deterministic else { throw .nothingToFallBackFrom }
    }

    private static func requireAvailability(
        _ condition: AssistantFallbackCondition,
        from provider: AssistantProvider
    ) throws(AssistantFallbackRefusal) {
        guard accepts(provider, condition) else { throw .availabilityMismatch }
    }

    /// Whether `provider` can report `condition` about itself.
    private static func accepts(_ provider: AssistantProvider, _ condition: AssistantFallbackCondition) -> Bool {
        switch provider {
        case .appleIntelligence:
            switch condition {
            case .externalProviderReady: false
            case .ready, .deterministic, .deviceNotEligible, .intelligenceDisabled,
                 .modelNotReady, .unsupportedOS, .failed: true
            }
        case .githubCopilot:
            switch condition {
            case .externalProviderReady, .failed, .deterministic: true
            case .ready, .deviceNotEligible, .intelligenceDisabled, .modelNotReady, .unsupportedOS: false
            }
        case .deterministic:
            false
        }
    }

    private static func fallbackReason(
        for failure: AssistantFallbackFailure,
        condition: AssistantFallbackCondition
    ) throws(AssistantFallbackRefusal) -> AssistantFallbackReason {
        switch failure {
        case .unavailable:
            return try unavailableReason(condition)
        case .generationFailed:
            try requireProducing(condition)
            return .generationFailed
        case .emptyResponse:
            try requireProducing(condition)
            return .emptyResponse
        }
    }

    private static func unavailableReason(
        _ condition: AssistantFallbackCondition
    ) throws(AssistantFallbackRefusal) -> AssistantFallbackReason {
        switch condition {
        case .deviceNotEligible: return .deviceNotEligible
        case .intelligenceDisabled: return .turnedOff
        case .modelNotReady: return .modelNotReady
        case .unsupportedOS: return .osUnsupported
        case .failed, .deterministic: return .providerUnavailable
        case .ready, .externalProviderReady: throw .failureMismatch
        }
    }

    /// A provider that was ready is the only one that can fail to generate or return nothing.
    private static func requireProducing(_ condition: AssistantFallbackCondition) throws(AssistantFallbackRefusal) {
        switch condition {
        case .ready, .externalProviderReady: return
        case .deterministic, .deviceNotEligible, .intelligenceDisabled,
             .modelNotReady, .unsupportedOS, .failed: throw .failureMismatch
        }
    }

    /// Whether the request carries the consent that its direction needs. Only an on-device source going to a cloud
    /// destination needs one; for every other request a consent is ignored and nothing counts as consent used.
    private static func consentUsed(by request: AssistantFallbackRequest) throws(AssistantFallbackRefusal) -> Bool {
        guard locality(of: request.from) == .onDevice else { return false }
        guard locality(of: request.to) == .cloud else { return false }
        guard let consent = request.consent else { throw .consentMissing }
        guard consent.from == request.from else { throw .consentWrongPair }
        guard consent.to == request.to else { throw .consentWrongPair }
        return true
    }
}
