//
//  ShowResumePoint.swift
//  FluxKlang
//
//  A saved show position that can be re-anchored later (#106). It holds IDs and one index only, so it never
//  reads titles, marks, links or charts. `capture` builds a point from a live cursor; any other value is
//  caller-built, and the planner validates it again on every use.
//

struct ShowResumePoint: Equatable, Sendable {
    /// The largest valid `entryOrdinal`: the last index of a setlist at `ShowLimits.maximumEntriesPerSetlist` (256)
    /// entries, the most `ShowSetlist` accepts. `validate` is what refuses a negative ordinal; the planner's
    /// clamp to the last index guards only the upper end.
    static let maximumOrdinal = ShowLimits.maximumEntriesPerSetlist - 1

    let setlist: SetlistID
    let entry: SetlistEntryID
    /// The song the entry played when the point was captured.
    let song: SongID
    /// `nil` when the song had no parts.
    let part: SongPartID?
    /// The entry's index in its setlist when captured.
    let entryOrdinal: Int
    let previousEntry: SetlistEntryID?
    let nextEntry: SetlistEntryID?

    var isValid: Bool {
        do {
            try validate()
            return true
        } catch {
            return false
        }
    }

    /// Checks run in this order and the first that applies decides: the ordinal range, a neighbour that is the
    /// entry itself, then equal neighbours.
    func validate() throws(ShowResumeRefusal) {
        guard (0...Self.maximumOrdinal).contains(entryOrdinal) else { throw .ordinalOutOfRange(entryOrdinal) }
        if previousEntry == entry || nextEntry == entry { throw .neighbourIsEntry }
        if let previousEntry, previousEntry == nextEntry { throw .neighboursEqual }
    }

    /// Reads the cursor's own position and the library's current neighbours of that entry. A cursor whose status is
    /// not `.current` is refused with that status first; then a cursor without a position.
    static func capture(from cursor: ShowCursor,
                        in library: ShowLibrary) throws(ShowResumeRefusal) -> ShowResumePoint {
        let status = cursor.status(in: library)
        guard status == .current else { throw .cursorNotCurrent(status) }
        guard let position = cursor.position else { throw .cursorNotPositioned }
        guard let setlist = library.setlist(position.setlist) else {
            throw .cursorNotCurrent(.setlistRemoved(position.setlist))
        }
        guard let index = setlist.index(of: position.entry) else {
            throw .cursorNotCurrent(.entryRemoved(position.entry))
        }
        let entries = setlist.entries
        let previous = index > 0 ? entries[index - 1].id : nil
        let next = index + 1 < entries.count ? entries[index + 1].id : nil
        return ShowResumePoint(setlist: position.setlist, entry: position.entry, song: entries[index].song,
                               part: position.part, entryOrdinal: index, previousEntry: previous, nextEntry: next)
    }
}
