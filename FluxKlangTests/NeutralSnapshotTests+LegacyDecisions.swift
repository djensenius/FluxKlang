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

extension NeutralSnapshotUnicodeTests {
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

    @Test func blankAtStartMiddleAndEndOfGraphemeKeepsA1CapDecision() {
        let marks = "\u{0316}"
        guard let blank = "\u{1BC9D}".unicodeScalars.first else {
            Issue.record("Expected the pinned blank scalar")
            return
        }
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
}
