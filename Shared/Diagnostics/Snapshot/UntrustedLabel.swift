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
/// 2. Withheld strings are found by canonical caseless matching (NFD, full case
///    folding, NFD) on the full, uncapped source form (the text without ZWJ/ZWNJ or
///    variation selectors, renormalized to NFC), together with the tail of a
///    scan-cut text. Every range covers whole source graphemes; all ranges are
///    merged and replaced once by `withheldMarker`. When anything is withheld the
///    label is the redacted source form; otherwise it keeps its allowed joiners and
///    presentation selectors.
/// 3. Each grapheme of the redacted text, as Swift segments the result, is limited
///    to `UntrustedTextSanitizer.maximumScalarsPerGrapheme` scalars. If that changed
///    anything, step 2 runs again, since dropping scalars can complete a withheld
///    string, and so on until stable (`settle`, bounded, failing closed).
/// 4. The text is truncated to `maximumBytes` UTF-8 bytes on a grapheme boundary of
///    the final text. If not even its first grapheme fits, the label is
///    `withheldMarker` (or empty, flagged truncated, when the marker does not fit
///    either), never a silently empty string.
///
/// Postcondition: every grapheme of `text` has at most `maximumScalarsPerGrapheme`
/// scalars, and `text` is at most `maximumBytes` UTF-8 bytes.
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
        let settled = Self.settle(redacted.text, terms: terms)
        var cut = UntrustedTextSanitizer.truncate(settled.text, maximumBytes: limit)
        if cut.text.isEmpty, !settled.text.isEmpty {
            // The first grapheme alone does not fit: the label is withheld, not silently emptied.
            cut = (Self.withheldMarker.utf8.count <= limit ? Self.withheldMarker : "", true)
        }
        text = cut.text
        isTruncated = cut.changed || !filtered.isComplete
        wasSanitized = filtered.changed || redacted.changed || settled.changed
    }

    /// At most this many cap-and-rematch passes run before a label is withheld.
    static let maximumSettlePasses = 4

    /// Caps graphemes (`capGraphemes`) until the text is stable. Dropping scalars can
    /// complete a withheld string, so a capped text is matched again; a rematch can drop
    /// a joiner and merge its neighbours into an oversized grapheme, so a rematched text
    /// is capped again.
    /// A pass that caps nothing, or rematches nothing, ends with every grapheme within
    /// the cap. If `maximumSettlePasses` pass without that, the label fails closed to
    /// `withheldMarker`.
    private static func settle(
        _ text: String, terms: [UntrustedTextSanitizer.WithheldTerm]
    ) -> UntrustedTextSanitizer.Result {
        var capped = UntrustedTextSanitizer.capGraphemes(text)
        var changed = capped.changed
        for _ in 0..<maximumSettlePasses {
            guard capped.changed else { return (capped.text, changed) }
            let again = UntrustedTextSanitizer.redactMatchForm(
                of: capped.text, withheld: terms, marker: withheldMarker, scanIsComplete: true
            )
            guard again.changed else { return (capped.text, changed) }
            capped = UntrustedTextSanitizer.capGraphemes(again.text)
            changed = true
        }
        return capped.changed ? (withheldMarker, true) : (capped.text, changed)
    }
}
