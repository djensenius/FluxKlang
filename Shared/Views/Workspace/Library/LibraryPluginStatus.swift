//
//  LibraryPluginStatus.swift
//  FluxKlang
//
//  The status of one Library plugin row (#99 LIB1; library-inspector.md "Library" plugin table): installed, missing,
//  incompatible, failed, needs rescan or quarantined. The list's "Not scanned" state is not a row status; it is the
//  list's scan row. Pure values: no view, no scan, no I/O. Nothing calls it yet.
//

/// Why the caller judged an installed plugin unusable for its target. The list is context free: it never infers this.
enum LibraryPluginIncompatibility: Hashable, Sendable, CaseIterable {
    case wrongKind
    case wrongPorts
}

/// What a plugin row says about the plugin. A row's status comes from its catalog entry alone.
enum LibraryPluginStatus: Hashable, Sendable {
    case installed
    case missing
    case incompatible(LibraryPluginIncompatibility)
    case failed
    case needsRescan
    case quarantined(PluginQuarantineReason)

    /// The status of an entry. Quarantine wins, as in `PluginCatalog.resolve`; then the caller's judgment, which
    /// counts only for an installed entry with a descriptor; then the entry's presence.
    static func of(_ entry: PluginCatalogEntry, judgment: LibraryPluginIncompatibility?) -> Self {
        if let reason = entry.quarantine { return .quarantined(reason) }
        switch entry.presence {
        case .installed:
            guard entry.lastKnown != nil else { return .needsRescan }
            return judgment.map { .incompatible($0) } ?? .installed
        case .missing:
            return .missing
        case .failed:
            return .failed
        case .needsRescan:
            return .needsRescan
        }
    }
}
