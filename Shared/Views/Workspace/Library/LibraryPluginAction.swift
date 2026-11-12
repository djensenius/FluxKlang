//
//  LibraryPluginAction.swift
//  FluxKlang
//
//  The actions of a Library plugin row (#99 LIB1; library-inspector.md "Library" plugin table and "Non-drag, keyboard
//  and VoiceOver paths"), named as the doc names them. An action is a value: the model starts nothing, scans nothing
//  and never edits a draft. Nothing calls it yet.
//

enum LibraryPluginActionKind: Hashable, Sendable, CaseIterable {
    case addToWiring
    case showInfo
    case locate
    case replaceWith
    case keepPlaceholder
    case scan
}

struct LibraryPluginAction: Hashable, Sendable {
    let kind: LibraryPluginActionKind
    let title: String
    /// Nil when the action is enabled; otherwise the reason it is disabled.
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }

    private init(_ kind: LibraryPluginActionKind, title: String, disabledReason: String? = nil) {
        self.kind = kind
        self.title = title
        self.disabledReason = disabledReason
    }

    /// The explicit scan request; the list's scan row and failed rows offer it.
    static let scan = Self(.scan, title: "Scan...")
    static let showInfo = Self(.showInfo, title: "Show info")
    private static let addToWiring = Self(.addToWiring, title: "Add to Wiring")

    /// The actions of a row with `status`, in display order.
    static func actions(for status: LibraryPluginStatus) -> [Self] {
        switch status {
        case .installed:
            [addToWiring, showInfo]
        case .missing:
            [
                Self(.locate, title: "Locate..."), Self(.replaceWith, title: "Replace with..."),
                Self(.keepPlaceholder, title: "Keep placeholder")
            ]
        case .incompatible(let incompatibility):
            [
                Self(
                    .addToWiring, title: "Add to Wiring",
                    disabledReason: LibraryPluginText.reason(of: .incompatible(incompatibility))
                ),
                showInfo
            ]
        case .failed, .needsRescan:
            [scan, showInfo]
        case .quarantined:
            [showInfo]
        }
    }
}
