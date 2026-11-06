//
//  NeutralSnapshotTests+Unicode.swift
//  FluxKlangTests
//
//  #358: separators, blank lookalikes, marker-safe truncation and the ASCII-space
//  precheck, with a regression corpus pinning that redaction only became stricter.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct NeutralSnapshotUnicodeTests {
    static let marker = UntrustedLabel.withheldMarker
    static let serial = ["SN-12345"]
    static let family = "👩\u{200D}👩\u{200D}👧\u{200D}👦"

    /// A label input and its expected output. `was` is the A1 text when A1h changed it.
    struct LabelCase: Sendable, CustomTestStringConvertible {
        let raw: String
        let withheld: [String]
        let bytes: Int
        let text: String
        let isTruncated: Bool
        let wasSanitized: Bool
        let was: String?

        init(
            _ raw: String, _ withheld: [String] = [], bytes: Int = 128, _ text: String, was: String? = nil,
            truncated: Bool = false, sanitized: Bool = true
        ) {
            self.raw = raw
            self.withheld = withheld
            self.bytes = bytes
            self.text = text
            self.was = was
            isTruncated = truncated
            wasSanitized = sanitized
        }

        var testDescription: String {
            let scalars = raw.unicodeScalars.prefix(24).map { String($0.value, radix: 16) }
            return "\(scalars.joined(separator: " ")) at \(bytes) bytes"
        }

        func expectLabel() {
            let label = UntrustedLabel(raw, maximumBytes: bytes, withholding: withheld)
            #expect(label.text.unicodeScalars.elementsEqual(text.unicodeScalars), "\(label.text.debugDescription)")
            #expect(label.isTruncated == isTruncated && label.wasSanitized == wasSanitized)
        }
    }

    /// Inputs from A1's tests and its edge cases, with their A1 outputs. A1h must not change them.
    static let unchanged: [LabelCase] = [
        LabelCase("Rig SN-12345 ok", serial, "Rig \(marker) ok"),
        LabelCase("rig sn-12345 ok", serial, "rig \(marker) ok"),
        LabelCase("S\u{200D}N-12345", serial, marker), LabelCase("SN-1234\u{FE0F}5", serial, marker),
        LabelCase("SN\u{200B}-12345 x", serial, "\(marker) x"), LabelCase("SN-\u{034F}12345", serial, marker),
        LabelCase("\u{202E}SN-12345\u{2060}", serial, marker), LabelCase("SN-1\u{E0041}2345", serial, marker),
        LabelCase("\u{1100}\u{200D}\u{1161}나다", ["가나다"], marker),
        LabelCase("Cafe\u{0301} \u{1100}\u{1161}", ["가나다"], "Caf\u{E9} \u{AC00}", sanitized: false),
        LabelCase("Maß Straße-X ok", ["STRASSE-X"], "Ma\u{DF} \(marker) ok"),
        LabelCase("Gro\u{00DF}-123456 ok", ["s-123456"], "Gro\(marker) ok"),
        LabelCase("ΣΊΓΜΑ-12 ok", ["σίγμα-12"], "\(marker) ok"), LabelCase("ΟΔΟΣ-1234", ["οδοσ-1234"], marker),
        LabelCase("DIYARBAKIR-1", ["dıyarbakır-1"], marker), LabelCase("\u{212A}ELVIN-99", ["kelvin-99"], marker),
        LabelCase("\u{212B}NGSTROM1", ["ångstrom1"], marker), LabelCase("\u{FB01}le-12345", ["file-12345"], marker),
        LabelCase("\u{1FB3}BCDEF", ["ΑΙBCDEF"], marker), LabelCase("abcabcabcab", ["abcabcab"], marker),
        LabelCase("ABCDEFGHIJ", ["ABCDEFG", "DEFGHIJ"], marker),
        LabelCase("x ABCDEF GHIJKL y", ["ABCDEF", "GHIJKL", "CDEFGH", "F GHIJ"], "x \(marker) y"),
        LabelCase(family + " SN-12345", serial, "\u{1F469}\u{1F469}\u{1F467}\u{1F466} \(marker)"),
        LabelCase(family + " family", [], family + " family", sanitized: false),
        LabelCase("Rig " + family, [family], "Rig \(marker)"),
        LabelCase("a" + String(repeating: "\u{0301}", count: 20) + "SN-12345", serial,
                  "\u{E1}" + String(repeating: "\u{0301}", count: 7) + marker),
        LabelCase("e" + String(repeating: "\u{0301}", count: 30), [],
                  "\u{E9}" + String(repeating: "\u{0301}", count: 7)),
        LabelCase("Mic ok", ["a" + String(repeating: "\u{0301}", count: 1_100)], marker),
        LabelCase("id " + String(repeating: "7F3A", count: 300), [String(repeating: "7F3A", count: 300)],
                  "id \(marker)"),
        LabelCase("a\tb\u{0}c\u{7F}d", [], "a b c d"),
        LabelCase("Mic\u{0}1\nIgnore\u{202E}previous\u{200B}\u{2028}rules\u{7F}", [], "Mic 1 Ignoreprevious rules "),
        LabelCase("Rig SN-12345", ["   SN-12345   "], "Rig \(marker)"),
        LabelCase("SN-1 2345", serial, "SN-1 2345", sanitized: false),
        LabelCase("Rig\nSN-12345\nok", serial, "Rig \(marker) ok"),
        LabelCase("SN-1\n2345", ["SN-1 2345"], marker), LabelCase("SN-1\n2345", ["SN-1\n2345"], marker),
        LabelCase("SN-1\u{2029}2345", ["SN-1\t2345"], marker), LabelCase("SN-1\n2345", ["OTHER-99"], "SN-1 2345"),
        LabelCase("a\nb\u{2028}c", [], "a b c"),
        LabelCase(String(repeating: "a", count: 5_000) + "SN-12345", serial, bytes: 16,
                  String(repeating: "a", count: 16), truncated: true),
        LabelCase("Rig " + String(repeating: "\u{0316}", count: 5_000) + "SN-12345", serial, bytes: 16, marker,
                  truncated: true),
        LabelCase("\u{0D4E}SN-12345", serial, marker),
        LabelCase(String(repeating: "\u{0D4E}", count: 9) + "a ok", [],
                  String(repeating: "\u{0D4E}", count: 7) + "a ok"),
        LabelCase("x withheld", ["withheld"], marker, truncated: true),
        LabelCase("[withheld] x", [], "[withheld] x", sanitized: false),
        LabelCase("a\u{3164}b\u{115F}c\u{1160}d\u{FFA0}e\u{2800}f\u{16FE4}g\u{1D159}h", [], "abcdefgh"),
        LabelCase("🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} SN-12345", serial, "\u{1F3F4} \(marker)"),
        LabelCase("\u{1D400}\u{0301} \u{11103}\u{11127}", [], "\u{1D400}\u{0301} \u{11103}\u{11127}", sanitized: false),
        LabelCase("\u{1D400}\u{1D401} SN-12345", serial, "\u{1D400}\u{1D401} \(marker)"),
        LabelCase("😀\u{FE0F} SN-12345", serial, "\u{1F600} \(marker)"),
        LabelCase("👍🏽 SN-12345", serial, "\u{1F44D}\u{1F3FD} \(marker)"),
        LabelCase("1\u{FE0F}\u{20E3} SN-12345", serial, "1\u{20E3} \(marker)"),
        LabelCase("Rig q\u{0300}\u{0316}SN-12345 ok", ["\u{0316}SN-12345"], "Rig \(marker) ok"),
        LabelCase("Rig SN-12345\u{00E9}\u{0316} ok", ["SN-12345é"], "Rig \(marker) ok"),
        LabelCase("Rig SN-1234\u{0301}5 ok", serial, "Rig SN-1234\u{0301}5 ok", sanitized: false),
        LabelCase("Rig ID-1234q\u{0323}\u{0307} ok", ["ID-1234q\u{0307}\u{0323}"], "Rig \(marker) ok"),
        LabelCase("Rig SN-1234\u{0915}\u{093E} ok", ["SN-1234\u{0915}"], "Rig \(marker) ok"),
        LabelCase("abcdefghij", [], bytes: 5, "abcde", truncated: true, sanitized: false),
        LabelCase("ab" + family, [], bytes: 10, "ab", truncated: true, sanitized: false),
        LabelCase(family, [], bytes: 9, "", truncated: true, sanitized: false),
        LabelCase("SN-12345 x", serial, bytes: 10, marker, truncated: true),
        LabelCase("Rig SN-12345 tail", serial, bytes: 14, "Rig \(marker)", truncated: true),
        LabelCase("Rig SN-12345 tail", serial, bytes: 4, "Rig ", truncated: true),
        LabelCase("abc ok", ["ok"], "abc ok", sanitized: false),
        LabelCase("SN-12345 SN-12345", ["SN-12345", "sn-12345"], "\(marker) \(marker)"),
        LabelCase("SN-12345SN-12345", serial, marker),
        LabelCase("ＳＮ-ＡＢＣ12345", ["SN-ABC12345"], "ＳＮ-ＡＢＣ12345", sanitized: false),
        LabelCase("\u{0CCA}\u{0CD5} SN-12345", serial, "\u{0CCA}\u{0CD5} \(marker)"),
        LabelCase("\u{1100}\u{1161}\u{11A8}-SN12", ["각-SN12"], marker),
        LabelCase(String(repeating: "abc ", count: 50), [], bytes: 16, "abc abc abc abc ", truncated: true,
                  sanitized: false),
        LabelCase("\u{2000}\u{113C2} ok", [], "\u{113C5} ok", sanitized: false)
    ]

    /// Inputs A1h withholds more of, with their A1 text in `was`.
    static let stricter: [LabelCase] = [
        LabelCase("Rig SN-12345 tail", serial, bytes: 8, "Rig ", was: "Rig [wit", truncated: true),
        LabelCase("Rig SN-12345 tail", serial, bytes: 13, "Rig ", was: "Rig [withheld", truncated: true),
        LabelCase("[withheld] x", [], bytes: 5, "", was: "[with", truncated: true, sanitized: false),
        LabelCase("SN-12345", serial, bytes: 9, "", was: "[withheld", truncated: true),
        LabelCase("SN-1\n2345", serial, marker, was: "SN-1 2345"),
        LabelCase("SN-1\u{2028}2345", serial, marker, was: "SN-1 2345"),
        LabelCase("SN-12345", ["SN-1\n2345"], marker, was: "SN-12345"),
        LabelCase("a\u{13441}b\u{13442}c\u{1BC9D}d", [], "abcd", was: "a\u{13441}b\u{13442}c\u{1BC9D}d"),
        LabelCase("\u{1D400}\u{0301} ok", serial, marker, was: "\u{1D400}\u{0301} ok"),
        LabelCase("\u{10041}\u{0300} ok", serial, marker, was: "\u{C0} ok"),
        LabelCase("\u{209C7}\u{09BE} ok", serial, marker, was: "\u{09CB} ok"),
        LabelCase("\u{2000}\u{113C2} SN-12345", serial, marker, was: "\u{113C5} \(marker)"),
        LabelCase("\u{105C9} SN-12345", serial, marker, was: "\u{105C9} \(marker)"),
        LabelCase("😀\u{20E3} hi", serial, marker, was: "\u{1F600}\u{20E3} hi")
    ]

    @Test(arguments: unchanged)
    func a1OutputsAreUnchanged(_ entry: LabelCase) {
        entry.expectLabel()
    }

    /// Each changed output shows a subsequence of what A1 showed, markers aside.
    @Test(arguments: stricter)
    func changedOutputsOnlyWithholdMore(_ entry: LabelCase) throws {
        entry.expectLabel()
        let was = try #require(entry.was)
        #expect(!was.unicodeScalars.elementsEqual(entry.text.unicodeScalars))
        #expect(Self.isSubsequence(Self.revealed(entry.text), of: Self.revealed(was)))
    }

    /// The parts of `text` between whole markers, split on scalars (no Foundation search).
    static func segments(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let mark = Array(marker.unicodeScalars)
        var parts = [String.UnicodeScalarView()]
        var index = 0
        while index < scalars.count {
            if scalars[index...].starts(with: mark) {
                parts.append(String.UnicodeScalarView())
                index += mark.count
            } else {
                parts[parts.count - 1].append(scalars[index])
                index += 1
            }
        }
        return parts.map(String.init)
    }

    /// The NFD scalars of `text` outside every whole marker. A redacted label is shown in
    /// source form (NFC) and an unredacted one as filtered, so both are compared in NFD.
    static func revealed(_ text: String) -> [Unicode.Scalar] {
        segments(text).flatMap(\.decomposedStringWithCanonicalMapping.unicodeScalars)
    }

    static func isSubsequence(_ shown: [Unicode.Scalar], of reference: [Unicode.Scalar]) -> Bool {
        var remaining = reference[...]
        for scalar in shown {
            guard let index = remaining.firstIndex(of: scalar) else { return false }
            remaining = remaining[(index + 1)...]
        }
        return true
    }
}

