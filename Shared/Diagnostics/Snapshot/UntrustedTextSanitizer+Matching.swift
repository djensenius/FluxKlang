//
//  UntrustedTextSanitizer+Matching.swift
//  FluxKlang
//
//  Withheld strings are found in a "match form" of a label without ZWJ/ZWNJ or
//  variation selectors, normalized to NFC, so the only invisible scalars that
//  survive filtering cannot split a secret.
//

import Foundation

extension UntrustedTextSanitizer {
    /// The display text without match-ignorable scalars, normalized to NFC
    /// afterwards because a removed joiner may have blocked a composition
    /// (`\u{1100}\u{200D}\u{1161}` becomes `가`). Idempotent. Labels and withheld
    /// strings are compared in this form.
    static func matchForm(_ display: String) -> String {
        var scalars = display.unicodeScalars
        scalars.removeAll(where: isMatchIgnorable)
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// ZWJ/ZWNJ and variation selectors. After `filterScalars` these are the only
    /// default-ignorable scalars left (it keeps joiners between letters or emoji and
    /// FE0E/FE0F after an emoji, and removes every other default-ignorable or format
    /// scalar), so this class covers every invisible scalar a display text can hold.
    /// The test covers all variation selectors (FE00–FE0F, E0100–E01EF and the
    /// Mongolian free variation selectors) so a raw withheld string is handled alike.
    ///
    /// Non-goal: visible space separators (Zs, such as a hair space U+200A inside a
    /// UID) are content and stay in the match form. A redacted label is shown in its
    /// match form, so removing them would corrupt the spacing of ordinary labels.
    static func isMatchIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        isJoiner(scalar) || scalar.properties.isVariationSelector
    }

    /// Redacting shorter strings would mangle ordinary words (evidence "ok").
    static let minimumRedactedBytes = 6
    /// At most this many UTF-8 bytes of a withheld string are prepared and matched.
    /// With the default 128-byte labels the scan limit stays at its 4,096 floor.
    static let maximumWithheldBytes = 1_024

    /// A withheld string in match form. When `isPrefix` is true the source was
    /// longer than `maximumWithheldBytes` and this is a safe prefix of it. An empty
    /// prefix term (`failClosed`) stands for a long string with no safe prefix and
    /// withholds every label it is applied to.
    struct WithheldTerm: Hashable, Sendable {
        static let failClosed = WithheldTerm(text: "", isPrefix: true)

        let text: String
        let isPrefix: Bool
        /// `text` case-folded scalar by scalar (`fold`), the form that is matched.
        let folded: [Unicode.Scalar]

        init(text: String, isPrefix: Bool) {
            self.text = text
            self.isPrefix = isPrefix
            folded = text.unicodeScalars.flatMap(UntrustedTextSanitizer.fold)
        }
    }

