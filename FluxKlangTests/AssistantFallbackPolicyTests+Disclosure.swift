//
//  AssistantFallbackPolicyTests+Disclosure.swift
//  FluxKlangTests
//
//  What an allowed fallback tells the user (the destination, the reason, the pair it was made for) and the proof
//  that the free text inside an availability never reaches a disclosure. Hostile text fixtures carry an ASCII
//  sentinel so a search of the output has a needle that cannot be found by accident.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AssistantFallbackPolicyTests {
    struct Pair: Equatable {
        let from: AssistantProvider
        let to: AssistantProvider
    }

    /// The four pairs `decide` can allow.
    static let allowedPairs: [Pair] = [
        Pair(from: .appleIntelligence, to: .githubCopilot),
        Pair(from: .appleIntelligence, to: .deterministic),
        Pair(from: .githubCopilot, to: .appleIntelligence),
        Pair(from: .githubCopilot, to: .deterministic)
    ]

    static let sentinel = "ZQ7SENTINEL9F3A"

    /// An allowed request for one of the four allowed pairs, with a consent only where the pair needs one.
    static func allowedRequest(_ pair: Pair, text: String = "") -> AssistantFallbackRequest {
        switch pair.from {
        case .appleIntelligence:
            let consent = pair.to == .githubCopilot ? exactConsent : nil
            return request(pair.from, pair.to, .failed(text), .unavailable, consent: consent)
        case .githubCopilot:
            return request(pair.from, pair.to, .externalProviderReady(text), .generationFailed)
        case .deterministic:
            return request(pair.from, pair.to, .deterministic, .unavailable)
        }
    }

    static func disclosure(of request: AssistantFallbackRequest) -> AssistantFallbackDisclosure? {
        switch outcome(of: request) {
        case .allowed(let disclosure): disclosure
        case .refused: nil
        }
    }

    /// Hostile free text: empty, secret-looking, bidi and zero-width controls, NUL and newlines, and 1 MiB.
    static func hostileTexts() -> [String] {
        let controls = "\u{202E}\u{2066}\u{200B}\u{200D}\u{FEFF}\u{0}\n\r\t\u{85}\u{2028}"
        return [
            "",
            "token-0000-FAKE-\(sentinel)",
            "\(controls)\(sentinel)\(controls)",
            "line one\nline two \(sentinel)\r\n",
            String(repeating: "A", count: 1_048_576) + sentinel
        ]
    }

    /// Whether the UTF-8 bytes of `needle` occur in the UTF-8 bytes of `haystack`; an empty needle is never found.
    static func containsBytes(_ needle: String, in haystack: String) -> Bool {
        let wanted = Array(needle.utf8)
        let bytes = Array(haystack.utf8)
        guard !wanted.isEmpty, wanted.count <= bytes.count else { return false }
        let last = bytes.count - wanted.count
        for start in 0...last {
            var matched = true
            for offset in 0..<wanted.count where bytes[start + offset] != wanted[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    // MARK: - The destination and the reason

    @Test func theDisclosureSaysDataLeavesTheDeviceOnlyWhenTheDestinationIsTheCloudProvider() throws {
        for pair in Self.allowedPairs {
            let disclosure = try #require(Self.disclosure(of: Self.allowedRequest(pair)))
            let expected = pair.to == .githubCopilot
            #expect(disclosure.dataLeavesDevice == expected)
            #expect(disclosure.from == pair.from)
            #expect(disclosure.to == pair.to)
        }
    }

    @Test func anUnavailableProviderGivesTheReasonOfItsConditionForEachConditionItCanReport() throws {
        let table: [(AssistantFallbackCondition, AssistantFallbackReason)] = [
            (.deviceNotEligible, .deviceNotEligible),
            (.intelligenceDisabled, .turnedOff),
            (.modelNotReady, .modelNotReady),
            (.unsupportedOS, .osUnsupported),
            (.failed, .providerUnavailable),
            (.deterministic, .providerUnavailable)
        ]
        for (condition, reason) in table {
            let value = Self.availability(condition)
            let request = Self.request(.appleIntelligence, .deterministic, value, .unavailable)
            let disclosure = try #require(Self.disclosure(of: request))
            #expect(disclosure.reason == reason)
        }
    }

    @Test func aReadyProviderThatFailedOrAnsweredNothingGivesThatFailureAsTheReason() throws {
        let readyFailed = Self.request(.appleIntelligence, .deterministic, .ready, .generationFailed)
        let readyEmpty = Self.request(.appleIntelligence, .deterministic, .ready, .emptyResponse)
        let externalFailed = Self.request(
            .githubCopilot, .deterministic, .externalProviderReady("x"), .generationFailed
        )
        let externalEmpty = Self.request(.githubCopilot, .deterministic, .externalProviderReady("x"), .emptyResponse)
        let one = try #require(Self.disclosure(of: readyFailed))
        let two = try #require(Self.disclosure(of: readyEmpty))
        let three = try #require(Self.disclosure(of: externalFailed))
        let four = try #require(Self.disclosure(of: externalEmpty))
        let failed: AssistantFallbackReason = .generationFailed
        let empty: AssistantFallbackReason = .emptyResponse
        #expect(one.reason == failed)
        #expect(two.reason == empty)
        #expect(three.reason == failed)
        #expect(four.reason == empty)
    }

    @Test func aDisclosureMatchesOnlyItsOwnPairInItsOwnDirectionOverAllNinePairs() throws {
        for pair in Self.allowedPairs {
            let disclosure = try #require(Self.disclosure(of: Self.allowedRequest(pair)))
            var matching: [Pair] = []
            for from in AssistantProvider.allCases {
                for to in AssistantProvider.allCases where disclosure.matches(from: from, to: to) {
                    matching.append(Pair(from: from, to: to))
                }
            }
            #expect(matching == [pair])
        }
    }

    // MARK: - The free text is never used

    @Test func requestsThatDifferOnlyInTheAvailabilityTextGiveEqualDisclosures() throws {
        for pair in Self.allowedPairs {
            let plain = try #require(Self.disclosure(of: Self.allowedRequest(pair)))
            for text in Self.hostileTexts() {
                let hostile = try #require(Self.disclosure(of: Self.allowedRequest(pair, text: text)))
                #expect(hostile == plain)
            }
        }
    }

    @Test func aSentinelPlantedInTheAvailabilityTextIsNotInTheMessageOrInTheDescriptionOfTheDisclosure() throws {
        var found = 0
        for pair in Self.allowedPairs {
            for text in Self.hostileTexts() {
                let disclosure = try #require(Self.disclosure(of: Self.allowedRequest(pair, text: text)))
                if Self.containsBytes(Self.sentinel, in: disclosure.message) { found += 1 }
                if Self.containsBytes(Self.sentinel, in: String(describing: disclosure)) { found += 1 }
            }
        }
        #expect(found == 0)
    }

    @Test func theSentinelSearchFindsTheSentinelInTheTextOfARequestThatHoldsIt() throws {
        try #require(Self.allowedPairs.count > 2)
        let held = Self.allowedRequest(Self.allowedPairs[2], text: "line one\nline two \(Self.sentinel)\r\n")
        let clean = Self.allowedRequest(Self.allowedPairs[2])
        #expect(Self.containsBytes(Self.sentinel, in: String(describing: held)))
        #expect(!Self.containsBytes(Self.sentinel, in: String(describing: clean)))
        #expect(!Self.containsBytes("", in: String(describing: held)))
    }

    @Test func noFieldOfADisclosureIsAStringOrCarriesOne() throws {
        for pair in Self.allowedPairs {
            let text = "text-\(Self.sentinel)"
            let disclosure = try #require(Self.disclosure(of: Self.allowedRequest(pair, text: text)))
            let children = Array(Mirror(reflecting: disclosure).children)
            var strings = 0
            for child in children where child.value is String { strings += 1 }
            #expect(children.count == 5)
            #expect(strings == 0)
        }
    }

    // MARK: - The message

    @Test func theMessageNamesBothProvidersAndWhetherTheRequestLeavesTheDeviceWithOrWithoutConsent() throws {
        try #require(Self.allowedPairs.count > 2)
        let leaving = try #require(Self.disclosure(of: Self.allowedRequest(Self.allowedPairs[0])))
        let staying = try #require(Self.disclosure(of: Self.allowedRequest(Self.allowedPairs[2])))
        let forged = AssistantFallbackDisclosure(
            from: .appleIntelligence, to: .githubCopilot, reason: .turnedOff,
            dataLeavesDevice: true, consentUsed: false
        )
        #expect(Self.containsBytes("from Apple Intelligence to GitHub Copilot", in: leaving.message))
        #expect(Self.containsBytes("sent off this device with your consent", in: leaving.message))
        #expect(Self.containsBytes("from GitHub Copilot to Apple Intelligence", in: staying.message))
        #expect(Self.containsBytes("handled on this device", in: staying.message))
        #expect(!Self.containsBytes("sent off", in: staying.message))
        #expect(Self.containsBytes("sent off this device.", in: forged.message))
        #expect(!Self.containsBytes("with your consent", in: forged.message))
    }

    @Test func theMessageGivesOneDistinctSentenceForEachOfTheSevenReasons() {
        let words: [(AssistantFallbackReason, String)] = [
            (.deviceNotEligible, "not eligible"),
            (.turnedOff, "turned off"),
            (.modelNotReady, "model is not ready"),
            (.osUnsupported, "operating system"),
            (.providerUnavailable, "provider is unavailable"),
            (.generationFailed, "failed to generate"),
            (.emptyResponse, "empty reply")
        ]
        var messages: Set<String> = []
        var missing = 0
        for (reason, word) in words {
            let disclosure = AssistantFallbackDisclosure(
                from: .appleIntelligence, to: .deterministic, reason: reason,
                dataLeavesDevice: false, consentUsed: false
            )
            messages.insert(disclosure.message)
            if !Self.containsBytes(word, in: disclosure.message) { missing += 1 }
        }
        #expect(words.count == AssistantFallbackReason.allCases.count)
        #expect(messages.count == 7)
        #expect(missing == 0)
    }

    // MARK: - Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Privacy/Providers",
            "../../Sources/FluxKlang/Shared/Privacy/Providers"
        ]
        let marker = "AssistantFallbackPolicy.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Words the three production files must not contain, even in a comment; built from pieces so this file does
    /// not contain them either.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["import Swift", "UI"].joined(), ["Da", "te("].joined(), ["Cl", "ock"].joined(), ["Ta", "sk"].joined(),
            ["Dispatch", "Queue"].joined(), ["User", "Defaults"].joined(), ["import Net", "work"].joined(),
            ["defa", "ult:"].joined()
        ]
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the fallback sources are not next to the tests"))
    func theThreeProductionFilesUseNoViewTimeSourceQueueStorageNetworkOrDefaultCase() throws {
        let directory = try #require(Self.sourceDirectory(), "the fallback sources are not next to the tests")
        let names = [
            "AssistantFallbackPolicy.swift", "AssistantFallbackDisclosure.swift", "AssistantFallbackRefusal.swift"
        ]
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            for word in Self.forbiddenSourceWords() where Self.containsBytes(word, in: text) {
                hits.append("\(name): \(word)")
            }
        }
        #expect(hits.isEmpty)
    }
}
