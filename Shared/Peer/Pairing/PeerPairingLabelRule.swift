//
//  PeerPairingLabelRule.swift
//  FluxKlang
//
//  The label rule the controller applies before it asks a host to pair (#94 P2).
//  `PeerTrustStore`'s rule is private, so this is a local mirror; a test compares
//  both on a table of labels through the store's real `pair`, which is what
//  catches drift. The host stays the authority: it re-checks the label itself.
//

enum PeerPairingLabelRule {
    /// Label length in UTF-8 bytes, the same bounds the store enforces.
    static let utf8Bounds = PeerTrustStore.labelUTF8Bounds

    private static let refusedCategories: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned
    ]
    private static let combiningMarks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
    private static let visibleCategories: Set<Unicode.GeneralCategory> = [
        .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
        .decimalNumber, .letterNumber, .otherNumber,
        .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
        .initialPunctuation, .finalPunctuation, .otherPunctuation,
        .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol
    ]
    private static let variationSelectors: ClosedRange<Unicode.Scalar> = "\u{FE00}"..."\u{FE0F}"

    /// Whether `label` reads as what it is: `utf8Bounds` bytes (counted first), no leading or trailing
    /// whitespace, no leading combining mark, no control, format, separator, private-use or unassigned scalar,
    /// no default-ignorable scalar other than a variation selector, and at least one visible scalar.
    /// Refused, never trimmed.
    static func isValid(_ label: String) -> Bool {
        guard utf8Bounds.contains(label.utf8.count) else { return false }
        let scalars = label.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              !first.properties.isWhitespace, !last.properties.isWhitespace,
              !combiningMarks.contains(first.properties.generalCategory) else { return false }
        let hidden = scalars.contains { scalar in
            refusedCategories.contains(scalar.properties.generalCategory)
                || (scalar.properties.isDefaultIgnorableCodePoint && !variationSelectors.contains(scalar))
        }
        return !hidden && scalars.contains(where: isVisible)
    }

    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return !properties.isWhitespace && !properties.isDefaultIgnorableCodePoint
            && visibleCategories.contains(properties.generalCategory)
    }
}
