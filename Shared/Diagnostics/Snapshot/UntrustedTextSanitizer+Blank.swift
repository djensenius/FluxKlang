//
//  UntrustedTextSanitizer+Blank.swift
//  FluxKlang
//
//  Pinned scalar sets that Unicode properties do not give: characters that render
//  as nothing, and the points where Foundation's normalization breaks canonical
//  equivalence on this toolchain.
//

import Foundation

extension UntrustedTextSanitizer {
    /// Scalars that render as nothing although they are neither default-ignorable nor
    /// format characters, so `filterScalars` removes them by value: the Hangul fillers
    /// (U+115F, U+1160, U+3164) and the halfwidth one (U+FFA0), the blank Braille pattern
    /// (U+2800), the Khitan small script filler (U+16FE4, a combining mark), the Egyptian
    /// hieroglyph full and half blanks (U+13441, U+13442), the Duployan thick letter
    /// selector (U+1BC9D, a mark) and the musical null notehead (U+1D159, So).
    static let blankLookalikes: Set<UInt32> = [
        0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x16FE4, 0x13441, 0x13442, 0x1BC9D, 0x1D159
    ]

    /// Added after A1. Keep their source byte width for withheld-term eligibility:
    /// removing them from both label and term must not make an old eligible term vanish.
    static let newlyRemovedBlankLookalikes: Set<UInt32> = [0x13441, 0x13442, 0x1BC9D]

    /// Scalars where Foundation's normalization breaks canonical equivalence on Swift
    /// 6.4.2 with the macOS 27.2 SDK (#358): its NFC composes a preceding scalar (U+2000,
    /// U+2001 and about 1,981 others) with U+113C2 or U+1611E into U+113C5 or U+16121, it
    /// does not recompose U+16D68–U+16D6A, and its NFD does not decompose U+105C9 or
    /// U+105E4. The test suite pins each of these against `NormalizationTest.txt`, so a
    /// Foundation that changes fails CI instead of silently narrowing matches.
    static let normalizationUnreliable: Set<UInt32> = [
        0x105C9, 0x105E4, 0x113C2, 0x1611E, 0x16D68, 0x16D69, 0x16D6A
    ]

    /// Whether Foundation may normalize `scalars` to a text that is not canonically
    /// equivalent, so matching could miss a withheld string: a scalar of
    /// `normalizationUnreliable`, or a supplementary-plane starter followed by a mark.
    /// Foundation composes a supplementary base as the BMP scalar with its low 16 bits
    /// (U+10041 U+0300 gives U+00C0, and U+209C7 U+09BE gives U+09CB, so a spacing mark
    /// of class 0 counts as well as any mark of a non-zero class). Match-ignorable scalars
    /// are skipped because `sourceForm` removes them before it normalizes again.
    /// `UntrustedLabel` withholds a label whole when this holds and a term is active.
    static func hasUnreliableNormalization(_ scalars: String.UnicodeScalarView) -> Bool {
        var afterSupplementaryBase = false
        for scalar in scalars where !isMatchIgnorable(scalar) {
            if normalizationUnreliable.contains(scalar.value) { return true }
            let properties = scalar.properties
            if afterSupplementaryBase, isMark(properties.generalCategory) { return true }
            afterSupplementaryBase = scalar.value > 0xFFFF && properties.canonicalCombiningClass.rawValue == 0
        }
        return false
    }

    /// Nonspacing, spacing and enclosing marks. Every scalar with a non-zero canonical
    /// combining class is one of them (checked over every scalar by the test suite).
    static func isMark(_ category: Unicode.GeneralCategory) -> Bool {
        [.nonspacingMark, .spacingMark, .enclosingMark].contains(category)
    }
}
