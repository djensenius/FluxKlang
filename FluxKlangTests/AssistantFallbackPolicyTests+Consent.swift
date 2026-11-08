//
//  AssistantFallbackPolicyTests+Consent.swift
//  FluxKlangTests
//
//  Consent is a value for one pair of providers: how it is built, what it records and what the policy does with
//  it for each direction.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AssistantFallbackPolicyTests {
    /// The pairs `grant` accepts, as a table: an on-device source and the cloud destination.
    static func tableGrants(_ from: AssistantProvider, _ to: AssistantProvider) -> Bool {
        let sources: [AssistantProvider] = [.appleIntelligence, .deterministic]
        return sources.contains(from) && to == .githubCopilot
    }

    @Test func grantBuildsAConsentOnlyForAnOnDeviceSourceAndTheCloudDestinationOverAllNinePairs() {
        var granted = 0
        var refused = 0
        var wrongRefusal = 0
        for from in AssistantProvider.allCases {
            for to in AssistantProvider.allCases {
                do throws(AssistantFallbackRefusal) {
                    let consent = try AssistantFallbackConsent.grant(from: from, to: to)
                    granted += 1
                    #expect(consent.from == from)
                    #expect(consent.to == to)
                    #expect(Self.tableGrants(from, to))
                } catch {
                    refused += 1
                    if error != .consentNotApplicable { wrongRefusal += 1 }
                    #expect(!Self.tableGrants(from, to))
                }
            }
        }
        #expect(granted == 2)
        #expect(refused == 7)
        #expect(wrongRefusal == 0)
    }

    @Test func aConsentIsEqualOnlyToAConsentForTheSamePair() {
        let again = try? AssistantFallbackConsent.grant(from: .appleIntelligence, to: .githubCopilot)
        #expect(Self.exactConsent != nil)
        #expect(Self.wrongConsent != nil)
        #expect(Self.exactConsent == again)
        #expect(Self.exactConsent != Self.wrongConsent)
    }

    @Test func aFallbackFromAppleToCopilotWithoutConsentIsRefusedAsConsentMissing() {
        let readyFailed = Self.request(.appleIntelligence, .githubCopilot, .ready, .generationFailed)
        let offUnavailable = Self.request(.appleIntelligence, .githubCopilot, .intelligenceDisabled, .unavailable)
        let expected: Outcome = .refused(.consentMissing)
        #expect(Self.outcome(of: readyFailed) == expected)
        #expect(Self.outcome(of: offUnavailable) == expected)
    }

    @Test func aConsentForAnotherPairIsRefusedAsConsentWrongPair() {
        let request = Self.request(
            .appleIntelligence, .githubCopilot, .ready, .emptyResponse, consent: Self.wrongConsent
        )
        let expected: Outcome = .refused(.consentWrongPair)
        #expect(Self.outcome(of: request) == expected)
    }

    @Test func theExactConsentAllowsAppleToCopilotAndTheDisclosureRecordsThatConsentWasUsed() {
        let request = Self.request(
            .appleIntelligence, .githubCopilot, .modelNotReady, .unavailable, consent: Self.exactConsent
        )
        let disclosure = AssistantFallbackDisclosure(
            from: .appleIntelligence, to: .githubCopilot, reason: .modelNotReady,
            dataLeavesDevice: true, consentUsed: true
        )
        let expected: Outcome = .allowed(disclosure)
        #expect(Self.outcome(of: request) == expected)
    }

    @Test func aFallbackFromCopilotToALocalProviderNeedsNoConsentAndIsDisclosedAsStayingOnTheDevice() {
        let toApple = Self.request(.githubCopilot, .appleIntelligence, .failed("x"), .unavailable)
        let toBuiltIn = Self.request(.githubCopilot, .deterministic, .externalProviderReady("x"), .emptyResponse)
        let appleDisclosure = AssistantFallbackDisclosure(
            from: .githubCopilot, to: .appleIntelligence, reason: .providerUnavailable,
            dataLeavesDevice: false, consentUsed: false
        )
        let builtInDisclosure = AssistantFallbackDisclosure(
            from: .githubCopilot, to: .deterministic, reason: .emptyResponse,
            dataLeavesDevice: false, consentUsed: false
        )
        let expectedApple: Outcome = .allowed(appleDisclosure)
        let expectedBuiltIn: Outcome = .allowed(builtInDisclosure)
        #expect(Self.outcome(of: toApple) == expectedApple)
        #expect(Self.outcome(of: toBuiltIn) == expectedBuiltIn)
    }

    @Test func aFallbackFromAppleToTheDeterministicProviderNeedsNoConsent() {
        let request = Self.request(.appleIntelligence, .deterministic, .unsupportedOS, .unavailable)
        let disclosure = AssistantFallbackDisclosure(
            from: .appleIntelligence, to: .deterministic, reason: .osUnsupported,
            dataLeavesDevice: false, consentUsed: false
        )
        let expected: Outcome = .allowed(disclosure)
        #expect(Self.outcome(of: request) == expected)
    }

    @Test func aConsentCarriedByAFallbackThatNeedsNoneIsNotReportedAsUsed() {
        let request = Self.request(
            .appleIntelligence, .deterministic, .ready, .generationFailed, consent: Self.exactConsent
        )
        let disclosure = AssistantFallbackDisclosure(
            from: .appleIntelligence, to: .deterministic, reason: .generationFailed,
            dataLeavesDevice: false, consentUsed: false
        )
        let expected: Outcome = .allowed(disclosure)
        #expect(Self.outcome(of: request) == expected)
    }
}
