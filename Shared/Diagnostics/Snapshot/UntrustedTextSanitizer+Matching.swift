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
    }

    /// Prepares a withheld string exactly like a label (filtering, grapheme cap,
    /// match form), then trims surrounding whitespace. An overlong string
    /// is cut to `maximumWithheldBytes` and loses its last grapheme, which the cut
    /// may have split, so the prefix matches wherever the full string occurs.
    /// Returns nil when fewer than `minimumRedactedBytes` remain.
    static func withheldTerm(_ raw: String) -> WithheldTerm? {
        let filtered = filterScalars(raw.unicodeScalars, keeping: maximumWithheldBytes)
        var display = capGraphemes(filtered.text).text
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

    /// Redacts withheld terms found in the match form of `display`. When one
    /// matches, or when a scan cut leaves a partial withheld string at the end,
    /// the result is the redacted match form; otherwise `display` is unchanged
    /// and keeps its joiners and presentation selectors (so an emoji family loses
    /// them only when the label also contains a withheld string).
    static func redactMatchForm(
        of display: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool
    ) -> Result {
        let redacted = redact(matchForm(display), withheld: withheld, marker: marker)
        guard !scanIsComplete else { return redacted.changed ? redacted : (display, false) }
        let trimmed = dropPartialWithheld(atEndOf: redacted.text, withheld: withheld.map(\.text))
        return redacted.changed || trimmed.changed ? (trimmed.text, true) : (display, false)
    }
}
