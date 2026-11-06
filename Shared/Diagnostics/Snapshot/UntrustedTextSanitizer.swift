//
//  UntrustedTextSanitizer.swift
//  FluxKlang
//
//  The pure steps behind `UntrustedLabel`. Each returns the new text and
//  whether it changed anything.
//

import Foundation

enum UntrustedTextSanitizer {
    typealias Result = (text: String, changed: Bool)

    static let maximumScalarsPerGrapheme = 8
    static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
    static let zeroWidthNonJoiner: Unicode.Scalar = "\u{200C}"

    struct Scan {
        let text: String
        let changed: Bool
        /// False when the kept-scalar limit stopped the scan before the end of the input.
        let isComplete: Bool
        /// The spaces that replaced a control, line or paragraph separator, as ordinals
        /// among the U+0020 scalars of `text` (ascending). Matching also tries the text
        /// without them, so `SN-1\u{2028}2345` is withheld for `SN-12345`.
        let separators: [Int]
        /// UTF-8 bytes of A1h-added blank lookalikes removed from this scan.
        let removedNewBlankBytes: Int
        /// A1-equivalent filtered text for trimmed term/identity eligibility and bounds.
        let a1Text: String?
    }

    /// Work done by `filterScalars`, counted so tests can pin the ASCII-space precheck.
    struct ScanWork {
        /// `disposition` calls; trimmed scans also classify the A1 shadow context.
        var dispositions = 0
    }

    private enum Disposition {
        case keep, remove, replaceWithSpace
    }

    /// Bounds how many raw scalars are kept: enough for the byte limit with
    /// capped graphemes, plus room to recognise a withheld string at the cut.
    ///
    /// The budget `maximumBytes × maximumScalarsPerGrapheme + longest` is an upper
    /// bound, so it saturates at `Int.max` instead of overflowing, and every byte limit
    /// the API accepts (any `Int`, including `Limits.labelBytes`) gives a budget without
    /// trapping. A negative limit counts as 0, as in `UntrustedLabel`, so the function is
    /// total. It is exact while
    /// `maximumBytes ≤ (Int.max − longest) / maximumScalarsPerGrapheme`: with no terms that
    /// is `Int.max / 8`, whose budget is `Int.max − 7`, and one more byte saturates.
    static func scanLimit(maximumBytes: Int, withheld: [String]) -> Int {
        let longest = withheld.map(\.unicodeScalars.count).max() ?? 0
        let graphemes = max(0, maximumBytes).multipliedReportingOverflow(by: maximumScalarsPerGrapheme)
        let budget = graphemes.partialValue.addingReportingOverflow(longest)
        guard !graphemes.overflow, !budget.overflow else { return .max }
        return max(4_096, budget.partialValue)
    }

    /// Filters scalars until `limit` of them have been kept. Removed scalars and
    /// kept match-ignorable scalars (joiners, presentation selectors) do not count,
    /// so the limit applies to the match form and invisible padding cannot push
    /// later text past it. A kept selector follows an emoji and a kept joiner
    /// follows a counted scalar or such a selector, so the kept text is at most
    /// `3 * limit` scalars. The scan stops (incomplete) only at a scalar it would
    /// keep once `limit` are kept; removable scalars past the limit are still
    /// scanned and removed, so trailing padding never makes the scan incomplete
    /// (still linear in the input).
    ///
    /// `trimmed` is for text that is trimmed afterwards (withheld terms and identities):
    /// whitespace and joiners/selectors are not kept before the first content scalar (kept,
    /// not whitespace, not match-ignorable) or once `limit` are kept, and the scan stops only
    /// at a content scalar. So surrounding whitespace never cuts the text, and kept text is
    /// still bounded. A long whitespace run is read to its end, linear as above. The A1h
    /// filtering decision always uses `kept` context; the parallel `a1Text` is an A1 shadow
    /// used only for legacy term eligibility and identity byte bounds.
    static func filterScalars(_ scalars: String.UnicodeScalarView, keeping limit: Int, trimmed: Bool = false) -> Scan {
        var work = ScanWork()
        return filterScalars(scalars, keeping: limit, trimmed: trimmed, work: &work)
    }

