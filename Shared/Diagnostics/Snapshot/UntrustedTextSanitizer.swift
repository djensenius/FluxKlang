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