    /// Prepares a withheld string like a label (filtering, match form), then trims
    /// surrounding whitespace. No display cap applies: graphemes are not capped, so
    /// a term matches the uncapped label it came from. A string over the matching
    /// limits becomes a prefix term, which redacts from its first match to the end
    /// of the label. The prefix is cut from the match form (joiners already removed,
    /// so an emoji family is many short characters, not one huge grapheme) to
    /// `maximumWithheldBytes` on a match-form character boundary, and loses its last
    /// character, which the scan limit may have split. If fewer than
    /// `minimumRedactedBytes` remain (one giant grapheme), the term is
    /// `WithheldTerm.failClosed`: it is never dropped.
    /// Returns nil only for a complete string shorter than `minimumRedactedBytes`.
    static func withheldTerm(_ raw: String) -> WithheldTerm? {
        let filtered = filterScalars(raw.unicodeScalars, keeping: maximumWithheldBytes)
        var text = matchForm(filtered.text)
        var isPrefix = !filtered.isComplete
        if text.utf8.count > maximumWithheldBytes {
            text = truncate(text, maximumBytes: maximumWithheldBytes).text
            isPrefix = true
        }
        if isPrefix, !text.isEmpty { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count >= minimumRedactedBytes else { return isPrefix ? .failClosed : nil }
        return WithheldTerm(text: text, isPrefix: isPrefix)
    }

    /// The distinct terms for `raw` strings, sorted for determinism.
    static func withheldTerms(_ raw: [String]) -> [WithheldTerm] {
        Set(raw.compactMap(withheldTerm)).sorted { lhs, rhs in
            lhs.text != rhs.text ? lhs.text < rhs.text : !lhs.isPrefix && rhs.isPrefix
        }
    }

    /// Redacts withheld terms found in the match form of `display`. When anything
    /// is withheld the result is the redacted match form; otherwise `display` is
    /// unchanged and keeps its joiners and presentation selectors (so an emoji
    /// family loses them only when the label also contains a withheld string).
    static func redactMatchForm(
        of display: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool
    ) -> Result {
        let redacted = redact(matchForm(display), withheld: withheld, marker: marker, scanIsComplete: scanIsComplete)
        return redacted.changed ? redacted : (display, false)
    }

    /// Replaces every withheld range of `text` (a match form) in one pass: all
    /// ranges are found on the original text first (`withheldRanges`), overlapping
    /// and adjacent ones are merged, and each merged range becomes one marker. The
    /// result therefore does not depend on term order, and no replacement can hide
    /// another term or the scan-cut tail.
    ///
    /// Accepted limit: only whole terms are found. A partial quote of a secret,
    /// short or long (for example the first 300 bytes of a 2,000-byte secret,
    /// shorter than its 1,024-byte prefix term), is not redacted, except in the
    /// withheld tail of a scan-cut label.
    static func redact(
        _ text: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool = true
    ) -> Result {
        let scalars = Array(text.unicodeScalars)
        let ranges = merge(withheldRanges(in: scalars, terms: withheld, scanIsComplete: scanIsComplete))
        guard !ranges.isEmpty else { return (text, false) }
        var result = String.UnicodeScalarView()
        var cursor = 0
        for range in ranges {
            result.append(contentsOf: scalars[cursor..<range.lowerBound])
            result.append(contentsOf: marker.unicodeScalars)
            cursor = range.upperBound
        }
        result.append(contentsOf: scalars[cursor...])
        return (String(result), true)
    }

    /// Scalar ranges of `text` to withhold:
    /// - all of it when a term is `WithheldTerm.failClosed`;
    /// - every occurrence of every term, overlapping ones included, found on the
    ///   case-folded text and mapped back through the fold's source index (a match
    ///   that starts or ends inside one scalar's folding covers that whole scalar);
    /// - for a prefix term, its first match through the end of the text;
    /// - when the scan was cut and a term exists, the last `L - 1` scalars, where `L`
    ///   is the longest folded term. Option (ii) of the ruling: a cut-off secret is a
    ///   proper prefix of an occurrence, so it has at most `L - 1` folded and hence at
    ///   most `L - 1` text scalars, and this tail always covers it, whatever its case
    ///   folding or composition at the cut. The cost is over-redaction of up to
    ///   `L - 1` trailing scalars of a label whose input exceeded the scan limit
    ///   (at least 4,096 kept scalars, far past the default 128-byte label).
    ///
    /// Cost: each term is tried at every folded position, O(n·m) for n folded text
    /// scalars and m folded term scalars. n is bounded by the scan limit (each
    /// scalar folds to at most three) and m by `maximumWithheldBytes`.
    static func withheldRanges(
        in text: [Unicode.Scalar], terms: [WithheldTerm], scanIsComplete: Bool
    ) -> [Range<Int>] {
        if terms.contains(.failClosed), !text.isEmpty { return [0..<text.count] }
        var folded: [Unicode.Scalar] = []
        var source: [Int] = []
        for (index, scalar) in text.enumerated() {
            let folding = fold(scalar)
            folded.append(contentsOf: folding)
            source.append(contentsOf: repeatElement(index, count: folding.count))
        }
        var ranges: [Range<Int>] = []
        for term in terms where !term.folded.isEmpty {
            for start in occurrences(of: term.folded, in: folded, firstOnly: term.isPrefix) {
                let end = term.isPrefix ? text.count : source[start + term.folded.count - 1] + 1
                ranges.append(source[start]..<end)
            }
        }
        if !scanIsComplete, let longest = terms.map(\.folded.count).max(), longest > 1, !text.isEmpty {
            ranges.append(max(0, text.count - (longest - 1))..<text.count)
        }
        return ranges
    }

    /// Start offsets of every occurrence of `term` in `text`, overlapping ones included.
    static func occurrences(of term: [Unicode.Scalar], in text: [Unicode.Scalar], firstOnly: Bool) -> [Int] {
        guard let first = term.first, term.count <= text.count else { return [] }
        var found: [Int] = []
        for start in 0...(text.count - term.count) where text[start] == first {
            guard text[start..<(start + term.count)].elementsEqual(term) else { continue }
            found.append(start)
            if firstOnly { break }
        }
        return found
    }

    /// Sorts ranges and merges overlapping or adjacent ones.
    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Full case folding per scalar, the same function for terms and labels: the
    /// lowercase mapping of the uppercase mapping, repeated to a fixed point (at most
    /// `maximumFoldRounds`). One round is not enough: `ẞ` gives `ß`, and only the
    /// second round gives `ss`. Lengths may change, which is why matches are mapped
    /// back through a source index.
    ///
    /// Checked against CaseFolding.txt (statuses C and F) over every scalar the
    /// toolchain assigns: two scalars fold equal here exactly when they do under C+F,
    /// except that dotless `ı` also folds with `i` (over-redaction only). Scalars the
    /// toolchain leaves unassigned are removed by `filterScalars` before matching.
    /// `String.folding(options: .caseInsensitive)` was not used: per character it
    /// leaves U+1C80–U+1C88 unfolded, which C+F folds to Cyrillic lowercase.
    static func fold(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if scalar.isASCII {
            let value = UInt8(scalar.value)
            return [Unicode.Scalar((65...90).contains(value) ? value + 32 : value)]
        }
        var folding = [scalar]
        for _ in 0..<maximumFoldRounds {
            let next = folding.flatMap(\.properties.uppercaseMapping.unicodeScalars)
                .flatMap(\.properties.lowercaseMapping.unicodeScalars)
            if next == folding { break }
            folding = next
        }
        return folding
    }

    /// Every scalar reaches its fixed point within two rounds; three leaves a margin.
    static let maximumFoldRounds = 3
}
