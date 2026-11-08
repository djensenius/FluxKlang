//
//  ExplanationRefusal.swift
//  FluxKlang
//
//  The typed refusals of the grounded Explain baseline and the validated limits
//  it works within. Both are plain values; nothing here reads a snapshot.
//

/// Bounds for building and checking an explanation. Built only by `make` or
/// `standard`, so every value in hand is inside its bounds.
struct ExplainLimits: Hashable, Sendable {
    /// Names a limit that is out of range.
    enum Field: Hashable, Sendable {
        case maximumFacts
        case maximumTextBytes
        case maximumCitations
    }

    static let factBounds = 1...256
    static let textByteBounds = 1...16_384
    static let citationBounds = 1...64

    /// The most facts a report keeps; the rest are counted as omitted.
    private(set) var maximumFacts: Int
    /// The most UTF-8 bytes of explanation text `validate` accepts.
    private(set) var maximumTextBytes: Int
    /// The most citations `validate` accepts for one text.
    private(set) var maximumCitations: Int

    private init(maximumFacts: Int, maximumTextBytes: Int, maximumCitations: Int) {
        self.maximumFacts = maximumFacts
        self.maximumTextBytes = maximumTextBytes
        self.maximumCitations = maximumCitations
    }

    /// The upper end of every bound.
    static let standard = ExplainLimits(
        maximumFacts: factBounds.upperBound, maximumTextBytes: textByteBounds.upperBound,
        maximumCitations: citationBounds.upperBound
    )

    /// Checks the fields in the order facts, text bytes, citations and reports the first one out of range.
    static func make(
        maximumFacts: Int, maximumTextBytes: Int, maximumCitations: Int
    ) throws(ExplanationRefusal) -> ExplainLimits {
        guard factBounds.contains(maximumFacts) else { throw .limitOutOfRange(.maximumFacts, maximumFacts) }
        guard textByteBounds.contains(maximumTextBytes) else {
            throw .limitOutOfRange(.maximumTextBytes, maximumTextBytes)
        }
        guard citationBounds.contains(maximumCitations) else {
            throw .limitOutOfRange(.maximumCitations, maximumCitations)
        }
        return ExplainLimits(
            maximumFacts: maximumFacts, maximumTextBytes: maximumTextBytes, maximumCitations: maximumCitations
        )
    }
}

/// Why an explanation text was refused. Text payloads compare by UTF-8 bytes.
enum ExplanationRefusal: Error, Equatable, Sendable {
    case limitOutOfRange(ExplainLimits.Field, Int)
    /// The text has more UTF-8 bytes than the limit; carries the byte count.
    case textTooLong(Int)
    case emptyText
    /// More citations than the limit; carries the count.
    case tooManyCitations(Int)
    /// Grounded text must cite at least one snapshot id.
    case noCitations
    /// The smallest (by UTF-8 bytes) citation that is not `kind:id` with a valid contract id.
    case malformedCitation(String)
    /// The well-formed citation whose id is smallest by bytes among those absent from the snapshot.
    case unknownCitation(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.limitOutOfRange(let field, let value), .limitOutOfRange(let otherField, let otherValue)):
            field == otherField && value == otherValue
        case (.textTooLong(let bytes), .textTooLong(let otherBytes)):
            bytes == otherBytes
        case (.emptyText, .emptyText):
            true
        case (.tooManyCitations(let count), .tooManyCitations(let otherCount)):
            count == otherCount
        case (.noCitations, .noCitations):
            true
        case (.malformedCitation(let text), .malformedCitation(let other)):
            text.utf8.elementsEqual(other.utf8)
        case (.unknownCitation(let text), .unknownCitation(let other)):
            text.utf8.elementsEqual(other.utf8)
        case (.limitOutOfRange, _), (.textTooLong, _), (.emptyText, _), (.tooManyCitations, _), (.noCitations, _),
            (.malformedCitation, _), (.unknownCitation, _):
            false
        }
    }
}
