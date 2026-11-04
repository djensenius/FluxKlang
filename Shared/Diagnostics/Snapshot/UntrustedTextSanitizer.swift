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
    /// Hangul fillers, halfwidth Hangul filler and the blank Braille pattern render as nothing.
    static let blankLookalikes: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800]
    static let minimumPartialBytes = 4
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

    /// Bounds how many raw scalars are read: enough for the byte limit with
    /// capped graphemes, plus room to recognise a withheld string at the cut.
    static func scanLimit(maximumBytes: Int, withheld: [String]) -> Int {
        let longest = withheld.map(\.unicodeScalars.count).max() ?? 0
        return max(4_096, maximumBytes * maximumScalarsPerGrapheme + longest)
    }

    /// Filters scalars until `limit` of them have been kept. Removed scalars and
    /// kept match-ignorable scalars (joiners, presentation selectors) do not count,
    /// so the limit applies to the match form and invisible padding cannot push
    /// later text past it. A kept selector follows an emoji and a kept joiner
    /// follows a counted scalar or such a selector, so the kept text is at most
    /// `3 * limit` scalars.
    static func filterScalars(_ scalars: String.UnicodeScalarView, keeping limit: Int) -> Scan {
        var kept = String.UnicodeScalarView()
        var keptCount = 0
        var changed = false
        var index = scalars.startIndex
        while index != scalars.endIndex {
            guard keptCount < limit else { return Scan(text: String(kept), changed: changed, isComplete: false) }
            let scalar = scalars[index]
            let nextIndex = scalars.index(after: index)
            let next = nextIndex == scalars.endIndex ? nil : scalars[nextIndex]
            switch disposition(of: scalar, after: kept, before: next) {
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

    /// Keeps the first scalars of an oversized grapheme, never ending it on a joiner.
    static func capGraphemes(_ text: String) -> Result {
        var result = String.UnicodeScalarView()
        var changed = false
        for character in text {
            let scalars = character.unicodeScalars
            guard scalars.count > maximumScalarsPerGrapheme else {
                result.append(contentsOf: scalars)
                continue
            }
            var prefix = Array(scalars.prefix(maximumScalarsPerGrapheme))
            while let last = prefix.last, isJoiner(last) {
                prefix.removeLast()
            }
            result.append(contentsOf: prefix)
            changed = true
        }
        return (String(result), changed)
    }

    /// Replaces every withheld term, ignoring case. All matches are found in the
    /// original text first: every occurrence of a term, including occurrences that
    /// overlap each other (the search restarts one Character after each match
    /// start, `abcabcab` in `abcabcabcab` matches twice), and for a
    /// prefix term (which stands for a longer secret) the range from its first
    /// match to the end, so the rest of the secret can never be shown. Overlapping
    /// and adjacent ranges are merged and each merged range becomes one marker, so
    /// overlapping terms cannot leave part of a longer secret behind and the
    /// result does not depend on term order.
    ///
    /// Cost: each search stops at its first match and the next starts one Character
    /// later, so a term costs O(n·m) for a match form of n Characters and a term of
    /// m. Both are bounded: n by the scan limit and m by `maximumWithheldBytes`.
    ///
    /// Accepted limit: only whole terms are found. A partial quote of a secret,
    /// short or long (for example the first 300 bytes of a 2,000-byte secret,
    /// shorter than its 1,024-byte prefix term), is not redacted. Only a partial
    /// at the end of a scan-cut label is dropped (`dropPartialWithheld`).
    static func redact(_ text: String, withheld: [WithheldTerm], marker: String) -> Result {
        let options: String.CompareOptions = [.caseInsensitive, .literal]
        var ranges: [Range<String.Index>] = []
        for term in withheld where !term.text.isEmpty {
            var start = text.startIndex
            while let range = text.range(of: term.text, options: options, range: start..<text.endIndex) {
                guard !term.isPrefix else {
                    ranges.append(range.lowerBound..<text.endIndex)
                    break
                }
                ranges.append(range)
                start = text.index(after: range.lowerBound)
            }
        }
        guard !ranges.isEmpty else { return (text, false) }
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var result = ""
        var cursor = text.startIndex
        for range in merged {
            result += text[cursor..<range.lowerBound] + marker
            cursor = range.upperBound
        }
        return (result + text[cursor...], true)
    }

    /// After a scan stopped early, drops a trailing piece of at least
    /// `minimumPartialBytes` that begins a withheld string, so a secret cut by
    /// the scan limit cannot escape redaction as a prefix.
    static func dropPartialWithheld(atEndOf text: String, withheld: [String]) -> Result {
        var result = text.unicodeScalars
        var dropping = true
        while dropping {
            dropping = false
            for secret in withheld {
                let length = partialLength(atEndOf: result, of: Array(secret.unicodeScalars))
                guard length > 0 else { continue }
                result.removeLast(length)
                dropping = true
            }
        }
        return (String(result), result.count != text.unicodeScalars.count)
    }

    /// The scalar length of the longest suffix of `text` that equals, ignoring
    /// case, a prefix of `secret` and is at least `minimumPartialBytes` long.
    private static func partialLength(atEndOf text: String.UnicodeScalarView, of secret: [Unicode.Scalar]) -> Int {
        let tail = Array(text.suffix(secret.count))
        for start in tail.indices {
            let piece = String(String.UnicodeScalarView(tail[start...]))
            guard piece.utf8.count >= minimumPartialBytes else { return 0 }
            let head = String(String.UnicodeScalarView(secret.prefix(tail.count - start)))
            if piece.caseInsensitiveCompare(head) == .orderedSame { return tail.count - start }
        }
        return 0
    }

    /// Keeps whole graphemes while they fit in `maximumBytes` UTF-8 bytes.
    static func truncate(_ text: String, maximumBytes: Int) -> Result {
        var used = 0
        for index in text.indices {
            let width = text[index].utf8.count
            guard used + width <= maximumBytes else { return (String(text[..<index]), true) }
            used += width
        }
        return (text, false)
    }
}