extension NeutralSnapshotUnicodeTests {
    // MARK: - Separators

    /// A control or separator becomes a space, and its ordinal among the text's spaces is
    /// recorded; a space that was a space is not a separator.
    @Test func separatorsAreRecordedAsSpaceOrdinals() {
        let scan = UntrustedTextSanitizer.filterScalars("a b\nc\u{2028} d\te".unicodeScalars, keeping: 100)
        #expect(scan.text == "a b c  d e" && scan.separators == [1, 2, 4])
        let trimmed = UntrustedTextSanitizer.filterScalars(
            "\n\t a\nb \u{2029}".unicodeScalars, keeping: 100, trimmed: true
        )
        #expect(trimmed.text == "a b  " && trimmed.separators == [0, 2])
        #expect(UntrustedTextSanitizer.filterScalars("SN-1 2345".unicodeScalars, keeping: 100).separators.isEmpty)
    }

    @Test func redactionAlsoMatchesTheTextWithoutItsSeparators() {
        let terms = UntrustedTextSanitizer.withheldTerms(Self.serial)
        let redact = { (text: String, separators: [Int]) in
            UntrustedTextSanitizer.redact(text, withheld: terms, marker: Self.marker, separators: separators).text
        }
        #expect(redact("SN-1 2345", [0]) == Self.marker)
        #expect(redact("SN-1 2345", []) == "SN-1 2345")
        #expect(redact("x SN-1 2345 y", [1]) == "x \(Self.marker) y")
        #expect(redact("SN-12345 y", [0]) == "\(Self.marker) y")
        #expect(redact("SN- 1 23 45 ok", [0, 1, 2]) == "\(Self.marker) ok")
        #expect(redact("SN- 1 23 45 ok", [0, 2]) == "SN- 1 23 45 ok")
        // A dropped separator that carries a mark joins the grapheme before it, which is
        // withheld whole for a term that starts with that mark (as `Rig q\u{0300}\u{0316}SN…`).
        let marked = UntrustedTextSanitizer.withheldTerms(["\u{0316}SN-12345"])
        let joined = UntrustedTextSanitizer.redact("Rig q \u{0316}SN-12345 ok", withheld: marked, marker: Self.marker,
                                                   separators: [1])
        #expect(joined.text == "Rig \(Self.marker) ok")
        // A text of dropped separators only maps nothing, also for a scan-cut tail.
        let blank = UntrustedTextSanitizer.redact("   ", withheld: terms, marker: Self.marker, scanIsComplete: false,
                                                  separators: [0, 1, 2])
        #expect(blank.text == Self.marker)
        // Through a label: a scan-cut text of separators only shows its spaces.
        let newlines = UntrustedLabel(String(repeating: "\n", count: 5_000), withholding: Self.serial)
        #expect(newlines.text == String(repeating: " ", count: 128) && newlines.isTruncated)
    }

