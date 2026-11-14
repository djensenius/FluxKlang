import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A comparable view of one worklist group: the asset, its reason and every item's target and chart.
struct ShowRecoveryDigest: Hashable {
    struct Entry: Hashable {
        let target: ShowRecoveryTarget
        let chart: ChartReference
    }

    let asset: AssetID
    let reason: ChartMissingReason
    var entries: [Entry]

    static func digests(of worklist: ShowRecoveryWorklist) -> [ShowRecoveryDigest] {
        worklist.groups.map { group -> ShowRecoveryDigest in
            let entries = group.items.map { Entry(target: $0.target, chart: $0.chart) }
            return ShowRecoveryDigest(asset: group.asset, reason: group.reason, entries: entries)
        }
    }
}

/// Songs A (song chart stale; parts gone, stale, patch-only, ok), B (song chart gone; parts gone, midi), C (ok chart,
/// no parts) and D (no chart; one stale part on page 9,999). Setlist `set.main` plays A, B, A, C, D; `set.alt` B, D.
enum ShowRecoveryTestFixture {
    static let songA = SongID(validated: "song.a")
    static let songB = SongID(validated: "song.b")
    static let songC = SongID(validated: "song.c")
    static let songD = SongID(validated: "song.d")
    static let unknownSong = SongID(validated: "song.zz")
    static let partA1 = SongPartID(validated: "part.a1")
    static let partA2 = SongPartID(validated: "part.a2")
    static let partA3 = SongPartID(validated: "part.a3")
    static let partA4 = SongPartID(validated: "part.a4")
    static let partB1 = SongPartID(validated: "part.b1")
    static let partB2 = SongPartID(validated: "part.b2")
    static let partD1 = SongPartID(validated: "part.d1")
    static let unknownPart = SongPartID(validated: "part.zz")
    static let mainList = SetlistID(validated: "set.main")
    static let altList = SetlistID(validated: "set.alt")
    static let okAsset = AssetID(validated: "ast.ok")
    static let okAsset2 = AssetID(validated: "ast.ok2")
    static let staleAsset = AssetID(validated: "ast.stale")
    static let staleAsset2 = AssetID(validated: "ast.stale2")
    static let midiAsset = AssetID(validated: "ast.midi")
    static let audioAsset = AssetID(validated: "ast.audio")
    static let goneAsset = AssetID(validated: "ast.gone")
    static let goneAsset2 = AssetID(validated: "ast.gone2")
    static let keysPatch = PatchID(validated: "pat.keys")
    static let wetVariation = PatchVariationID(validated: "var.wet")
    static let unknownPatch = PatchID(validated: "pat.none")
    static let unknownVariation = PatchVariationID(validated: "var.none")
    static let unknownSet = ActionSetID(validated: "as.none")

    static func asset(_ id: AssetID, _ media: AssetMedia) -> ProjectAsset {
        ProjectAsset(id: id, label: "Asset", media: media, contentDigest: "sha256:" + String(repeating: "a", count: 64))
    }

    /// ok and ok2 are documents with content; stale and stale2 are documents without; midi and audio are not
    /// documents; gone and gone2 are not in the project.
    static func catalog() throws -> ShowLinkCatalog {
        try ShowLinkCatalog.make(
            patches: [(keysPatch, [wetVariation])],
            assets: [asset(okAsset, .document), asset(okAsset2, .document), asset(staleAsset, .document),
                     asset(staleAsset2, .document), asset(midiAsset, .midi), asset(audioAsset, .audio)],
            availableContent: [okAsset, okAsset2, midiAsset, audioAsset]
        )
    }

    static func chart(_ asset: AssetID, page: Int? = nil) throws -> ChartReference {
        try ChartReference.make(asset: asset, page: page)
    }

    static func makeLinks(chart: ChartReference? = nil, patch: PatchID? = nil, variation: PatchVariationID? = nil,
                          actionSet: ActionSetID? = nil) throws -> SongPartLinks {
        try SongPartLinks.make(patch: patch, variation: variation, actionSet: actionSet, chart: chart)
    }

    static func part(_ id: SongPartID, ticks: Int64? = nil, links: SongPartLinks = .none) throws -> SongPart {
        try SongPart.make(id: id, title: "Part \(id)", mark: ticks.map { try RehearsalMark.make(ticks: $0) },
                          links: links)
    }

    static func buildSongA() throws -> ShowSong {
        try ShowSong.make(id: songA, title: "Song A", parts: [
            part(partA1, ticks: 0, links: makeLinks(chart: chart(goneAsset, page: 3))),
            part(partA2, ticks: 1_000, links: makeLinks(chart: chart(staleAsset, page: 2))),
            part(partA3, links: makeLinks(patch: unknownPatch)),
            part(partA4, ticks: 5_000, links: makeLinks(chart: chart(okAsset, page: 5), actionSet: unknownSet))
        ], chart: chart(staleAsset, page: 1))
    }

