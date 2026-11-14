import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A song for the stage tests: `parts` are the part ids; titles are derived from the ids unless given.
enum ShowStageFixture {
    static let list = SetlistID(validated: "set.stage")
    static let foot = ShowInputSourceID(validated: "src.foot")
    static let songA = SongID(validated: "song.a")
    static let songB = SongID(validated: "song.b")
    static let songC = SongID(validated: "song.c")
    static let songD = SongID(validated: "song.d")
    static let songE = SongID(validated: "song.e")

    static func songID(_ raw: String) -> SongID {
        guard let id = SongID(rawValue: raw) else { preconditionFailure("invalid song id in the fixture: \(raw)") }
        return id
    }

    static func entryID(_ raw: String) -> SetlistEntryID {
        guard let id = SetlistEntryID(rawValue: raw) else {
            preconditionFailure("invalid entry id in the fixture: \(raw)")
        }
        return id
    }

    static func partID(_ raw: String) -> SongPartID {
        guard let id = SongPartID(rawValue: raw) else { preconditionFailure("invalid part id in the fixture: \(raw)") }
        return id
    }

    static func pos(_ entry: String, _ part: String?) -> ShowPosition {
        ShowPosition(setlist: list, entry: entryID(entry), part: part.map { partID($0) })
    }

    static func part(_ raw: String, title: String? = nil, mark: RehearsalMark? = nil,
                     links: SongPartLinks = .none) throws -> SongPart {
        try SongPart.make(id: partID(raw), title: title ?? "Part \(raw)", mark: mark, links: links)
    }

    static func song(_ id: SongID, title: String? = nil, parts: [String],
                     chart: ChartReference? = nil) throws -> ShowSong {
        try ShowSong.make(id: id, title: title ?? "Song \(id)", parts: parts.map { try part($0) }, chart: chart)
    }

    static func entry(_ raw: String, _ song: SongID) -> SetlistEntry {
        SetlistEntry.make(id: entryID(raw), song: song)
    }

    static func library(songs: [ShowSong], entries: [SetlistEntry]) throws -> ShowLibrary {
        let setlist = try ShowSetlist.make(id: list, title: "Stage", entries: entries)
        return try ShowLibrary.make(songs: songs, setlists: [setlist])
    }

    static func catalog() throws -> ShowLinkCatalog {
        try ShowLinkCatalog.make(
            patches: [(PatchID(validated: "pat.keys"), [PatchVariationID(validated: "var.wet")])],
            assets: [asset("ast.chart", .document), asset("ast.stale", .document), asset("ast.midi", .midi)],
            availableContent: [AssetID(validated: "ast.chart"), AssetID(validated: "ast.midi")]
        )
    }

    static func asset(_ raw: StaticString, _ media: AssetMedia) -> ProjectAsset {
        ProjectAsset(id: AssetID(validated: raw), label: "Asset", media: media,
                     contentDigest: "sha256:" + String(repeating: "a", count: 64))
    }

    static func cursor(_ library: ShowLibrary, at entry: String, part: String?) throws -> ShowCursor {
        var cursor = try ShowCursor.make(setlist: list, bounceTicks: 0, sources: [foot], in: library)
        let input = ShowNavigationInput(.jump(entryID(entry), part.map { partID($0) }), source: foot, sequence: 1,
                                        tick: 0)
        _ = try cursor.navigate(input, in: library, catalog: catalog())
        return cursor
    }

    static func command(_ destination: ShowStageDestination) -> ShowNavigationCommand {
        switch destination {
        case .nextPart: .nextPart
        case .previousPart: .previousPart
        case .nextSong: .nextSong
        case .previousSong: .previousSong
        }
    }

    /// What `navigate` refuses with at the end or start of a setlist.
    static func boundary(_ destination: ShowStageDestination) -> ShowRefusal {
        switch destination {
        case .nextPart, .nextSong: .atEnd
        case .previousPart, .previousSong: .atStart
        }
    }

    enum Reach: Hashable {
        case moved(ShowPosition)
        case ignored
        case refused(ShowRefusal)
    }