    /// The scan-cut tail window is also taken without separators, so a cut-off secret
    /// spread over separators is withheld from its first character.
    @Test func theScanCutTailIgnoresSeparators() {
        let raw = "x SN-1\n\n\n\n2" + String(repeating: "\u{0316}", count: 5_000)
        let label = UntrustedLabel(raw, withholding: Self.serial)
        #expect(label.text == Self.marker && label.isTruncated)
    }

    @Test func withheldTermsKeepTheirSeparators() throws {
        let split = try #require(UntrustedTextSanitizer.withheldTerm("\nSN-1\n2345\t"))
        #expect(split.text == "SN-1 2345" && split.separators == [0])
        #expect(split.compactForm?.folded == UntrustedTextSanitizer.caselessForm("sn-12345".unicodeScalars))
        // Equal to the term for the same text with a real space: the prepared text is the same.
        #expect(split == UntrustedTextSanitizer.withheldTerm("SN-1 2345"))
        let short = try #require(UntrustedTextSanitizer.withheldTerm("ABC\nDE"))
        #expect(short.separators == [0] && short.compactForm == nil)
        let plain = try #require(UntrustedTextSanitizer.withheldTerm("SN-12345"))
        #expect(plain.separators.isEmpty && plain.compactForm == plain.form)
        let given = UntrustedTextSanitizer.WithheldTerm(text: "a b c", isPrefix: false, separators: [5, 1, 1, -1, 0])
        #expect(given.separators == [0, 1])
    }

