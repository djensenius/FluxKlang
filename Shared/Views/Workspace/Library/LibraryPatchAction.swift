//
//  LibraryPatchAction.swift
//  FluxKlang
//
//  The actions of a Library patch or variation row (#99 LIB2; library-inspector.md "Library" mock: [Recall] [Open]
//  on a patch, [Recall] on a variation), named as the doc names them. An action is a value: what Open and Recall do
//  is not defined anywhere yet, so the model starts nothing. Used by `LibrarySectionView`.
//

enum LibraryPatchActionKind: Hashable, Sendable, CaseIterable {
    case recall
    case open
}

struct LibraryPatchAction: Hashable, Sendable {
    let kind: LibraryPatchActionKind
    let title: String
    /// Nil when the action is enabled; otherwise the reason it is disabled.
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }

    private init(_ kind: LibraryPatchActionKind, title: String, disabledReason: String? = nil) {
        self.kind = kind
        self.title = title
        self.disabledReason = disabledReason
    }

    /// Recall of a variation; a variation row exists only for a readable patch.
    static let recall = Self(.recall, title: "Recall")

    /// `Recall` and `Open`, in that order. Recall refuses a malformed or newer-version set, so it is disabled with
    /// the status's reason exactly then; Open is always enabled.
    static func actions(for status: LibraryPatchStatus) -> [Self] {
        [Self(.recall, title: "Recall", disabledReason: status.reasonText), Self(.open, title: "Open")]
    }
}
