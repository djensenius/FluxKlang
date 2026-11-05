//
//  ShowSetlist.swift
//  FluxKlang
//
//  An ordered setlist of entries (#106 SH1). Entries, not songs, are the
//  navigation targets, so a song may repeat and reordering never retargets.
//

/// Callers create entries (adding a song to a setlist) through `make`, which cannot refuse: both IDs are already
/// validated. Uniqueness is checked by `ShowSetlist` and `ShowLibrary`, and song existence by `ShowLibrary`.
struct SetlistEntry: Hashable, Sendable, Identifiable {
    private let storedID: SetlistEntryID
    private let storedSong: SongID

    var id: SetlistEntryID { storedID }
    var song: SongID { storedSong }

    private init(id: SetlistEntryID, song: SongID) {
        storedID = id
        storedSong = song
    }

    static func make(id: SetlistEntryID, song: SongID) -> SetlistEntry {
        SetlistEntry(id: id, song: song)
    }
}

struct ShowSetlist: Hashable, Sendable, Identifiable {
    private let storedID: SetlistID
    private let storedTitle: String
    private let storedEntries: [SetlistEntry]

    var id: SetlistID { storedID }
    var title: String { storedTitle }
    /// In performance order.
    var entries: [SetlistEntry] { storedEntries }

    private init(id: SetlistID, title: String, entries: [SetlistEntry]) {
        storedID = id
        storedTitle = title
        storedEntries = entries
    }

    /// Song existence is checked by `ShowLibrary`, which owns the songs.
    static func make(id: SetlistID, title: String, entries: [SetlistEntry] = []) throws(ShowRefusal) -> ShowSetlist {
        guard ShowLimits.isValidTitle(title) else { throw .invalidTitle }
        guard entries.count <= ShowLimits.maximumEntriesPerSetlist else { throw .tooManyEntries(id, entries.count) }
        if let duplicate = ShowOrdering.firstDuplicate(in: entries) { throw .duplicateEntry(duplicate) }
        return ShowSetlist(id: id, title: title, entries: entries)
    }

    func index(of entry: SetlistEntryID) -> Int? { entries.firstIndex { $0.id == entry } }

    func inserting(_ entry: SetlistEntry, before anchor: SetlistEntryID? = nil) throws(ShowRefusal) -> ShowSetlist {
        try rebuilt(ShowOrdering.inserting(entry, before: anchor, in: entries, unknown: ShowRefusal.unknownEntry))
    }

    func moving(_ entry: SetlistEntryID, before anchor: SetlistEntryID?) throws(ShowRefusal) -> ShowSetlist {
        try rebuilt(ShowOrdering.moving(entry, before: anchor, in: entries, unknown: ShowRefusal.unknownEntry))
    }

    func removing(_ entry: SetlistEntryID) throws(ShowRefusal) -> ShowSetlist {
        try rebuilt(ShowOrdering.removing(entry, from: entries, unknown: ShowRefusal.unknownEntry))
    }

    private func rebuilt(_ entries: [SetlistEntry]) throws(ShowRefusal) -> ShowSetlist {
        try Self.make(id: id, title: title, entries: entries)
    }
}