    /// Runs the real command on a FRESH copy of the cursor (the cursor is a value), sequence 2 after the jump.
    static func reach(_ destination: ShowStageDestination, from cursor: ShowCursor, in library: ShowLibrary,
                      catalog: ShowLinkCatalog) -> Reach {
        var copy = cursor
        let input = ShowNavigationInput(command(destination), source: foot, sequence: 2, tick: 0)
        do {
            switch try copy.navigate(input, in: library, catalog: catalog) {
            case let .moved(stop): return .moved(stop.position)
            case .ignored: return .ignored
            }
        } catch {
            return .refused(error)
        }
    }

    /// Runs the real command on the given cursor (mutating it when it moves).
    static func attempt(_ cursor: inout ShowCursor, _ input: ShowNavigationInput, in library: ShowLibrary,
                        catalog: ShowLinkCatalog) -> Reach {
        do {
            switch try cursor.navigate(input, in: library, catalog: catalog) {
            case let .moved(stop): return .moved(stop.position)
            case .ignored: return .ignored
            }
        } catch {
            return .refused(error)
        }
    }

    struct Spot {
        let entry: SetlistEntryID
        let part: SongPartID?
    }

    /// Every entry with each of its parts (or the one part-less position).
    static func spots(_ library: ShowLibrary) -> [Spot] {
        var result: [Spot] = []
        for entry in library.setlist(list)?.entries ?? [] {
            let parts = library.song(entry.song)?.parts ?? []
            if parts.isEmpty { result.append(Spot(entry: entry.id, part: nil)) }
            for part in parts { result.append(Spot(entry: entry.id, part: part.id)) }
        }
        return result
    }

    struct GridCase {
        let name: String
        let library: ShowLibrary
    }

    static func songs(_ shapes: [SongID: [String]]) throws -> [ShowSong] {
        var result: [ShowSong] = []
        for id in shapes.keys.sorted() { result.append(try song(id, parts: shapes[id] ?? [])) }
        return result
    }

    static func mainLibrary() throws -> ShowLibrary {
        let songs = try songs([songA: ["a1", "a2", "a3"], songB: ["b1", "b2"], songC: []])
        let entries = [entry("e1", songA), entry("e2", songB), entry("e3", songA), entry("e4", songC)]
        return try library(songs: songs, entries: entries)
    }

    /// One-part song; three parts; the main four entries; part-less songs; three entries; a one-part song repeated.
    static func grid() throws -> [GridCase] {
        let single = try library(songs: songs([songD: ["d1"]]), entries: [entry("e1", songD)])
        let three = try library(songs: songs([songA: ["a1", "a2", "a3"]]), entries: [entry("e1", songA)])
        let partless = try library(songs: songs([songC: [], songE: []]),
                                   entries: [entry("e1", songC), entry("e2", songE), entry("e3", songC)])
        let mixed = try library(songs: songs([songA: ["a1", "a2"], songC: [], songB: ["b1"]]),
                                entries: [entry("e1", songA), entry("e2", songC), entry("e3", songB)])
        let repeated = try library(songs: songs([songD: ["d1"]]),
                                   entries: [entry("e1", songD), entry("e2", songD), entry("e3", songD)])
        return try [GridCase(name: "single", library: single), GridCase(name: "threeParts", library: three),
                    GridCase(name: "main", library: mainLibrary()), GridCase(name: "partless", library: partless),
                    GridCase(name: "mixed", library: mixed), GridCase(name: "repeated", library: repeated)]
    }
}

@Suite(.productionAccessAudit)
struct ShowStageProjectionTests {
    typealias Fix = ShowStageFixture

    /// One-part song, three parts, main, part-less, mixed, repeated: 1 + 3 + 9 + 3 + 4 + 3 positions.
    static let gridPositionCount = 23

    @Test
    func everyProjectedDestinationIsTheCursorsOwnTargetAndAbsentExactlyWhereNavigateRefuses() throws {
        let catalog = try Fix.catalog()
        var checked = 0
        for item in try Fix.grid() {
            for spot in Fix.spots(item.library) {
                let cursor = try Fix.cursor(item.library, at: spot.entry.rawValue, part: spot.part?.rawValue)
                let projection = try ShowStageProjection.make(library: item.library, cursor: cursor, catalog: catalog)
                #expect(projection.cursorState == .positioned, "\(item.name)")
                for destination in ShowStageDestination.allCases {
                    let reach = Fix.reach(destination, from: cursor, in: item.library, catalog: catalog)
                    let label = "\(item.name) \(spot.entry) \(String(describing: spot.part)) \(destination)"
                    if let line = projection.line(for: destination) {
                        #expect(reach == .moved(line.position), "\(label)")
                    } else {
                        #expect(reach == .refused(Fix.boundary(destination)), "\(label)")
                    }
                }
                checked += 1
            }
        }
        #expect(checked == Self.gridPositionCount)
    }

