//
//  LibraryPluginRow.swift
//  FluxKlang
//
//  One row of the Library "Plugins" section (#99 LIB1; library-inspector.md "Library"): a name, a kind, a status
//  word and the actions, plus the list's "(scan)" row for a catalog that was never scanned. Built only by
//  `LibraryPluginList.make`; storage is `let`. Used by `LibrarySectionView`.
//

/// One plugin as the list shows it.
struct LibraryPluginRow: Hashable, Sendable, Identifiable {
    let id: PluginID
    /// The last known name, or `Unnamed plugin` when the entry was never described.
    let title: String
    /// The id's raw value for a row with no name; nil for a named row (ids are secondary text).
    let secondaryText: String?
    let kind: PluginComponentKind
    let kindText: String
    let status: LibraryPluginStatus
    let statusText: String
    let reasonText: String?
    let actions: [LibraryPluginAction]
    let accessibilityLabel: String

    init(entry: PluginCatalogEntry, judgment: LibraryPluginIncompatibility?) {
        let name = entry.lastKnown?.name
        let status = LibraryPluginStatus.of(entry, judgment: judgment)
        let title = name ?? LibraryPluginText.namelessTitle
        id = entry.identity.id
        self.title = title
        secondaryText = name == nil ? entry.identity.id.rawValue : nil
        kind = entry.identity.kind
        kindText = LibraryPluginText.kind(entry.identity.kind)
        self.status = status
        statusText = LibraryPluginText.status(status)
        reasonText = LibraryPluginText.reason(of: status)
        actions = LibraryPluginAction.actions(for: status)
        accessibilityLabel = LibraryPluginText.accessibilityLabel(
            title: title, kind: entry.identity.kind, status: status
        )
    }

    /// Whether every term (already lowercased) is a substring of the lowercased title, kind text or status text.
    func matches(terms: [String]) -> Bool {
        let fields = [title, kindText, statusText].map { $0.lowercased() }
        return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }
}

/// The row that stands for a catalog that was never scanned. Its one action asks for a scan; it never starts one.
struct LibraryPluginScanRow: Hashable, Sendable {
    let title: String
    let statusText: String
    let actions: [LibraryPluginAction]
    let accessibilityLabel: String

    init() {
        title = LibraryPluginText.scanRowTitle
        statusText = LibraryPluginText.notScannedText
        actions = [.scan]
        accessibilityLabel = LibraryPluginText.scanRowAccessibilityLabel
    }

    func matches(terms: [String]) -> Bool {
        let fields = [title, statusText].map { $0.lowercased() }
        return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }
}
