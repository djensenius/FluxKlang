//
//  NeutralSnapshotTests+UnicodeScan.swift
//  FluxKlangTests
//
//  Every-scalar checks of the Unicode facts snapshot matching relies on, and pins of
//  Foundation's normalization errors (#358), so newer Unicode tables or a changed
//  Foundation fail CI instead of silently narrowing matches.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct NeutralSnapshotUnicodeScanTests {
    /// Every valid Unicode scalar, including unassigned and private-use values.
    /// `filterScalars` removes the latter two before matching, but case-fold closure is
    /// still checked for them.
    static let validScalars: [Unicode.Scalar] = (0...0x10FFFF).compactMap { value in
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return scalar
    }

    /// Scalars that `filterScalars` can keep. The full scalar loops use `validScalars`;
    /// normalization-space coverage and the expensive contextual-map cases use this set.
    static let labelScalars: [Unicode.Scalar] = (0...0x10FFFF).compactMap { value in
        guard let scalar = Unicode.Scalar(value) else { return nil }
        switch scalar.properties.generalCategory {
        case .unassigned, .privateUse: return nil
        default: return scalar
        }
    }

    static func hex(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        scalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }

    static func ccc(_ scalar: Unicode.Scalar) -> UInt8 {
        scalar.properties.canonicalCombiningClass.rawValue
    }

    /// `fold` stops at a fixed point, never at its round limit: every scalar's case
    /// folding settles in fewer than `maximumFoldRounds` changing rounds (two, for `ẞ`),
    /// and `fold` returns that fixed point.
    @Test func foldReachesAFixedPointWithinItsRoundLimit() {
        var deepest = 0
        var wrong: [UInt32] = []
        for scalar in Self.validScalars {
            var folding = [scalar]
            var rounds = 0
            var settled = false
            while rounds < UntrustedTextSanitizer.maximumFoldRounds {
                let next = folding.flatMap(\.properties.uppercaseMapping.unicodeScalars)
                    .flatMap(\.properties.lowercaseMapping.unicodeScalars)
                if next == folding {
                    settled = true
                    break
                }
                folding = next
                rounds += 1
            }
            deepest = max(deepest, rounds)
            if !settled || UntrustedTextSanitizer.fold(scalar) != folding { wrong.append(scalar.value) }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(20).map { String($0, radix: 16) })")
        #expect(deepest == 2 && deepest < UntrustedTextSanitizer.maximumFoldRounds)
        #expect(UntrustedTextSanitizer.fold("ẞ") == ["s", "s"])
    }

    /// Full coverage over all valid scalars took 22.254 seconds in Debug, exceeding the
    /// plan's 10-second budget, so this map test uses every assigned, non-private-use scalar
    /// (`labelScalars`). Fixed-point coverage remains over every valid scalar. Scalars whose
    /// form has a nonstarter additionally extend the preceding grapheme and are checked in
    /// context, plain and with dropped separators.
    ///
    /// `CaselessMap` folds grapheme by grapheme, which equals folding the whole text when
    /// no grapheme's caseless form starts with a nonstarter (NFD only reorders runs of
    /// them). So a scalar whose caseless form starts with one must extend the grapheme
    /// before it, and a scalar of a non-zero class must be a mark (`isMark`). Scalars whose
    /// caseless form holds a nonstarter are also mapped between marks of high and low
    /// class, plain and with dropped separators whose marks join them.
    @Test func caselessMapsEqualTheWholeTextFormForEveryAssignedScalar() {
        var wrong: [UInt32] = []
        var mapped = 0
        for scalar in Self.labelScalars {
            let form = UntrustedTextSanitizer.caselessForm(CollectionOfOne(scalar))
            let single = String(scalar)
            if UntrustedTextSanitizer.CaselessMap(single).scalars != form { wrong.append(scalar.value) }
            if Self.ccc(scalar) != 0, !UntrustedTextSanitizer.isMark(scalar.properties.generalCategory) {
                wrong.append(scalar.value)
            }
            guard form.contains(where: { Self.ccc($0) != 0 }) else { continue }
            mapped += 1
            if Self.ccc(form[0]) != 0, ("a" + String(scalar)).count != 1 {
                wrong.append(scalar.value)
            }
            let plain = "a\u{035D}" + String(scalar) + "\u{0334}b"
            let whole = UntrustedTextSanitizer.caselessForm(plain.unicodeScalars)
            if UntrustedTextSanitizer.CaselessMap(plain).scalars != whole {
                wrong.append(scalar.value)
            }
            let spaced = "a \u{035D}" + String(scalar) + " \u{0334}b"
            let compact = UntrustedTextSanitizer.dropping([0, 1], from: spaced)
            if compact != plain || UntrustedTextSanitizer.CaselessMap(spaced, dropping: [0, 1]).scalars
                != UntrustedTextSanitizer.caselessForm(compact.unicodeScalars) {
                wrong.append(scalar.value)
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(20).map { String($0, radix: 16) })")
        #expect(mapped >= 1_900)
    }

    /// Normalization neither creates nor removes U+0020, so `Scan.separators` keep their
    /// ordinals through `sourceForm` and matching: no scalar's NFC or NFD holds a space
    /// unless it is the space, and no mark composes with a space.
    @Test func normalizationNeitherCreatesNorRemovesSpaces() {
        var wrong: [UInt32] = []
        for scalar in Self.labelScalars where scalar != " " {
            let text = String(scalar)
            let forms = [text.precomposedStringWithCanonicalMapping, text.decomposedStringWithCanonicalMapping]
            if forms.contains(where: { $0.unicodeScalars.contains(" ") }) { wrong.append(scalar.value) }
            if Self.ccc(scalar) != 0 || UntrustedTextSanitizer.isMark(scalar.properties.generalCategory) {
                let composed = (" " + text).precomposedStringWithCanonicalMapping
                if composed.unicodeScalars.first != " " { wrong.append(scalar.value) }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(20).map { String($0, radix: 16) })")
    }
}

extension NeutralSnapshotUnicodeScanTests {
    // MARK: - Foundation normalization (#358)

    /// Lines of NormalizationTest-16.0.0.txt (columns c1;c2;c3;c4;c5), © 2024 Unicode®, Inc.,
    /// used under the Unicode License v3 (https://www.unicode.org/license.txt). Foundation
    /// fails each of them on this toolchain.
    static let normalizationLines = [
        "1100 AC00 11A8;1100 AC01;1100 1100 1161 11A8;1100 AC01;1100 1100 1161 11A8",
        "105C9;105C9;105D2 0307;105C9;105D2 0307",
        "105E4;105E4;105DA 0307;105E4;105DA 0307",
        "16D68;16D68;16D67 16D67;16D68;16D67 16D67",
        "0CCA 0CD5;0CCB;0CC6 0CC2 0CD5;0CCB;0CC6 0CC2 0CD5",
        "16121 1611F;16126;1611E 1611E 1611F;16126;1611E 1611E 1611F",
        "1138B 113C5 113C2;1138E 113C5;1138B 113C2 113C2 113C2;1138E 113C5;1138B 113C2 113C2 113C2",
        "1611E 16121 1611E 1611F;16121 16126;1611E 1611E 1611E 1611E 1611F;16121 16126;1611E 1611E 1611E 1611E 1611F",
        "16D63 16D67 16D68 16D67;16D6A 16D68;16D63 16D67 16D67 16D67 16D67;16D6A 16D68;16D63 16D67 16D67 16D67 16D67"
    ]

    static func columns(_ line: String) -> [String] {
        line.split(separator: ";").map { field in
            String(String.UnicodeScalarView(field.split(separator: " ").compactMap { UInt32($0, radix: 16) }
                .compactMap(Unicode.Scalar.init)))
        }
    }

    /// Foundation still breaks each line (when it is fixed, the unreliable set can shrink),
    /// the standard library still agrees with the file, and for every column the match
    /// pipeline (NFC, then NFD) gives the file's NFD, or the label is withheld whole
    /// (`hasUnreliableNormalization`).
    @Test(arguments: normalizationLines)
    func foundationNormalizationErrorsAreGuarded(line: String) {
        let column = Self.columns(line)
        let nfc = [column[1], column[1], column[1], column[3], column[3]]
        let nfd = [column[2], column[2], column[2], column[4], column[4]]
        let conforms = column.indices.allSatisfy { index in
            let text = column[index]
            return text.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(nfc[index].unicodeScalars)
                && text.decomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(nfd[index].unicodeScalars)
        }
        #expect(!conforms)
        #expect(column[0] == column[1] && column[1] == column[2] && column[3] == column[4])
        for index in column.indices {
            let pipeline = column[index].precomposedStringWithCanonicalMapping.decomposedStringWithCanonicalMapping
            let exact = pipeline.unicodeScalars.elementsEqual(nfd[index].unicodeScalars)
            #expect(exact || UntrustedTextSanitizer.hasUnreliableNormalization(column[index].unicodeScalars),
                    "\(Self.hex(column[index].unicodeScalars))")
        }
    }

    /// The review's cases: a withheld string that starts with U+2000 or U+2001 and then
    /// U+113C2 or U+1611E loses the space when it is trimmed, while Foundation's NFC
    /// composes the label's pair into U+113C5 or U+16121, which is not equivalent. The
    /// term still matches only because Foundation decomposes those into two of the mark
    /// (class 0); the guard withholds the label whatever a future Foundation does.
    @Test(arguments: [("\u{2000}", "\u{2002}"), ("\u{2001}", "\u{2003}")], ["\u{113C2}", "\u{1611E}"])
    func leadingSpacesBeforeUnreliableMarksAreWithheld(space: (String, String), mark: String) throws {
        let raw = space.0 + mark + "-SN-123"
        let composed = mark == "\u{113C2}" ? "\u{113C5}" : "\u{16121}"
        let source = UntrustedTextSanitizer.sourceForm(raw)
        #expect(source.unicodeScalars.elementsEqual((composed + "-SN-123").unicodeScalars) && source != raw)
        #expect(UntrustedTextSanitizer.caselessForm(raw.unicodeScalars).starts(with: (space.1 + mark).unicodeScalars))
        let decomposed = UntrustedTextSanitizer.caselessForm(composed.unicodeScalars)
        #expect(decomposed.elementsEqual((mark + mark).unicodeScalars))
        let term = try #require(UntrustedTextSanitizer.withheldTerm(raw))
        #expect(term.text.unicodeScalars.elementsEqual((mark + "-SN-123").unicodeScalars))
        let marker = UntrustedLabel.withheldMarker
        let matched = UntrustedTextSanitizer.redactMatchForm(
            of: raw, withheld: [term], marker: marker, scanIsComplete: true
        )
        #expect(matched.text == marker)
        #expect(UntrustedTextSanitizer.hasUnreliableNormalization(raw.unicodeScalars))
        #expect(UntrustedLabel("Rig " + raw, withholding: [raw]).text == marker)
    }

    /// Foundation composes a supplementary starter as the BMP scalar with its low 16 bits,
    /// with a mark of any class.
    @Test(arguments: [("\u{10041}\u{0300}", "\u{00C0}"), ("\u{209C7}\u{09BE}", "\u{09CB}")])
    func supplementaryStartersBeforeMarksAreGuarded(raw: String, masked: String) {
        #expect(raw.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(masked.unicodeScalars))
        #expect(raw != masked)
        #expect(UntrustedTextSanitizer.hasUnreliableNormalization(raw.unicodeScalars))
        #expect(UntrustedLabel(raw + " ok", withholding: ["SN-12345"]).text == UntrustedLabel.withheldMarker)
        #expect(UntrustedLabel(raw + " ok").text == masked + " ok")
    }

    @Test func theUnreliableGuardSkipsJoinersAndSelectorsAndNeedsAMark() {
        let guarded = ["\u{105C9}", "x\u{16D68}", "\u{1D400}\u{0301}", "\u{1D400}\u{FE0F}\u{0301}", "😀\u{200D}\u{20E3}"]
        let plain = ["\u{1D400} \u{0301}", "a\u{0301}", "\u{1D400}\u{1D401}", "😀\u{FE0F}", "👍🏽", "\u{0301}\u{1D400}"]
        for text in guarded {
            #expect(UntrustedTextSanitizer.hasUnreliableNormalization(text.unicodeScalars), "\(text)")
        }
        for text in plain {
            #expect(!UntrustedTextSanitizer.hasUnreliableNormalization(text.unicodeScalars), "\(text)")
        }
        let pinned: Set<UInt32> = [0x105C9, 0x105E4, 0x113C2, 0x1611E, 0x16D68, 0x16D69, 0x16D6A]
        #expect(UntrustedTextSanitizer.normalizationUnreliable == pinned)
        // Without a withheld term nothing is matched, so the label is shown.
        #expect(UntrustedLabel("\u{105C9} ok").text == "\u{105C9} ok")
    }
}
