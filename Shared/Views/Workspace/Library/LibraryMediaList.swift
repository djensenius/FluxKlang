//
//  LibraryMediaList.swift
//  FluxKlang
//
//  The Library "Charts & media" section as a value (#99 LIB4; library-inspector.md "Library" mock and "Search
//  filters by name, kind and status"), built from the project's assets: one row per asset, ordered by title, with
//  search by name, kind and status. Content availability is the caller's input, as `ShowLinkCatalog.make` takes it.
//  No view, command, picker, I/O or clock; nothing calls it yet.
//
//  Not modelled, because there is no data source or no doc rule yet: timing (owned by #53); digest and byte count;
//  what Locate does; bookmark resolution; charts a show references that the project lacks; an empty-state text; and
//  localisation.
//

struct LibraryMediaList: Hashable, Sendable {
    static let title = LibraryMediaText.sectionTitle

    /// Ordered by lowercased title bytes, then exact title bytes, then id bytes (all UTF-8). Status never ranks.
    let rows: [LibraryMediaRow]

    private init(rows: [LibraryMediaRow]) {
        self.rows = rows
    }

    /// An asset whose id is not in `availableContent` is a stale bookmark; an id that matches no asset is ignored.
    /// Throws for the first asset, in input order, whose id repeats an earlier one.
    static func make(
        assets: [ProjectAsset], availableContent: Set<AssetID>
    ) throws(LibraryMediaListRefusal) -> Self {
        var seen = Set<AssetID>()
        for asset in assets where !seen.insert(asset.id).inserted {
            throw .duplicateAsset(asset.id)
        }
        let keyed = assets.map { asset -> (key: SortKey, row: LibraryMediaRow) in
            let row = LibraryMediaRow(asset: asset, isContentAvailable: availableContent.contains(asset.id))
            return (SortKey(row), row)
        }
        return Self(rows: keyed.sorted { $0.key.precedes($1.key) }.map(\.row))
    }

    /// Rows where every whitespace-separated term is a case-insensitive substring of the title, kind text or status
    /// text. A blank query returns the list unchanged.
    func filtered(by query: String) -> Self {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !terms.isEmpty else { return self }
        return Self(rows: rows.filter { $0.matches(terms: terms) })
    }

    /// UTF-8 byte keys, computed once per row, so the order never depends on `String` comparison or input order.
    private struct SortKey {
        let folded: [UInt8]
        let exact: [UInt8]
        let id: [UInt8]

        init(_ row: LibraryMediaRow) {
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
