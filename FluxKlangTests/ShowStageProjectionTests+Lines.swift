import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowStageProjectionTests {
    static let keysPatch = PatchID(validated: "pat.keys")
    static let wetVariation = PatchVariationID(validated: "var.wet")
    static let unknownPatch = PatchID(validated: "pat.gone")
    static let unknownActionSet = ActionSetID(validated: "as.gone")

    private func chartRef(_ raw: StaticString, page: Int? = nil) throws -> ChartReference {
        try ChartReference.make(asset: AssetID(validated: raw), page: page)
    }

    private func nowLine(_ library: ShowLibrary, entry: String, part: String?) throws -> ShowStageLine {
        let cursor = try Fix.cursor(library, at: entry, part: part)
        let projection = try ShowStageProjection.make(library: library, cursor: cursor, catalog: Fix.catalog())
        return try #require(projection.now)
    }

    private func scalars(_ text: String) -> [UInt32] {
        var result: [UInt32] = []
        for scalar in text.unicodeScalars { result.append(scalar.value) }
        return result
    }

    @Test
    func aLineCarriesTheEntryNumberTheSetlistCountAndThePartNumberAndCountOfItsSong() throws {
        let library = try Fix.mainLibrary()
        let line = try nowLine(library, entry: "e3", part: "a2")
        #expect(line.songNumber == 3)
        #expect(line.songCount == 4)
        #expect(line.partNumber == 2)
        #expect(line.partCount == 3)
        #expect(line.songTitle == "Song song.a")
        #expect(line.partTitle == "Part a2")
        #expect(line.song == Fix.songA)
        let first = try nowLine(library, entry: "e1", part: "a1")
        #expect(first.partNumber == 1)
        #expect(first.songNumber == 1)
        let partless = try nowLine(library, entry: "e4", part: nil)
        #expect(partless.songNumber == 4)
        #expect(partless.partCount == 0)
    }

    @Test
    func aPartsRehearsalMarkAndLabelReachTheLineAndAPartWithoutOneHasNone() throws {
        let marked = try RehearsalMark.make(ticks: 1_920, label: "Verse")
        let plain = try RehearsalMark.make(ticks: 3_840)
        let parts = [try Fix.part("p1", mark: marked), try Fix.part("p2", mark: plain), try Fix.part("p3")]
        let song = try ShowSong.make(id: Fix.songA, title: "Marked", parts: parts)
        let library = try Fix.library(songs: [song], entries: [Fix.entry("e1", Fix.songA)])
        let labelled = try nowLine(library, entry: "e1", part: "p1")
        #expect(labelled.mark?.ticks == 1_920)
        #expect(labelled.mark?.label == "Verse")
        let unlabelled = try nowLine(library, entry: "e1", part: "p2")
        #expect(unlabelled.mark?.ticks == 3_840)
        #expect(unlabelled.mark?.label == nil)
        let none = try nowLine(library, entry: "e1", part: "p3")
        #expect(none.mark == nil)
    }

    @Test
    func theEffectiveChartIsThePartsOwnThenTheSongsAndNoneWhenThereIsNoChart() throws {
        let songChart = try chartRef("ast.chart", page: 2)
        let partChart = try chartRef("ast.chart", page: 7)
        let own = try SongPartLinks.make(chart: partChart)
        let parts = [try Fix.part("p1", links: own), try Fix.part("p2")]
        let withChart = try ShowSong.make(id: Fix.songA, title: "Charted", parts: parts, chart: songChart)
        let noChart = try Fix.song(Fix.songB, parts: ["q1"])
        let partlessWithChart = try ShowSong.make(id: Fix.songC, title: "Plain", chart: songChart)
        let library = try Fix.library(songs: [withChart, noChart, partlessWithChart],
                                      entries: [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB),
                                                Fix.entry("e3", Fix.songC)])
        #expect(try nowLine(library, entry: "e1", part: "p1").chart == .available(partChart))
        #expect(try nowLine(library, entry: "e1", part: "p2").chart == .available(songChart))
        #expect(try nowLine(library, entry: "e2", part: "q1").chart == .none)
        #expect(try nowLine(library, entry: "e3", part: nil).chart == .available(songChart))
    }

    @Test
    func aMissingChartKeepsItsReferenceAndReasonForEveryReasonAndTheLineIsStillProduced() throws {
        let gone = try chartRef("ast.gone")
        let stale = try chartRef("ast.stale", page: 3)
        let midi = try chartRef("ast.midi")
        let songs = [
            try ShowSong.make(id: Fix.songA, title: "Gone", parts: [Fix.part("p1")], chart: gone),
            try ShowSong.make(id: Fix.songB, title: "Stale", parts: [Fix.part("p1")], chart: stale),
            try ShowSong.make(id: Fix.songC, title: "Midi", parts: [Fix.part("p1")], chart: midi)
        ]
        let entries = [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB), Fix.entry("e3", Fix.songC)]
        let library = try Fix.library(songs: songs, entries: entries)
        let first = try nowLine(library, entry: "e1", part: "p1")
        #expect(first.chart == .missing(gone, .notInProject))
        #expect(first.problems == [.chart(gone, .notInProject)])
        let second = try nowLine(library, entry: "e2", part: "p1")
        #expect(second.chart == .missing(stale, .contentUnavailable))
        let third = try nowLine(library, entry: "e3", part: "p1")
        #expect(third.chart == .missing(midi, .notDocument(.midi)))
        let projection = try ShowStageProjection.make(
            library: library, cursor: Fix.cursor(library, at: "e1", part: "p1"), catalog: Fix.catalog())
        #expect(projection.nextSong?.chart == .missing(stale, .contentUnavailable))
        #expect(projection.nextSong?.problems == [.chart(stale, .contentUnavailable)])
    }

    @Test
    func linkProblemsAreCopiedWholeAndInOrderAndNeverDropFromTheLine() throws {
        let gone = try chartRef("ast.gone")
        let links = try SongPartLinks.make(patch: Self.unknownPatch, actionSet: Self.unknownActionSet, chart: gone)
        let variation = try SongPartLinks.make(patch: Self.keysPatch, variation: PatchVariationID(validated: "var.dry"))
        let clean = try SongPartLinks.make(patch: Self.keysPatch, variation: Self.wetVariation)
        let parts = [try Fix.part("p1", links: links), try Fix.part("p2", links: variation),
                     try Fix.part("p3", links: clean)]
        let song = try ShowSong.make(id: Fix.songA, title: "Linked", parts: parts)
        let library = try Fix.library(songs: [song], entries: [Fix.entry("e1", Fix.songA)])
        let expected: [ShowLinkProblem] = [.unknownPatch(Self.unknownPatch), .unknownActionSet(Self.unknownActionSet),
                                           .chart(gone, .notInProject)]
        #expect(try nowLine(library, entry: "e1", part: "p1").problems == expected)
        let second: [ShowLinkProblem] = [.unknownVariation(Self.keysPatch, PatchVariationID(validated: "var.dry"))]
        #expect(try nowLine(library, entry: "e1", part: "p2").problems == second)
        let none: [ShowLinkProblem] = []
        #expect(try nowLine(library, entry: "e1", part: "p3").problems == none)
        let projection = try ShowStageProjection.make(
            library: library, cursor: Fix.cursor(library, at: "e1", part: "p1"), catalog: Fix.catalog())
        #expect(projection.nextPart?.problems == second)
        #expect(projection.nextPart?.chart == ShowStageChart.none)
    }

    @Test
    func titlesAndLabelsReachTheLineScalarForScalarEvenWhenCanonicallyEquivalent() throws {
        let precomposed = "Caf\u{E9}"
        let decomposed = "Cafe\u{301}"
        let partTitle = "Intro\u{E9}\u{301}"
        let mark = try RehearsalMark.make(ticks: 0, label: "Mark\u{301}")
        let part = try SongPart.make(id: Fix.partID("p1"), title: partTitle, mark: mark)
        let one = try ShowSong.make(id: Fix.songA, title: precomposed, parts: [part])
        let two = try ShowSong.make(id: Fix.songB, title: decomposed, parts: [])
        let library = try Fix.library(songs: [one, two],
                                      entries: [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB)])
        let cursor = try Fix.cursor(library, at: "e1", part: "p1")
        let projection = try ShowStageProjection.make(library: library, cursor: cursor, catalog: Fix.catalog())
        let now = try #require(projection.now)
        let next = try #require(projection.nextSong)
        #expect(scalars(now.songTitle) == [0x43, 0x61, 0x66, 0xE9])
        #expect(scalars(next.songTitle) == [0x43, 0x61, 0x66, 0x65, 0x301])
        #expect(now.songTitle.utf8.count == 5)
        #expect(next.songTitle.utf8.count == 6)
        let expectedPart: [UInt32] = [0x49, 0x6E, 0x74, 0x72, 0x6F, 0xE9, 0x301]
        #expect(scalars(try #require(now.partTitle)) == expectedPart)
        #expect(scalars(try #require(now.mark?.label)) == [0x4D, 0x61, 0x72, 0x6B, 0x301])
    }

    @Test
    func theProjectionAtTheMaximumEntryAndPartCountNumbersAndTargetsFourSpotsWithoutTruncation() throws {
        let catalog = try Fix.catalog()
        let names = (0..<ShowLimits.maximumPartsPerSong).map { "p\($0)" }
        let big = try Fix.song(Fix.songA, parts: names)
        let small = try Fix.song(Fix.songB, parts: ["q0"])
        var entries: [SetlistEntry] = []
        for index in 0..<ShowLimits.maximumEntriesPerSetlist {
            entries.append(Fix.entry("e\(index)", index.isMultiple(of: 2) ? Fix.songA : Fix.songB))
        }
        let library = try Fix.library(songs: [big, small], entries: entries)
        #expect(library.setlist(Fix.list)?.entries.count == 256)
        let spots: [(String, String)] = [("e0", "p0"), ("e128", "p0"), ("e128", "p63"), ("e255", "q0")]
        for (entry, part) in spots {
            let cursor = try Fix.cursor(library, at: entry, part: part)
            let projection = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog)
            #expect(projection.entryCount == 256)
            #expect(projection.now?.songCount == 256)
            for destination in ShowStageDestination.allCases {
                let reach = Fix.reach(destination, from: cursor, in: library, catalog: catalog)
                if let line = projection.line(for: destination) {
                    #expect(reach == .moved(line.position), "\(entry) \(part) \(destination)")
                } else {
                    #expect(reach == .refused(Fix.boundary(destination)), "\(entry) \(part) \(destination)")
                }
            }
        }
        let middle = try Fix.cursor(library, at: "e128", part: "p63")
        let line = try ShowStageProjection.make(library: library, cursor: middle, catalog: catalog)
        #expect(line.now?.songNumber == 129)
        #expect(line.now?.partNumber == 64)
        #expect(line.now?.partCount == 64)
        #expect(line.nextPart?.position == Fix.pos("e129", "q0"))
        #expect(line.nextPart?.songNumber == 130)
        #expect(line.previousPart?.position == Fix.pos("e128", "p62"))
        let last = try ShowStageProjection.make(library: library, cursor: Fix.cursor(library, at: "e255", part: "q0"),
                                                catalog: catalog)
        #expect(last.now?.songNumber == 256)
        #expect(last.nextSong == nil)
        #expect(last.previousPart?.position == Fix.pos("e254", "p63"))
    }
}
