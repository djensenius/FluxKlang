//
//  ShowStageLine.swift
//  FluxKlang
//
//  One line of the stage display: a song and part with its numbering, rehearsal
//  mark, chart availability and link problems (#106 SHV1). Values are derived
//  only from a library, a setlist and a catalog; nothing is opened or fired.
//

/// The effective chart of a line. A missing chart keeps its reference and reason so it stays recoverable.
enum ShowStageChart: Hashable, Sendable {
    case none
    case available(ChartReference)
    case missing(ChartReference, ChartMissingReason)

    init(_ availability: ChartAvailability?) {
        switch availability {
        case nil: self = .none
        case let .available(reference)?: self = .available(reference)
        case let .missing(reference, reason)?: self = .missing(reference, reason)
        }
    }
}

/// Titles and labels are the library's text byte for byte (no trimming, truncation or normalization); identity is
/// the ids, so the synthesized `Equatable` over display text is deliberate.
struct ShowStageLine: Hashable, Sendable {
    let position: ShowPosition
    let song: SongID
    let songTitle: String
    /// `nil` for a song without parts.
    let partTitle: String?
    let mark: RehearsalMark?
    /// The ENTRY's index in the setlist plus one (one song can occupy several entries).
    let songNumber: Int
    let songCount: Int
    /// The part's index in its song plus one; `nil` for a song without parts.
    let partNumber: Int?
    /// `0` for a song without parts.
    let partCount: Int
    let chart: ShowStageChart
    /// Copied whole and in order from the resolved links; a line with problems is still produced.
    let problems: [ShowLinkProblem]
    /// True when this line's entry is not the entry the cursor is on.
    let startsNewSong: Bool

    /// `current` is the entry the cursor is on, or `nil` for a cursor that has no position yet.
    init(at position: ShowPosition, current: SetlistEntryID?, in setlist: ShowSetlist, library: ShowLibrary,
         catalog: ShowLinkCatalog) throws(ShowRefusal) {
        guard let entryIndex = setlist.index(of: position.entry) else { throw .unknownEntry(position.entry) }
        let entry = setlist.entries[entryIndex]
        guard let song = library.song(entry.song) else { throw .unknownSong(entry.song) }
        let resolved = try ShowLibrary.resolvedLinks(song: song, part: position.part, in: catalog)
        let partIndex = position.part.flatMap { id in song.parts.firstIndex { $0.id == id } }
        self.position = position
        self.song = song.id
        songTitle = song.title
        partTitle = partIndex.map { song.parts[$0].title }
        mark = partIndex.flatMap { song.parts[$0].mark }
        songNumber = entryIndex + 1
        songCount = setlist.entries.count
        partNumber = partIndex.map { $0 + 1 }
        partCount = song.parts.count
        chart = ShowStageChart(resolved.chart)
        problems = resolved.problems
        startsNewSong = current != position.entry
    }
}