    /// `filterScalars`, counting its work. An ASCII space, the commonest padding of a long
    /// withheld string, is kept without classifying it (`disposition` keeps it anyway).
    static func filterScalars(
        _ scalars: String.UnicodeScalarView, keeping limit: Int, trimmed: Bool, work: inout ScanWork
    ) -> Scan {
        var kept = String.UnicodeScalarView()
        var a1Kept = String.UnicodeScalarView()
        var keptCount = 0
        var a1KeptCount = 0
        var changed = false
        var spaces = 0
        var removedNewBlankBytes = 0
        var separators: [Int] = []
        var index = scalars.startIndex
        while index != scalars.endIndex {
            let scalar = scalars[index]
            let nextIndex = scalars.index(after: index)
            let next = nextIndex == scalars.endIndex ? nil : scalars[nextIndex]
            let action: Disposition
            if scalar == " " {
                action = .keep
            } else {
                work.dispositions += 1
                action = disposition(of: scalar, after: kept, before: next)
            }
            // The A1 shadow determines legacy eligibility/bounds only. Filtering and
            // matching actions always use the current A1h context.
            let a1RawAction: Disposition
            if trimmed, scalar != " " {
                work.dispositions += 1
                a1RawAction = disposition(of: scalar, after: a1Kept, before: next)
            } else {
                a1RawAction = action
            }
            let (a1Action, removedBlankWidth) = a1Disposition(a1RawAction, for: scalar)
            if trimmed, a1Kept.isEmpty || a1KeptCount >= limit, a1Action != .remove, !isContent(scalar, a1Action) {
                changed = true
                index = nextIndex
                continue
            }
            if (trimmed ? a1KeptCount : keptCount) >= limit, a1Action != .remove {
                return Scan(
                    text: String(kept), changed: changed, isComplete: false, separators: separators,
                    removedNewBlankBytes: removedNewBlankBytes,
                    a1Text: trimmed ? String(a1Kept) : nil
                )
            }
            if trimmed {
                appendA1Shadow(scalar, action: a1Action, kept: &a1Kept, count: &a1KeptCount)
            }
            switch action {
            case .keep:
                kept.append(scalar)
                keptCount += isMatchIgnorable(scalar) ? 0 : 1
                spaces += scalar == " " ? 1 : 0
            case .remove:
                changed = true
                removedNewBlankBytes += removedBlankWidth
            case .replaceWithSpace:
                kept.append(" ")
                keptCount += 1
                changed = true
                separators.append(spaces)
                spaces += 1
            }
            index = nextIndex
        }
        return Scan(
            text: String(kept), changed: changed, isComplete: true, separators: separators,
            removedNewBlankBytes: removedNewBlankBytes, a1Text: trimmed ? String(a1Kept) : nil
        )
    }

    private static func appendA1Shadow(
        _ scalar: Unicode.Scalar, action: Disposition, kept: inout String.UnicodeScalarView, count: inout Int
    ) {
        switch action {
        case .keep:
            kept.append(scalar)
            count += isMatchIgnorable(scalar) ? 0 : 1
        case .remove:
            break
        case .replaceWithSpace:
            kept.append(" ")
            count += 1
        }
    }

    private static func disposition(
        of scalar: Unicode.Scalar, after kept: String.UnicodeScalarView, before next: Unicode.Scalar?
    ) -> Disposition {
        let properties = scalar.properties
        if isTag(scalar) || blankLookalikes.contains(scalar.value) { return .remove }
        if properties.isVariationSelector {
            let presentation = scalar.value == 0xFE0E || scalar.value == 0xFE0F
            return presentation && kept.last?.properties.isEmoji == true ? .keep : .remove
        }

        if isJoiner(scalar) {
            return joinsBefore(kept) && next.map(joinsAfter) == true ? .keep : .remove
        }
        if properties.isDefaultIgnorableCodePoint { return .remove }
        switch properties.generalCategory {
        case .privateUse, .unassigned, .surrogate:
            return .remove
        case .control, .lineSeparator, .paragraphSeparator:
            return .replaceWithSpace
        case .format:
            return .remove
        default:
            return .keep
        }
    }

    private static func a1Disposition(
        _ action: Disposition, for scalar: Unicode.Scalar
    ) -> (Disposition, Int) {
        guard action == .remove, newlyRemovedBlankLookalikes.contains(scalar.value) else { return (action, 0) }
        return (.keep, scalar.utf8.count)
    }

    /// Whether a scalar that is not removed survives `sourceForm` and the trim of
    /// `.whitespacesAndNewlines` (a replaced scalar becomes a space). The only ASCII
    /// whitespace `disposition` keeps is the space; ASCII controls are replaced.
    private static func isContent(_ scalar: Unicode.Scalar, _ action: Disposition) -> Bool {
        guard action == .keep, !isMatchIgnorable(scalar) else { return false }
        return scalar.isASCII ? scalar != " " : !trimmedWhitespace.contains(scalar)
    }

    private static let trimmedWhitespace = CharacterSet.whitespacesAndNewlines

