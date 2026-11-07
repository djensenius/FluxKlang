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

    /// A withheld string in source form; longer source strings use a safe prefix. Empty fail-closed terms
    /// withhold every applicable label; scoped terms are dropped only after a complete scan with no new blanks.
    struct WithheldTerm: Hashable, Sendable {
        static let failClosed = WithheldTerm(text: "", isPrefix: true)
        static let newBlankFailClosed = WithheldTerm(text: "", isPrefix: true, requiresNewBlank: true)

        let text: String
        let isPrefix: Bool
        /// Apply only to labels whose scan removed a new blank lookalike.
        let requiresNewBlank: Bool
        /// The spaces of `text` that replaced a control or separator (`Scan.separators`):
        /// ordinals among its U+0020 scalars, ascending and in range.
        let separators: [Int]
        /// The form of `text` that is matched.
        let form: MatchForm
        /// The form of `text` without its `separators`, matched against labels without
        /// theirs; `form` when there are none, and nil when that text is shorter than
        /// `minimumRedactedBytes`.
        let compactForm: MatchForm?

        /// The canonical caseless form of `text` (`caselessForm`), the form that is matched.
        var folded: [Unicode.Scalar] { form.folded }
        /// See `MatchForm.core`.
        var core: Range<Int> { form.core }
        var isFailClosed: Bool { isPrefix && text.isEmpty }

        init(text: String, isPrefix: Bool, separators: [Int] = [], requiresNewBlank: Bool = false) {
            self.text = text
            self.isPrefix = isPrefix
            self.requiresNewBlank = requiresNewBlank
            let spaces = text.unicodeScalars.count { $0 == " " }
            self.separators = Set(separators).filter { (0..<spaces).contains($0) }.sorted()
            form = MatchForm(text.unicodeScalars)
            let compact = UntrustedTextSanitizer.dropping(self.separators, from: text)
            compactForm = self.separators.isEmpty ? form
                : compact.utf8.count < minimumRedactedBytes ? nil : MatchForm(compact.unicodeScalars)
        }

        /// Equality uses text and `isPrefix`; separators add a match form and preparing a prepared term is idempotent.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text == rhs.text && lhs.isPrefix == rhs.isPrefix
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
            hasher.combine(isPrefix)
        }
    }

    /// A text in the canonical caseless form it is matched in.
    struct MatchForm: Hashable, Sendable {
        /// The canonical caseless form of the text (`caselessForm`).
        let folded: [Unicode.Scalar]
        /// The indices of `folded` from its first to its last starter (`matchClass` 0),
        /// matched in place. The marks before and after it are matched per class
        /// (`marksFit`), because a label's marks can be reordered in among them. Empty
        /// when `folded` has no starter.
        let core: Range<Int>

        init(_ text: some Sequence<Unicode.Scalar>) {
            let folded = UntrustedTextSanitizer.caselessForm(text)
            let starters = folded.indices.filter { UntrustedTextSanitizer.matchClass(folded[$0]) == 0 }
            self.folded = folded
            core = (starters.first ?? 0)..<((starters.last ?? -1) + 1)
        }
    }

    /// Prepares a withheld string like a label (filtering, source form), then trims
    /// surrounding whitespace. Filtering is `trimmed`, so surrounding whitespace and
    /// controls, however long, neither count toward the limit nor cut the string (an
    /// all-whitespace string gives no term), and a complete string is trimmed before the
    /// byte limit applies. No display cap applies: graphemes are not capped, so
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
    /// Eligibility is measured on the trimmed A1 shadow (`a1Text`): the three A1h-added
    /// blank lookalikes count at their original UTF-8 width even though the matched form
    /// omits them. Leading/trailing new blanks are not whitespace and count as A1 content;
    /// ordinary surrounding whitespace is trimmed. Existing compact separator forms keep
    /// their independent `minimumRedactedBytes` minimum. A cut A1 prefix whose source
    /// included a newly removed blank fails closed rather than using a shortened prefix.
    static func withheldTerm(_ raw: String) -> WithheldTerm? {
        let filtered = filterScalars(raw.unicodeScalars, keeping: maximumWithheldBytes, trimmed: true)
        return withheldTerm(filtered)
    }

    /// Builds a term from the shared trimmed scan also used by `RefusedIdentities`.
    static func withheldTerm(_ filtered: Scan) -> WithheldTerm? {
        var text = sourceForm(filtered.text)
        var a1Text = sourceForm(filtered.a1Text ?? filtered.text)
        if filtered.isComplete { a1Text = a1Text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let termSeparators = shiftedSeparatorsAfterLeadingTrim(filtered.separators, from: text)
        var isPrefix = !filtered.isComplete || a1Text.utf8.count > maximumWithheldBytes
        let requiresNewBlank = filtered.removedNewBlankBytes > 0
        // A removed blank can move an A1 byte cut. A short filtered prefix no longer
        // identifies a safe matching prefix, so preserve A1's fail-closed outcome.
        if isPrefix, requiresNewBlank { return .newBlankFailClosed }
        // Trailing whitespace kept within the limit must not push a complete string over the
        // byte limit; a cut string keeps it so its split last character is still dropped.
        if !isPrefix { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.utf8.count > maximumWithheldBytes {
            text = graphemePrefix(text, fittingBytes: maximumWithheldBytes).text
            isPrefix = true
        }
        if isPrefix, !text.isEmpty { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let eligibilityBytes = isPrefix ? text.utf8.count : a1Text.utf8.count
        guard eligibilityBytes >= minimumRedactedBytes else {
            return isPrefix ? .failClosed : nil
        }
        guard !text.isEmpty else { return requiresNewBlank ? .newBlankFailClosed : .failClosed }
        return WithheldTerm(
            text: text, isPrefix: isPrefix, separators: termSeparators, requiresNewBlank: requiresNewBlank
        )
    }

    private static func shiftedSeparatorsAfterLeadingTrim(_ separators: [Int], from text: String) -> [Int] {
        let leadingWhitespace = text.unicodeScalars.prefix {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let leadingSpaces = leadingWhitespace.count { $0 == " " }
        guard leadingSpaces > 0 else { return separators }
        return separators.compactMap { $0 >= leadingSpaces ? $0 - leadingSpaces : nil }
    }

    /// The distinct terms for `raw` strings, sorted for determinism. Equal terms with
    /// different `separators` are all kept, since each is also matched without its own.
    static func withheldTerms(_ raw: [String]) -> [WithheldTerm] {
        let scans = raw.map {
            filterScalars($0.unicodeScalars, keeping: maximumWithheldBytes, trimmed: true)
        }
        return withheldTerms(scans)
    }

    /// Prepares terms from scans already shared with the identity-form pipeline.
    static func withheldTerms(_ scans: [Scan]) -> [WithheldTerm] {
        let sorted = scans.flatMap(preparedTerms).sorted { lhs, rhs in
            if lhs.text != rhs.text { return lhs.text < rhs.text }
            if lhs.isPrefix != rhs.isPrefix { return !lhs.isPrefix }
            if lhs.requiresNewBlank != rhs.requiresNewBlank { return !lhs.requiresNewBlank }
            return lhs.separators.lexicographicallyPrecedes(rhs.separators)
        }
        var terms: [WithheldTerm] = []
        for term in sorted where terms.last != term || terms.last?.separators != term.separators
            || terms.last?.requiresNewBlank != term.requiresNewBlank {
            terms.append(term)
        }
        return terms
    }

    static func applicableTerms(_ terms: [WithheldTerm], for scan: Scan) -> [WithheldTerm] {
        guard scan.removedNewBlankBytes == 0, scan.isComplete else { return terms }
        return terms.filter { !$0.requiresNewBlank }
    }

    /// Redacts withheld terms found in the source form of `display`. When anything
    /// is withheld the result is the redacted source form; otherwise `display` is
    /// unchanged and keeps its joiners and presentation selectors (so an emoji
    /// family loses them only when the label also contains a withheld string).
    ///
    /// `separators` are the spaces of `display` that replaced a control or separator
    /// (`Scan.separators`); they keep their ordinals in the source form, because
    /// normalization neither creates nor removes U+0020.
    static func redactMatchForm(
        of display: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool, separators: [Int] = []
    ) -> Result {
        redactMatchFormWithSeparators(
            of: display, withheld: withheld, marker: marker, scanIsComplete: scanIsComplete, separators: separators
        ).result
    }

    /// `compactOnly` means a compact match added a range not covered by ordinary matches.
    /// Separator provenance is remapped through the same range replacement.
    static func redactMatchFormWithSeparators(
        of display: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool, separators: [Int]
    ) -> SeparatorRedaction {
        let source = sourceForm(display)
        let redacted = redactWithRanges(
            source, withheld: withheld, marker: marker, scanIsComplete: scanIsComplete, separators: separators
        )
        guard redacted.result.changed else {
            return SeparatorRedaction(
                result: (display, false), separators: separators, compactOnly: false, hasExact: false
            )
        }
        return SeparatorRedaction(
            result: redacted.result,
            separators: remapSeparators(separators, in: source, ranges: redacted.ranges, marker: marker),
            compactOnly: redacted.compactOnly, hasExact: redacted.hasExact
        )
    }

    private static func remapSeparators(
        _ separators: [Int], in text: String, ranges: [Range<Int>], marker: String
    ) -> [Int] {
        var marked: Set<Int> = []
        var wanted = Set(separators)
        var ordinal = 0
        for (offset, scalar) in text.unicodeScalars.enumerated() where scalar == " " {
            if wanted.remove(ordinal) != nil { marked.insert(offset) }
            ordinal += 1
        }
        let scalars = Array(text.unicodeScalars)
        let markerSpaces = marker.unicodeScalars.filter { $0 == " " }.count
        var outputSpaces = 0
        var cursor = 0
        var result: [Int] = []
        for range in ranges {
            for offset in cursor..<range.lowerBound where scalars[offset] == " " {
                if marked.contains(offset) { result.append(outputSpaces) }
                outputSpaces += 1
            }
            outputSpaces += markerSpaces
            cursor = range.upperBound
        }
        for offset in cursor..<scalars.count where scalars[offset] == " " {
            if marked.contains(offset) { result.append(outputSpaces) }
            outputSpaces += 1
        }
        return result
    }

    /// Replaces every withheld range of `text` (a source form) in one pass: all
    /// ranges are found on the original text first (`withheldRanges`), overlapping
    /// and adjacent ones are merged, and each merged range becomes one marker. The
    /// result therefore does not depend on term order, and no replacement can hide
    /// another term or the scan-cut tail.
    ///
    /// Controls and separators can split a secret, so text and terms are also matched
    /// without their recorded separators. `SN-1\u{2028}2345` and `SN-12345` match either way.
    ///
    /// Accepted limit: only whole terms are found; partial quotes are not redacted,
    /// except in the withheld tail of a scan-cut label.
    static func redact(
        _ text: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool = true,
        separators: [Int] = []
    ) -> Result {
        redactWithRanges(
            text, withheld: withheld, marker: marker, scanIsComplete: scanIsComplete, separators: separators
        ).result
    }

    /// One range calculation feeds both display replacement and separator remapping.
    private static func redactWithRanges(
        _ text: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool, separators: [Int]
    ) -> RangeRedaction {
        let scalars = Array(text.unicodeScalars)
        let map = CaselessMap(text)
        var found = withheldRanges(in: map, terms: withheld, scanIsComplete: scanIsComplete)
        let exactCoverage = merge(found)
        let exactMatches = withheldRanges(in: map, terms: withheld, scanIsComplete: true)
        let hasExactMatch = !exactMatches.isEmpty
        let compactMap = separators.isEmpty ? map : CaselessMap(text, dropping: separators)
        let compactTerms = separators.isEmpty ? withheld.filter { !$0.separators.isEmpty } : withheld
        let compactRanges = withheldRanges(
            in: compactMap, terms: compactTerms, scanIsComplete: scanIsComplete, compact: true
        )
        let compactMatches = scanIsComplete ? compactRanges : withheldRanges(
            in: compactMap, terms: compactTerms, scanIsComplete: true, compact: true
        )
        let compactOnly = compactMatches.contains { candidate in
            !exactCoverage.contains { $0.lowerBound <= candidate.lowerBound && $0.upperBound >= candidate.upperBound }
        }
        found += compactRanges
        let ranges = merge(found)
        guard !ranges.isEmpty else {
            return RangeRedaction(
                result: (text, false), ranges: [], compactOnly: false, hasExact: false
            )
        }
        var result = String.UnicodeScalarView()
        var cursor = 0
        for range in ranges {
            result.append(contentsOf: scalars[cursor..<range.lowerBound])
            result.append(contentsOf: marker.unicodeScalars)
            cursor = range.upperBound
        }
        result.append(contentsOf: scalars[cursor...])
        return RangeRedaction(
            result: (String(result), true), ranges: ranges, compactOnly: compactOnly, hasExact: hasExactMatch
        )
    }

    /// Source scalar ranges to withhold, always whole source graphemes:
    /// - all of the text when a term is `WithheldTerm.failClosed`;
    /// - every caseless occurrence, overlapping ones included, expanded to the source
    ///   graphemes containing its first and last scalars (`CaselessMap`), covering NFD-reordered marks;
    /// - for a prefix term, its first match through the end of the text;
    /// - for a cut scan, the final mark run and up to `L - 1` preceding caseless scalars,
    ///   extended to whole graphemes, where `L` is the longest term. This catches partial
    ///   terms and unfinished normalization segments, over-redacting only that tail. The
    ///   final mark run is found in one backward walk.
    ///
    /// `compact` matches each term's `compactForm`, skipping terms without one.
    ///
    /// Cost: O(n·m), with `n` linear in the scan limit and `m` bounded by
    /// `maximumWithheldBytes`; edge checks add O(n) per term and O(m) per match.
    /// Exact, compact and provenance scans can quadruple work on cut scans.
    static func withheldRanges(
        in map: CaselessMap, terms: [WithheldTerm], scanIsComplete: Bool, compact: Bool = false
    ) -> [Range<Int>] {
        guard map.sourceCount > 0 else { return [] }
        if terms.contains(where: { $0.isFailClosed }) { return [0..<map.sourceCount] }
        var ranges: [Range<Int>] = []
        let forms = terms.map { compact ? $0.compactForm : $0.form }
        for (term, form) in zip(terms, forms) {
            guard let form, !form.folded.isEmpty else { continue }
            for match in occurrences(of: form, in: map.scalars, firstOnly: term.isPrefix) {
                let end = term.isPrefix ? map.sourceCount : map.graphemeEnd[match.upperBound - 1]
                ranges.append(map.graphemeStart[match.lowerBound]..<end)
            }
        }
        if !scanIsComplete, !map.scalars.isEmpty, let longest = forms.compactMap({ $0?.folded.count }).max(),
           longest > 1 {
            let tail = runStart(before: map.scalars.count, in: map.scalars)
            let first = max(0, tail - (longest - 1))
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
    /// term with no starter must be placeable inside one run. The match covers those runs,
    /// which may hold any number of the label's own marks (see the scan-cut window in
    /// `withheldRanges`). This never misses a canonically caseless-equivalent placement of
    /// the edges; it may over-match (over-redact) around a real `ι`, which `matchClass`
    /// counts as a mark.
    static func occurrences(of term: MatchForm, in text: [Unicode.Scalar], firstOnly: Bool) -> [Range<Int>] {
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
}
