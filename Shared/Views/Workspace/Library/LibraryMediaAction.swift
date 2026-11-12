//
//  LibraryMediaAction.swift
//  FluxKlang
//
//  The action of a Library chart or media row (#99 LIB4; library-inspector.md "Library" mock: [Locate...] on a stale
//  bookmark), named as the doc names it. An action is a value: what Locate does is not defined anywhere yet, so the
//  model starts nothing and opens no picker. Nothing calls it yet.
//

enum LibraryMediaActionKind: Hashable, Sendable, CaseIterable {
    case locate
}

struct LibraryMediaAction: Hashable, Sendable {
    let kind: LibraryMediaActionKind
    let title: String
    /// Nil when the action is enabled; otherwise the reason it is disabled.
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }

    private init(_ kind: LibraryMediaActionKind, title: String, disabledReason: String? = nil) {
        self.kind = kind
        self.title = title
        self.disabledReason = disabledReason
    }

    /// `Locate...` for a stale bookmark, always enabled; an available row has no action.
    static func actions(for status: LibraryMediaStatus) -> [Self] {
        switch status {
        case .available: []
        case .staleBookmark: [Self(.locate, title: LibraryMediaText.locate)]
        }
    }
}
