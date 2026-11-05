//
//  UntrustedTextSanitizer+Matching.swift
//  FluxKlang
//
//  Withheld strings are found by Unicode canonical caseless matching (Unicode
//  §3.13, D145) on a "source form" of the label without ZWJ/ZWNJ or variation
//  selectors, so the only invisible scalars that survive filtering cannot split
//  a secret, and neither case nor canonical equivalence can hide one.
//

import Foundation

extension UntrustedTextSanitizer {
    /// The display text without match-ignorable scalars, normalized to NFC
    /// afterwards because a removed joiner may have blocked a composition
    /// (`\u{1100}\u{200D}\u{1161}` becomes `가`). Idempotent. A redacted label is
    /// shown in this form, and withheld strings are prepared (cut, measured) in it.
    static func sourceForm(_ display: String) -> String {
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

    /// A withheld string in source form. When `isPrefix` is true the source was
    /// longer than `maximumWithheldBytes` and this is a safe prefix of it. An empty
    /// prefix term (`failClosed`) stands for a long string with no safe prefix and
    /// withholds every label it is applied to.
    struct WithheldTerm: Hashable, Sendable {
        static let failClosed = WithheldTerm(text: "", isPrefix: true)

        let text: String
        let isPrefix: Bool
        /// The canonical caseless form of `text` (`caselessForm`), the form that is matched.
        let folded: [Unicode.Scalar]
        /// The indices of `folded` from its first to its last starter (`matchClass` 0),
        /// matched in place. The marks before and after it are matched per class
        /// (`marksFit`), because a label's marks can be reordered in among them. Empty
        /// when `folded` has no starter.
        let core: Range<Int>

        init(text: String, isPrefix: Bool) {
            self.text = text
            self.isPrefix = isPrefix
            let folded = UntrustedTextSanitizer.caselessForm(text.unicodeScalars)
            let starters = folded.indices.filter { UntrustedTextSanitizer.matchClass(folded[$0]) == 0 }
            self.folded = folded
            core = (starters.first ?? 0)..<((starters.last ?? -1) + 1)
        }
    }

    /// Prepares a withheld string like a label (filtering, source form), then trims
    /// surrounding whitespace. No display cap applies: graphemes are not capped, so
    /// a term matches the uncapped label it came from. A string over the matching
    /// limits becomes a prefix term, which redacts from its first match to the end
    /// of the label. The prefix is cut from the source form (joiners already removed,
    /// so an emoji family is many short characters, not one huge grapheme) to
    /// `maximumWithheldBytes` on a source-form character boundary (`graphemePrefix`,
    /// which does not cap the kept graphemes: the label is matched uncapped, so a
    /// capped prefix could miss it), and loses its last character, which the scan
    /// limit may have split. If fewer than
    /// `minimumRedactedBytes` remain (one giant grapheme), the term is
    /// `WithheldTerm.failClosed`: it is never dropped.
    /// Returns nil only for a complete string shorter than `minimumRedactedBytes`.
    static func withheldTerm(_ raw: String) -> WithheldTerm? {
        let filtered = filterScalars(raw.unicodeScalars, keeping: maximumWithheldBytes)
        var text = sourceForm(filtered.text)
        var isPrefix = !filtered.isComplete
        if text.utf8.count > maximumWithheldBytes {
            text = graphemePrefix(text, fittingBytes: maximumWithheldBytes).text
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

    /// Redacts withheld terms found in the source form of `display`. When anything
    /// is withheld the result is the redacted source form; otherwise `display` is
    /// unchanged and keeps its joiners and presentation selectors (so an emoji
    /// family loses them only when the label also contains a withheld string).
    static func redactMatchForm(
        of display: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool
    ) -> Result {
        let redacted = redact(sourceForm(display), withheld: withheld, marker: marker, scanIsComplete: scanIsComplete)
        return redacted.changed ? redacted : (display, false)
    }

    /// Replaces every withheld range of `text` (a source form) in one pass: all
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
        let map = CaselessMap(text)
        let ranges = merge(withheldRanges(in: map, terms: withheld, scanIsComplete: scanIsComplete))
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

    /// Source scalar ranges to withhold, always whole source graphemes:
    /// - all of the text when a term is `WithheldTerm.failClosed`;
    /// - every occurrence of every term in the caseless form (`occurrences`),
    ///   overlapping ones included, expanded to the source graphemes that contain its
    ///   first and last scalars (`CaselessMap`), which also covers marks that NFD
    ///   reordered;
    /// - for a prefix term, its first match through the end of the text;
    /// - when the scan was cut and a term exists, the last `L - 1` caseless scalars,
    ///   where `L` is the longest caseless term, extended back to the start of the
    ///   source grapheme that holds the first of them. A cut-off secret is a proper
    ///   prefix of an occurrence, so its caseless form is at most `L - 1` scalars,
    ///   and the grapheme extension covers a normalization segment the cut left
    ///   unfinished (Hangul L+V+T, a run of combining marks). The cost is
    ///   over-redaction of up to `L - 1` trailing caseless scalars plus one grapheme
    ///   of a label whose input exceeded the scan limit (at least 4,096 kept scalars,
    ///   far past the default 128-byte label).
    ///
    /// Cost: each term is tried at every caseless position, O(n·m) for n caseless
    /// text scalars and m caseless term scalars. n is linear in the scan limit
    /// (a scalar folds to at most three and NFD expands it by a bounded factor) and
    /// m in `maximumWithheldBytes`. The edge checks add O(n + m) per match.
    static func withheldRanges(in map: CaselessMap, terms: [WithheldTerm], scanIsComplete: Bool) -> [Range<Int>] {
        guard map.sourceCount > 0 else { return [] }
        if terms.contains(.failClosed) { return [0..<map.sourceCount] }
        var ranges: [Range<Int>] = []
        for term in terms where !term.folded.isEmpty {
            for match in occurrences(of: term, in: map.scalars, firstOnly: term.isPrefix) {
                let end = term.isPrefix ? map.sourceCount : map.graphemeEnd[match.upperBound - 1]
                ranges.append(map.graphemeStart[match.lowerBound]..<end)
            }
        }
        if !scanIsComplete, let longest = terms.map(\.folded.count).max(), longest > 1 {
            let first = max(0, map.scalars.count - (longest - 1))
            ranges.append(map.graphemeStart[first]..<map.sourceCount)
        }
        return ranges
    }

    /// Caseless ranges of every occurrence of `term` in `text`, overlapping ones included.
    ///
    /// The term's `core` (first to last starter) must appear in place. Canonical
    /// reordering never moves a mark across a starter, so inside the core both forms
    /// agree. At its edges it can: NFD sorts the label's marks next to the term's leading
    /// or trailing marks by class, so `q` + U+0300 + U+0316 + `SN…` holds U+0316 + `SN…`
    /// but its caseless form is `q` U+0316 U+0300 `s n…`, and `é` + U+0316 (displayed in
    /// NFC as U+00E9 U+0316, which holds `SN-12345é` verbatim) is `e` U+0316 U+0301. So the
    /// term's leading marks must be placeable at the end of the label's run of marks before
    /// the core, and its trailing marks at the start of the run after it (`marksFit`). A
    /// term with no starter must be placeable inside one run. The match covers those runs.
    static func occurrences(of term: WithheldTerm, in text: [Unicode.Scalar], firstOnly: Bool) -> [Range<Int>] {
        let core = term.folded[term.core]
        guard let first = core.first else { return markRuns(holding: term.folded[...], in: text, firstOnly: firstOnly) }
        guard core.count <= text.count else { return [] }
        let lead = term.folded[..<term.core.lowerBound]
        let trail = term.folded[term.core.upperBound...]
        var found: [Range<Int>] = []
        for start in 0...(text.count - core.count) where text[start] == first {
            let end = start + core.count
            guard text[start..<end].elementsEqual(core) else { continue }
            let before = runStart(before: start, in: text)
            let after = runEnd(from: end, in: text)
            guard marksFit(lead, at: .end, of: text[before..<start]),
                  marksFit(trail, at: .start, of: text[end..<after]) else { continue }
            // The run after the core is part of its last grapheme; the run before it
            // belongs to the previous grapheme, which is withheld only for leading marks.
            found.append((lead.isEmpty ? start : before)..<after)
            if firstOnly { break }
        }
        return found
    }

    /// Runs of `text` where a term made only of marks can be placed (see `occurrences`).
    private static func markRuns(
        holding marks: ArraySlice<Unicode.Scalar>, in text: [Unicode.Scalar], firstOnly: Bool
    ) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start = 0
        while start < text.count {
            guard matchClass(text[start]) != 0 else {
                start += 1
                continue
            }
            let end = runEnd(from: start, in: text)
            if marksFit(marks, at: .inside, of: text[start..<end]) {
                found.append(start..<end)
                if firstOnly { break }
            }
            start = end
        }
        return found
    }

    /// The canonical combining class used to find runs of marks. `ι` counts as 240
    /// because it is also the fold of U+0345 (ccc 240), the one mark that folding turns
    /// into a starter: `α` U+0345 + U+0301 is `α` U+0301 `ι` in caseless form. A real `ι`
    /// therefore joins a run too, which can only widen a match.
    static func matchClass(_ scalar: Unicode.Scalar) -> UInt8 {
        scalar == "\u{03B9}" ? 240 : scalar.properties.canonicalCombiningClass.rawValue
    }

    private static func runStart(before index: Int, in text: [Unicode.Scalar]) -> Int {
        var start = index
        while start > 0, matchClass(text[start - 1]) != 0 { start -= 1 }
        return start
    }

    private static func runEnd(from index: Int, in text: [Unicode.Scalar]) -> Int {
        var end = index
        while end < text.count, matchClass(text[end]) != 0 { end += 1 }
        return end
    }

    enum RunEdge {
        case start, end, inside
    }

    /// Whether canonical reordering of `run` (a label's run of marks) can bring `marks`
    /// (a term's edge marks, in canonical order) together at its `edge`. Reordering keeps
    /// the order of marks of one class and may move marks of different classes past each
    /// other, so it can exactly when, for each class, the term's marks of that class are
    /// the run's first (`.start`), last (`.end`) or some consecutive (`.inside`) marks of
    /// that class. Linear in `run` and `marks` for the edges.
    static func marksFit(
        _ marks: ArraySlice<Unicode.Scalar>, at edge: RunEdge, of run: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        var wanted: [UInt8: [Unicode.Scalar]] = [:]
        for mark in marks { wanted[matchClass(mark), default: []].append(mark) }
        var held: [UInt8: [Unicode.Scalar]] = [:]
        for mark in run where wanted[matchClass(mark)] != nil { held[matchClass(mark), default: []].append(mark) }
        return wanted.allSatisfy { ccc, want in
            let have = held[ccc] ?? []
            switch edge {
            case .start: return have.prefix(want.count).elementsEqual(want)
            case .end: return have.suffix(want.count).elementsEqual(want)
            case .inside:
                return want.count <= have.count
                    && (0...(have.count - want.count)).contains { have[$0..<($0 + want.count)].elementsEqual(want) }
            }
        }
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

    /// The canonical caseless form NFD(fold(NFD(text))) of Unicode D145, the one
    /// form both terms and labels are matched in. `fold` is full case folding.
    static func caselessForm(_ text: some Sequence<Unicode.Scalar>) -> [Unicode.Scalar] {
        let scalars = Array(text)
        if scalars.allSatisfy(\.isASCII) { return scalars.flatMap(fold) }
        let decomposed = String(String.UnicodeScalarView(scalars)).decomposedStringWithCanonicalMapping
        let folded = String.UnicodeScalarView(decomposed.unicodeScalars.flatMap(fold))
        return Array(String(folded).decomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// The caseless form of a source text, with every caseless scalar mapped to
    /// the source scalar range of the grapheme that contains it.
    ///
    /// It is built grapheme by grapheme, which equals the caseless form of the
    /// complete text: NFD only reorders runs of nonstarters (ccc ≠ 0), and every
    /// nonstarter extends the grapheme before it except after a control, line or
    /// paragraph separator, which `filterScalars` has replaced with a space. Case
    /// folding is per scalar and its output is already NFD; only U+0345 changes
    /// class (240 to ι), and nothing it could reorder past follows it. Checked over
    /// every assigned scalar on this toolchain; `caselessMapMatchesTheWholeText`
    /// pins it for the test corpus.
    struct CaselessMap {
        private(set) var scalars: [Unicode.Scalar] = []
        private(set) var graphemeStart: [Int] = []
        private(set) var graphemeEnd: [Int] = []
        private(set) var sourceCount = 0

        init(_ text: String) {
            for grapheme in text {
                let width = grapheme.unicodeScalars.count
                let form = UntrustedTextSanitizer.caselessForm(grapheme.unicodeScalars)
                scalars.append(contentsOf: form)
                graphemeStart.append(contentsOf: repeatElement(sourceCount, count: form.count))
                graphemeEnd.append(contentsOf: repeatElement(sourceCount + width, count: form.count))
                sourceCount += width
            }
        }
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
