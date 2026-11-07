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
///    scan-cut text. A term's marks before its first and after its last starter are
///    matched per combining class, since NFD can reorder a label's neighbouring marks in
///    among them (`UntrustedTextSanitizer.occurrences`). Every range covers whole source
///    graphemes; all ranges are
///    merged and replaced once by `withheldMarker`. When anything is withheld the
///    label is the redacted source form; otherwise it keeps its allowed joiners and
///    presentation selectors. The text is also matched without the spaces that replaced
///    a control or separator, and each term without its own, so a line break cannot
///    split a secret (`SN-1\n2345` is withheld for `SN-12345`, and the other way round).
///    When terms are active and the text holds a scalar Foundation does not normalize
///    reliably (`UntrustedTextSanitizer.hasUnreliableNormalization`), the whole label
///    is withheld instead, since its match form cannot be trusted.
///    If an eligible fail-closed term consists only of a newly removed blank and the
///    filtered label is empty for the same reason, it still emits the withheld marker.
/// 3. Separator provenance is carried through redaction, every cap sweep, settle,
///    truncation and stable passes; only original control replacements may be dropped
///    from compact matching. Any redaction in a label that removed a newly pinned
///    blank withholds the whole label. A literal marker's edge padding can still be
///    trimmed with provenance remapped. Each
///    grapheme of the redacted text is limited
///    to `UntrustedTextSanitizer.maximumScalarsPerGrapheme` scalars. If that changed
///    anything, step 2 runs again, since dropping scalars can complete a withheld
///    string, and so on until stable (`settle`, bounded, failing closed).
/// 4. The text is truncated to `maximumBytes` UTF-8 bytes on a grapheme boundary of
///    the final text, before any `withheldMarker` the cut would split (a cut marker
///    such as `[with` could pass for label text). If not even its first grapheme fits,
///    the label is
///    `withheldMarker` (or empty, flagged truncated, when the marker does not fit
///    either), never a silently empty string.
///
/// 5. Steps 1–4 repeat until the text is a fixed point (bounded by
///    `maximumStablePasses`), and a final whole-string scan checks the postcondition;
///    either failing withholds the label.
///
/// Postcondition: every grapheme of `text`, as Swift segments the whole string, has at
/// most `maximumScalarsPerGrapheme` scalars; `text` is at most `maximumBytes` UTF-8
/// bytes; and labelling `text` again with the same terms returns `text`. So the emitted
/// text is the text the last pass matched (up to canonical equivalence, which matching
/// ignores): every renormalization, cap and cut is matched again before it is shown.
/// After new-blank removal, withhold whole if A1's blank-kept shadow needs a cap/cut,
/// A1h redacts or settle changes text, or the NFC display is not a scalar subsequence
/// of A1's; a later A1h byte cut only removes text. The guard does not apply to labels
/// containing only A1-old blanks such as U+3164. Leading-prefix reconstruction can
/// over-fire (e.g. `\u{200B} Rig\u{13441}` or a leading NUL), but cannot under-fire.
///
/// Withheld strings longer than `UntrustedTextSanitizer.maximumWithheldBytes` are
/// matched by a match-form prefix, and a match redacts the rest of the label. One
/// with no safe prefix (a single giant grapheme) withholds the whole label.
///
/// Scanning stops at the first scalar it would keep once
/// `UntrustedTextSanitizer.scanLimit(maximumBytes:withheld:)` match-form scalars have
/// been kept (saturating at `Int.max`, so no byte limit traps). Removed scalars and
/// joiners are read but not counted, so the work is linear in the input and the kept
/// text is bounded.
///
/// Not handled (accepted for A1): visible combining marks placed on the characters
/// of a withheld string, between its first and last starter or in front of its own
/// edge marks of the same class, keep it from matching. Marks of other classes next
/// to its edges do not.
///
/// Non-goal: compatibility equivalence (NFKC). A fullwidth `ＳＮ-ＡＢＣ12345` does not
/// match `SN-ABC12345`. Labels come from device and network names, where a fullwidth
/// copy of a serial is not a realistic leak, and folding compatibility forms would
/// rewrite ordinary labels (ligatures, superscripts) that are shown in their match form.
struct UntrustedLabel: Hashable, Sendable, Encodable {
    static let defaultMaximumBytes = 128
    static let withheldMarker = "[withheld]"

