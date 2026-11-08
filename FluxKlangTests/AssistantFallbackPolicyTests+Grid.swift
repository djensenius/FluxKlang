//
//  AssistantFallbackPolicyTests+Grid.swift
//  FluxKlangTests
//
//  Every cell of providers x providers x conditions x failures x consents against a hand-written table.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AssistantFallbackPolicyTests {
    /// The three consents a grid cell can carry.
    enum GridConsent: CaseIterable {
        case absent
        case exact
        case wrongPair

        var value: AssistantFallbackConsent? {
            switch self {
            case .absent: nil
            case .exact: AssistantFallbackPolicyTests.exactConsent
            case .wrongPair: AssistantFallbackPolicyTests.wrongConsent
            }
        }
    }

    /// Whether `provider` can report `condition` about itself, written out as a table.
    static func tableAccepts(_ provider: AssistantProvider, _ condition: AssistantFallbackCondition) -> Bool {
        switch provider {
        case .appleIntelligence:
            let rejected: [AssistantFallbackCondition] = [.externalProviderReady]
            return !rejected.contains(condition)
        case .githubCopilot:
            let accepted: [AssistantFallbackCondition] = [.externalProviderReady, .failed, .deterministic]
            return accepted.contains(condition)
        case .deterministic:
            return false
        }
    }

    /// The reason a (condition, failure) pair gives, or nil when the failure does not fit the condition.
    static func tableReason(
        _ condition: AssistantFallbackCondition,
        _ failure: AssistantFallbackFailure
    ) -> AssistantFallbackReason? {
        switch failure {
        case .unavailable:
            return tableUnavailableReason(condition)
        case .generationFailed:
            let ready: [AssistantFallbackCondition] = [.ready, .externalProviderReady]
            return ready.contains(condition) ? .generationFailed : nil
        case .emptyResponse:
            let ready: [AssistantFallbackCondition] = [.ready, .externalProviderReady]
            return ready.contains(condition) ? .emptyResponse : nil
        }
    }

    static func tableUnavailableReason(_ condition: AssistantFallbackCondition) -> AssistantFallbackReason? {
        switch condition {
        case .deviceNotEligible: .deviceNotEligible
        case .intelligenceDisabled: .turnedOff
        case .modelNotReady: .modelNotReady
        case .unsupportedOS: .osUnsupported
        case .failed: .providerUnavailable
        case .deterministic: .providerUnavailable
        case .ready: nil
        case .externalProviderReady: nil
        }
    }

    /// The expected outcome of one cell.
    static func tableOutcome(
        _ from: AssistantProvider,
        _ to: AssistantProvider,
        _ condition: AssistantFallbackCondition,
        _ failure: AssistantFallbackFailure,
        _ consent: GridConsent
    ) -> Outcome {
        if from == to { return .refused(.sameProvider) }
        if from == .deterministic { return .refused(.nothingToFallBackFrom) }
        if !tableAccepts(from, condition) { return .refused(.availabilityMismatch) }
        guard let reason = tableReason(condition, failure) else { return .refused(.failureMismatch) }
        let toCloud = to == .githubCopilot
        let appleToCopilot = from == .appleIntelligence && toCloud
        if appleToCopilot {
            switch consent {
            case .absent: return .refused(.consentMissing)
            case .wrongPair: return .refused(.consentWrongPair)
            case .exact: break
            }
        }
        let disclosure = AssistantFallbackDisclosure(
            from: from, to: to, reason: reason, dataLeavesDevice: toCloud, consentUsed: appleToCopilot
        )
        return .allowed(disclosure)
    }

    @Test func everyCellOfTheGridOf648RequestsGivesTheOutcomeOfTheHandWrittenTable() {
        var cells = 0
        var differing = 0
        for from in AssistantProvider.allCases {
            for to in AssistantProvider.allCases {
                for condition in AssistantFallbackCondition.allCases {
                    for failure in AssistantFallbackFailure.allCases {
                        for consent in GridConsent.allCases {
                            let value = Self.availability(condition, text: "text")
                            let request = Self.request(from, to, value, failure, consent: consent.value)
                            let actual = Self.outcome(of: request)
                            let expected = Self.tableOutcome(from, to, condition, failure, consent)
                            cells += 1
                            if actual != expected { differing += 1 }
                        }
                    }
                }
            }
        }
        #expect(cells == 648)
        #expect(differing == 0)
    }

    /// How many cells of the grid are allowed, and how many are refused for their consent, with one consent value.
    static func gridCounts(_ consent: GridConsent) -> (allowed: Int, refusedForConsent: Int) {
        var allowed = 0
        var refusedForConsent = 0
        for from in AssistantProvider.allCases {
            for to in AssistantProvider.allCases {
                for condition in AssistantFallbackCondition.allCases {
                    for failure in AssistantFallbackFailure.allCases {
                        let value = availability(condition)
                        let request = Self.request(from, to, value, failure, consent: consent.value)
                        switch outcome(of: request) {
                        case .allowed: allowed += 1
                        case .refused(.consentMissing), .refused(.consentWrongPair): refusedForConsent += 1
                        case .refused: break
                        }
                    }
                }
            }
        }
        return (allowed, refusedForConsent)
    }

    @Test func theGridAllowsTwentyFourFallbacksWithTheExactConsentAndSixteenWithNoneOrTheWrongPair() {
        let exact = Self.gridCounts(.exact)
        let absent = Self.gridCounts(.absent)
        let wrong = Self.gridCounts(.wrongPair)
        #expect(exact.allowed == 24)
        #expect(absent.allowed == 16)
        #expect(wrong.allowed == 16)
        #expect(exact.refusedForConsent == 0)
        #expect(absent.refusedForConsent == 8)
        #expect(wrong.refusedForConsent == 8)
    }

    @Test func aConsentOnARequestThatDoesNotGoFromOnDeviceToTheCloudChangesNoDecision() {
        var compared = 0
        var differing = 0
        for from in AssistantProvider.allCases {
            for to in AssistantProvider.allCases {
                let noConsentNeeded = !(from == .appleIntelligence && to == .githubCopilot)
                guard noConsentNeeded else { continue }
                for condition in AssistantFallbackCondition.allCases {
                    for failure in AssistantFallbackFailure.allCases {
                        let value = Self.availability(condition)
                        let bare = Self.outcome(of: Self.request(from, to, value, failure))
                        for consent in [GridConsent.exact, GridConsent.wrongPair] {
                            let request = Self.request(from, to, value, failure, consent: consent.value)
                            compared += 1
                            if Self.outcome(of: request) != bare { differing += 1 }
                        }
                    }
                }
            }
        }
        #expect(compared == 384)
        #expect(differing == 0)
    }

    @Test func decidingTheSameRequestRepeatedlyGivesEqualOutcomes() {
        let request = Self.request(
            .appleIntelligence, .githubCopilot, .failed("same"), .unavailable, consent: Self.exactConsent
        )
        let first = Self.outcome(of: request)
        var equal = 0
        for _ in 0..<50 where Self.outcome(of: request) == first { equal += 1 }
        let isAllowed: Bool
        switch first {
        case .allowed: isAllowed = true
        case .refused: isAllowed = false
        }
        #expect(isAllowed)
        #expect(equal == 50)
    }
}
