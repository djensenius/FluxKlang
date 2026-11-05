//
//  ShowLibrary.swift
//  FluxKlang
//
//  A project's songs and setlists (#106 SH1). Every setlist entry names an
//  existing song, entry IDs are unique across setlists, and edits that would
//  break either are refused rather than cascading.
//

struct ShowLibrary: Hashable, Sendable {
    private let storedSongs: [ShowSong]
    private let storedSetlists: [ShowSetlist]

    var songs: [ShowSong] { storedSongs }
    var setlists: [ShowSetlist] { storedSetlists }

    private init(songs: [ShowSong], setlists: [ShowSetlist]) {
        storedSongs = songs
        storedSetlists = setlists
    }

    /// The LOAD path only: links are not checked against a catalog (`linkReport(in:)` reports them, and they stay
    /// relinkable). Edits go through the catalog-checked paths such as `upsertingSong(_:in:)`.
    static func make(songs: [ShowSong] = [], setlists: [ShowSetlist] = []) throws(ShowRefusal) -> ShowLibrary {
        guard songs.count <= ShowLimits.maximumSongs else { throw .tooManySongs(songs.count) }
        guard setlists.count <= ShowLimits.maximumSetlists else { throw .tooManySetlists(setlists.count) }
        if let duplicate = ShowOrdering.firstDuplicate(in: songs) { throw .duplicateSong(duplicate) }
        if let duplicate = ShowOrdering.firstDuplicate(in: setlists) { throw .duplicateSetlist(duplicate) }
        let songIDs = Set(songs.map(\.id))
        var entryIDs = Set<SetlistEntryID>()
        for entry in setlists.flatMap(\.entries) {
            guard entryIDs.insert(entry.id).inserted else { throw .duplicateEntry(entry.id) }
            guard songIDs.contains(entry.song) else { throw .unknownSong(entry.song) }
        }
        return ShowLibrary(songs: songs, setlists: setlists)
    }

    func song(_ id: SongID) -> ShowSong? { songs.first { $0.id == id } }
    func setlist(_ id: SetlistID) -> ShowSetlist? { setlists.first { $0.id == id } }

    /// Edit path: replaces the song with the same ID in place, or appends a new one. Every reference added or
    /// changed against the stored song (its chart, and each part's links matched by part ID) must resolve; see
    /// `ShowLinkCatalog.check(_:replacing:)`. Unchanged loaded broken links stay until relinked; a song with
    /// broken links enters only through `make` (load), which `linkReport(in:)` then reports.
    func upsertingSong(_ song: ShowSong, in catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowLibrary {
        let stored = self.song(song.id)
        if let chart = song.chart, chart != stored?.chart { try catalog.checkChart(chart) }
        for part in song.parts { try catalog.check(part.links, replacing: stored?.part(part.id)?.links) }
        var updated = songs
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            updated[index] = song
        } else {
            updated.append(song)
        }
        return try Self.make(songs: updated, setlists: setlists)
    }

    /// Refused while any entry still plays the song.
    func removingSong(_ id: SongID) throws(ShowRefusal) -> ShowLibrary {
        if let entry = setlists.lazy.flatMap(\.entries).first(where: { $0.song == id }) {
            throw .songInUse(id, entry.id)
        }
        return try Self.make(songs: ShowOrdering.removing(id, from: songs, unknown: ShowRefusal.unknownSong),
                             setlists: setlists)
    }

    func insertingSetlist(_ setlist: ShowSetlist, before anchor: SetlistID? = nil) throws(ShowRefusal) -> ShowLibrary {
        try Self.make(songs: songs, setlists: ShowOrdering.inserting(setlist, before: anchor, in: setlists,
                                                                     unknown: ShowRefusal.unknownSetlist))
    }

    func movingSetlist(_ id: SetlistID, before anchor: SetlistID?) throws(ShowRefusal) -> ShowLibrary {
        try Self.make(songs: songs, setlists: ShowOrdering.moving(id, before: anchor, in: setlists,
                                                                  unknown: ShowRefusal.unknownSetlist))
    }

    func removingSetlist(_ id: SetlistID) throws(ShowRefusal) -> ShowLibrary {
        try Self.make(songs: songs, setlists: ShowOrdering.removing(id, from: setlists,
                                                                    unknown: ShowRefusal.unknownSetlist))
    }

    /// Replaces the setlist with the same ID, for example after an entry edit.
    func replacingSetlist(_ setlist: ShowSetlist) throws(ShowRefusal) -> ShowLibrary {
        guard let index = setlists.firstIndex(where: { $0.id == setlist.id }) else {
            throw .unknownSetlist(setlist.id)
        }
        var updated = setlists
        updated[index] = setlist
        return try Self.make(songs: songs, setlists: updated)
    }
}