    let text: String
    /// True when characters were dropped to fit the byte or scan limit.
    /// A blank-decision fallback can report a cut A1 did not need when A1's own output fits the limit.
    /// It never under-reports a cut A1 would have made and never changes `text` or `wasSanitized`.
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
        let first = Self.sanitizeOnce(raw, limit: limit, terms: terms)
        var text = first.text
        var isTruncated = first.isTruncated
        var wasSanitized = first.wasSanitized
        var separators = first.separators
        var isStable = false
        for _ in 0..<Self.maximumStablePasses {
            let again = Self.sanitizeOnce(text, limit: limit, terms: terms, inheritedSeparators: separators)
            // Scalar-exact: `String ==` is canonical equivalence and would accept a text
            // that a second labelling still renormalizes.
            if again.text.unicodeScalars.elementsEqual(text.unicodeScalars), again.separators == separators {
                isStable = true
                break
            }
            text = again.text
            separators = again.separators
            isTruncated = isTruncated || again.isTruncated
            wasSanitized = true
        }
        // The final guard scans the whole text. A label that is not a fixed point, or
        // still breaks the postcondition, is withheld rather than shown.
        if !isStable || !UntrustedTextSanitizer.meetsGraphemeCap(text) || text.utf8.count > limit {
            text = Self.withheldMarker.utf8.count <= limit ? Self.withheldMarker : ""
            isTruncated = true
            wasSanitized = true
        }
        self.text = text
        self.isTruncated = isTruncated
        self.wasSanitized = wasSanitized
    }

    /// At most this many extra passes of the whole pipeline run before a label that is
    /// not yet a fixed point is withheld. Capping can leave text that normalizes or
    /// segments differently (dropped marks let a base compose with the next mark), so
    /// the label is the pipeline's fixed point, which also makes it idempotent.
    static let maximumStablePasses = 4

    private struct Pass {
        let text: String
        let isTruncated: Bool
        let wasSanitized: Bool
        let separators: [Int]
    }

    /// One pass of steps 1–4.
    private static func sanitizeOnce(
        _ raw: String, limit: Int, terms: [UntrustedTextSanitizer.WithheldTerm],
        inheritedSeparators: [Int]? = nil
    ) -> Pass {
        let scan = UntrustedTextSanitizer.scanLimit(maximumBytes: limit, withheld: terms.map(\.text))
        let filtered = UntrustedTextSanitizer.filterScalars(raw.unicodeScalars, keeping: scan)
        let activeTerms = UntrustedTextSanitizer.applicableTerms(terms, for: filtered)
        let display = filtered.text.precomposedStringWithCanonicalMapping
        let unreliable = !activeTerms.isEmpty
            && UntrustedTextSanitizer.hasUnreliableNormalization(filtered.text.unicodeScalars)
        let emptyFailClosed = filtered.text.isEmpty && filtered.removedNewBlankBytes > 0
            && activeTerms.contains(where: { $0.isFailClosed })
        let redacted = unreliable || emptyFailClosed
            ? (result: (text: withheldMarker, changed: true), separators: [])
            : UntrustedTextSanitizer.redactMatchFormWithSeparators(
                of: display, withheld: activeTerms, marker: withheldMarker, scanIsComplete: filtered.isComplete,
                separators: inheritedSeparators ?? filtered.separators
            )
        let legacyGraphemeRisk = redacted.result.changed
        let settled = settle(redacted.result.text, separators: redacted.separators, terms: activeTerms)
        let legacyDecision = filtered.removedNewBlankBytes > 0
            ? UntrustedTextSanitizer.legacyLabelDecision(
                raw, hardened: display, maximumBytes: limit, scanLimit: scan
            )
            : UntrustedTextSanitizer.LegacyLabelDecision(
                needsGraphemeCap: false, needsByteCut: false,
                needsScalarSubsequenceGuard: false, scanIsComplete: true
            )
        let legacyCutRisk = legacyDecision.needsByteCut
        let blankDecisionRisk = filtered.removedNewBlankBytes > 0
            && (legacyGraphemeRisk
                || settled.result.changed
                || legacyDecision.needsGraphemeCap
                || legacyCutRisk
                || legacyDecision.needsScalarSubsequenceGuard)
        let protected = blankDecisionRisk
            ? (result: (text: withheldMarker, changed: true), separators: [])
            : settled
        let edgeTrimmed = filtered.removedNewBlankBytes > 0 && protected.result.text.contains(withheldMarker)
            ? Self.trimRedactedEdges(protected.result.text, separators: protected.separators)
            : (text: protected.result.text, separators: protected.separators)
        var cut = UntrustedTextSanitizer.truncate(
            edgeTrimmed.text, maximumBytes: limit, marker: withheldMarker,
            separators: edgeTrimmed.separators
        )
        if cut.result.text.isEmpty, !edgeTrimmed.text.isEmpty {
            // The first grapheme alone does not fit: the label is withheld, not silently emptied.
            cut.result = (withheldMarker.utf8.count <= limit ? withheldMarker : "", true)
            cut.separators = []
        }
        return Pass(
            text: cut.result.text,
            isTruncated: truncationFlag(
                cutChanged: cut.result.changed, scanIsComplete: filtered.isComplete,
                legacyCutRisk: legacyCutRisk, blankDecisionRisk: blankDecisionRisk,
                legacyGraphemeRisk: legacyGraphemeRisk
            ),
            wasSanitized: filtered.changed || redacted.result.changed || settled.result.changed,
            separators: cut.separators
        )
    }

    private static func truncationFlag(
        cutChanged: Bool, scanIsComplete: Bool, legacyCutRisk: Bool,
        blankDecisionRisk: Bool, legacyGraphemeRisk: Bool
    ) -> Bool {
        cutChanged || !scanIsComplete || legacyCutRisk || (blankDecisionRisk && legacyGraphemeRisk)
    }

    /// Actual redaction after new-blank removal withholds the whole label. This only
    /// trims padding around a literal marker in a pass-through label, so it shows less.
    static func trimRedactedEdges(_ text: String, separators: [Int]) -> (text: String, separators: [Int]) {
        let scalars = Array(text.unicodeScalars)
        var lower = 0
        var upper = scalars.count
        let whitespace = CharacterSet.whitespacesAndNewlines
        while lower < upper, whitespace.contains(scalars[lower]) { lower += 1 }
        while upper > lower, whitespace.contains(scalars[upper - 1]) { upper -= 1 }
        guard lower > 0 || upper < scalars.count else { return (text, separators) }

        var markedOffsets: Set<Int> = []
        let markedSpaces = Set(separators)
        var ordinal = 0
        for (offset, scalar) in scalars.enumerated() where scalar == " " {
            if markedSpaces.contains(ordinal) { markedOffsets.insert(offset) }
            ordinal += 1
        }
        var remapped: [Int] = []
        ordinal = 0
        for (offset, scalar) in scalars[lower..<upper].enumerated() where scalar == " " {
            if markedOffsets.contains(offset + lower) { remapped.append(ordinal) }
            ordinal += 1
        }
        return (String(String.UnicodeScalarView(scalars[lower..<upper])), remapped)
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
    /// Test-only convenience; production uses the provenance-aware overload below.
    static func settle(
        _ text: String, terms: [UntrustedTextSanitizer.WithheldTerm]
    ) -> UntrustedTextSanitizer.Result {
        settle(text, separators: [], terms: terms).result
    }

    private static func settle(
        _ text: String, separators: [Int], terms: [UntrustedTextSanitizer.WithheldTerm]
    ) -> (result: UntrustedTextSanitizer.Result, separators: [Int]) {
        var capped = UntrustedTextSanitizer.capGraphemes(text, separators: separators)
        var changed = capped.result.changed
        for _ in 0..<maximumSettlePasses {
            guard capped.result.changed else { return ((capped.result.text, changed), capped.separators) }
            let again = UntrustedTextSanitizer.redactMatchFormWithSeparators(
                of: capped.result.text, withheld: terms, marker: withheldMarker, scanIsComplete: true,
                separators: capped.separators
            )
            guard again.result.changed else { return ((capped.result.text, changed), capped.separators) }
            capped = UntrustedTextSanitizer.capGraphemes(again.result.text, separators: again.separators)
            changed = true
        }
        return capped.result.changed
            ? ((withheldMarker, true), [])
            : ((capped.result.text, changed), capped.separators)
    }
}