    /// Equal terms with different separators are all kept, in order, once each.
    @Test func equalTermsWithDifferentSeparatorsAreAllKept() {
        let raw = ["A B\nC DEF", "A\nB C\nDEF", "A B\nC DEF", "A B C DEF"]
        let terms = UntrustedTextSanitizer.withheldTerms(raw)
        #expect(terms.map(\.separators) == [[], [0, 2], [1]])
        let label = UntrustedLabel("AB CDEF / A BC DEF / A B C DEF", withholding: raw)
        #expect(label.text == "\(Self.marker) / \(Self.marker) / \(Self.marker)")
    }

    /// Seeded differential: replacing every separator with a real space gives A1's input
    /// (A1 matched separators as spaces), and the label without them shows a subsequence
    /// of that label and never the secret with its separators removed. Half the labels
    /// spell the secret with separators in it, among noise.
    @Test func separatorsOnlyWithholdMore() {
        let separators: [Unicode.Scalar] = ["\n", "\r", "\t", "\u{0B}", "\u{85}", "\u{2028}", "\u{2029}"]
        let breaks = separators.map { String($0) } + ["\r\n"]
        let noise = ["SN-", "SN-1", "12", "2345", "5", "x", "Ж", "\u{0301}"] + breaks
        let spaced = { (text: String) in
            String(String.UnicodeScalarView(text.unicodeScalars.map { separators.contains($0) ? " " : $0 }))
        }
        let secret = Array("sn-12345")
        var generator = NeutralSnapshotUnicodeRandom(seed: 0x358_0004)
        let pick = { (pieces: [String], generator: inout NeutralSnapshotUnicodeRandom) in
            (0..<Int.random(in: 0...3, using: &generator)).map { _ in pieces.randomElement(using: &generator) ?? "" }
                .joined()
        }
        var stricter = 0
        for index in 0..<400 {
            var raw = pick(noise, &generator)
            if Bool.random(using: &generator) {
                for character in index % 2 == 0 ? "SN-12345" : "sn-12345" {
                    let split = Int.random(in: 0..<3, using: &generator) == 0
                    raw += String(character) + (split ? pick(breaks, &generator) : "")
                }
            }
            raw += pick(noise, &generator)
            let withheld = [["SN-12345"], ["SN-1\n2345"], ["sn-1\u{2028}23\t45"]][index % 3]
            let label = UntrustedLabel(raw, withholding: withheld)
            let reference = UntrustedLabel(spaced(raw), withholding: withheld.map(spaced))
            stricter += label.text == reference.text ? 0 : 1
            let shown = Self.revealed(label.text)
            #expect(Self.isSubsequence(shown, of: Self.revealed(reference.text)), "\(raw.debugDescription)")
            // Whole characters, so a secret with a mark on a letter is another string.
            for segment in Self.segments(label.text) {
                let kept = String.UnicodeScalarView(segment.unicodeScalars.filter { $0 != " " })
                let compact = Array(String(kept).lowercased())
                let leaks = compact.count >= secret.count
                    && (0...(compact.count - secret.count)).contains {
                        compact[$0..<($0 + secret.count)].elementsEqual(secret)
                    }
                #expect(!leaks, "\(raw.debugDescription) -> \(label.text.debugDescription)")
            }
        }
        #expect(stricter >= 100, "\(stricter)")
    }

