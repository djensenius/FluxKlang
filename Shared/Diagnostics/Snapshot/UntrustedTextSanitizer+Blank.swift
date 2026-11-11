//
//  UntrustedTextSanitizer+Blank.swift
//  FluxKlang
//
//  Pinned scalar sets that Unicode properties do not give: characters that render
//  as nothing, and the points where Foundation's normalization breaks canonical
//  equivalence on this toolchain. Also records A1's legacy-label decision: what A1
//  capped, cut or exposed after new-blank scalars were removed, so A1h fails closed.
//

import Foundation

extension UntrustedTextSanitizer {
    struct LegacyLabelDecision {
        let needsGraphemeCap: Bool
        let needsByteCut: Bool
        let needsScalarSubsequenceGuard: Bool
        /// Tests observe whether the bounded shadow scan finished or was cut (N73);
        /// fail-closed uses `needsByteCut`.
        let scanIsComplete: Bool
    }

    /// The bounded A1 shadow keeps new blanks. Prefix reconstruction can over-fire for
    /// leading filtered scalars (including ZWSP and NUL), but the A1h subsequence check
    /// makes that fail closed rather than expose text.
    static func legacyLabelDecision(
        _ raw: String, hardened: String, maximumBytes: Int, scanLimit: Int
    ) -> LegacyLabelDecision {
        let scan = filterScalars(raw.unicodeScalars, keeping: scanLimit, trimmed: true)
        let byteLimit = max(0, maximumBytes)
        var prefix = String.UnicodeScalarView()
        var prefixBytes = 0
        var prefixExceedsBound = false
        // Every prefix scalar adds at least one byte, so this loop stops by byteLimit + 1 scalars.
        for scalar in raw.unicodeScalars {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            let prefixScalar: Unicode.Scalar
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                prefixScalar = " "
            default:
                prefixScalar = scalar
            }
            let (nextBytes, overflow) = prefixBytes.addingReportingOverflow(prefixScalar.utf8.count)
            guard !overflow, nextBytes <= byteLimit else {
                prefixExceedsBound = true
                break
            }
            prefix.append(prefixScalar)
            prefixBytes = nextBytes
        }
        let legacyDisplay = (String(prefix) + (scan.a1Text ?? scan.text))
            .precomposedStringWithCanonicalMapping
        let needsGraphemeCap = legacyDisplay.contains {
            $0.unicodeScalars.count > maximumScalarsPerGrapheme
        }
        let needsByteCut = prefixExceedsBound
            // An incomplete scan means A1 needs a byte cut, whatever the measured display length.
            // Keep the complete-scan guard separate so these cases stay independent and readable.
            || !scan.isComplete
            || (scan.isComplete && legacyDisplay.utf8.count > byteLimit)
        let needsScalarSubsequenceGuard = !scalarSubsequence(hardened, of: legacyDisplay)
        return LegacyLabelDecision(
            needsGraphemeCap: needsGraphemeCap,
            needsByteCut: needsByteCut,
            needsScalarSubsequenceGuard: needsScalarSubsequenceGuard,
            scanIsComplete: scan.isComplete
        )
    }

    private static func scalarSubsequence(_ text: String, of legacy: String) -> Bool {
        var index = legacy.unicodeScalars.startIndex
        for scalar in text.unicodeScalars {
            while index != legacy.unicodeScalars.endIndex, legacy.unicodeScalars[index] != scalar {
                index = legacy.unicodeScalars.index(after: index)
            }
            guard index != legacy.unicodeScalars.endIndex else { return false }
            index = legacy.unicodeScalars.index(after: index)
        }
        return true
    }

    /// Scalars that render as nothing and that `filterScalars` removes by value. The Hangul
    /// fillers (U+115F, U+1160, U+3164) and the halfwidth one (U+FFA0) are also
    /// default-ignorable, so they are removed either way and are listed so the set is
    /// pinned. The rest are neither default-ignorable nor format characters: the blank
    /// Braille pattern (U+2800), the Khitan small script filler (U+16FE4, a combining mark),
    /// the Egyptian hieroglyph full and half blanks (U+13441, U+13442), the Duployan thick
    /// letter selector (U+1BC9D, a mark) and the musical null notehead (U+1D159, So).
    ///
    /// No Unicode property marks a glyph as blank, so the list cannot be derived.
    /// `everyBlankNamedScalarIsRemovedOrReviewedAsDrawn` scans every assigned scalar whose
    /// name says blank, filler, null, space, invisible or zero width. It fails when one is
    /// kept that was not reviewed as drawn, or when a reviewed one stops being kept, so
    /// newer Unicode tables surface new candidates. A blank glyph whose name says nothing
    /// of it (U+1BC9D is one), or one that only a particular font draws as nothing, is not
    /// caught.
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
