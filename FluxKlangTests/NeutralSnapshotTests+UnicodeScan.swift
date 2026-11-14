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

@Suite(.productionAccessAudit)
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

    // MARK: - Round 6 monotone hardening

    @Test func legacyHardwareOrderingKeepsA1SerialsInsideTheCap() {
        let serial = "SN-12345"
        var inputs = NeutralSnapshot.Inputs(graph: GraphDocument(id: GraphID(validated: "graph.round6")))
        inputs.hardwareIdentifiers = [serial] + (0..<NeutralSnapshotAssembly.maximumWithheldCount).map {
            "\u{13441}AAAA\($0)"
        }
        let assembly = NeutralSnapshotAssembly(inputs: inputs, limits: NeutralSnapshot.Limits())
        let refused = RefusedIdentities(forms: assembly.withheldForms, terms: assembly.redacted)
        #expect(assembly.withheld.contains(serial) && assembly.withheldOverflow == 1)
        #expect(refused.refuses(serial) && assembly.label(serial).text == UntrustedLabel.withheldMarker)
    }

    @Test func newBlankRemovalCannotExposeAnOriginalGraphemeBase() {
        let label = UntrustedLabel(
            "Rig q\u{1BC9D}SN-12345 ok", withholding: ["\u{1BC9D}SN-12345"]
        )
        #expect(label.text == UntrustedLabel.withheldMarker)
    }

    @Test func literalMarkerWithNewBlankAtEdgeStillTrimsWhitespace() {
        let label = UntrustedLabel(" [withheld] \u{13441}")
        #expect(label.text == UntrustedLabel.withheldMarker)
    }

    @Test func blankFreeLabelsRetainLegacyPrefixesFromNewBlankCutTerms() {
        let raw = String(repeating: "A", count: 1_023) + "\u{13441}A"
        let scan = UntrustedTextSanitizer.filterScalars(
            raw.unicodeScalars, keeping: UntrustedTextSanitizer.maximumWithheldBytes, trimmed: true
        )
        let terms = UntrustedTextSanitizer.withheldTerms([scan])
        let legacy = terms.first { !$0.requiresNewBlank }
        #expect(legacy?.isPrefix == true && legacy?.text == String(repeating: "A", count: 1_022))
        #expect(terms.contains(where: { $0.requiresNewBlank && $0.isFailClosed }))
        let label = UntrustedLabel(String(repeating: "A", count: 1_023), maximumBytes: 128, terms: terms)
        #expect(label.text == UntrustedLabel.withheldMarker)
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
        let guarded = ["\u{105C9}", "x\u{16D68}", "\u{1D400}\u{0301}",
                       "\u{1D400}\u{FE0F}\u{0301}", "😀\u{200D}\u{20E3}"]
        let plain = ["\u{1D400} \u{0301}", "a\u{0301}", "\u{1D400}\u{1D401}",
                     "😀\u{FE0F}", "👍🏽", "\u{0301}\u{1D400}"]
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

    @Test func separatorProvenanceSurvivesSettleRedactionAndStablePasses() throws {
        let marks = String(repeating: "\u{0316}", count: 7)
        let term = "ABq" + marks + "CDEF"
        let capped = "ABq" + String(repeating: "\u{0316}", count: 8) + "CD\nEF"
        #expect(UntrustedLabel(capped, withholding: [term]).text == UntrustedLabel.withheldMarker)

        for raw in [
            "ABq\n" + String(repeating: "\u{0316}", count: 8) + "CDEF",
            capped,
            "ABq" + String(repeating: "\u{0316}", count: 8) + "\nCDEF"
        ] {
            #expect(UntrustedLabel(raw, withholding: [term]).text == UntrustedLabel.withheldMarker)
        }

        let scan = UntrustedTextSanitizer.filterScalars(
            "ABC\nDEF X\nY".unicodeScalars, keeping: 100
        )
        let first = try #require(UntrustedTextSanitizer.withheldTerm("ABCDEF"))
        let redacted = UntrustedTextSanitizer.redactMatchFormWithSeparators(
            of: scan.text, withheld: [first], marker: UntrustedLabel.withheldMarker,
            scanIsComplete: true, separators: scan.separators
        )
        #expect(redacted.result.text == UntrustedLabel.withheldMarker + " X Y")
        #expect(redacted.separators == [1])
    }

    @Test func separatorsAndTermsKeepTheirOwnControlProvenance() {
        let controls = ["\u{2028}", "\u{2029}", "\u{0085}", "\u{0000}"]
        for control in controls {
            #expect(UntrustedLabel("AB" + control + "CDEF", withholding: ["ABCDEF"]).text
                == UntrustedLabel.withheldMarker)
            #expect(UntrustedLabel("ABCDEF", withholding: ["AB" + control + "CDEF"]).text
                == UntrustedLabel.withheldMarker)
        }
    }

    @Test func separatorProvenanceSurvivesMultipleCapSweeps() throws {
        let run = String(repeating: "\u{0D4E}", count: 8)
            + "\u{1F1E8}\u{200D}\u{1F1E8}\u{1F1E8}" + " ABC\nDEF"
        let scan = UntrustedTextSanitizer.filterScalars(run.unicodeScalars, keeping: 100)
        var work = UntrustedTextSanitizer.CapWork()
        let capped = UntrustedTextSanitizer.capGraphemes(
            scan.text, separators: scan.separators, work: &work
        )
        #expect(work.sweeps > 1)
        let term = try #require(UntrustedTextSanitizer.withheldTerm("ABCDEF"))
        let redacted = UntrustedTextSanitizer.redactMatchFormWithSeparators(
            of: capped.result.text, withheld: [term], marker: UntrustedLabel.withheldMarker,
            scanIsComplete: true, separators: capped.separators
        )
        #expect(redacted.result.text.hasSuffix(UntrustedLabel.withheldMarker))
    }

    @Test func seededSeparatorSentinelOracleFindsPostCapSecrets() {
        var random = NeutralSnapshotUnicodeRandom(seed: 0x358A_1F00_007B)
        let controls = ["\u{0000}", "\u{0085}", "\u{2028}", "\u{2029}"]
        let sentinels: [Unicode.Scalar] = ["■", "□", "▪", "▫"]
        let decorations = [" ", "\u{0301}", "\u{0316}", "\u{0D4E}", "A", "B", "C", "D"]
        let marks = String(repeating: "\u{0316}", count: 7)
        let term = "ABq" + marks + "CDEF"
        var oracleCases = 0
        var randomOracleCases = 0
        for iteration in 0..<96 {
            // Iteration zero is fixed. Iterations 1–16 randomize the control, but keep
            // eight marks and no decorations: capping and sentinel removal guarantee N=16 hits.
            let controlIndex = iteration == 0 ? 0 : Int(random.next() % UInt64(controls.count))
            let guaranteedHit = iteration == 0 || (1...16).contains(iteration)
            let extraMarks = guaranteedHit ? 8 : 8 + Int(random.next() % 3)
            let lead = guaranteedHit ? 0 : Int(random.next() % 4)
            let tail = guaranteedHit ? 0 : Int(random.next() % 4)
            let prefix = (0..<lead).map { _ in decorations[Int(random.next() % UInt64(decorations.count))] }
                .joined()
            let suffix = (0..<tail).map { _ in decorations[Int(random.next() % UInt64(decorations.count))] }
                .joined()
            let raw = prefix + "ABq" + String(repeating: "\u{0316}", count: extraMarks)
                + "CD" + controls[controlIndex] + "EF" + suffix
            let sentinelRaw = raw.replacingOccurrences(
                of: controls[controlIndex], with: String(sentinels[controlIndex])
            )
            let parallel = UntrustedLabel(sentinelRaw, maximumBytes: 4_096, withholding: [term]).text
            let compactParallel = String(parallel.unicodeScalars.filter { !sentinels.contains($0) })
            if compactParallel.contains(term) {
                oracleCases += 1
                if iteration > 0 { randomOracleCases += 1 }
                let actual = UntrustedLabel(raw, maximumBytes: 4_096, withholding: [term]).text
                #expect(!actual.replacingOccurrences(of: " ", with: "").contains(term))
            }
        }
        #expect(oracleCases >= 17)
        #expect(randomOracleCases >= 16)
    }

    @Test func trimmedTermsAndLabelsAgreeAcrossAdversarialScalars() throws {
        let values: [UInt32] = [
            0x1F600, 0xFE0E, 0xFE0F, 0x200D, 0x200C, 0x13441, 0x13442, 0x1BC9D,
            0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x16FE4, 0x1D159,
            0x0000, 0x000A, 0x0085, 0x2028, 0x2029, 0x0020, 0x0316, 0x0301, 0x0D4E,
            0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0053, 0x004E, 0x002D
        ]
        let alphabet = try values.map { try #require(Unicode.Scalar($0)) }
        let seeds: [UInt64] = [0x358A_3790_0001, 0x358A_3790_0002, 0x358A_3790_0003]
        var compared = 0
        for seed in seeds {
            var random = NeutralSnapshotUnicodeRandom(seed: seed)
            for _ in 0..<96 {
                let count = 1 + Int(random.next() % 12)
                let raw = String(String.UnicodeScalarView((0..<count).map { _ in
                    alphabet[Int(random.next() % UInt64(alphabet.count))]
                }))
                guard UntrustedTextSanitizer.withheldTerm(raw) != nil else { continue }
                let selfLabel = UntrustedLabel(raw, withholding: [raw]).text
                #expect(selfLabel.contains(UntrustedLabel.withheldMarker),
                        "seed=\(seed), raw=\(Self.hex(raw.unicodeScalars))")
                let prefix = String(String.UnicodeScalarView((0..<3).map { _ in
                    alphabet[Int(random.next() % UInt64(alphabet.count))]
                }))
                let suffix = String(String.UnicodeScalarView((0..<3).map { _ in
                    alphabet[Int(random.next() % UInt64(alphabet.count))]
                }))
                let embeddedLabel = UntrustedLabel(prefix + raw + suffix, withholding: [raw]).text
                #expect(embeddedLabel.contains(UntrustedLabel.withheldMarker),
                        "seed=\(seed), raw=\(Self.hex(raw.unicodeScalars))")
                compared += 2
            }
        }
        #expect(compared > 100)

        // Context-only differences for kept joiners/selectors are removed by sourceForm
        // before eligibility or matching, so these public outputs stay identical.
        for raw in ["😀\u{13441}\u{FE0F}", " \u{13441}\u{200D}A", "A\u{1BC9D}\u{200C}B"] {
            guard UntrustedTextSanitizer.withheldTerm(raw) != nil else { continue }
            #expect(UntrustedLabel(raw, withholding: [raw]).text == UntrustedLabel.withheldMarker)
        }
    }

    @Test func redactionDropsEdgePaddingExposedByNewBlankRemoval() {
        let leading = "  \u{1BC9D}D😀\u{115F}\u{FE0F}D"
        #expect(UntrustedLabel(leading, withholding: [leading]).text == UntrustedLabel.withheldMarker)

        let trailing = "\u{1D159}\u{FE0F}\n   D\u{115F} \u{0316}\u{200C}\n   \u{3164}\u{1160}\u{1BC9D}S"
        #expect(UntrustedLabel(trailing, withholding: [trailing]).text == UntrustedLabel.withheldMarker)
    }

    @Test func newBlankShadowTermsDoNotMatchLabelsWithoutNewBlanks() {
        let hostile = "a\u{13441}\u{13441}"
        let term = UntrustedTextSanitizer.withheldTerm(hostile)
        #expect(term?.text == "a" && term?.requiresNewBlank == true)
        #expect(UntrustedLabel("Rig Table", withholding: [hostile]).text == "Rig Table")

        let blankOnly = String(repeating: "\u{13441}", count: 2)
        #expect(UntrustedTextSanitizer.withheldTerm(blankOnly)?.isFailClosed == true)
        #expect(UntrustedLabel("Rig Table", withholding: [blankOnly]).text == "Rig Table")
        #expect(UntrustedLabel(blankOnly, withholding: [blankOnly]).text == UntrustedLabel.withheldMarker)
    }

    @Test func leadingTrimRemapsTermSeparatorsAfterNewBlankRemoval() {
        let term = "\u{13441} AB\nCDEF"
        let label = "\u{13441}ABCDEF"
        #expect(UntrustedLabel(label, withholding: [term]).text == UntrustedLabel.withheldMarker)
    }

    @Test func trimmingNewBlankEdgePaddingPreservesInteriorSeparatorProvenance() {
        let trimmed = UntrustedLabel.trimRedactedEdges(" [withheld] X Y ", separators: [2])
        #expect(trimmed.text == "[withheld] X Y")
        #expect(trimmed.separators == [1])
    }

    /// A matched tail does not prove that the A1 byte-cut boundary is preserved.
    @Test func aMatchedCutTailStillWithholdsTheWholeLabel() {
        let marks = String(repeating: "\u{0316}", count: 4_089)
        let term = "SECRET\u{13441}"
        let label = "x" + marks + "SECRET\u{13441}Y"
        let result = UntrustedLabel(label, withholding: [term])
        #expect(result.text == UntrustedLabel.withheldMarker)
        #expect(result.isTruncated)
    }

    @Test func incompleteMatchedBlankTermTailWithholdsWholeAfterBlankRemoval() {
        let blank = "\u{13441}"
        let term = "SECRET" + blank
        let raw = "x" + blank + String(repeating: "\u{0316}", count: 4_089) + "SECRET" + blank + "Y"
        let terms = UntrustedTextSanitizer.withheldTerms([term])
        let limit = UntrustedTextSanitizer.scanLimit(maximumBytes: UntrustedLabel.defaultMaximumBytes, withheld: [term])
        let filtered = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: limit)
        let active = UntrustedTextSanitizer.applicableTerms(terms, for: filtered)
        let matched = UntrustedTextSanitizer.redactMatchFormWithSeparators(
            of: filtered.text.precomposedStringWithCanonicalMapping,
            withheld: active,
            marker: UntrustedLabel.withheldMarker,
            scanIsComplete: filtered.isComplete,
            separators: filtered.separators
        )
        #expect(!filtered.isComplete && filtered.removedNewBlankBytes > 0)
        #expect(matched.result.changed)
        #expect(UntrustedLabel(raw, withholding: [term]).text == UntrustedLabel.withheldMarker)
    }

    @Test func incompleteScanWithoutBlankDependentTermKeepsBoundedPrefix() {
        let raw = "x" + String(repeating: "z", count: 4_200)
        let ordinaryTerm = "SECRET"
        #expect(UntrustedTextSanitizer.withheldTerm(ordinaryTerm)?.requiresNewBlank == false)
        let result = UntrustedLabel(raw, withholding: [ordinaryTerm])
        #expect(result.text == String(raw.prefix(UntrustedLabel.defaultMaximumBytes)))
        #expect(result.isTruncated)
    }

    @Test func completeScanBlankDependentTermKeepsLabelUnchanged() {
        let raw = "Rig Table"
        let term = "SECRET\u{13441}"
        let limit = UntrustedTextSanitizer.scanLimit(
            maximumBytes: UntrustedLabel.defaultMaximumBytes, withheld: [term]
        )
        let scan = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: limit)
        #expect(scan.isComplete)
        #expect(UntrustedTextSanitizer.withheldTerm(term)?.requiresNewBlank == true)
        #expect(UntrustedLabel(raw, withholding: [term]).text == raw)
    }

    @Test func newBlankShadowTermsDoNotRefuseA1Aliases() throws {
        let term = try #require(UntrustedTextSanitizer.withheldTerm("confirmed\u{13441}"))
        #expect(term.requiresNewBlank)
        let refused = RefusedIdentities([], terms: [term])
        #expect(!refused.refuses("dev.confirmed-a"))
    }
}
