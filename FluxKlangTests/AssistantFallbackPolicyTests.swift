//
//  AssistantFallbackPolicyTests.swift
//  FluxKlangTests
//
//  The assistant fallback policy (#124 FBK1): the builders every AssistantFallbackPolicyTests+*.swift file shares,
//  the refusals one at a time and the order in which they are reported. The policy is a pure function: nothing
//  here touches settings, storage, the network or any provider.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct AssistantFallbackPolicyTests {
    /// What `decide` produced: one disclosure or one refusal.
    enum Outcome: Equatable {
        case allowed(AssistantFallbackDisclosure)
        case refused(AssistantFallbackRefusal)
    }

    /// The consent for apple to copilot, the only pair a request can use.
    static let exactConsent: AssistantFallbackConsent? = try? AssistantFallbackConsent.grant(
        from: .appleIntelligence, to: .githubCopilot
    )

    /// A consent for another pair: the deterministic provider as the source, which no request can use.
    static let wrongConsent: AssistantFallbackConsent? = try? AssistantFallbackConsent.grant(
        from: .deterministic, to: .githubCopilot
    )

    static func request(
        _ from: AssistantProvider,
        _ to: AssistantProvider,
        _ availability: AssistantModelAvailability,
        _ failure: AssistantFallbackFailure,
        consent: AssistantFallbackConsent? = nil
    ) -> AssistantFallbackRequest {
        AssistantFallbackRequest(
            from: from, to: to, availability: availability, failure: failure, consent: consent
        )
    }

    static func outcome(of request: AssistantFallbackRequest) -> Outcome {
        do throws(AssistantFallbackRefusal) {
            let disclosure = try AssistantFallbackPolicy.decide(request)
            return .allowed(disclosure)
        } catch {
            return .refused(error)
        }
    }

    static func availability(
        _ condition: AssistantFallbackCondition,
        text: String = ""
    ) -> AssistantModelAvailability {
        switch condition {
        case .ready: .ready
        case .externalProviderReady: .externalProviderReady(text)
        case .deterministic: .deterministic
        case .deviceNotEligible: .deviceNotEligible
        case .intelligenceDisabled: .intelligenceDisabled
        case .modelNotReady: .modelNotReady
        case .unsupportedOS: .unsupportedOS
        case .failed: .failed(text)
        }
    }

    // MARK: - Each refusal on its own

    @Test func aFallbackToTheProviderThatFailedIsRefusedAsSameProvider() {
        let apple = Self.request(.appleIntelligence, .appleIntelligence, .ready, .generationFailed)
        let copilot = Self.request(.githubCopilot, .githubCopilot, .externalProviderReady("x"), .emptyResponse)
        let expected: Outcome = .refused(.sameProvider)
        #expect(Self.outcome(of: apple) == expected)
        #expect(Self.outcome(of: copilot) == expected)
    }

    @Test func aFallbackFromTheDeterministicProviderIsRefusedAsNothingToFallBackFromWhateverTheOtherFields() {
        #expect(Self.exactConsent != nil)
        let expected: Outcome = .refused(.nothingToFallBackFrom)
        var refused = 0
        var cells = 0
        for to in [AssistantProvider.appleIntelligence, AssistantProvider.githubCopilot] {
            for condition in AssistantFallbackCondition.allCases {
                for failure in AssistantFallbackFailure.allCases {
                    let value = Self.availability(condition, text: "t")
                    let plain = Self.request(.deterministic, to, value, failure)
                    let consented = Self.request(.deterministic, to, value, failure, consent: Self.exactConsent)
                    cells += 1
                    if Self.outcome(of: plain) == expected { refused += 1 }
                    if Self.outcome(of: consented) == expected { refused += 1 }
                }
            }
        }
        #expect(cells == 48)
        #expect(refused == 96)
    }

    @Test func anAvailabilityTheFailedProviderCannotReportIsRefusedAsAvailabilityMismatch() {
        let expected: Outcome = .refused(.availabilityMismatch)
        let appleExternal = Self.request(
            .appleIntelligence, .deterministic, .externalProviderReady("x"), .generationFailed
        )
        let copilotReady = Self.request(.githubCopilot, .deterministic, .ready, .generationFailed)
        let copilotOff = Self.request(.githubCopilot, .appleIntelligence, .intelligenceDisabled, .unavailable)
        let copilotModel = Self.request(.githubCopilot, .deterministic, .modelNotReady, .unavailable)
        #expect(Self.outcome(of: appleExternal) == expected)
        #expect(Self.outcome(of: copilotReady) == expected)
        #expect(Self.outcome(of: copilotOff) == expected)
        #expect(Self.outcome(of: copilotModel) == expected)
    }

    @Test func aFailureThatDoesNotFitTheAvailabilityIsRefusedAsFailureMismatch() {
        let expected: Outcome = .refused(.failureMismatch)
        let readyUnavailable = Self.request(.appleIntelligence, .deterministic, .ready, .unavailable)
        let offFailed = Self.request(.appleIntelligence, .deterministic, .intelligenceDisabled, .generationFailed)
        let offEmpty = Self.request(.appleIntelligence, .deterministic, .modelNotReady, .emptyResponse)
        let externalUnavailable = Self.request(
            .githubCopilot, .appleIntelligence, .externalProviderReady("x"), .unavailable
        )
        let failedEmpty = Self.request(.githubCopilot, .deterministic, .failed("x"), .emptyResponse)
        #expect(Self.outcome(of: readyUnavailable) == expected)
        #expect(Self.outcome(of: offFailed) == expected)
        #expect(Self.outcome(of: offEmpty) == expected)
        #expect(Self.outcome(of: externalUnavailable) == expected)
        #expect(Self.outcome(of: failedEmpty) == expected)
    }

    @Test func anUnavailableFailureFitsAFailedOrDeterministicCondition() {
        let mismatch: Outcome = .refused(.failureMismatch)
        let failed = Self.request(.githubCopilot, .appleIntelligence, .failed("x"), .unavailable)
        let deterministic = Self.request(.githubCopilot, .appleIntelligence, .deterministic, .unavailable)
        let failedOutcome = Self.outcome(of: failed)
        let deterministicOutcome = Self.outcome(of: deterministic)
        let failedIsMismatch: Bool = failedOutcome == mismatch
        let deterministicIsMismatch: Bool = deterministicOutcome == mismatch
        #expect(failedIsMismatch == false)
        #expect(deterministicIsMismatch == false)
    }

    // MARK: - The order in which refusals are reported

    @Test func sameProviderIsReportedBeforeNothingToFallBackFrom() {
        // Both hold: the same provider, and a deterministic source.
        let both = Self.request(.deterministic, .deterministic, .deterministic, .unavailable)
        let onlySame = Self.request(.appleIntelligence, .appleIntelligence, .ready, .generationFailed)
        let onlyNothing = Self.request(.deterministic, .appleIntelligence, .deterministic, .unavailable)
        let sameProvider: Outcome = .refused(.sameProvider)
        let nothing: Outcome = .refused(.nothingToFallBackFrom)
        #expect(Self.outcome(of: both) == sameProvider)
        #expect(Self.outcome(of: onlySame) == sameProvider)
        #expect(Self.outcome(of: onlyNothing) == nothing)
    }

    @Test func nothingToFallBackFromIsReportedBeforeAvailabilityMismatch() {
        // The deterministic provider accepts no availability, so a deterministic source with .ready holds both.
        let both = Self.request(.deterministic, .appleIntelligence, .ready, .generationFailed)
        let bothCloud = Self.request(.deterministic, .githubCopilot, .externalProviderReady("x"), .emptyResponse)
        let onlyMismatch = Self.request(
            .appleIntelligence, .deterministic, .externalProviderReady("x"), .generationFailed
        )
        let nothing: Outcome = .refused(.nothingToFallBackFrom)
        let mismatch: Outcome = .refused(.availabilityMismatch)
        #expect(Self.outcome(of: both) == nothing)
        #expect(Self.outcome(of: bothCloud) == nothing)
        #expect(Self.outcome(of: onlyMismatch) == mismatch)
    }

    @Test func availabilityMismatchIsReportedBeforeFailureMismatch() {
        // Both hold: the availability is wrong for the source and the failure does not fit it.
        let appleBoth = Self.request(.appleIntelligence, .deterministic, .externalProviderReady("x"), .unavailable)
        let copilotBoth = Self.request(.githubCopilot, .appleIntelligence, .ready, .unavailable)
        let onlyFailure = Self.request(.appleIntelligence, .deterministic, .ready, .unavailable)
        let mismatch: Outcome = .refused(.availabilityMismatch)
        let failure: Outcome = .refused(.failureMismatch)
        #expect(Self.outcome(of: appleBoth) == mismatch)
        #expect(Self.outcome(of: copilotBoth) == mismatch)
        #expect(Self.outcome(of: onlyFailure) == failure)
    }

    @Test func failureMismatchIsReportedBeforeAMissingOrWrongConsent() {
        // Both hold: the failure does not fit .ready, and apple to copilot needs a consent it does not carry.
        let missing = Self.request(.appleIntelligence, .githubCopilot, .ready, .unavailable)
        let wrong = Self.request(.appleIntelligence, .githubCopilot, .ready, .unavailable, consent: Self.wrongConsent)
        let onlyMissing = Self.request(.appleIntelligence, .githubCopilot, .ready, .generationFailed)
        let failure: Outcome = .refused(.failureMismatch)
        let consentMissing: Outcome = .refused(.consentMissing)
        #expect(Self.wrongConsent != nil)
        #expect(Self.outcome(of: missing) == failure)
        #expect(Self.outcome(of: wrong) == failure)
        #expect(Self.outcome(of: onlyMissing) == consentMissing)
    }
}
