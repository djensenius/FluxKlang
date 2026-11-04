//
//  UntrustedTextSanitizer+Matching.swift
//  FluxKlang
//
//  Withheld strings are found in a joiner-free, NFC "match form" of a label, so
//  ZWJ/ZWNJ (kept for display between letters or emoji) cannot split a secret.
//

import Foundation

extension UntrustedTextSanitizer {
    /// The display text without ZWJ/ZWNJ. Labels and withheld strings are compared in this form.
    static func matchForm(_ display: String) -> String {
        var scalars = display.unicodeScalars
        scalars.removeAll(where: isJoiner)
        return String(scalars)
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
    /// NFC, joiner removal), then trims surrounding whitespace. An overlong string
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
        let text = matchForm(display.precomposedStringWithCanonicalMapping)
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
    /// and keeps its joiners (so an emoji family loses its joiners only when the
    /// label also contains a withheld string).
    static func redactMatchForm(
        of display: String, withheld: [WithheldTerm], marker: String, scanIsComplete: Bool
    ) -> Result {
        let redacted = redact(matchForm(display), withheld: withheld, marker: marker)
        guard !scanIsComplete else { return redacted.changed ? redacted : (display, false) }
        let trimmed = dropPartialWithheld(atEndOf: redacted.text, withheld: withheld.map(\.text))
        return redacted.changed || trimmed.changed ? (trimmed.text, true) : (display, false)
    }
}
