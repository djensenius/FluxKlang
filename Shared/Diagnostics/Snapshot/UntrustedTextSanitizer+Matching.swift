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
    /// longer than `maximumWithheldBytes` and this is a safe prefix of it.
    struct WithheldTerm: Hashable, Sendable {
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
    /// limits fails closed: it is cut to `maximumWithheldBytes`, loses its last
    /// grapheme (which the cut may have split) and becomes a prefix term, which
    /// redacts from its first match to the end of the label.
    /// Returns nil when fewer than `minimumRedactedBytes` remain.
    static func withheldTerm(_ raw: String) -> WithheldTerm? {
        let filtered = filterScalars(raw.unicodeScalars, keeping: maximumWithheldBytes)
        var display = filtered.text
        var isPrefix = !filtered.isComplete
        if display.utf8.count > maximumWithheldBytes {
            display = truncate(display, maximumBytes: maximumWithheldBytes).text
            isPrefix = true
        }
        if isPrefix, !display.isEmpty { display.removeLast() }
        let text = matchForm(display)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.utf8.count >= minimumRedactedBytes ? WithheldTerm(text: text, isPrefix: isPrefix) : nil
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

    /// Full case folding, approximated per scalar as the lowercase mapping of the
    /// uppercase mapping: `ß`, `SS` and `ss` fold to `ss`; `ς`, `σ` and `Σ` to `σ`.
    /// Lengths may change, which is why matches are mapped back through a source index.
    static func fold(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if scalar.isASCII {
            let value = UInt8(scalar.value)
            return [Unicode.Scalar((65...90).contains(value) ? value + 32 : value)]
        }
        return scalar.properties.uppercaseMapping.unicodeScalars.flatMap { upper in
            upper.properties.lowercaseMapping.unicodeScalars
        }
    }
}
