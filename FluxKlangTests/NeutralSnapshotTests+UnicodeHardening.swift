//
//  NeutralSnapshotTests+UnicodeHardening.swift
//  FluxKlangTests
//
//  A systematic guard for `UntrustedTextSanitizer.blankLookalikes` (#358): no Unicode
//  property says that a scalar renders as nothing, so every assigned scalar whose
//  name calls it blank, a filler, null, a space or invisible is either removed by the
//  sanitizer or reviewed as drawn. Newer Unicode tables that name another such scalar
//  fail CI instead of silently letting it split a withheld string.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    /// Whole words of a scalar name (split at spaces and hyphens) that suggest it may
    /// render as nothing.
    static let blankNameWords: Set<String> = ["BLANK", "FILLER", "NULL", "SPACE", "INVISIBLE"]

    /// Scalars with such a name that `filterScalars` keeps because they are drawn: the
    /// control pictures for NUL, SP and blank (U+2400, U+2420, U+2422), the hatched
    /// ideographic half fill space (U+303F), the gap and line fillers of Devanagari,
    /// Manichaean, Newa, Dives Akuru, Bhaiksuki and Kawi (U+A8F9, U+10AF6, U+1144E,
    /// U+11945, U+11C44, U+11C45, U+11F48), and the SignWriting location symbols
    /// (U+1DA7F, U+1DA80). All are symbols or punctuation, not marks or letters, and their
    /// names describe a drawn sign; a candidate that is not must join `blankLookalikes`.
    static let reviewedDrawnBlankNames: Set<UInt32> = [
        0x2400, 0x2420, 0x2422, 0x303F, 0xA8F9, 0x10AF6, 0x1144E, 0x11945, 0x11C44, 0x11C45, 0x11F48,
        0x1DA7F, 0x1DA80
    ]

    static func hasBlankName(_ scalar: Unicode.Scalar) -> Bool {
        guard let name = scalar.properties.name else { return false }
        if name.contains("ZERO WIDTH") { return true }
        return name.split(whereSeparator: { $0 == " " || $0 == "-" })
            .contains { blankNameWords.contains(String($0)) }
    }

    /// Every assigned scalar with a blank-sounding name is removed between two letters
    /// (and a withheld string split by it is still withheld), or is one of
    /// `reviewedDrawnBlankNames`. Whitespace is left out: it renders as a visible gap,
    /// like U+0020, which matching does not treat as nothing. So are ZWJ and ZWNJ, which
    /// may be kept between letters but which matching ignores. Blank glyphs whose names
    /// say nothing of it (font-dependent) are outside what this can find.
    @Test func everyBlankNamedScalarIsRemovedOrReviewedAsDrawn() {
        var kept: Set<UInt32> = []
        var removed: [Unicode.Scalar] = []
        var otherwise: [UInt32] = []
        var named = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = scalar.properties
            switch properties.generalCategory {
            case .unassigned, .privateUse, .surrogate: continue
            default: break
            }
            guard !properties.isWhitespace, !UntrustedTextSanitizer.isMatchIgnorable(scalar),
                  Self.hasBlankName(scalar) else { continue }
            named += 1
            let probe = "a" + String(scalar) + "b"
            let scan = UntrustedTextSanitizer.filterScalars(probe.unicodeScalars, keeping: 16)
            if scan.text.unicodeScalars.contains(scalar) {
                kept.insert(value)
            } else if scan.text == "ab" {
                removed.append(scalar)
            } else {
                otherwise.append(value)
            }
        }
        let hex = { (values: [UInt32]) in values.map { String($0, radix: 16, uppercase: true) } }
        let unexpected = kept.subtracting(Self.reviewedDrawnBlankNames).sorted()
        let missing = Self.reviewedDrawnBlankNames.subtracting(kept).sorted()
        #expect(unexpected.isEmpty, "kept \(hex(unexpected)): add to blankLookalikes or reviewedDrawnBlankNames")
        #expect(missing.isEmpty, "no longer kept \(hex(missing)): remove from reviewedDrawnBlankNames")
        #expect(otherwise.isEmpty, "neither kept nor removed between letters: \(hex(otherwise))")
        let marker = NeutralSnapshotUnicodeTests.marker
        let exposed = removed.filter { scalar in
            UntrustedLabel("SN-1" + String(scalar) + "2345", withholding: NeutralSnapshotUnicodeTests.serial).text
                != marker
        }
        #expect(exposed.isEmpty, "removed but not withheld inside a serial: \(hex(exposed.map(\.value)))")
        // The scan reaches the pinned blanks it is meant to cover, and every one of them is removed.
        for value: UInt32 in [0x2800, 0x13441, 0x13442, 0x16FE4, 0x1D159] {
            let scalar = Unicode.Scalar(value)
            #expect(scalar.map(Self.hasBlankName) == true)
            #expect(UntrustedTextSanitizer.blankLookalikes.contains(value))
        }
        #expect(named >= 20)
    }
}
