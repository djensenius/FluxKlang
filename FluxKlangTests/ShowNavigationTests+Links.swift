import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ShowNavigationLinkTests {
    typealias Fix = ShowNavigationTestFixture
    static let patch = PatchID(validated: "pat.keys")
    static let variation = PatchVariationID(validated: "var.wet")
    static let actionSet = ActionSetID(validated: "as.intro")
    static let chartAsset = AssetID(validated: "ast.chart")
    static let staleAsset = AssetID(validated: "ast.stale")
    static let midiAsset = AssetID(validated: "ast.midi")
    static let goneAsset = AssetID(validated: "ast.gone")

    static func asset(_ id: AssetID, _ media: AssetMedia) -> ProjectAsset {
        ProjectAsset(id: id, label: "Asset", media: media, contentDigest: "sha256:" + String(repeating: "a", count: 64))
    }

    static func catalog() throws -> ShowLinkCatalog {
        let sets = try PerformanceActionSetLibrary(sets: [
            PerformanceActionSet(id: actionSet, members: [ActionID(validated: "act.click")])
        ])
        return try ShowLinkCatalog.make(
            patches: [(patch, [variation])], actionSets: sets,
            assets: [asset(chartAsset, .document), asset(staleAsset, .document), asset(midiAsset, .midi)],
            availableContent: [chartAsset, midiAsset]
        )
    }

    static func chart(_ asset: AssetID, page: Int? = nil) throws -> ChartReference {
        try ChartReference.make(asset: asset, page: page)
    }

    @Test
    func chartAvailabilityNamesEachMissingReason() throws {
        let catalog = try Self.catalog()
        #expect(try catalog.availability(of: Self.chart(Self.chartAsset)) == .available(Self.chart(Self.chartAsset)))
        #expect(try catalog.availability(of: Self.chart(Self.goneAsset)) == .missing(Self.chart(Self.goneAsset),
                                                                                    .notInProject))
        #expect(try catalog.availability(of: Self.chart(Self.midiAsset)) == .missing(Self.chart(Self.midiAsset),
                                                                                    .notDocument(.midi)))
        #expect(try catalog.availability(of: Self.chart(Self.staleAsset, page: 3))
            == .missing(Self.chart(Self.staleAsset, page: 3), .contentUnavailable))
    }

    @Test
    func editsRefuseLinksThatDoNotResolve() throws {
        let catalog = try Self.catalog()
        let song = try Fix.song(Fix.songA, parts: ["a1"])
        let part = Fix.partID("a1")
        let good = try SongPartLinks.make(patch: Self.patch, variation: Self.variation, actionSet: Self.actionSet,
                                          chart: Self.chart(Self.chartAsset))
        #expect(try song.replacingLinks(good, for: part, in: catalog).parts[0].links == good)
        let otherPatch = PatchID(validated: "pat.none")
        let otherVariation = PatchVariationID(validated: "var.none")
        let otherSet = ActionSetID(validated: "as.none")
        let cases: [(SongPartLinks, ShowRefusal)] = try [
            (.make(patch: otherPatch), .unknownPatch(otherPatch)),
            (.make(patch: Self.patch, variation: otherVariation), .unknownVariation(Self.patch, otherVariation)),
            (.make(actionSet: otherSet), .unknownActionSet(otherSet)),
            (.make(chart: Self.chart(Self.staleAsset)), .chartUnavailable(Self.chart(Self.staleAsset),
                                                                           .contentUnavailable))
        ]
        for (links, refusal) in cases {
            #expect(throws: refusal) { try song.replacingLinks(links, for: part, in: catalog) }
        }
        #expect(throws: ShowRefusal.unknownPart(Fix.partID("zz"))) {
            try song.replacingLinks(good, for: Fix.partID("zz"), in: catalog)
        }
    }

    @Test
    func loadReportsEveryBrokenLinkInDocumentOrderAndKeepsIt() throws {
        let catalog = try Self.catalog()
        let gone = try Self.chart(Self.goneAsset)
        let midi = try Self.chart(Self.midiAsset)
        let unknownSet = ActionSetID(validated: "as.none")
        let brokenA = try SongPartLinks.make(patch: PatchID(validated: "pat.none"), variation: Self.variation,
                                             actionSet: unknownSet, chart: midi)
        let songA = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1"), Fix.part("a2", links: brokenA)
        ], chart: gone)
        let brokenB = try SongPartLinks.make(patch: Self.patch, variation: PatchVariationID(validated: "var.none"))
        let songB = try ShowSong.make(id: Fix.songB, title: "B", parts: [Fix.part("b1", links: brokenB)])
        let library = try Fix.library(songs: [songA, songB, Fix.song(Fix.songC, parts: [])])
        let report = library.linkReport(in: catalog)
        #expect(report == [
            ShowLinkIssue(song: Fix.songA, part: nil, problem: .chart(gone, .notInProject)),
            ShowLinkIssue(song: Fix.songA, part: Fix.partID("a2"),
                          problem: .unknownPatch(PatchID(validated: "pat.none"))),
            ShowLinkIssue(song: Fix.songA, part: Fix.partID("a2"), problem: .unknownActionSet(unknownSet)),
            ShowLinkIssue(song: Fix.songA, part: Fix.partID("a2"), problem: .chart(midi, .notDocument(.midi))),
            ShowLinkIssue(song: Fix.songB, part: Fix.partID("b1"),
                          problem: .unknownVariation(Self.patch, PatchVariationID(validated: "var.none")))
        ])
        #expect(library.song(Fix.songA)?.parts[1].links == brokenA)
        #expect(library.song(Fix.songA)?.chart == gone)
    }

    @Test
    func aMissingChartIsRecoverableByRelinking() throws {
        let catalog = try Self.catalog()
        let stale = try Self.chart(Self.staleAsset)
        let song = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1", links: .make(chart: stale))
        ], chart: stale)
        #expect(throws: ShowRefusal.chartUnavailable(stale, .contentUnavailable)) {
            try song.relinkingChart(stale, in: catalog)
        }
        let fixed = try Self.chart(Self.chartAsset, page: 2)
        let relinked = try song.relinkingChart(fixed, in: catalog).relinkingChart(fixed, part: Fix.partID("a1"),
                                                                                  in: catalog)
        #expect(relinked.chart == fixed)
        #expect(relinked.parts[0].links.chart == fixed)
        #expect(try song.relinkingChart(nil, part: Fix.partID("a1"), in: catalog).parts[0].links.chart == nil)
        #expect(throws: ShowRefusal.unknownPart(Fix.partID("zz"))) {
            try song.relinkingChart(fixed, part: Fix.partID("zz"), in: catalog)
        }
        #expect(song.chart == stale)
    }

    @Test
    func navigationResolvesLinksWithThePartChartOverridingTheSong() throws {
        let catalog = try Self.catalog()
        let songChart = try Self.chart(Self.chartAsset, page: 1)
        let partChart = try Self.chart(Self.staleAsset)
        let links = try SongPartLinks.make(patch: Self.patch, actionSet: Self.actionSet, chart: partChart)
        let songA = try ShowSong.make(id: Fix.songA, title: "A", parts: [Fix.part("a1"), Fix.part("a2", links: links)],
                                      chart: songChart)
        let library = try Fix.library(songs: [songA, Fix.song(Fix.songB, parts: ["b1"]),
                                              Fix.song(Fix.songC, parts: [])])
        var cursor = try Fix.cursor(library)
        let first = try #require(try cursor.currentStop(in: library, catalog: catalog))
        #expect(first.links.chart == .available(songChart))
        #expect(first.links.problems.isEmpty)
        let input = ShowNavigationInput(.nextPart, source: Fix.foot, sequence: 1, tick: 1)
        let result = try cursor.navigate(input, in: library, catalog: catalog)
        guard case let .moved(stop) = result else { Issue.record("not moved"); return }
        #expect(stop.song == Fix.songA)
        #expect(stop.links.links.patch == Self.patch)
        #expect(stop.links.links.actionSet == Self.actionSet)
        #expect(stop.links.chart == .missing(partChart, .contentUnavailable))
        #expect(stop.links.problems == [.chart(partChart, .contentUnavailable)])
        #expect(throws: ShowRefusal.unknownPart(Fix.partID("b1"))) {
            try ShowLibrary.resolvedLinks(song: songA, part: Fix.partID("b1"), in: catalog)
        }
        #expect(try ShowLibrary.resolvedLinks(song: songA, part: nil, in: catalog).chart == .available(songChart))
    }

    @Test
    func catalogsRefuseAmbiguityAndExcess() throws {
        #expect(throws: ShowRefusal.duplicatePatch(Self.patch)) {
            try ShowLinkCatalog.make(patches: [(Self.patch, []), (Self.patch, [])])
        }
        #expect(throws: ShowRefusal.duplicateVariation(Self.patch, Self.variation)) {
            try ShowLinkCatalog.make(patches: [(Self.patch, [Self.variation, Self.variation])])
        }
        #expect(throws: ShowRefusal.duplicateAsset(Self.chartAsset)) {
            try ShowLinkCatalog.make(assets: [Self.asset(Self.chartAsset, .document),
                                              Self.asset(Self.chartAsset, .midi)])
        }
    }

    @Test
    func eachCatalogBoundAcceptsNAndRefusesNPlusOneByName() throws {
        let patches = (0...ShowLimits.maximumCatalogPatches).map {
            (PatchID(rawValue: "p\($0)")!, [PatchVariationID]())
        }
        _ = try ShowLinkCatalog.make(patches: Array(patches.dropLast()))
        #expect(throws: ShowRefusal.catalogTooLarge(.patches, 4_097)) { try ShowLinkCatalog.make(patches: patches) }
        let ids = (0...ShowLimits.maximumCatalogAssets).map { AssetID(rawValue: "a\($0)")! }
        _ = try ShowLinkCatalog.make(availableContent: Array(ids.dropLast()))
        #expect(throws: ShowRefusal.catalogTooLarge(.availableContent, 4_097)) {
            try ShowLinkCatalog.make(availableContent: ids)
        }
        let assets = ids.map { Self.asset($0, .document) }
        _ = try ShowLinkCatalog.make(assets: Array(assets.dropLast()))
        #expect(throws: ShowRefusal.catalogTooLarge(.assets, 4_097)) { try ShowLinkCatalog.make(assets: assets) }
        let variations = (0...PatchVariationLimits.maximumVariations).map { PatchVariationID(rawValue: "v\($0)")! }
        _ = try ShowLinkCatalog.make(patches: [(Self.patch, Array(variations.dropLast()))])
        #expect(throws: ShowRefusal.catalogTooLarge(.variationsPerPatch(Self.patch), 129)) {
            try ShowLinkCatalog.make(patches: [(Self.patch, variations)])
        }
    }

    @Test
    func insertingAPartRefusesItsBrokenLinks() throws {
        let catalog = try Self.catalog()
        let song = try Fix.song(Fix.songA, parts: ["a1"])
        let unknown = PatchID(validated: "pat.none")
        let broken = try Fix.part("a2", links: .make(patch: unknown))
        #expect(throws: ShowRefusal.unknownPatch(unknown)) { try song.insertingPart(broken, in: catalog) }
        #expect(song.parts.map(\.id) == [Fix.partID("a1")])
        let good = try Fix.part("a2", links: .make(patch: Self.patch, chart: Self.chart(Self.chartAsset)))
        #expect(try song.insertingPart(good, before: Fix.partID("a1"), in: catalog).parts.map(\.id.rawValue)
            == ["a2", "a1"])
    }

    @Test
    func editPathUpsertRefusesOnlyNewProblemsAndKeepsLoadedOnes() throws {
        let catalog = try Self.catalog()
        let unknownSet = ActionSetID(validated: "as.none")
        let stale = try Self.chart(Self.staleAsset)
        let loadedA = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1"), Fix.part("a2", links: .make(actionSet: unknownSet))
        ])
        let library = try Fix.library(songs: [loadedA, Fix.song(Fix.songB, parts: ["b1"]),
                                              Fix.song(Fix.songC, parts: [])])
        let newSong = try Fix.song(SongID(validated: "song.d"), parts: [], chart: stale)
        #expect(throws: ShowRefusal.chartUnavailable(stale, .contentUnavailable)) {
            try library.upsertingSong(newSong, in: catalog)
        }
        #expect(library.songs.count == 3)
        let moved = try library.upsertingSong(loadedA.movingPart(Fix.partID("a2"), before: Fix.partID("a1")),
                                              in: catalog)
        #expect(moved.song(Fix.songA)?.parts.first?.links.actionSet == unknownSet)
        #expect(moved.linkReport(in: catalog) == [
            ShowLinkIssue(song: Fix.songA, part: Fix.partID("a2"), problem: .unknownActionSet(unknownSet))
        ])
        let worse = try loadedA.relinkingChart(nil, in: catalog).insertingPart(Fix.part("a3"), in: catalog)
        let brokenChart = try ShowSong.make(id: Fix.songA, title: "A", parts: worse.parts, chart: stale)
        #expect(throws: ShowRefusal.chartUnavailable(stale, .contentUnavailable)) {
            try library.upsertingSong(brokenChart, in: catalog)
        }
        let renamed = try ShowSong.make(id: Fix.songA, title: "Renamed", parts: worse.parts)
        #expect(try library.upsertingSong(renamed, in: catalog).song(Fix.songA)?.title == "Renamed")
    }

    @Test
    func addedOrChangedVariationsUnderAMissingPatchAreRefusedInBothEditPaths() throws {
        let catalog = try Self.catalog()
        let missing = PatchID(validated: "pat.none")
        let old = PatchVariationID(validated: "var.old")
        let bare = try SongPartLinks.make(patch: missing)
        let pinned = try SongPartLinks.make(patch: missing, variation: old)
        let stale = try Self.chart(Self.staleAsset)
        let song = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1", links: bare), Fix.part("a2", links: pinned)
        ], chart: stale)
        let library = try Fix.library(songs: [song, Fix.song(Fix.songB, parts: []), Fix.song(Fix.songC, parts: [])])
        let added = try SongPartLinks.make(patch: missing, variation: Self.variation)
        let relinked = try SongPartLinks.make(patch: missing, variation: old, chart: Self.chart(Self.chartAsset))
        let refusal = ShowRefusal.unknownVariation(missing, Self.variation)
        // (part, links): adding a variation under a missing patch, changing one, and an unrelated chart relink.
        for (part, links) in [(Fix.partID("a1"), added), (Fix.partID("a2"), added), (Fix.partID("a2"), relinked)] {
            let index = try #require(song.parts.firstIndex { $0.id == part })
            var parts = song.parts
            parts[index] = try SongPart.make(id: part, title: "Edited", links: links)
            let edited = try ShowSong.make(id: Fix.songA, title: "A", parts: parts, chart: stale)
            if links == added {
                #expect(throws: refusal) { try song.replacingLinks(links, for: part, in: catalog) }
                #expect(throws: refusal) { try library.upsertingSong(edited, in: catalog) }
            } else {
                #expect(try song.replacingLinks(links, for: part, in: catalog).part(part)?.links == links)
                #expect(try library.upsertingSong(edited, in: catalog).song(Fix.songA)?.part(part)?.links == links)
            }
        }
        #expect(throws: ShowRefusal.unknownPatch(missing)) {
            try song.insertingPart(Fix.part("a3", links: added), in: catalog)
        }
        #expect(library.linkReport(in: catalog).map(\.problem)
            == [.chart(stale, .contentUnavailable), .unknownPatch(missing), .unknownPatch(missing)])
    }

    @Test
    func upsertChecksEveryReferenceOfANewPartOrSong() throws {
        let catalog = try Self.catalog()
        let library = try Fix.library()
        let unknownSet = ActionSetID(validated: "as.none")
        let songA = try #require(library.song(Fix.songA))
        let withNewPart = try ShowSong.make(id: Fix.songA, title: songA.title,
                                            parts: songA.parts + [Fix.part("a9", links: .make(actionSet: unknownSet))])
        #expect(throws: ShowRefusal.unknownActionSet(unknownSet)) {
            try library.upsertingSong(withNewPart, in: catalog)
        }
        let stale = try Self.chart(Self.staleAsset)
        let newSong = try ShowSong.make(id: SongID(validated: "song.d"), title: "D",
                                        parts: [Fix.part("d1", links: .make(chart: stale))])
        #expect(throws: ShowRefusal.chartUnavailable(stale, .contentUnavailable)) {
            try library.upsertingSong(newSong, in: catalog)
        }
        #expect(library == (try Fix.library()))
    }

    @Test
    func replacingLinksChecksOnlyWhatChanged() throws {
        let catalog = try Self.catalog()
        let unknown = PatchID(validated: "pat.none")
        let stale = try Self.chart(Self.staleAsset)
        let song = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1", links: .make(patch: unknown, chart: stale))
        ])
        let part = Fix.partID("a1")
        let fixedChart = try SongPartLinks.make(patch: unknown, chart: Self.chart(Self.chartAsset))
        #expect(try song.replacingLinks(fixedChart, for: part, in: catalog).parts[0].links == fixedChart)
        let unknownSet = ActionSetID(validated: "as.none")
        #expect(throws: ShowRefusal.unknownActionSet(unknownSet)) {
            try song.replacingLinks(.make(patch: unknown, actionSet: unknownSet, chart: stale), for: part,
                                    in: catalog)
        }
        let keptSet = try ShowSong.make(id: Fix.songA, title: "A", parts: [
            Fix.part("a1", links: .make(actionSet: unknownSet, chart: stale))
        ])
        let fixedPatch = try SongPartLinks.make(patch: Self.patch, actionSet: unknownSet, chart: stale)
        #expect(try keptSet.replacingLinks(fixedPatch, for: part, in: catalog).parts[0].links == fixedPatch)
        let otherPatch = PatchID(validated: "pat.other")
        #expect(throws: ShowRefusal.unknownPatch(otherPatch)) {
            try song.replacingLinks(.make(patch: otherPatch), for: part, in: catalog)
        }
    }
}
