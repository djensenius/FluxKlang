import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Songs A (a1, a2, a3), B (b1, b2) and C (no parts); setlist `set.main` plays e1 A, e2 B, e3 A again, e4 C.
enum ShowNavigationTestFixture {
    static let songA = SongID(validated: "song.a")
    static let songB = SongID(validated: "song.b")
    static let songC = SongID(validated: "song.c")
    static let main = SetlistID(validated: "set.main")
    static let entries = ["e1", "e2", "e3", "e4"].map { SetlistEntryID(rawValue: $0)! }
    static let foot = ShowInputSourceID(validated: "src.foot")
    static let screen = ShowInputSourceID(validated: "src.screen")

    static func partID(_ raw: String) -> SongPartID { SongPartID(rawValue: raw)! }
    static func entryID(_ raw: String) -> SetlistEntryID { SetlistEntryID(rawValue: raw)! }

    static func part(_ raw: String, ticks: Int64? = nil, links: SongPartLinks = .none) throws -> SongPart {
        try SongPart.make(id: partID(raw), title: "Part \(raw)", mark: ticks.map { try RehearsalMark.make(ticks: $0) },
                          links: links)
    }

    static func song(_ id: SongID, parts: [String], chart: ChartReference? = nil) throws -> ShowSong {
        try ShowSong.make(id: id, title: "Song \(id)", parts: parts.map { try part($0) }, chart: chart)
    }

    static func entry(_ raw: String, _ song: SongID) -> SetlistEntry { SetlistEntry.make(id: entryID(raw), song: song) }

    static func cursor(_ library: ShowLibrary, bounce: UInt64 = 0) throws -> ShowCursor {
        try ShowCursor.make(setlist: main, bounceTicks: bounce, sources: [foot, screen], in: library)
    }

    static func library(songs: [ShowSong]? = nil) throws -> ShowLibrary {
        let songs = try songs ?? [song(songA, parts: ["a1", "a2", "a3"]), song(songB, parts: ["b1", "b2"]),
                                  song(songC, parts: [])]
        let setlist = try ShowSetlist.make(id: main, title: "Main", entries: [
            entry("e1", songA), entry("e2", songB), entry("e3", songA), entry("e4", songC)
        ])
        return try ShowLibrary.make(songs: songs, setlists: [setlist])
    }

