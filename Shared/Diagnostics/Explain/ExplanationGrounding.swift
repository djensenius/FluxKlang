//
//  ExplanationGrounding.swift
//  FluxKlang
//
//  Refuses explanation text that cites a snapshot id the snapshot does not hold.
//  The cited ids are the explicit `kind:id` list the caller passes; the text is
//  only measured, never scraped for ids.
//

enum ExplanationGrounding {
    /// Accepts `text` when it is non-empty, within the byte limit, and every entry of `citedIDs` is a
    /// well-formed `kind:id` naming an element of that kind in `snapshot` (an id of another kind is absent).
    /// A truncated snapshot is not treated specially: absent is absent.
    ///
    /// Refusals in this order, the first defect winning: text longer than `maximumTextBytes` (UTF-8 bytes),
    /// empty text, more than `maximumCitations` entries, no entries, a malformed entry (smallest by bytes), an
    /// absent id (smallest by id bytes, then kind). The text is only measured with `utf8.count`; the counts are
    /// checked before any entry is read.
    static func validate(
        text: String, citedIDs: [String], against snapshot: NeutralSnapshot, limits: ExplainLimits
    ) throws(ExplanationRefusal) {
        let bytes = text.utf8.count
        guard bytes <= limits.maximumTextBytes else { throw .textTooLong(bytes) }
        guard bytes > 0 else { throw .emptyText }
        guard citedIDs.count <= limits.maximumCitations else { throw .tooManyCitations(citedIDs.count) }
        guard !citedIDs.isEmpty else { throw .noCitations }
        var citations: [ExplanationCitation] = []
        var malformed: String?
        for reference in citedIDs {
            if let citation = ExplanationCitation.parse(reference) {
                citations.append(citation)
            } else if malformed.map({ reference.utf8.lexicographicallyPrecedes($0.utf8) }) ?? true {
                malformed = reference
            }
        }
        if let malformed { throw .malformedCitation(malformed) }
        if let unknown = firstUnknown(citations, in: snapshot) { throw .unknownCitation(unknown.reference) }
    }

    private static func firstUnknown(
        _ citations: [ExplanationCitation], in snapshot: NeutralSnapshot
    ) -> ExplanationCitation? {
        var unknown: ExplanationCitation?
        for citation in citations where !contains(citation, in: snapshot) {
            if unknown.map({ comesBefore(citation, $0) }) ?? true { unknown = citation }
        }
        return unknown
    }

    private static func contains(_ citation: ExplanationCitation, in snapshot: NeutralSnapshot) -> Bool {
        switch citation {
        case .node(let id): snapshot.node(id) != nil
        case .parameter(let id): snapshot.parameter(id) != nil
        case .route(let id): snapshot.route(id) != nil
        case .diagnostic(let id): snapshot.diagnostics.contains { $0.id == id }
        }
    }

    /// Ascending id bytes; the same id of two kinds is ordered by kind.
    private static func comesBefore(_ lhs: ExplanationCitation, _ rhs: ExplanationCitation) -> Bool {
        let (left, right) = (lhs.identifier.utf8, rhs.identifier.utf8)
        if left.elementsEqual(right) { return lhs < rhs }
        return left.lexicographicallyPrecedes(right)
    }
}