    static func buildSongB() throws -> ShowSong {
        let broken = try makeLinks(chart: chart(midiAsset, page: 1), patch: keysPatch, variation: unknownVariation)
        return try ShowSong.make(id: songB, title: "Song B", parts: [
            part(partB1, ticks: 0, links: makeLinks(chart: chart(goneAsset))),
            part(partB2, ticks: 960, links: broken)
        ], chart: chart(goneAsset))
    }

    static func buildSongC() throws -> ShowSong {
        try ShowSong.make(id: songC, title: "Song C", chart: chart(okAsset, page: 4))
    }

    static func buildSongD() throws -> ShowSong {
        let links = try makeLinks(chart: chart(staleAsset, page: 9_999), patch: keysPatch, variation: wetVariation)
        return try ShowSong.make(id: songD, title: "Song D", parts: [part(partD1, links: links)])
    }

    static func entry(_ number: Int, _ song: SongID) throws -> SetlistEntry {
        try SetlistEntry.make(id: SetlistEntryID("ent.\(number)"), song: song)
    }

    static func library() throws -> ShowLibrary {
        let main = try ShowSetlist.make(id: mainList, title: "Main", entries: [
            entry(1, songA), entry(2, songB), entry(3, songA), entry(4, songC), entry(5, songD)
        ])
        let alt = try ShowSetlist.make(id: altList, title: "Alt", entries: [entry(6, songB), entry(7, songD)])
        return try ShowLibrary.make(songs: [buildSongA(), buildSongB(), buildSongC(), buildSongD()],
                                    setlists: [main, alt])
    }

    static func target(_ song: SongID, _ part: SongPartID? = nil) -> ShowRecoveryTarget {
        ShowRecoveryTarget(song: song, part: part)
    }

    /// The refusal of a batch, or `nil` when it is accepted.
    static func refusal(of decisions: [ShowRecoveryDecision], in library: ShowLibrary,
                        catalog: ShowLinkCatalog) -> ShowRecoveryRefusal? {
        do throws(ShowRecoveryRefusal) {
            _ = try ShowChartRecovery.apply(decisions, to: library, in: catalog)
            return nil
        } catch {
            return error
        }
    }

    /// Every stored chart reference by address. An address without a chart is absent.
    static func chartMap(_ library: ShowLibrary) -> [ShowRecoveryTarget: ChartReference] {
        var map: [ShowRecoveryTarget: ChartReference] = [:]
        for song in library.songs {
            map[target(song.id)] = song.chart
            for part in song.parts { map[target(song.id, part.id)] = part.links.chart }
        }
        return map
    }

    static func digestEntry(_ song: SongID, _ part: SongPartID?, _ asset: AssetID,
                            _ page: Int?) throws -> ShowRecoveryDigest.Entry {
        try ShowRecoveryDigest.Entry(target: target(song, part), chart: chart(asset, page: page))
    }

    /// The fixture's worklist: stale, gone and midi in order of first occurrence, each target in document order.
    static func expectedDigests() throws -> [ShowRecoveryDigest] {
        try [
            ShowRecoveryDigest(asset: staleAsset, reason: .contentUnavailable, entries: [
                digestEntry(songA, nil, staleAsset, 1), digestEntry(songA, partA2, staleAsset, 2),
                digestEntry(songD, partD1, staleAsset, 9_999)
            ]),
            ShowRecoveryDigest(asset: goneAsset, reason: .notInProject, entries: [
                digestEntry(songA, partA1, goneAsset, 3), digestEntry(songB, nil, goneAsset, nil),
                digestEntry(songB, partB1, goneAsset, nil)
            ]),
            ShowRecoveryDigest(asset: midiAsset, reason: .notDocument(.midi), entries: [
                digestEntry(songB, partB2, midiAsset, 1)
            ])
        ]
    }

    /// Relinks the stale asset (3 targets), clears the gone asset (3 targets) and relinks the midi chart (1 target).
    static func recoverEverything() throws -> [ShowRecoveryDecision] {
        try [
            .relinkAsset(from: staleAsset, to: okAsset),
            .clearAsset(goneAsset),
            .relinkTarget(target(songB, partB2), to: chart(okAsset2, page: 7))
        ]
    }
}

/// Worklist tests; the decision, batch, navigation and randomized tests are in the `ShowRecoveryTests+` files.
@Suite("Show chart recovery", .productionAccessAudit)
struct ShowRecoveryTests {
    typealias Fix = ShowRecoveryTestFixture

