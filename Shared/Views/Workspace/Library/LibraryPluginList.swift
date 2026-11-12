//
//  LibraryPluginList.swift
//  FluxKlang
//
//  The Library "Plugins" section as a value (#99 LIB1; library-inspector.md "Library", "Non-drag, keyboard and
//  VoiceOver paths" and "States"), built from the plugin catalog (#70): one row per entry, ordered by name, with a
//  "Not scanned" row and its explicit Scan... action when the catalog was never scanned, and search by name, kind
//  and status. No view, scan, command, I/O or clock; nothing calls it yet.
//
//  Not modelled, because there is no data source or no doc rule yet: the Stale state ("Last seen previous session");
//  the remote-host Add refusal ("Hosts edit structure"); the Patches, Rigs, Templates and Charts sections, which
//  belong to other lanes; where Add to Wiring places a node; the Replace with... picker; an empty-state text; and
//  any forget or quarantine-release action.
//

struct LibraryPluginList: Hashable, Sendable {
    /// The catalog generation the list was built from.
    let generation: Generation
    /// Ordered by lowercased title bytes, then exact title bytes, then id bytes (all UTF-8). Status never ranks.
    let rows: [LibraryPluginRow]
    /// Non-nil exactly when the catalog was never scanned.
    let scanRow: LibraryPluginScanRow?

    private init(generation: Generation, rows: [LibraryPluginRow], scanRow: LibraryPluginScanRow?) {
        self.generation = generation
        self.rows = rows
        self.scanRow = scanRow
    }

    /// `incompatible` is the caller's judgment per plugin id (the list is context free and never infers it). It
    /// counts only for an installed entry with a descriptor and quarantine still wins; any other id is ignored.
    /// Nothing in the inputs is refusable, so this does not throw.
    static func make(
        catalog: PluginCatalog, incompatible: [PluginID: LibraryPluginIncompatibility] = [:]
    ) -> Self {
        let keyed = catalog.entries.values.map { entry -> (key: SortKey, row: LibraryPluginRow) in
            let row = LibraryPluginRow(entry: entry, judgment: incompatible[entry.identity.id])
            return (SortKey(row), row)
        }
        return Self(
            generation: catalog.generation,
            rows: keyed.sorted { $0.key.precedes($1.key) }.map(\.row),
            scanRow: catalog.scanState == .notScanned ? LibraryPluginScanRow() : nil
        )
    }

    /// Rows (and the scan row) where every whitespace-separated term is a case-insensitive substring of the title,
    /// kind text or status text. A blank query returns the list unchanged. The generation and order are kept.
    func filtered(by query: String) -> Self {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !terms.isEmpty else { return self }
        return Self(
            generation: generation,
            rows: rows.filter { $0.matches(terms: terms) },
            scanRow: scanRow.flatMap { $0.matches(terms: terms) ? $0 : nil }
        )
    }

    /// UTF-8 byte keys, computed once per row, so the order never depends on `String` comparison or dictionary order.
    private struct SortKey {
        let folded: [UInt8]
        let exact: [UInt8]
        let id: [UInt8]

        init(_ row: LibraryPluginRow) {
            folded = Array(row.title.lowercased().utf8)
            exact = Array(row.title.utf8)
            id = Array(row.id.rawValue.utf8)
        }

        func precedes(_ other: Self) -> Bool {
            if folded != other.folded { return folded.lexicographicallyPrecedes(other.folded) }
            if exact != other.exact { return exact.lexicographicallyPrecedes(other.exact) }
            return id.lexicographicallyPrecedes(other.id)
        }
    }
}
