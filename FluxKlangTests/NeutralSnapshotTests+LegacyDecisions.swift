//
//  NeutralSnapshotTests+LegacyDecisions.swift
//  FluxKlangTests
//
//  A1's blank-kept cap and cut decisions must not disappear in A1h.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct GeneratedMarkerCase: Sendable, CustomTestStringConvertible {
    let name: String
    let term: UntrustedTextSanitizer.WithheldTerm

    var testDescription: String { name }
}

private let generatedMarkerCases: [GeneratedMarkerCase] = [
    .init(name: "contained", term: .init(text: "withhe", isPrefix: false)),
    .init(name: "contains", term: .init(text: "x[withheld]suffix", isPrefix: false)),
    .init(name: "leading boundary", term: .init(text: "secret[", isPrefix: false)),
    .init(name: "trailing boundary", term: .init(text: "]secret", isPrefix: false)),
    .init(name: "compact contained", term: .init(text: "wi thhe", isPrefix: false, separators: [0])),
    .init(name: "compact leading boundary", term: .init(text: "secretx[ w", isPrefix: false, separators: [0])),
    .init(name: "compact trailing boundary", term: .init(text: "d ]secret", isPrefix: false, separators: [0]))
]

extension NeutralSnapshotUnicodeTests {
    @Test func incompleteScanFailsClosedWhenA1hHasNoTailWindow() {
        let term = "Q\u{13441}\u{13441}"
        let raw = "x" + String(repeating: "\u{0316}", count: 4_090) + "abcdefgh"
        let result = UntrustedLabel(raw, withholding: [term])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
    }

    @Test func incompleteScanOrdinaryExactTermKeepsPartialRedaction() {
        let term = "ABCDEFGHIJKLM"
        let raw = term + String(repeating: "z", count: 4_200)
        let result = UntrustedLabel(raw, withholding: [term])
        #expect(result.text == UntrustedLabel.withheldMarker + String(repeating: "z", count: 118))
        #expect(result.isTruncated)
    }

