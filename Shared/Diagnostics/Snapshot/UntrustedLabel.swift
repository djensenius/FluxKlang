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
///    so they cannot split a withheld string and hide it from step 2. The text is
///    normalized to NFC.
/// 2. Withheld strings are found in the full, uncapped match form (the text without
///    ZWJ/ZWNJ or variation selectors, renormalized to NFC), case-folded, together
///    with the tail of a scan-cut text. All ranges are merged and replaced once by
///    `withheldMarker`. When anything is withheld the label is the redacted match
///    form; otherwise it keeps its allowed joiners and presentation selectors.
/// 3. Each grapheme of the redacted text is limited to
///    `UntrustedTextSanitizer.maximumScalarsPerGrapheme` scalars. If that changed
///    anything, step 2 runs again, since dropping scalars can complete a withheld string.
/// 4. The text is truncated to `maximumBytes` UTF-8 bytes on a grapheme boundary.
///
/// Withheld strings longer than `UntrustedTextSanitizer.maximumWithheldBytes` are
/// matched by a match-form prefix, and a match redacts the rest of the label. One
/// with no safe prefix (a single giant grapheme) withholds the whole label.
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
        let display = filtered.text.precomposedStringWithCanonicalMapping
        let redacted = UntrustedTextSanitizer.redactMatchForm(
            of: display, withheld: terms, marker: Self.withheldMarker, scanIsComplete: filtered.isComplete
        )
        let capped = UntrustedTextSanitizer.capGraphemes(redacted.text)
        // Dropping scalars can complete a withheld string, so a capped text is matched again.
        let confirmed = capped.changed
            ? UntrustedTextSanitizer.redactMatchForm(
                of: capped.text, withheld: terms, marker: Self.withheldMarker, scanIsComplete: true
            )
            : capped
        let cut = UntrustedTextSanitizer.truncate(confirmed.text, maximumBytes: limit)
        text = cut.text
        isTruncated = cut.changed || !filtered.isComplete
        wasSanitized = filtered.changed || capped.changed || redacted.changed || confirmed.changed
    }
}