    static func entryOrder(_ library: ShowLibrary) -> [String] {
        library.setlist(main)?.entries.map(\.id.rawValue) ?? []
    }
}

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct ShowNavigationTests {
    typealias Fix = ShowNavigationTestFixture

    @Test
    func songAndSetlistBoundsAcceptNAndRefuseNPlusOne() throws {
        let songs = try (0...ShowLimits.maximumSongs).map { try Fix.song(SongID(rawValue: "s\($0)")!, parts: []) }
        #expect(try ShowLibrary.make(songs: Array(songs.dropLast())).songs.count == ShowLimits.maximumSongs)
        #expect(throws: ShowRefusal.tooManySongs(513)) { try ShowLibrary.make(songs: songs) }
        let setlists = try (0...ShowLimits.maximumSetlists).map {
            try ShowSetlist.make(id: SetlistID(rawValue: "l\($0)")!, title: "List")
        }
        #expect(try ShowLibrary.make(setlists: Array(setlists.dropLast())).setlists.count == 64)
        #expect(throws: ShowRefusal.tooManySetlists(65)) { try ShowLibrary.make(setlists: setlists) }
    }

    @Test
    func entryAndPartBoundsAcceptNAndRefuseNPlusOne() throws {
        let entries = (0...ShowLimits.maximumEntriesPerSetlist).map { Fix.entry("x\($0)", Fix.songA) }
        #expect(try ShowSetlist.make(id: Fix.main, title: "Main", entries: Array(entries.dropLast())).entries.count
            == 256)
        #expect(throws: ShowRefusal.tooManyEntries(Fix.main, 257)) {
            try ShowSetlist.make(id: Fix.main, title: "Main", entries: entries)
        }
        let parts = (0...ShowLimits.maximumPartsPerSong).map { "p\($0)" }
        #expect(try Fix.song(Fix.songA, parts: Array(parts.dropLast())).parts.count == 64)
        #expect(throws: ShowRefusal.tooManyParts(Fix.songA, 65)) { try Fix.song(Fix.songA, parts: parts) }
        let full = try Fix.song(Fix.songA, parts: Array(parts.dropLast()))
        #expect(throws: ShowRefusal.tooManyParts(Fix.songA, 65)) {
            try full.insertingPart(Fix.part("extra"), in: .make())
        }
    }

    @Test
    func duplicateIdentitiesAreRefused() throws {
        #expect(throws: ShowRefusal.duplicatePart(Fix.songA, Fix.partID("a1"))) {
            try Fix.song(Fix.songA, parts: ["a1", "a2", "a1"])
        }
        let songA = try Fix.song(Fix.songA, parts: [])
        #expect(throws: ShowRefusal.duplicateSong(Fix.songA)) { try ShowLibrary.make(songs: [songA, songA]) }
        let first = try ShowSetlist.make(id: Fix.main, title: "One", entries: [Fix.entry("e1", Fix.songA)])
        let other = try ShowSetlist.make(id: SetlistID(validated: "set.b"), title: "Two",
                                         entries: [Fix.entry("e1", Fix.songA)])
        #expect(throws: ShowRefusal.duplicateEntry(Fix.entries[0])) {
            try ShowLibrary.make(songs: [songA], setlists: [first, other])
        }
        #expect(throws: ShowRefusal.duplicateSetlist(Fix.main)) {
            try ShowLibrary.make(songs: [songA], setlists: [first, first])
        }
        #expect(throws: ShowRefusal.unknownSong(Fix.songB)) {
            try ShowLibrary.make(songs: [songA], setlists: [first.inserting(Fix.entry("e9", Fix.songB))])
        }
    }

    @Test
    func movingKeepsEveryEntryAndOrdersByAnchor() throws {
        let setlist = try #require(try Fix.library().setlist(Fix.main))
        let ids = { (list: ShowSetlist) in list.entries.map(\.id.rawValue) }
        #expect(try ids(setlist.moving(Fix.entries[3], before: Fix.entries[1])) == ["e1", "e4", "e2", "e3"])
        #expect(try ids(setlist.moving(Fix.entries[0], before: nil)) == ["e2", "e3", "e4", "e1"])
        #expect(try ids(setlist.moving(Fix.entries[2], before: Fix.entries[2])) == ["e1", "e2", "e3", "e4"])
        #expect(try ids(setlist.moving(Fix.entries[0], before: Fix.entries[2])) == ["e2", "e1", "e3", "e4"])
        #expect(try setlist.moving(Fix.entries[3], before: Fix.entries[0]).entries.last?.song == Fix.songA)
        #expect(throws: ShowRefusal.unknownEntry(Fix.entryID("e9"))) {
            try setlist.moving(Fix.entries[0], before: Fix.entryID("e9"))
        }
        #expect(throws: ShowRefusal.unknownEntry(Fix.entryID("e9"))) {
            try setlist.moving(Fix.entryID("e9"), before: nil)
        }
        #expect(try ids(setlist.inserting(Fix.entry("e5", Fix.songB), before: Fix.entries[0])).first == "e5")
        #expect(try ids(setlist.removing(Fix.entries[1])) == ["e1", "e3", "e4"])
        #expect(throws: ShowRefusal.unknownEntry(Fix.entryID("e9"))) { try setlist.removing(Fix.entryID("e9")) }
        #expect(ids(setlist) == ["e1", "e2", "e3", "e4"])
    }

    @Test
    func movingPartsAndSetlistsKeepsIdentity() throws {
        let song = try Fix.song(Fix.songA, parts: ["a1", "a2", "a3"])
        #expect(try song.movingPart(Fix.partID("a3"), before: Fix.partID("a1")).parts.map(\.id.rawValue)
            == ["a3", "a1", "a2"])
        #expect(try song.removingPart(Fix.partID("a2")).parts.map(\.id.rawValue) == ["a1", "a3"])
        #expect(throws: ShowRefusal.unknownPart(Fix.partID("zz"))) { try song.removingPart(Fix.partID("zz")) }
        let library = try Fix.library()
        let second = try ShowSetlist.make(id: SetlistID(validated: "set.b"), title: "B")
        let both = try library.insertingSetlist(second, before: Fix.main)
        #expect(both.setlists.map(\.id.rawValue) == ["set.b", "set.main"])
        #expect(try both.movingSetlist(second.id, before: nil).setlists.map(\.id.rawValue) == ["set.main", "set.b"])
        #expect(try both.removingSetlist(Fix.main).setlists.map(\.id) == [second.id])
    }

    @Test
    func removingAReferencedSongIsRefusedWithItsFirstEntry() throws {
        let library = try Fix.library()
        let catalog = try ShowLinkCatalog.make()
        #expect(throws: ShowRefusal.songInUse(Fix.songA, Fix.entries[0])) { try library.removingSong(Fix.songA) }
        let unused = try library.upsertingSong(Fix.song(SongID(validated: "song.d"), parts: []), in: catalog)
        #expect(try unused.removingSong(SongID(validated: "song.d")).songs.count == 3)
        #expect(throws: ShowRefusal.unknownSong(SongID(validated: "song.z"))) {
            try library.removingSong(SongID(validated: "song.z"))
        }
        let renamed = try ShowSong.make(id: Fix.songB, title: "Renamed")
        #expect(try library.upsertingSong(renamed, in: catalog).songs.map(\.id) == [Fix.songA, Fix.songB, Fix.songC])
        #expect(library.songs.count == 3)
    }

    @Test
    func rehearsalMarksAreBoundedAndNonDecreasing() throws {
        #expect(try RehearsalMark.make(ticks: 0).ticks == 0)
        #expect(try RehearsalMark.make(ticks: ShowLimits.maximumMarkTicks, label: "Bar 10000").ticks == 614_400_000)
        #expect(throws: ShowRefusal.markOutOfRange(614_400_001)) { try RehearsalMark.make(ticks: 614_400_001) }
        #expect(throws: ShowRefusal.markOutOfRange(-1)) { try RehearsalMark.make(ticks: -1) }
        #expect(throws: ShowRefusal.invalidTitle) { try RehearsalMark.make(ticks: 0, label: " A") }
        let tied = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1", ticks: 0), Fix.part("a2"), Fix.part("a3", ticks: 0), Fix.part("a4", ticks: 61_440)
        ])
        #expect(tied.parts.count == 4)
        #expect(throws: ShowRefusal.marksOutOfOrder(Fix.partID("a1"))) {
            try tied.movingPart(Fix.partID("a1"), before: nil)
        }
    }

    @Test
    func titlesFollowThePatchLabelRuleAndChartPagesAreBounded() throws {
        #expect(try ShowSong.make(id: Fix.songA, title: String(repeating: "x", count: 256)).title.utf8.count == 256)
        for title in ["", " Lead", "Trail ", String(repeating: "x", count: 257), "Tab\tHere"] {
            #expect(throws: ShowRefusal.invalidTitle) { try ShowSong.make(id: Fix.songA, title: title) }
        }
        #expect(throws: ShowRefusal.invalidTitle) { try ShowSetlist.make(id: Fix.main, title: "") }
        #expect(throws: ShowRefusal.invalidTitle) { try SongPart.make(id: Fix.partID("a1"), title: "") }
        let asset = AssetID(validated: "ast.chart")
        #expect(try ChartReference.make(asset: asset, page: 1).page == 1)
        #expect(try ChartReference.make(asset: asset, page: 9_999).page == 9_999)
        #expect(throws: ShowRefusal.invalidChartPage(0)) { try ChartReference.make(asset: asset, page: 0) }
        #expect(throws: ShowRefusal.invalidChartPage(10_000)) { try ChartReference.make(asset: asset, page: 10_000) }
        let variation = PatchVariationID(validated: "var.wet")
        #expect(throws: ShowRefusal.variationWithoutPatch(variation)) { try SongPartLinks.make(variation: variation) }
    }
}