    @Test func incompleteScanBlankDependentTermFailsClosed() {
        let term = "ABCDEFGH\u{13441}IJKLMNOP"
        let raw = "ABCDEFGHIJKLMNOP" + String(repeating: "z", count: 4_200)
        let result = UntrustedLabel(raw, maximumBytes: 20, withholding: [term])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test func completeScanBlankDependentTermStaysInert() {
        let term = "ABCDEFGH\u{13441}IJKLMNOP"
        let raw = "ABCDEFGHIJKLMNOPzzzz"
        let result = UntrustedLabel(raw, maximumBytes: 20, withholding: [term])
        #expect(result.text == raw)
        #expect(!result.isTruncated)
        #expect(!result.wasSanitized)
    }

    /// A1's cut to `ABCDEFGHIJKLMNOPzzzz` is hand-traced, not computed by a test oracle.
    /// Restored round-15 A1h returned `[withheld]zzzzzzzzzz`; the final guard withholds whole.
    @Test func shadowTermAndRealMatchFailClosedAtA1Cut() {
        let shadowTerm = "ABCDEFGH\u{13441}IJKLMNOP"
        let raw = "ABCDEFGHIJKLMNOP" + String(repeating: "z", count: 4_074) + "SECRETzz"
        let result = UntrustedLabel(raw, maximumBytes: 20, withholding: [shadowTerm, "SECRET"])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test func incompleteScanScopedBlankTermMarksWholeLabelSanitized() {
        let raw = String(repeating: "z", count: 4_200)
        let result = UntrustedLabel(raw, withholding: ["Q\u{13441}\u{13441}"])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
        let short = UntrustedLabel(raw, maximumBytes: 5, withholding: ["Q\u{13441}\u{13441}"])
        #expect(short.text.isEmpty)
        #expect(short.wasSanitized)
    }

    /// Control: this blank-only fallback already passed before the round-17 sanitization fix.
    @Test func incompleteScanBlankOnlyScopedTermMarksWholeLabelSanitized() {
        let raw = String(repeating: "z", count: 4_200)
        let result = UntrustedLabel(raw, withholding: ["\u{13441}\u{13442}"])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test func markerMatchingTermPreservesLegacyWholeLabelOutcome() {
        let result = UntrustedLabel("Rig withhe", maximumBytes: 14, withholding: ["withhe"])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test(arguments: generatedMarkerCases)
    func generatedMarkerOverlapShapesFailClosed(_ entry: GeneratedMarkerCase) {
        let result = UntrustedLabel("Rig Table", maximumBytes: 128, terms: [entry.term])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test func generatedMarkerRiskWithNilCompactFormFailsClosed() {
        let term = UntrustedTextSanitizer.WithheldTerm(
            text: "x     [", isPrefix: false, separators: [1, 2, 3, 4, 5]
        )
        #expect(term.compactForm == nil)
        let result = UntrustedLabel("Rig Table", maximumBytes: 128, terms: [term])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test func a1GraphemeCapDecisionSurvivesNewBlankRemoval() {
        let blank = "\u{1BC9D}"
        let marks = "\u{0316}"
        for count in 6...9 {
            let label = "q" + blank + String(repeating: marks, count: count) + "SN-12345"
            let term = "q" + blank + String(repeating: marks, count: count - 1) + "SN-12345"
            let expected = count == 6
                ? "q" + String(repeating: marks, count: count) + "SN-12345"
                : UntrustedLabel.withheldMarker
            #expect(UntrustedLabel(label, withholding: [term]).text == expected, "count \(count)")
        }
    }

    @Test func settleRematchAfterBlankRemovalFailsClosed() {
        let marks = String(repeating: "\u{0316}", count: 4)
        let label = "Rig S" + marks + "\u{13441}" + marks + "N-12345 ok"
        let term = "S" + String(repeating: "\u{0316}", count: 7) + "N-12345"
        #expect(UntrustedLabel(label, withholding: [term]).text == UntrustedLabel.withheldMarker)
    }

    @Test func a1ByteCutDoesNotShiftWhenBlankIsRemoved() {
        let raw = "A\u{13441}0123456789ABCDEFGHIJ"
        let label = UntrustedLabel(raw, maximumBytes: 16)
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.isTruncated)
        #expect(label.wasSanitized)
    }

    @Test func a1ByteCutBoundaryAndPassThrough() {
        let limit = 16
        let blank = "\u{13441}"
        for count in 10...12 {
            let label = "A" + blank + String(repeating: "B", count: count)
            let result = UntrustedLabel(label, maximumBytes: limit, withholding: ["SN-12345"])
            let expected = count == 12
                ? UntrustedLabel.withheldMarker
                : "A" + String(repeating: "B", count: count)
            #expect(result.text == expected, "count \(count)")
            #expect(result.isTruncated == (count == 12), "count \(count)")
        }
    }

    @Test func newBlankAtEightScalarsDoesNotOverWithhold() {
        let marks = String(repeating: "\u{0316}", count: 6)
        let label = "q\u{1BC9D}" + marks + "SN-12345"
        let expected = "q" + marks + "SN-12345"
        #expect(UntrustedLabel(label, withholding: ["Rig-12345"]).text == expected)
    }

    @Test func newBlankRemovalCannotChangeVisibleNFCScalars() {
        let label = "S\u{0316}\u{13441}\u{0301}\u{0301}\u{0301}SN-12345"
        #expect(UntrustedLabel(label).text == UntrustedLabel.withheldMarker)
    }

    @Test func blankAtStartMiddleAndEndOfGraphemeKeepsA1CapDecision() throws {
        let marks = "\u{0316}"
        let blank = try #require("\u{1BC9D}".unicodeScalars.first)
        let labelScalars = Array(("q" + String(repeating: marks, count: 7)).unicodeScalars)
        for position in [1, 4, labelScalars.count] {
            var label = labelScalars
            label.insert(blank, at: position)
            var term = Array(("q" + String(repeating: marks, count: 6)).unicodeScalars)
            term.insert(blank, at: min(position, term.count))
            let raw = String(String.UnicodeScalarView(label)) + "SN-12345"
            let withheld = String(String.UnicodeScalarView(term)) + "SN-12345"
            #expect(
                UntrustedLabel(raw, withholding: [withheld]).text == UntrustedLabel.withheldMarker,
                "position \(position)"
            )
        }
    }

    @Test func shortUnmatchedNewBlankLabelStillPassesThrough() {
        let result = UntrustedLabel("Rig\u{13441} Table", withholding: ["SN-12345"])
        #expect(result.text == "Rig Table")
        #expect(result.wasSanitized)
        #expect(!result.isTruncated)
    }

    @Test func a1CapOnlyDecisionFailsClosedAfterNewBlankRemoval() {
        let marks = String(repeating: "\u{0316}", count: 7)
        let label = "q\u{1BC9D}" + marks + "ok"
        let result = UntrustedLabel(label, withholding: ["SN-12345"])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.wasSanitized)
        #expect(!result.isTruncated)
    }

    @Test func loBlankCanCreateOnlyAnA1hCapDecision() {
        let leadingMarks = String(repeating: "\u{0316}", count: 4)
        let trailingMarks = String(repeating: "\u{0301}", count: 4)
        for blank in ["\u{13441}", "\u{13442}"] {
            let scalarValues = blank.unicodeScalars.map(\.value)
            let result = UntrustedLabel(
                "q" + leadingMarks + blank + trailingMarks + "ok", withholding: ["SN-12345"]
            )
            #expect(result.text == UntrustedLabel.withheldMarker, "blank scalars \(scalarValues)")
            #expect(result.wasSanitized, "blank scalars \(scalarValues)")
            #expect(!result.isTruncated, "blank scalars \(scalarValues)")
        }
    }

    @Test func incompleteLegacyShadowScanIsBoundedAndFailsClosed() {
        let raw = "A\u{13441}" + String(repeating: "A", count: 5_000)
        let scanLimit = UntrustedTextSanitizer.scanLimit(maximumBytes: 128, withheld: [])
        let filtered = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: scanLimit)
        let decision = UntrustedTextSanitizer.legacyLabelDecision(
            raw, hardened: filtered.text.precomposedStringWithCanonicalMapping,
            maximumBytes: 128, scanLimit: scanLimit
        )
        #expect(!decision.scanIsComplete)
        #expect(decision.needsByteCut)

        let result = UntrustedLabel(raw, maximumBytes: 128)
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
        #expect(result.wasSanitized)
    }

    @Test func blankRedactionRetainsA1TruncatedFlag() {
        let result = UntrustedLabel(
            "\u{13441}SN-123 abcd", maximumBytes: 16, withholding: ["SN-123"]
        )
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
    }

    @Test func shortBlankRedactionConservativelyReportsTruncation() {
        let result = UntrustedLabel(
            "A\u{13441}SN-123", maximumBytes: 16, withholding: ["SN-123"]
        )
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
    }

    @Test func legacyShadowScanBoundaryIsExact() {
        let maximumBytes = 128
        let scanLimit = UntrustedTextSanitizer.scanLimit(maximumBytes: maximumBytes, withheld: [])
        let blank = "\u{13441}"
        let exactRaw = blank + String(repeating: "A", count: scanLimit - 1)
        let overRaw = blank + String(repeating: "A", count: scanLimit)
        #expect(exactRaw.unicodeScalars.count == scanLimit)
        #expect(overRaw.unicodeScalars.count == scanLimit + 1)

        let exact = legacyDecision(for: exactRaw, scanLimit: scanLimit, maximumBytes: maximumBytes)
        let over = legacyDecision(for: overRaw, scanLimit: scanLimit, maximumBytes: maximumBytes)
        #expect(exact.scanIsComplete)
        #expect(exact.needsByteCut)
        #expect(!over.scanIsComplete)
        #expect(over.needsByteCut)

        let result = UntrustedLabel(overRaw, maximumBytes: maximumBytes)
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
    }

    @Test func compactOnlyRedactionFailsClosedAtTheReviewersCut() {
        let label = UntrustedLabel(
            "ABC\nDEFGHIJKLMNO XYZ", maximumBytes: 16, withholding: ["ABCDEFGHIJKLMNO"]
        )
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.isTruncated)
        #expect(label.wasSanitized)
    }

    @Test func settlePassCompactOnlyRedactionFailsClosed() {
        let marks = String(repeating: "\u{0316}", count: 9)
        let term = "S" + String(repeating: "\u{0316}", count: 7) + "N-12345"
        let label = UntrustedLabel("S" + marks + "N-1\n2345 XYZ", withholding: [term])
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.wasSanitized)
    }

