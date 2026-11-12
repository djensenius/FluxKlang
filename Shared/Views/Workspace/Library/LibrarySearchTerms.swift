//
//  LibrarySearchTerms.swift
//  FluxKlang
//
//  The Library's search-term splitting in one place (#99 LIBQ1). Every Library section's `filtered(by:)` shares it;
//  each row keeps its own matching rule and field list.
//

enum LibrarySearchTerms {
    /// The query's whitespace-separated terms, each lowercased. A blank query has no terms.
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    }
}
