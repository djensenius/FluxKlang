//
//  LibraryTemplatesSection.swift
//  FluxKlang
//
//  The Library "Templates" section as a constant placeholder (#99 LIB4; library-inspector.md "Library" mock:
//  "(none yet)"). No template type exists, so none is read or invented. Search matches the placeholder text only,
//  never the heading. Nothing calls it yet.
//

struct LibraryTemplatesSection: Hashable, Sendable {
    let title = LibraryMediaText.templatesTitle
    let placeholderText = LibraryMediaText.templatesPlaceholder

    init() {}

    /// "<title>, none yet"
    var accessibilityLabel: String { "\(title), none yet" }

    /// True for a blank query, or when every whitespace-separated term is a case-insensitive substring of the
    /// placeholder text.
    func matches(query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let field = placeholderText.lowercased()
        return terms.allSatisfy { field.contains($0) }
    }
}
