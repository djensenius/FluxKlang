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
    /// Hangul fillers, halfwidth Hangul filler, the blank Braille pattern, the Khitan
    /// small script filler (a combining mark, not default-ignorable) and the musical
    /// null notehead (So) render as nothing.
    static let blankLookalikes: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x16FE4, 0x1D159]
    static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
    static let zeroWidthNonJoiner: Unicode.Scalar = "\u{200C}"

    struct Scan {
        let text: String
        let changed: Bool
        /// False when the kept-scalar limit stopped the scan before the end of the input.
        let isComplete: Bool
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
    /// still bounded. A long whitespace run is read to its end, linear as above.
    static func filterScalars(_ scalars: String.UnicodeScalarView, keeping limit: Int, trimmed: Bool = false) -> Scan {
        var kept = String.UnicodeScalarView()
        var keptCount = 0
        var changed = false
        var index = scalars.startIndex
        while index != scalars.endIndex {
            let scalar = scalars[index]
            let nextIndex = scalars.index(after: index)
            let next = nextIndex == scalars.endIndex ? nil : scalars[nextIndex]
            let action = disposition(of: scalar, after: kept, before: next)
            if trimmed, kept.isEmpty || keptCount >= limit, action != .remove, !isContent(scalar, action) {
                changed = true
                index = nextIndex
                continue
            }
            if keptCount >= limit, action != .remove {
                return Scan(text: String(kept), changed: changed, isComplete: false)
            }
            switch action {
            case .keep:
                kept.append(scalar)
                keptCount += isMatchIgnorable(scalar) ? 0 : 1
            case .remove:
                changed = true
            case .replaceWithSpace:
                kept.append(" ")
                keptCount += 1
                changed = true
            }
            index = nextIndex
        }
        return Scan(text: String(kept), changed: changed, isComplete: true)
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
    /// oversized grapheme replaced by `cappedScalars`; a changing sweep removes at least
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
        var text = text
        var changed = false
        for _ in 0..<maximumCapSweeps {
            guard text.contains(where: { character in
                work.graphemesVisited += 1
                return character.unicodeScalars.count > maximumScalarsPerGrapheme
            }) else { break }
            var rebuilt = String.UnicodeScalarView()
            for character in text {
                work.graphemesVisited += 1
                let scalars = Array(character.unicodeScalars)
                let oversized = scalars.count > maximumScalarsPerGrapheme
                rebuilt.append(contentsOf: oversized ? cappedScalars(scalars) : scalars)
            }
            text = String(rebuilt)
            work.sweeps += 1
            changed = true
        }
        return (text, changed)
    }

    /// Whether every grapheme of `text`, as Swift segments the whole string, fits the cap.
    static func meetsGraphemeCap(_ text: String) -> Bool {
        text.allSatisfy { $0.unicodeScalars.count <= maximumScalarsPerGrapheme }
    }

    /// Keeps the base and its first marks, never ending on a joiner. An oversized run of
    /// leading `Prepend` scalars loses only its excess (the scalars farthest from the
    /// base), so the base and the text after it survive. A run with no base keeps its
    /// first scalars.
    private static func cappedScalars(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let limit = maximumScalarsPerGrapheme
        let leading = scalars.prefix(while: isPrepend).count
        guard leading < scalars.count else { return Array(scalars.prefix(limit)) }
        var body = Array(scalars[leading...].prefix(limit))
        while let scalar = body.last, isJoiner(scalar) {
            body.removeLast()
        }
        return Array(scalars[..<leading].suffix(limit - body.count)) + body
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
    static func truncate(_ text: String, maximumBytes: Int) -> Result {
        let cut = graphemePrefix(text, fittingBytes: maximumBytes)
        return cut.changed ? (capGraphemes(cut.text).text, true) : cut
    }
}