    // MARK: - Blank lookalikes, marker truncation, precheck

    @Test(arguments: [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x16FE4, 0x13441, 0x13442, 0x1BC9D, 0x1D159] as [UInt32])
    func eachBlankLookalikeIsRemoved(value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        let label = UntrustedLabel("a" + String(scalar) + "b")
        #expect(label.text == "ab" && label.wasSanitized)
        #expect(UntrustedLabel("SN-1" + String(scalar) + "2345", withholding: Self.serial).text == Self.marker)
        #expect(UntrustedTextSanitizer.blankLookalikes.contains(value))
    }

    @Test func theBlankLookalikeSetIsPinned() {
        let pinned: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x16FE4, 0x13441, 0x13442, 0x1BC9D, 0x1D159]
        #expect(UntrustedTextSanitizer.blankLookalikes == pinned)
    }

    /// At every byte limit the label keeps a whole marker or ends before it.
    @Test(arguments: ["Rig SN-12345 tail", "[withheld] x", "x [withheld]"])
    func truncationNeverShowsPartOfAMarker(raw: String) throws {
        let shown = raw.replacingOccurrences(of: "SN-12345", with: Self.marker)
        let start = try #require(shown.range(of: Self.marker)).lowerBound.utf16Offset(in: shown)
        for limit in 0...(shown.utf8.count + 1) {
            let label = UntrustedLabel(raw, maximumBytes: limit, withholding: Self.serial)
            let kept = limit < start || limit >= start + Self.marker.utf8.count ? min(limit, shown.utf8.count) : start
            #expect(label.text == String(shown.prefix(kept)), "\(limit)")
            #expect(label.isTruncated == (limit < shown.utf8.count))
        }
    }

    /// An ASCII space is kept without classifying it; `disposition` would keep it too.
    @Test func anASCIISpaceIsKeptWithoutClassifyingIt() {
        var work = UntrustedTextSanitizer.ScanWork()
        let padded = String(repeating: " ", count: 5_000) + "SN-12345" + String(repeating: " ", count: 5_000)
        let scan = UntrustedTextSanitizer.filterScalars(
            padded.unicodeScalars, keeping: 4_096, trimmed: true, work: &work
        )
        #expect(work.dispositions == 8)
        #expect(scan.text == "SN-12345" + String(repeating: " ", count: 4_088) && scan.isComplete && scan.changed)
        let blank: Unicode.Scalar = " "
        let space = blank.properties
        #expect(!space.isDefaultIgnorableCodePoint && !space.isVariationSelector)
        #expect(space.generalCategory == .spaceSeparator)
        #expect(!UntrustedTextSanitizer.blankLookalikes.contains(0x20) && !UntrustedTextSanitizer.isJoiner(" "))
    }
}

/// SplitMix64, so the differential is reproducible.
private struct NeutralSnapshotUnicodeRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
