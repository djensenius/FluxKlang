/// Why a fallback request is refused. Refusals carry no text: a caller compares the case.
enum AssistantFallbackRefusal: Error, Equatable, Sendable {
    /// The provider that would take over is the provider that failed.
    case sameProvider
    /// The deterministic provider is the last resort, so nothing can take over from it.
    case nothingToFallBackFrom
    /// The availability does not describe a state the failed provider can report.
    case availabilityMismatch
    /// The failure kind does not fit the reported availability.
    case failureMismatch
    /// The fallback leaves the device and the request carries no consent.
    case consentMissing
    /// The fallback leaves the device and the consent the request carries is for another pair of providers.
    case consentWrongPair
    /// Only `AssistantFallbackConsent.grant` throws this: consent exists only for local to cloud.
    case consentNotApplicable
}

/// A consent for exactly one pair of providers. It is a value the caller attaches to one request: nothing stores it,
/// derives it from settings or carries it over to a later request.
struct AssistantFallbackConsent: Equatable, Sendable {
    let from: AssistantProvider
    let to: AssistantProvider

    private init(from: AssistantProvider, to: AssistantProvider) {
        self.from = from
        self.to = to
    }

    /// A consent for `from` falling back to `to`. Only a fallback from an on-device provider to the cloud provider
    /// can be consented to; any other pair throws `consentNotApplicable`. A consent for a pair that no request can
    /// use (the deterministic provider as the source) is still built, and `decide` refuses the request.
    static func grant(
        from: AssistantProvider,
        to: AssistantProvider
    ) throws(AssistantFallbackRefusal) -> AssistantFallbackConsent {
        let source = AssistantFallbackPolicy.locality(of: from)
        let destination = AssistantFallbackPolicy.locality(of: to)
        guard source == .onDevice else { throw .consentNotApplicable }
        guard destination == .cloud else { throw .consentNotApplicable }
        return AssistantFallbackConsent(from: from, to: to)
    }
}
