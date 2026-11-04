//
//  UntrustedLabel.swift
//  FluxKlang
//
//  Display text copied from a document, device or diagnostic into a read-only
//  snapshot. It is data to show or quote, never an instruction, and it is
//  bounded and stripped of invisible characters and known hardware identities.
//

import Foundation

/// A sanitized, length-bounded label from an untrusted source.
///
/// The text goes through these steps in order:
/// 1. Invisible characters are removed or replaced (see `UntrustedTextSanitizer`),
///    so they cannot split a withheld string and hide it from step 3.
/// 2. Each grapheme is limited to `UntrustedTextSanitizer.maximumScalarsPerGrapheme`
///    scalars, and the text is normalized to NFC.
/// 3. Withheld strings are searched in the match form (the text without ZWJ/ZWNJ)
///    and replaced, ignoring case, by `withheldMarker`. If the scan stopped early, a
///    trailing piece that begins a withheld string is dropped. When either happens
///    the label is the redacted match form; otherwise it keeps its allowed joiners.
/// 4. The text is truncated to `maximumBytes` UTF-8 bytes on a grapheme boundary.
///
/// Withheld strings longer than `UntrustedTextSanitizer.maximumWithheldBytes` are
/// matched by prefix, and a match redacts the rest of the label.
///
/// Scanning stops once `UntrustedTextSanitizer.scanLimit(maximumBytes:withheld:)`
/// match-form scalars have been kept. Removed scalars and joiners are read but not
/// counted, so the work is linear in the input and the kept text is bounded.
///
/// Not handled (accepted for A1): visible combining marks placed on the characters
/// of a withheld string keep it from matching.
struct UntrustedLabel: Hashable, Sendable, Encodable {
    static let defaultMaximumBytes = 128
    static let withheldMarker = "[withheld]"

    let text: String
    /// True when characters were dropped to fit the byte limit or the scan limit.
    let isTruncated: Bool
    /// True when characters were replaced or removed, a grapheme was capped or a
    /// withheld string was redacted.
    let wasSanitized: Bool

    /// Accepts raw withheld strings and prepares them like the snapshot builder
    /// does (`UntrustedTextSanitizer.withheldTerms`). Preparing an already
    /// prepared, uncut string returns it unchanged.
    /// A non-positive `maximumBytes` is clamped to zero, which yields empty text.
    init(_ raw: String, maximumBytes: Int = defaultMaximumBytes, withholding withheld: [String] = []) {
        self.init(raw, maximumBytes: maximumBytes, terms: UntrustedTextSanitizer.withheldTerms(withheld))
    }

    /// Used by the snapshot builder, which prepares the terms once for all labels.
    init(_ raw: String, maximumBytes: Int, terms: [UntrustedTextSanitizer.WithheldTerm]) {
        let limit = max(0, maximumBytes)
        let scan = UntrustedTextSanitizer.scanLimit(maximumBytes: limit, withheld: terms.map(\.text))
        let filtered = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: scan)
        let capped = UntrustedTextSanitizer.capGraphemes(filtered.text)
        let display = capped.text.precomposedStringWithCanonicalMapping
        let redacted = UntrustedTextSanitizer.redactMatchForm(
            of: display, withheld: terms, marker: Self.withheldMarker, scanIsComplete: filtered.isComplete
        )
        let cut = UntrustedTextSanitizer.truncate(redacted.text, maximumBytes: limit)
        text = cut.text
        isTruncated = cut.changed || !filtered.isComplete
        wasSanitized = filtered.changed || capped.changed || redacted.changed
    }
}