    @Test
    func nowIsTheCursorsCurrentStopWithItsSongChartAndProblems() throws {
        let catalog = try Fix.catalog()
        var checked = 0
        for item in try Fix.grid() {
            for spot in Fix.spots(item.library) {
                let cursor = try Fix.cursor(item.library, at: spot.entry.rawValue, part: spot.part?.rawValue)
                let projection = try ShowStageProjection.make(library: item.library, cursor: cursor, catalog: catalog)
                let stop = try #require(try cursor.currentStop(in: item.library, catalog: catalog))
                let now = try #require(projection.now)
                #expect(now.position == stop.position)
                #expect(now.song == stop.song)
                #expect(now.chart == ShowStageChart(stop.links.chart))
                #expect(now.problems == stop.links.problems)
                #expect(now.startsNewSong == false)
                checked += 1
            }
        }
        #expect(checked == Self.gridPositionCount)
    }

    @Test
    func aCursorOnAnEmptySetlistShowsNothingUntilTheSetlistGainsEntries() throws {
        let catalog = try Fix.catalog()
        let empty = try Fix.library(songs: Fix.songs([Fix.songA: ["a1", "a2"]]), entries: [])
        let cursor = try ShowCursor.make(setlist: Fix.list, bounceTicks: 0, sources: [Fix.foot], in: empty)
        let before = try ShowStageProjection.make(library: empty, cursor: cursor, catalog: catalog)
        #expect(before.cursorState == .unpositioned)
        #expect(before.entryCount == 0)
        #expect(before.setlistTitle == "Stage")
        for destination in ShowStageDestination.allCases {
            #expect(before.line(for: destination) == nil)
            #expect(Fix.reach(destination, from: cursor, in: empty, catalog: catalog)
                == .refused(.emptySetlist(Fix.list)))
        }
        #expect(before.now == nil)

        let setlist = try #require(empty.setlist(Fix.list))
        let grown = try empty.replacingSetlist(setlist.inserting(Fix.entry("e1", Fix.songA))
            .inserting(Fix.entry("e2", Fix.songA)))
        let after = try ShowStageProjection.make(library: grown, cursor: cursor, catalog: catalog)
        #expect(after.cursorState == .unpositioned)
        #expect(after.entryCount == 2)
        #expect(after.now == nil)
        #expect(after.previousPart == nil)
        #expect(after.previousSong == nil)
        let first = try #require(after.nextSong)
        #expect(first.position == Fix.pos("e1", "a1"))
        #expect(first.songNumber == 1)
        #expect(first.startsNewSong)
        #expect(after.nextPart == first)
        for destination in ShowStageDestination.allCases {
            let reach = Fix.reach(destination, from: cursor, in: grown, catalog: catalog)
            if let line = after.line(for: destination) {
                #expect(reach == .moved(line.position), "\(destination)")
            } else {
                #expect(reach == .refused(.atStart), "\(destination)")
            }
        }
    }

    @Test
    func aPartlessFirstEntryIsTheUnpositionedDestinationWithNoPart() throws {
        let catalog = try Fix.catalog()
        let empty = try Fix.library(songs: Fix.songs([Fix.songC: []]), entries: [])
        let cursor = try ShowCursor.make(setlist: Fix.list, bounceTicks: 0, sources: [Fix.foot], in: empty)
        let setlist = try #require(empty.setlist(Fix.list))
        let grown = try empty.replacingSetlist(setlist.inserting(Fix.entry("e1", Fix.songC)))
        let projection = try ShowStageProjection.make(library: grown, cursor: cursor, catalog: catalog)
        let line = try #require(projection.nextPart)
        #expect(line.position == Fix.pos("e1", nil))
        #expect(line.partNumber == nil)
        #expect(projection.nextSong == line)
        #expect(Fix.reach(.nextPart, from: cursor, in: grown, catalog: catalog) == .moved(Fix.pos("e1", nil)))
    }
}
