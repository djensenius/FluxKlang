//
//  ShowStageProjection.swift
//  FluxKlang
//
//  What the stage display shows for a show cursor: the current line and the line each relative foot command would
//  reach (#106 SHV1). It reads and never moves the cursor, and it computes the destinations from the setlist itself;
//  they are proven equal to `ShowCursor.navigate` by tests, not by sharing its code.
//

enum ShowStageDestination: CaseIterable, Hashable, Sendable {
    case nextPart
    case previousPart
    case nextSong
    case previousSong
}

struct ShowStageProjection: Hashable, Sendable {
    enum CursorState: Hashable, Sendable {
        case positioned
        /// Made on an empty setlist and never moved.
        case unpositioned
        /// The cursor's target is gone or stale: nothing is projected, and only a jump recovers.
        case stale(ShowCursorStatus)
    }

    let setlist: SetlistID
    /// `nil` only when the setlist was removed.
    let setlistTitle: String?
    /// `nil` only when the setlist was removed.
    let entryCount: Int?
    let cursorState: CursorState
    let now: ShowStageLine?
    let nextPart: ShowStageLine?
    let previousPart: ShowStageLine?
    let nextSong: ShowStageLine?
    let previousSong: ShowStageLine?

    private init(setlist: ShowSetlist?, id: SetlistID, state: CursorState, lines: Lines) {
        self.setlist = id
        setlistTitle = setlist?.title
        entryCount = setlist?.entries.count
        cursorState = state
        now = lines.now
        nextPart = lines.nextPart
        previousPart = lines.previousPart
        nextSong = lines.nextSong
        previousSong = lines.previousSong
    }

    /// The line the command would reach, or `nil` at the end or start of the setlist and for a stale cursor.
    func line(for destination: ShowStageDestination) -> ShowStageLine? {
        switch destination {
        case .nextPart: nextPart
        case .previousPart: previousPart
        case .nextSong: nextSong
        case .previousSong: previousSong
        }
    }

    /// Refuses only for a library or position that is inconsistent (`unknownSong`, `unknownPart`, `unknownEntry`),
    /// which `ShowLibrary.make` and the cursor status rule out.
    static func make(library: ShowLibrary, cursor: ShowCursor,
                     catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowStageProjection {
        let status = cursor.status(in: library)
        let stored = library.setlist(cursor.setlist)
        guard status == .current, let setlist = stored else {
            return ShowStageProjection(setlist: stored, id: cursor.setlist, state: .stale(status), lines: Lines())
        }
        guard let position = cursor.position else {
            let lines = try unpositionedLines(in: setlist, library: library, catalog: catalog)
            return ShowStageProjection(setlist: setlist, id: setlist.id, state: .unpositioned, lines: lines)
        }
        let lines = try positionedLines(from: position, in: setlist, library: library, catalog: catalog)
        return ShowStageProjection(setlist: setlist, id: setlist.id, state: .positioned, lines: lines)
    }
}

extension ShowStageProjection {
    private struct Lines {
        var now: ShowStageLine?
        var nextPart: ShowStageLine?
        var previousPart: ShowStageLine?
        var nextSong: ShowStageLine?
        var previousSong: ShowStageLine?
    }

    private struct Targets {
        var nextPart: ShowPosition?
        var previousPart: ShowPosition?
        var nextSong: ShowPosition?
        var previousSong: ShowPosition?
    }

    private static func unpositionedLines(in setlist: ShowSetlist, library: ShowLibrary,
                                          catalog: ShowLinkCatalog) throws(ShowRefusal) -> Lines {
        var lines = Lines()
        guard let first = setlist.entries.first else { return lines }
        let target = try start(of: first, in: setlist, library: library)
        let line = try ShowStageLine(at: target, current: nil, in: setlist, library: library, catalog: catalog)
        lines.nextPart = line
        lines.nextSong = line
        return lines
    }

    private static func positionedLines(from position: ShowPosition, in setlist: ShowSetlist, library: ShowLibrary,
                                        catalog: ShowLinkCatalog) throws(ShowRefusal) -> Lines {
        let targets = try targets(from: position, in: setlist, library: library)
        func line(_ target: ShowPosition?) throws(ShowRefusal) -> ShowStageLine? {
            guard let target else { return nil }
            return try ShowStageLine(at: target, current: position.entry, in: setlist, library: library,
                                     catalog: catalog)
        }
        return try Lines(now: line(position), nextPart: line(targets.nextPart),
                         previousPart: line(targets.previousPart), nextSong: line(targets.nextSong),
                         previousSong: line(targets.previousSong))
    }

    private static func targets(from position: ShowPosition, in setlist: ShowSetlist,
                                library: ShowLibrary) throws(ShowRefusal) -> Targets {
        let entries = setlist.entries
        guard let index = setlist.index(of: position.entry) else { throw .unknownEntry(position.entry) }
        guard let song = library.song(entries[index].song) else { throw .unknownSong(entries[index].song) }
        let partIndex = position.part.flatMap { id in song.parts.firstIndex { $0.id == id } }
        var targets = Targets()
        if index + 1 < entries.count {
            targets.nextSong = try start(of: entries[index + 1], in: setlist, library: library)
        }
        targets.nextPart = targets.nextSong
        let following = (partIndex ?? -1) + 1
        if following < song.parts.count {
            targets.nextPart = ShowPosition(setlist: setlist.id, entry: position.entry, part: song.parts[following].id)
        }
        if index > 0 {
            targets.previousSong = try start(of: entries[index - 1], in: setlist, library: library)
            targets.previousPart = try end(of: entries[index - 1], in: setlist, library: library)
        }
        if let partIndex, partIndex > 0 {
            targets.previousPart = ShowPosition(setlist: setlist.id, entry: position.entry,
                                                part: song.parts[partIndex - 1].id)
        }
        return targets
    }

    private static func start(of entry: SetlistEntry, in setlist: ShowSetlist,
                              library: ShowLibrary) throws(ShowRefusal) -> ShowPosition {
        guard let song = library.song(entry.song) else { throw .unknownSong(entry.song) }
        return ShowPosition(setlist: setlist.id, entry: entry.id, part: song.parts.first?.id)
    }

    private static func end(of entry: SetlistEntry, in setlist: ShowSetlist,
                            library: ShowLibrary) throws(ShowRefusal) -> ShowPosition {
        guard let song = library.song(entry.song) else { throw .unknownSong(entry.song) }
        return ShowPosition(setlist: setlist.id, entry: entry.id, part: song.parts.last?.id)
    }
}