    let library: ShowLibrary
    let catalog: ShowLinkCatalog

    init() throws {
        library = try Fix.library()
        catalog = try Fix.catalog()
    }

    var worklist: ShowRecoveryWorklist { ShowRecoveryWorklist.make(library: library, catalog: catalog) }

    func refusal(_ decisions: [ShowRecoveryDecision]) -> ShowRecoveryRefusal? {
        Fix.refusal(of: decisions, in: library, catalog: catalog)
    }

    func recover(_ decisions: [ShowRecoveryDecision]) throws -> ShowRecoveryOutcome {
        try ShowChartRecovery.apply(decisions, to: library, in: catalog)
    }

    @Test
    func worklistGroupsMissingChartsByAssetInFirstOccurrenceOrder() throws {
        let expected = try Fix.expectedDigests()
        #expect(ShowRecoveryDigest.digests(of: worklist) == expected)
        #expect(worklist.groups.map(\.asset) == [Fix.staleAsset, Fix.goneAsset, Fix.midiAsset])
        // Song B first: the groups and the targets inside them follow that document order.
        let songs = library.songs
        let swapped = try ShowLibrary.make(songs: [songs[1], songs[0], songs[2], songs[3]], setlists: library.setlists)
        let moved = ShowRecoveryWorklist.make(library: swapped, catalog: catalog)
        #expect(moved.groups.map(\.asset) == [Fix.goneAsset, Fix.midiAsset, Fix.staleAsset])
        #expect(moved.group(for: Fix.goneAsset)?.items.map(\.target)
            == [Fix.target(Fix.songB), Fix.target(Fix.songB, Fix.partB1), Fix.target(Fix.songA, Fix.partA1)])
    }

    @Test
    func worklistNamesEachMissingReasonOncePerAsset() throws {
        #expect(worklist.group(for: Fix.staleAsset)?.reason == .contentUnavailable)
        #expect(worklist.group(for: Fix.goneAsset)?.reason == .notInProject)
        #expect(worklist.group(for: Fix.midiAsset)?.reason == .notDocument(.midi))
        #expect(worklist.group(for: Fix.okAsset) == nil)
        #expect(worklist.group(for: Fix.goneAsset2) == nil)
        let audio = try ShowSong.make(id: Fix.songC, title: "Song C", chart: Fix.chart(Fix.audioAsset, page: 2))
        let audioLibrary = try ShowLibrary.make(songs: [audio])
        let audioList = ShowRecoveryWorklist.make(library: audioLibrary, catalog: catalog)
        #expect(audioList.group(for: Fix.audioAsset)?.reason == .notDocument(.audio))
        #expect(audioList.groups.count == 1)
    }

    @Test
    func worklistSharesOneGroupAcrossSongAndPartTargets() throws {
        let stale = try #require(worklist.group(for: Fix.staleAsset))
        #expect(stale.items.map(\.target) == [Fix.target(Fix.songA), Fix.target(Fix.songA, Fix.partA2),
                                              Fix.target(Fix.songD, Fix.partD1)])
        let gone = try #require(worklist.group(for: Fix.goneAsset))
        #expect(gone.items.map(\.target) == [Fix.target(Fix.songA, Fix.partA1), Fix.target(Fix.songB),
                                             Fix.target(Fix.songB, Fix.partB1)])
        #expect(worklist.groups.count == 3)
    }

    @Test
    func worklistCountsNonChartProblemsWithoutGroupingThem() throws {
        #expect(worklist.nonChartProblemCount == 3)
        #expect(!worklist.isEmpty)
        // Only broken patch, variation and action-set links: reported by the link report, nothing to recover.
        let song = try ShowSong.make(id: Fix.songA, title: "Song A", parts: [
            Fix.part(Fix.partA1, links: Fix.makeLinks(patch: Fix.unknownPatch)),
            Fix.part(Fix.partA2, links: Fix.makeLinks(patch: Fix.keysPatch, variation: Fix.unknownVariation)),
            Fix.part(Fix.partA3, links: Fix.makeLinks(actionSet: Fix.unknownSet))
        ])
        let broken = try ShowLibrary.make(songs: [song])
        let list = ShowRecoveryWorklist.make(library: broken, catalog: catalog)
        #expect(broken.linkReport(in: catalog).count == 3)
        #expect(list.nonChartProblemCount == 3)
        #expect(list.isEmpty)
        #expect(list.groups.isEmpty)
        #expect(list.targetCount == 0)
    }

    @Test
    func healthyAndEmptyLibrariesHaveEmptyWorklists() throws {
        let none = ShowRecoveryWorklist.make(library: try ShowLibrary.make(), catalog: catalog)
        let healthy = try ShowSong.make(id: Fix.songC, title: "Song C", parts: [
            Fix.part(Fix.partA1, links: Fix.makeLinks(chart: Fix.chart(Fix.okAsset, page: 2)))
        ], chart: Fix.chart(Fix.okAsset2))
        let sound = ShowRecoveryWorklist.make(library: try ShowLibrary.make(songs: [healthy]), catalog: catalog)
        for list in [none, sound] {
            #expect(list.isEmpty)
            #expect(list.groups.isEmpty)
            #expect(list.targetCount == 0)
            #expect(list.nonChartProblemCount == 0)
        }
    }

    @Test
    func worklistTargetCountAndLookupFollowTheGroups() {
        #expect(worklist.targetCount == 7)
        #expect(worklist.groups.map { $0.items.count } == [3, 3, 1])
        #expect(worklist.group(for: Fix.staleAsset)?.items.count == 3)
        #expect(worklist.group(for: Fix.goneAsset)?.items.count == 3)
        #expect(worklist.group(for: Fix.midiAsset)?.items.count == 1)
        #expect(worklist.group(for: Fix.staleAsset2) == nil)
        #expect(worklist.group(for: Fix.audioAsset) == nil)
    }

    @Test
    func worklistKeepsEachReferenceItsOwnPage() {
        let pages = worklist.groups.map { $0.items.map { $0.chart.page } }
        #expect(pages == [[1, 2, 9_999], [3, nil, nil], [1]])
        #expect(worklist.groups.map { $0.items.map { $0.chart.asset } }
            == [[Fix.staleAsset, Fix.staleAsset, Fix.staleAsset], [Fix.goneAsset, Fix.goneAsset, Fix.goneAsset],
                [Fix.midiAsset]])
    }

    @Test
    func worklistFollowsTheCatalogAvailabilityInsteadOfItsOwnRules() throws {
        // Here the stale and gone assets are documents with content, so only the MIDI chart stays missing.
        let content = [Fix.okAsset, Fix.staleAsset, Fix.goneAsset]
        let lenient = try ShowLinkCatalog.make(
            patches: [(Fix.keysPatch, [Fix.wetVariation])],
            assets: [Fix.asset(Fix.okAsset, .document), Fix.asset(Fix.staleAsset, .document),
                     Fix.asset(Fix.goneAsset, .document), Fix.asset(Fix.midiAsset, .midi)],
            availableContent: content
        )
        let list = ShowRecoveryWorklist.make(library: library, catalog: lenient)
        #expect(list.groups.map(\.asset) == [Fix.midiAsset])
        #expect(list.targetCount == 1)
        #expect(list.nonChartProblemCount == 3)
        // An empty catalog lists no asset, so every referenced asset, even a healthy one, is not in the project.
        let nothing = ShowRecoveryWorklist.make(library: library, catalog: try ShowLinkCatalog.make())
        #expect(nothing.groups.map(\.asset) == [Fix.staleAsset, Fix.goneAsset, Fix.okAsset, Fix.midiAsset])
        #expect(Set(nothing.groups.map(\.reason)) == [.notInProject])
    }

    @Test
    func maximalLibraryReachesTheTargetBound() throws {
        let gone = try Fix.chart(Fix.goneAsset)
        let parts = try (0..<ShowLimits.maximumPartsPerSong).map {
            try SongPart.make(id: SongPartID("p\($0)"), title: "Part", links: Fix.makeLinks(chart: gone))
        }
        let songs = try (0..<ShowLimits.maximumSongs).map {
            try ShowSong.make(id: SongID("s\($0)"), title: "Song", parts: parts, chart: gone)
        }
        let full = ShowRecoveryWorklist.make(library: try ShowLibrary.make(songs: songs), catalog: catalog)
        #expect(ShowRecoveryWorklist.maximumTargets == 33_280)
        #expect(full.targetCount == ShowRecoveryWorklist.maximumTargets)
        #expect(full.groups.count == 1)
        // One more song or one more part is refused by the library's own limits, so the bound cannot be exceeded.
        let extra = try ShowSong.make(id: SongID("extra"), title: "Song", chart: gone)
        let oneMoreSong = songs + [extra]
        #expect(throws: ShowRefusal.tooManySongs(513)) { try ShowLibrary.make(songs: oneMoreSong) }
        let oneMorePart = try parts + [SongPart.make(id: SongPartID("extra"), title: "Part")]
        let longID = try SongID("long")
        #expect(throws: ShowRefusal.tooManyParts(longID, 65)) {
            try ShowSong.make(id: longID, title: "Song", parts: oneMorePart)
        }
    }
}