    @Test func settlePassExactAndCompactRedactionsReportTruncation() {
        let marks = String(repeating: "\u{0316}", count: 9)
        let compactTerm = "S" + String(repeating: "\u{0316}", count: 7) + "N-12345"
        let exactTerm = "R" + String(repeating: "\u{0316}", count: 7) + "Q"
        let label = UntrustedLabel(
            "S" + marks + "N-1\n2345 XYZ R" + marks + "Q tail",
            withholding: [compactTerm, exactTerm]
        )
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.isTruncated)
        #expect(label.wasSanitized)
    }

    @Test func newBlankAndSeparatorRedactionFailsClosed() {
        let label = UntrustedLabel("AB\u{13441}CD\nEFGH", withholding: ["CDEFGH"])
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.isTruncated)
        #expect(label.wasSanitized)
    }

    @Test func compactAndExactRedactionsFailClosedAtA1Cut() {
        let label = UntrustedLabel(
            "ABCDEF ABCDEF ABCDEF LMNOP\nQRSTUVWX tail!!",
            maximumBytes: 48,
            withholding: ["ABCDEF", "LMNOPQRSTUVWX"]
        )
        #expect(label.text == UntrustedLabel.withheldMarker)
        #expect(label.isTruncated)
        #expect(label.wasSanitized)
    }

    @Test func compactOnlyRedactionUsesA1CutBoundary() {
        let raw = "ABC\nDEFGHIJKLMNO XYZ"
        let term = "ABCDEFGHIJKLMNO"
        let a1DisplayLength = "ABC DEFGHIJKLMNO XYZ".utf8.count
        let exact = UntrustedLabel(raw, maximumBytes: a1DisplayLength, withholding: [term])
        let oneShort = UntrustedLabel(raw, maximumBytes: a1DisplayLength - 1, withholding: [term])
        #expect(exact.text == "[withheld] XYZ")
        #expect(oneShort.text == UntrustedLabel.withheldMarker)
    }

    @Test func compactOnlyRedactionKeepsPartialMatchWhenA1Fits() {
        let label = UntrustedLabel(
            "ABC\nDEFGHIJKLMNO XYZ", withholding: ["ABCDEFGHIJKLMNO"]
        )
        #expect(label.text == "[withheld] XYZ")
    }

    @Test func exactRedactionKeepsA1ByteCutBehavior() {
        let label = UntrustedLabel(
            "ABC\nDEFGHIJKLMNO XYZ", maximumBytes: 16, withholding: ["DEFGHIJKLMNO"]
        )
        #expect(label.text == "ABC [withheld] X")
    }

    @Test func compactOnlyRedactionFailsClosedForA1GraphemeCap() {
        let overCap = "q" + String(repeating: "\u{0316}", count: 8)
        let label = UntrustedLabel(
            overCap + " ABC\nDEFGHIJKLMNO XYZ", withholding: ["ABCDEFGHIJKLMNO"]
        )
        #expect(label.text == UntrustedLabel.withheldMarker)
    }

    @Test func compactOnlyRedactionIsIdempotent() {
        let raw = "ABC\nDEFGHIJKLMNO XYZ"
        let terms = ["ABCDEFGHIJKLMNO"]
        let first = UntrustedLabel(raw, withholding: terms)
        let second = UntrustedLabel(first.text, withholding: terms)
        #expect(second.text.unicodeScalars.elementsEqual(first.text.unicodeScalars))
    }
}

private func legacyDecision(
    for raw: String, scanLimit: Int, maximumBytes: Int
) -> UntrustedTextSanitizer.LegacyLabelDecision {
    let hardened = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: scanLimit)
        .text.precomposedStringWithCanonicalMapping
    return UntrustedTextSanitizer.legacyLabelDecision(
        raw, hardened: hardened, maximumBytes: maximumBytes, scanLimit: scanLimit
    )
}
