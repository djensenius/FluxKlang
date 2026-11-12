//
//  LibraryMediaRow.swift
//  FluxKlang
//
//  One asset of the Library "Charts & media" section (#99 LIB4; library-inspector.md "Library" mock): its stored
//  label, a kind word, a status word and the Locate action of a stale bookmark. Timing is owned by #53 and is never
//  read. Built only by `LibraryMediaList.make`; storage is `let`. Nothing calls it yet.
//

struct LibraryMediaRow: Hashable, Sendable, Identifiable {
    let id: AssetID
    /// The stored label exactly, or `Unnamed asset` when it has no non-whitespace character.
    let title: String
    /// The raw asset id for a nameless row, so it can be told apart; nil otherwise.
    let secondaryText: String?
    let media: AssetMedia
    let kindText: String
    let status: LibraryMediaStatus
    let statusText: String
    let actions: [LibraryMediaAction]
    let accessibilityLabel: String

    init(asset: ProjectAsset, isContentAvailable: Bool) {
        let isNamed = asset.label.contains { !$0.isWhitespace }
        let title = isNamed ? asset.label : LibraryMediaText.unnamedAsset
        let status: LibraryMediaStatus = isContentAvailable ? .available : .staleBookmark
        let kindText = LibraryMediaText.kind(asset.media)
        let statusText = LibraryMediaText.status(status)
        id = asset.id
        self.title = title
        secondaryText = isNamed ? nil : asset.id.rawValue
        media = asset.media
        self.kindText = kindText
        self.status = status
        self.statusText = statusText
        actions = LibraryMediaAction.actions(for: status)
        accessibilityLabel = LibraryMediaText.accessibilityLabel(
            title: title, kindText: kindText, statusText: statusText
        )
    }

    /// Lowercased title, kind text and status text; never an id or the secondary text.
    var searchFields: [String] { [title, kindText, statusText].map { $0.lowercased() } }

    func matches(terms: [String]) -> Bool {
        let fields = searchFields
        return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }
}
