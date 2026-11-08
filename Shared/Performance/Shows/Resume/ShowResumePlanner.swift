//
//  ShowResumePlanner.swift
//  FluxKlang
//
//  Turns a saved `ShowResumePoint` and the CURRENT library into exactly one decision (#106).
//  The planner has no cursor: it never moves one, and a `confirm` is applied by the caller through its `jump`
//  only after the operator accepts. It never reads titles, marks, links or charts, and it never proposes an entry
//  of another setlist.
//
//  Order of the checks, the first that applies decides:
//  0. The point is validated (a refusal is thrown, even when the setlist is gone).
//  1. The setlist is gone: `blocked(.setlistRemoved)`.
//  2. The saved entry is not in that setlist: an empty setlist is `blocked(.setlistEmpty)`; otherwise `confirm` at
//     the next entry, else the previous entry (each only when it is in that setlist), else the entry at the saved
//     index clamped to the last.
//  3. The entry plays another song than the point recorded, or the library has no such song:
//     `blocked(.songChanged)`.
//  4. The part no longer matches: `confirm`. Every confirm jumps with no part, which the cursor resolves to the first
//     part of the entry's song (no part when the song has none).
//  5. Otherwise `exact`.
//

enum ShowResumePlanner {
    static func plan(_ point: ShowResumePoint, in library: ShowLibrary) throws(ShowResumeRefusal)
        -> ShowResumeDecision {
        try point.validate()
        guard let setlist = library.setlist(point.setlist) else { return .blocked(.setlistRemoved(point.setlist)) }
        guard let entry = setlist.entries.first(where: { $0.id == point.entry }) else {
            return replacement(for: point, in: setlist, library: library)
        }
        guard entry.song == point.song else { return .blocked(.songChanged(point.entry)) }
        guard let song = library.song(entry.song) else { return .blocked(.songChanged(point.entry)) }
        return decision(at: entry, point: point, song: song)
    }

    private static func decision(at entry: SetlistEntry, point: ShowResumePoint,
                                 song: ShowSong) -> ShowResumeDecision {
        let landing = ShowPosition(setlist: point.setlist, entry: entry.id, part: song.parts.first?.id)
        if let saved = point.part {
            guard song.part(saved) != nil else {
                return .confirm(proposal(landing, basis: .partMissing(saved)))
            }
            let target = ShowPosition(setlist: point.setlist, entry: entry.id, part: saved)
            return .exact(target: target, jump: .jump(entry.id, saved))
        }
        guard song.parts.isEmpty else { return .confirm(proposal(landing, basis: .partsAdded)) }
        return .exact(target: landing, jump: .jump(entry.id, nil))
    }

    /// The saved entry is gone: the neighbours in the pinned order, then the clamped index.
    private static func replacement(for point: ShowResumePoint, in setlist: ShowSetlist,
                                    library: ShowLibrary) -> ShowResumeDecision {
        let entries = setlist.entries
        guard !entries.isEmpty else { return .blocked(.setlistEmpty(setlist.id)) }
        if let next = point.nextEntry, let found = entries.first(where: { $0.id == next }) {
            return start(of: found, in: setlist, library: library, basis: .entryMissingNext(point.entry))
        }
        if let previous = point.previousEntry, let found = entries.first(where: { $0.id == previous }) {
            return start(of: found, in: setlist, library: library, basis: .entryMissingPrevious(point.entry))
        }
        let last = entries.count - 1
        let index = min(point.entryOrdinal, last)
        return start(of: entries[index], in: setlist, library: library, basis: .entryMissingOrdinal(point.entry))
    }

    private static func start(of entry: SetlistEntry, in setlist: ShowSetlist, library: ShowLibrary,
                              basis: ShowResumeBasis) -> ShowResumeDecision {
        let first = library.song(entry.song)?.parts.first?.id
        return .confirm(proposal(ShowPosition(setlist: setlist.id, entry: entry.id, part: first), basis: basis))
    }

    private static func proposal(_ target: ShowPosition, basis: ShowResumeBasis) -> ShowResumeProposal {
        ShowResumeProposal(target: target, jump: .jump(target.entry, nil), basis: basis)
    }
}
