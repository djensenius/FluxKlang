//
//  LibraryRigList.swift
//  FluxKlang
//
//  The Library "Rigs" section as a value (#99 LIB3; library-inspector.md "Library", whose rig row is owned by rigs
//  #100), built from the saved rig library and the devices the host currently observes: one flat row per saved rig,
//  ordered by name, with the matcher's operating mode as its status word, counts of its saved devices, and search by
//  name, kind and status. No view, scan, command, action, I/O or clock; nothing calls it yet.
//
//  Not modelled: the doc's "rev 7" (the library has no revision); any rig action (the doc shows none on a rig row;
//  a rig's content and actions belong to #100); which devices are missing and whether each is required (only the
//  mode and the counts are shown); activating or selecting a rig; an empty-state text for the section; the other
//  Library sections, which belong to other lanes; and localisation.
//

struct LibraryRigList: Hashable, Sendable {
    /// Ordered by lowercased title bytes, then exact title bytes (UTF-8). Status and selection never rank.
    let rows: [LibraryRigRow]

    private init(rows: [LibraryRigRow]) {
        self.rows = rows
    }

    /// Builds the observed index once, before any row, so an invalid observed list refuses even for an empty
    /// library (`tooManyObserved`, then `duplicateObservedDevice`). An empty list is legal: every saved device then
    /// reads missing. Presence comes only from the descriptors themselves.
    static func make(library: RigLibrary, observed: [DeviceDescriptor]) throws(RigIdentityRefusal) -> Self {
        let index = try RigObservedIndex.make(observed)
        let keyed = library.entries.map { entry -> (key: SortKey, row: LibraryRigRow) in
            let report = RigIdentityMatcher.report(for: entry.rig, index: index)
            let row = LibraryRigRow(entry: entry, report: report, isSelected: library.selected == entry.id)
            return (SortKey(row), row)
        }
        return Self(rows: keyed.sorted { $0.key.precedes($1.key) }.map(\.row))
    }

    /// Rows where every whitespace-separated term is a case-insensitive substring of the title, kind text, status
    /// text, detail text or selected text. A blank query returns the list unchanged. Order is kept and a kept row
    /// is never rewritten.
    func filtered(by query: String) -> Self {
        let terms = LibrarySearchTerms.terms(query)
        guard !terms.isEmpty else { return self }
        return Self(rows: rows.filter { $0.matches(terms: terms) })
    }

    /// UTF-8 byte keys, computed once per row. Names are unique, so no id tiebreak is needed.
    private struct SortKey {
        let folded: [UInt8]
        let exact: [UInt8]

        init(_ row: LibraryRigRow) {
            folded = Array(row.title.lowercased().utf8)
            exact = Array(row.title.utf8)
        }

        func precedes(_ other: Self) -> Bool {
            if folded != other.folded { return folded.lexicographicallyPrecedes(other.folded) }
            return exact.lexicographicallyPrecedes(other.exact)
        }
    }
}
