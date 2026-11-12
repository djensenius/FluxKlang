//
//  LibraryPatchList.swift
//  FluxKlang
//
//  The Library "Patches & Variations" section as a value (#99 LIB2; library-inspector.md "Library" mock and "Search
//  filters by name, kind and status"), built from the project's patches: one row per patch, ordered by title, with
//  its variations nested in their STORED order (the user's order is the data), and search by name, kind and detail.
//  No view, command, scan, I/O or clock; nothing calls it yet.
//
//  Not modelled, because there is no data source or no doc rule yet: which patch or variation is active; any source
//  of prepared-ness other than the caller's set; editing, repair, discard and delete actions; what Open or Recall
//  do; an empty-state text; unknown top-level fields of a patch; the other Library sections (rigs, templates,
//  charts and media belong to other lanes); and localisation.
//

struct LibraryPatchList: Hashable, Sendable {
    /// Ordered by lowercased title bytes, then exact title bytes, then id bytes (all UTF-8). Status never ranks.
    let rows: [LibraryPatchRow]

    private init(rows: [LibraryPatchRow]) {
        self.rows = rows
    }

    /// `prepared` is the caller's input (no data source for it exists yet): a listed variation shows it, an id that
    /// matches no listed variation is ignored, and the same variation id under another patch is not affected.
    /// Throws for the first patch, in input order, whose id repeats an earlier one.
    static func make(
        patches: [ProjectPatch], prepared: Set<LibraryVariationID> = []
    ) throws(LibraryPatchListRefusal) -> Self {
        var seen = Set<PatchID>()
        for patch in patches where !seen.insert(patch.id).inserted {
            throw .duplicatePatch(patch.id)
        }
        let keyed = patches.map { patch -> (key: SortKey, row: LibraryPatchRow) in
            let row = LibraryPatchRow(patch: patch, prepared: prepared)
            return (SortKey(row), row)
        }
        return Self(rows: keyed.sorted { $0.key.precedes($1.key) }.map(\.row))
    }

    /// Rows where every whitespace-separated term is a case-insensitive substring of the title, kind text or detail
    /// text; a variation row also matches through its patch row. A blank query returns the list unchanged.
    func filtered(by query: String) -> Self {
        let terms = LibrarySearchTerms.terms(query)
        guard !terms.isEmpty else { return self }
        return Self(rows: rows.compactMap { $0.keeping(terms: terms) })
    }

    /// UTF-8 byte keys, computed once per row, so the order never depends on `String` comparison or input order.
    private struct SortKey {
        let folded: [UInt8]
        let exact: [UInt8]
        let id: [UInt8]

        init(_ row: LibraryPatchRow) {
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