    static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar == zeroWidthJoiner || scalar == zeroWidthNonJoiner
    }

    private static func isTag(_ scalar: Unicode.Scalar) -> Bool {
        (0xE0000...0xE007F).contains(scalar.value)
    }

    /// A joiner must follow a letter, a mark on a letter or an emoji (optionally
    /// with its presentation selector).
    private static func joinsBefore(_ kept: String.UnicodeScalarView) -> Bool {
        var previous = kept.last
        if let scalar = previous, scalar.properties.isVariationSelector {
            previous = kept.dropLast().last
        }
        guard let previous else { return false }
        let properties = previous.properties
        if isPictographic(previous) || properties.isEmojiModifier { return true }
        return isLetter(previous) || [.nonspacingMark, .spacingMark].contains(properties.generalCategory)
    }

    private static func joinsAfter(_ next: Unicode.Scalar) -> Bool {
        isPictographic(next) || isLetter(next)
    }

    /// Emoji outside ASCII; ASCII digits, `#` and `*` are emoji only as keycap bases.
    private static func isPictographic(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && !scalar.isASCII
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// Caps every grapheme of the text, as Swift segments the WHOLE text, to
    /// `maximumScalarsPerGrapheme` scalars, never ending a capped one on a joiner.
    ///
    /// Segmentation is not local: a capped grapheme can end in a `Prepend` scalar
    /// (U+0D4E) and merge with the next one, dropping a Prepend run lets marks attach to
    /// the previous base (`"a" + 9×U+0D4E + 9×U+0301` caps to `"a" + 7×U+0301`), and
    /// regional indicators pair by parity from the left, so capping one re-pairs those
    /// after it and can enlarge an EARLIER grapheme (`8×U+0D4E + 🇨 ZWJ 🇨🇨` once gave
    /// `[9, 1]`). So the text is capped by whole-string sweeps: each sweep scans the
    /// whole text once and, if any grapheme is oversized, rebuilds it with every
    /// oversized grapheme capped; a changing sweep removes at least
    /// one scalar. At most `maximumCapSweeps` rebuilds run, so the work is linear in the
    /// text. (An earlier per-append check of the trailing grapheme was quadratic on a
    /// regional-indicator run, because `String.last` scans back to the start of the run.)
    /// A rematch can still create an oversized grapheme (dropping a joiner merges its
    /// neighbours), so `UntrustedLabel` caps again after every rematch, and finally
    /// checks `meetsGraphemeCap` on the whole text and fails closed if the sweeps ran out.
    static func capGraphemes(_ text: String) -> Result {
        var work = CapWork()
        return capGraphemes(text, work: &work)
    }

    /// Work done by `capGraphemes`, counted so tests can pin it as linear.
    struct CapWork {
        /// Whole-text rebuilds, at most `maximumCapSweeps`.
        var sweeps = 0
        /// Graphemes visited by the cap checks and the rebuilds.
        var graphemesVisited = 0
    }

    /// At most this many whole-string rebuilds run; `UntrustedLabel` fails closed if the
    /// text still has an oversized grapheme after them.
    static let maximumCapSweeps = 4

    static func capGraphemes(_ text: String, work: inout CapWork) -> Result {
        capGraphemes(text, separators: [], work: &work).result
    }

    static func capGraphemes(
        _ text: String, separators: [Int]
    ) -> (result: Result, separators: [Int]) {
        var work = CapWork()
        return capGraphemes(text, separators: separators, work: &work)
    }

    /// Caps while carrying the exact separator provenance through every whole-string
    /// sweep. Ordinals are among U+0020 scalars, not scalar offsets.
    static func capGraphemes(
        _ text: String, separators: [Int], work: inout CapWork
    ) -> (result: Result, separators: [Int]) {
        var text = text
        var marked = scalarOffsets(ofSpaces: separators, in: text)
        var changed = false
        for _ in 0..<maximumCapSweeps {
            guard text.contains(where: { character in
                work.graphemesVisited += 1
                return character.unicodeScalars.count > maximumScalarsPerGrapheme
            }) else { break }
            var rebuilt = String.UnicodeScalarView()
            var nextMarked: Set<Int> = []
            var sourceOffset = 0
            var outputOffset = 0
            for character in text {
                work.graphemesVisited += 1
                let scalars = Array(character.unicodeScalars)
                let oversized = scalars.count > maximumScalarsPerGrapheme
                let indices = oversized ? cappedScalarIndices(scalars) : Array(scalars.indices)
                for index in indices {
                    if marked.contains(sourceOffset + index) { nextMarked.insert(outputOffset) }
                    rebuilt.append(scalars[index])
                    outputOffset += 1
                }
                sourceOffset += scalars.count
            }
            text = String(rebuilt)
            marked = nextMarked
            work.sweeps += 1
            changed = true
        }
        return (result: (text, changed), separators: spaceOrdinals(in: text, at: marked))
    }

    private static func scalarOffsets(ofSpaces ordinals: [Int], in text: String) -> Set<Int> {
        let wanted = Set(ordinals)
        var offsets: Set<Int> = []
        var space = 0
        for (offset, scalar) in text.unicodeScalars.enumerated() where scalar == " " {
            if wanted.contains(space) { offsets.insert(offset) }
            space += 1
        }
        return offsets
    }

    private static func spaceOrdinals(in text: String, at offsets: Set<Int>) -> [Int] {
        var result: [Int] = []
        var space = 0
        for (offset, scalar) in text.unicodeScalars.enumerated() where scalar == " " {
            if offsets.contains(offset) { result.append(space) }
            space += 1
        }
        return result
    }

    /// Whether every grapheme of `text`, as Swift segments the whole string, fits the cap.
    static func meetsGraphemeCap(_ text: String) -> Bool {
        text.allSatisfy { $0.unicodeScalars.count <= maximumScalarsPerGrapheme }
    }

    /// Keeps the base and its first marks, never ending on a joiner. An oversized run of
    /// leading `Prepend` scalars loses only its excess (the scalars farthest from the
    /// base), so the base and the text after it survive. A run with no base keeps its
    /// first scalars.
    private static func cappedScalarIndices(_ scalars: [Unicode.Scalar]) -> [Int] {
        let limit = maximumScalarsPerGrapheme
        let leading = scalars.prefix(while: isPrepend).count
        guard leading < scalars.count else { return Array(0..<min(limit, scalars.count)) }
        var end = min(scalars.count, leading + limit)
        while end > leading, isJoiner(scalars[end - 1]) { end -= 1 }
        let prefixCount = min(leading, limit - (end - leading))
        return Array((leading - prefixCount)..<leading) + Array(leading..<end)
    }

    /// Whether `scalar` joins the letter after it into one grapheme (Unicode's
    /// `Prepend`), probed on the toolchain's own segmentation rather than a fixed table.
    private static func isPrepend(_ scalar: Unicode.Scalar) -> Bool {
        var probe = String(Character(scalar))
        probe.append("a")
        return probe.count == 1
    }

    /// Keeps whole graphemes of `text` while they fit in `maximumBytes` UTF-8 bytes.
    /// The cut is at a grapheme boundary of `text`, and the kept graphemes are not
    /// changed: no grapheme cap applies, so a withheld prefix still matches the
    /// uncapped label it came from.
    static func graphemePrefix(_ text: String, fittingBytes maximumBytes: Int) -> Result {
        var used = 0
        for index in text.indices {
            let width = text[index].utf8.count
            guard used + width <= maximumBytes else { return (String(text[..<index]), true) }
            used += width
        }
        return (text, false)
    }

    /// `graphemePrefix` for display text. The kept prefix is capped again (defensive:
    /// a prefix cut at a boundary never enlarges a grapheme), which only ever removes
    /// scalars, so it still fits.
    ///
    /// A cut never shows part of `marker` (`UntrustedLabel.withheldMarker`): one that
    /// splits an occurrence moves back to the last grapheme boundary at or before the
    /// occurrence, so the text keeps the whole marker or ends before it (`Rig [withheld]
    /// tail` cut to 8 bytes is `Rig `, not `Rig [wit`). Literal marker text is cut alike.
    static func truncate(
        _ text: String, maximumBytes: Int, marker: String, separators: [Int]
    ) -> (result: Result, separators: [Int]) {
        var cut = graphemePrefix(text, fittingBytes: maximumBytes)
        if cut.changed, let start = splitOccurrence(of: marker, in: text, at: cut.text.unicodeScalars.count) {
            cut.text = prefix(of: text, atOrBefore: start)
        }
        guard cut.changed else { return (cut, separators) }
        let keptScalarCount = cut.text.unicodeScalars.count
        let oldOffsets = scalarOffsets(ofSpaces: separators, in: text)
        let keptOffsets = Set(oldOffsets.filter { $0 < keptScalarCount })
        let prefixSeparators = spaceOrdinals(in: cut.text, at: keptOffsets)
        let capped = capGraphemes(cut.text, separators: prefixSeparators)
        return ((capped.result.text, true), capped.separators)
    }

    /// The scalar offset of the first occurrence of `marker` in `text` that starts before
    /// the scalar offset `cut` and ends after it, if any.
    private static func splitOccurrence(of marker: String, in text: String, at cut: Int) -> Int? {
        let marker = Array(marker.unicodeScalars)
        let scalars = Array(text.unicodeScalars)
        return stride(from: max(0, cut - marker.count + 1), to: cut, by: 1).first { start in
            start + marker.count <= scalars.count && scalars[start..<(start + marker.count)].elementsEqual(marker)
        }
    }

    /// The longest prefix of `text` that ends on a grapheme boundary at or before the
    /// scalar offset `offset`.
    private static func prefix(of text: String, atOrBefore offset: Int) -> String {
        var scalars = 0
        var end = text.startIndex
        for index in text.indices {
            guard scalars <= offset else { break }
            end = index
            scalars += text[index].unicodeScalars.count
        }
        return String(text[..<end])
    }
}
