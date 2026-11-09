import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Patches `pat.keys` (variations `var.verse`, `var.chorus`; `var.gone` is unknown) and `pat.pad`; the action set
/// `as.one`; the available chart `ast.chart`; `ast.gone` is not in the project. Song A: a1 keys/verse, a2 keys/chorus,
/// a3 pad. Song B: b1 keys (base) with a missing chart, b2 keys/`var.gone` with `as.one` and a missing chart, b3
/// nothing. Song C has no parts and the available chart. Setlist `set.main` plays ent.1 A, ent.2 B, ent.3 C: seven
/// stops. No test passes an action source.
private enum ShowTransitionWalkFixture {
    static let keys = PatchID(validated: "pat.keys")
    static let pad = PatchID(validated: "pat.pad")
    static let verse = PatchVariationID(validated: "var.verse")
    static let chorus = PatchVariationID(validated: "var.chorus")
    static let goneVariation = PatchVariationID(validated: "var.gone")
    static let gain = ParameterID(validated: "par.gain")
    static let actionSet = ActionSetID(validated: "as.one")
    static let chartAsset = AssetID(validated: "ast.chart")
    static let goneAsset = AssetID(validated: "ast.gone")
    static let songA = SongID(validated: "song.a")
    static let songB = SongID(validated: "song.b")
    static let songC = SongID(validated: "song.c")
    static let main = SetlistID(validated: "set.main")
    static let small = SetlistID(validated: "set.small")
    static let foot = ShowInputSourceID(validated: "src.foot")
    static let ent1 = SetlistEntryID(validated: "ent.1")
    static let ent2 = SetlistEntryID(validated: "ent.2")
    static let ent3 = SetlistEntryID(validated: "ent.3")
    static let partA1 = SongPartID(validated: "part.a1")
    static let partA2 = SongPartID(validated: "part.a2")
    static let partA3 = SongPartID(validated: "part.a3")
    static let partB1 = SongPartID(validated: "part.b1")
    static let partB2 = SongPartID(validated: "part.b2")
    static let partB3 = SongPartID(validated: "part.b3")

    static func loaded(_ patch: PatchID, _ variation: PatchVariationID? = nil) -> ShowActivePatch {
        ShowActivePatch(patch: patch, variation: variation)
    }

    static func position(_ entry: SetlistEntryID, _ part: SongPartID?) -> ShowPosition {
        ShowPosition(setlist: main, entry: entry, part: part)
    }

    /// verse: gain -6 dB; chorus: gain 0 dB.
    static func recallSource() throws -> ShowPatchRecallSource {
        let descriptor = try ParameterDescriptor(.init(
            id: gain, unit: .decibels, lower: -90, upper: 10, defaultValue: -90, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: .live, verification: .unverified
        ))
        let parameters = try PatchParameterTable(ParameterCatalog([descriptor]))
        let verseGain = PatchParameterDelta(parameter: gain, value: ParameterValue(value: -6, unit: .decibels))
        let chorusGain = PatchParameterDelta(parameter: gain, value: ParameterValue(value: 0, unit: .decibels))
        let variations = [
            PatchVariation(id: verse, label: "Verse", deltas: [verseGain]),
            PatchVariation(id: chorus, label: "Chorus", deltas: [chorusGain])
        ]
        let patch = try PatchVariationExtension.write(
            PatchVariationSet(variations: variations),
            to: ProjectPatch(id: keys, label: "Keys", graph: GraphID(validated: "graph.main"))
        )
        return ShowPatchRecallSource(patch: patch, table: parameters, baseline: .defaults(parameters))
    }

    static func context() throws -> ShowTransitionContext {
        try ShowTransitionContext.make(patches: [recallSource()], actionSets: nil)
    }

    static func catalog() throws -> ShowLinkCatalog {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let asset = ProjectAsset(id: chartAsset, label: "Chart", media: .document, contentDigest: digest)
        let sets = try PerformanceActionSetLibrary(sets: [
            PerformanceActionSet(id: actionSet, members: [ActionID(validated: "act.0")])
        ])
        return try ShowLinkCatalog.make(
            patches: [(keys, [verse, chorus]), (pad, [])], actionSets: sets, assets: [asset],
            availableContent: [chartAsset]
        )
    }

    static func availableChart(page: Int? = nil) throws -> ChartReference {
        try ChartReference.make(asset: chartAsset, page: page)
    }

    static func goneChart() throws -> ChartReference {
        try ChartReference.make(asset: goneAsset)
    }

    /// The block of a part that links the chart the project lacks.
    static func missingChart() throws -> ShowTransitionBlock {
        try .unresolvedLink(.chart(goneChart(), .notInProject))
    }

    static func part(_ raw: String, _ links: SongPartLinks = .none) throws -> SongPart {
        try SongPart.make(id: SongPartID(raw), title: "Part \(raw)", links: links)
    }

    /// A song whose parts are `part.<raw>.<n>` and carry `links` in order.
    static func song(_ raw: String, _ links: [SongPartLinks] = [], chart: ChartReference? = nil) throws -> ShowSong {
        var parts: [SongPart] = []
        for (number, link) in links.enumerated() { try parts.append(part("part.\(raw).\(number)", link)) }
        return try ShowSong.make(id: SongID("song.\(raw)"), title: "Song \(raw)", parts: parts, chart: chart)
    }

    static func entryList(_ played: [SongID], from first: Int = 1) throws -> [SetlistEntry] {
        var entries: [SetlistEntry] = []
        for (offset, song) in played.enumerated() {
            try entries.append(SetlistEntry.make(id: SetlistEntryID("ent.\(first + offset)"), song: song))
        }
        return entries
    }

    /// `set.main` plays `played` (entries `ent.1`, `ent.2`, ...); a non-empty `side` is a second setlist `set.small`.
    static func library(_ songs: [ShowSong], played: [SongID], side: [SongID] = []) throws -> ShowLibrary {
        let first = try ShowSetlist.make(id: main, title: "Main", entries: entryList(played))
        guard !side.isEmpty else { return try ShowLibrary.make(songs: songs, setlists: [first]) }
        let second = try ShowSetlist.make(id: small, title: "Small", entries: entryList(side, from: played.count + 1))
        return try ShowLibrary.make(songs: songs, setlists: [first, second])
    }

    static func mainLibrary() throws -> ShowLibrary {
        let first = try ShowSong.make(id: songA, title: "A", parts: [
            part("part.a1", .make(patch: keys, variation: verse)),
            part("part.a2", .make(patch: keys, variation: chorus)),
            part("part.a3", .make(patch: pad))
        ])
        let second = try ShowSong.make(id: songB, title: "B", parts: [
            part("part.b1", .make(patch: keys, chart: goneChart())),
            part("part.b2", .make(patch: keys, variation: goneVariation, actionSet: actionSet, chart: goneChart())),
            part("part.b3")
        ])
        let third = try ShowSong.make(id: songC, title: "C", chart: availableChart())
        return try library([first, second, third], played: [songA, songB, songC])
    }

    /// One song per entry of `partCounts`; each part links the available chart with its own page, so no two parts
    /// have equal links. `set.main` plays the songs in order and `set.small` plays the first song.
    static func wideLibrary(_ partCounts: [Int]) throws -> ShowLibrary {
        var songs: [ShowSong] = []
        var page = 0
        for (index, count) in partCounts.enumerated() {
            var links: [SongPartLinks] = []
            for _ in 0..<count {
                page += 1
                try links.append(.make(chart: availableChart(page: page)))
            }
            try songs.append(song("w\(index)", links))
        }
        return try library(songs, played: songs.map(\.id), side: songs.prefix(1).map(\.id))
    }

    /// The part counts of 256 songs: 255 songs of 8 parts and a last song of `last` parts. The stop cap is 256 entries
    /// x 8 parts = 2,048 stops, so a `last` of 7, 8 and 9 gives 2,047, 2,048 and 2,049 stops.
    static func capCounts(lastSong last: Int) -> [Int] {
        var counts = [Int](repeating: 8, count: 255)
        counts.append(last)
        return counts
    }

    static func digest(_ library: ShowLibrary, _ id: SetlistID? = nil,
                       startingWith start: ShowActivePatch? = nil) throws -> ShowTransitionWalkDigest {
        try ShowTransitionWalk.digest(of: id ?? main, in: library, catalog: catalog(), context: context(),
                                      startingWith: start)
    }

    /// The stop a fresh cursor reaches by jumping to `position`.
    static func stop(_ position: ShowPosition, in library: ShowLibrary) throws -> ShowStop {
        var cursor = try ShowCursor.make(setlist: position.setlist, bounceTicks: 0, sources: [foot], in: library)
        let jump = ShowNavigationInput(.jump(position.entry, position.part), source: foot, sequence: 1, tick: 0)
        let result = try cursor.navigate(jump, in: library, catalog: catalog())
        guard case let .moved(stop) = result else { throw ShowRefusal.atStart }
        return stop
    }
}

struct ShowTransitionWalkTests {
    private typealias Fix = ShowTransitionWalkFixture

    private func mainDigest(startingWith start: ShowActivePatch?) throws -> ShowTransitionWalkDigest {
        try Fix.digest(Fix.mainLibrary(), startingWith: start)
    }

    /// One song `song.x` with parts carrying `links`, played by `entries` entries of `set.main`.
    private func run(_ links: [SongPartLinks], entries: Int = 1,
                     start: ShowActivePatch? = nil) throws -> ShowTransitionWalkDigest {
        let song = try Fix.song("x", links)
        let library = try Fix.library([song], played: Array(repeating: song.id, count: entries))
        return try Fix.digest(library, startingWith: start)
    }

    @Test
    func showTransitionWalkReportsOneRowPerStopWithItsBlocks() throws {
        let digest = try mainDigest(startingWith: Fix.loaded(Fix.keys))
        let positions = digest.rows.map(\.to.position)
        let expectedPositions: [ShowPosition] = [
            Fix.position(Fix.ent1, Fix.partA1), Fix.position(Fix.ent1, Fix.partA2), Fix.position(Fix.ent1, Fix.partA3),
            Fix.position(Fix.ent2, Fix.partB1), Fix.position(Fix.ent2, Fix.partB2), Fix.position(Fix.ent2, Fix.partB3),
            Fix.position(Fix.ent3, nil)
        ]
        #expect(positions == expectedPositions)
        let songs = digest.rows.map(\.to.song)
        let expectedSongs: [SongID] = [Fix.songA, Fix.songA, Fix.songA, Fix.songB, Fix.songB, Fix.songB, Fix.songC]
        #expect(songs == expectedSongs)
        let missing = try Fix.missingChart()
        let review: ShowTransitionBlock = .requiresStructuralActivationReview(from: Fix.keys, to: Fix.pad)
        let brokenVariation: ShowTransitionBlock = .unresolvedLink(.unknownVariation(Fix.keys, Fix.goneVariation))
        let noSource: ShowTransitionBlock = .actionSetSourceUnavailable(Fix.actionSet)
        let blocks = digest.rows.map(\.blocks)
        let expectedBlocks: [[ShowTransitionBlock]] = [
            [], [], [review], [missing], [brokenVariation, noSource, missing], [], []
        ]
        #expect(blocks == expectedBlocks)
        let clear = digest.rows.map(\.isClear)
        let expectedClear: [Bool] = [true, true, false, false, false, true, true]
        #expect(clear == expectedClear)
        #expect(digest.setlist == Fix.main)
        #expect(digest.stopCount == 7)
        #expect(digest.blockedCount == 3)
        #expect(digest.structuralReviewCount == 1)
        #expect(digest.plannerRuns == 7)
    }

    @Test
    func showTransitionWalkPlansTheOpeningStopFirstAndChainsTheReferences() throws {
        let start = Fix.loaded(Fix.keys, Fix.chorus)
        let digest = try mainDigest(startingWith: start)
        let first = try #require(digest.rows.first)
        #expect(first.from == nil)
        #expect(first.to.position == Fix.position(Fix.ent1, Fix.partA1))
        #expect(first.loaded == start)
        let reached: [ShowStopReference?] = digest.rows.dropLast().map(\.to)
        let departed = digest.rows.dropFirst().map(\.from)
        #expect(departed == reached)
    }

    @Test
    func showTransitionWalkLoadedPatchFollowsPlannedRecallsAndHoldsAcrossBlocks() throws {
        let digest = try mainDigest(startingWith: Fix.loaded(Fix.keys))
        let loaded = digest.rows.map(\.loaded)
        let expected: [ShowActivePatch?] = [
            Fix.loaded(Fix.keys), Fix.loaded(Fix.keys, Fix.verse), Fix.loaded(Fix.keys, Fix.chorus),
            Fix.loaded(Fix.keys, Fix.chorus), Fix.loaded(Fix.keys), Fix.loaded(Fix.keys), Fix.loaded(Fix.keys)
        ]
        #expect(loaded == expected)
    }

    @Test
    func showTransitionWalkLeavesNothingLoadedWhenNothingWasLoaded() throws {
        let digest = try mainDigest(startingWith: nil)
        let loaded = digest.rows.map(\.loaded)
        let expectedLoaded: [ShowActivePatch?] = Array(repeating: nil, count: 7)
        #expect(loaded == expectedLoaded)
        let missing = try Fix.missingChart()
        let toKeys: ShowTransitionBlock = .requiresStructuralActivationReview(from: nil, to: Fix.keys)
        let toPad: ShowTransitionBlock = .requiresStructuralActivationReview(from: nil, to: Fix.pad)
        let noSource: ShowTransitionBlock = .actionSetSourceUnavailable(Fix.actionSet)
        let blocks = digest.rows.map(\.blocks)
        let expectedBlocks: [[ShowTransitionBlock]] = [
            [toKeys], [toKeys], [toPad], [toKeys, missing], [toKeys, noSource, missing], [], []
        ]
        #expect(blocks == expectedBlocks)
        #expect(digest.blockedCount == 5)
        #expect(digest.structuralReviewCount == 5)
        #expect(digest.plannerRuns == 7)
    }

    @Test
    func showTransitionWalkRowsEqualThePlannerForTheSameStopAndLoadedPatch() throws {
        let library = try Fix.mainLibrary()
        let context = try Fix.context()
        let starts: [ShowActivePatch?] = [Fix.loaded(Fix.keys), nil]
        for start in starts {
            let digest = try Fix.digest(library, startingWith: start)
            for row in digest.rows {
                let stop = try Fix.stop(row.to.position, in: library)
                let plan = ShowTransitionPlanner.plan(from: nil, to: stop, active: row.loaded, in: context)
                let reference = ShowStopReference(stop)
                #expect(plan.blocks == row.blocks)
                #expect(row.to == reference)
            }
        }
    }

    @Test
    func showTransitionWalkPlansEachDistinctLinkAndLoadedPatchPairOnce() throws {
        let chart = try Fix.availableChart()
        let startKeys = Fix.loaded(Fix.keys)
        let atVerse = Fix.loaded(Fix.keys, Fix.verse)
        let atChorus = Fix.loaded(Fix.keys, Fix.chorus)
        let verseLinks = try SongPartLinks.make(patch: Fix.keys, variation: Fix.verse, chart: chart)
        let sameVerse = Array(repeating: verseLinks, count: 4)
        let held = try run(sameVerse, start: startKeys)
        let heldLoaded = held.rows.map(\.loaded)
        let expectedHeld: [ShowActivePatch?] = [startKeys, atVerse, atVerse, atVerse]
        #expect(held.plannerRuns == 2)
        #expect(heldLoaded == expectedHeld)
        let twice = try run(sameVerse, entries: 2, start: startKeys)
        #expect(twice.stopCount == 8)
        #expect(twice.plannerRuns == 2)
        let chartOnly = try run(Array(repeating: SongPartLinks.make(chart: chart), count: 4))
        #expect(chartOnly.plannerRuns == 1)
        var pages: [SongPartLinks] = []
        for page in 1...4 { try pages.append(.make(chart: Fix.availableChart(page: page))) }
        let distinct = try run(pages)
        #expect(distinct.plannerRuns == 4)
        let verseOnly = try SongPartLinks.make(patch: Fix.keys, variation: Fix.verse)
        let chorusOnly = try SongPartLinks.make(patch: Fix.keys, variation: Fix.chorus)
        let swung = try run([verseOnly, chorusOnly, verseOnly, chorusOnly, verseOnly], start: startKeys)
        let swungLoaded = swung.rows.map(\.loaded)
        let expectedSwung: [ShowActivePatch?] = [startKeys, atVerse, atChorus, atVerse, atChorus]
        let swungBlocks = swung.rows.flatMap(\.blocks)
        #expect(swung.plannerRuns == 3)
        #expect(swungLoaded == expectedSwung)
        #expect(swungBlocks.isEmpty)
        let missingLinks = try SongPartLinks.make(chart: Fix.goneChart())
        let gaps = try run([missingLinks, SongPartLinks.none, missingLinks])
        let missing = try Fix.missingChart()
        let gapBlocks = gaps.rows.map(\.blocks)
        let expectedGaps: [[ShowTransitionBlock]] = [[missing], [], [missing]]
        #expect(gaps.plannerRuns == 2)
        #expect(gapBlocks == expectedGaps)
    }

    @Test
    func showTransitionWalkTreatsAPartlessSongAsOneStop() throws {
        let before = try Fix.song("p", [.none, .none])
        let partless = try Fix.song("q")
        let after = try Fix.song("r", [.none])
        let library = try Fix.library([before, partless, after], played: [before.id, partless.id, after.id])
        let digest = try Fix.digest(library)
        let parts = digest.rows.map(\.to.position.part)
        let expectedParts: [SongPartID?] = [
            try SongPartID("part.p.0"), try SongPartID("part.p.1"), nil, try SongPartID("part.r.0")
        ]
        #expect(digest.stopCount == 4)
        #expect(parts == expectedParts)
        let songs = digest.rows.map(\.to.song)
        let expectedSongs: [SongID] = [before.id, before.id, partless.id, after.id]
        #expect(songs == expectedSongs)
    }

    @Test
    func showTransitionWalkOfAnEmptySetlistIsAnEmptyDigest() throws {
        let library = try Fix.library([], played: [])
        let digest = try Fix.digest(library, startingWith: Fix.loaded(Fix.keys))
        #expect(digest.rows.isEmpty)
        #expect(digest.setlist == Fix.main)
        #expect(digest.stopCount == 0)
        #expect(digest.blockedCount == 0)
        #expect(digest.structuralReviewCount == 0)
        #expect(digest.plannerRuns == 0)
    }

    @Test
    func showTransitionWalkOfASingleStopSetlistHasOneRow() throws {
        let lone = try Fix.song("lone")
        let library = try Fix.library([lone], played: [lone.id])
        let start = Fix.loaded(Fix.keys, Fix.verse)
        let digest = try Fix.digest(library, startingWith: start)
        let row = try #require(digest.rows.first)
        #expect(digest.stopCount == 1)
        #expect(row.from == nil)
        #expect(row.to.position.part == nil)
        #expect(row.loaded == start)
        #expect(row.isClear)
        #expect(digest.plannerRuns == 1)
    }

    @Test
    func showTransitionWalkRefusesAnUnknownSetlist() throws {
        let gone = SetlistID(validated: "set.gone")
        let empty = try ShowLibrary.make()
        #expect(throws: ShowTransitionWalkRefusal.unknownSetlist(gone)) { try Fix.digest(empty, gone) }
        let other = try Fix.mainLibrary()
        #expect(throws: ShowTransitionWalkRefusal.unknownSetlist(gone)) { try Fix.digest(other, gone) }
        let oversized = try Fix.wideLibrary(Fix.capCounts(lastSong: 9))
        #expect(throws: ShowTransitionWalkRefusal.unknownSetlist(gone)) { try Fix.digest(oversized, gone) }
    }

    @Test
    func showTransitionWalkAcceptsExactlyTheStopCap() throws {
        let library = try Fix.wideLibrary(Fix.capCounts(lastSong: 8))
        let digest = try Fix.digest(library)
        #expect(digest.stopCount == 2_048)
        #expect(digest.plannerRuns == 2_048)
        #expect(digest.blockedCount == 0)
    }

    @Test
    func showTransitionWalkRefusesOneStopOverTheCap() throws {
        let library = try Fix.wideLibrary(Fix.capCounts(lastSong: 9))
        #expect(throws: ShowTransitionWalkRefusal.tooManyStops(2_049)) { try Fix.digest(library) }
    }

    @Test
    func showTransitionWalkRefusesTheContractMaximumAndReportsItsStopCount() throws {
        let giant = try Fix.song("giant", Array(repeating: SongPartLinks.none, count: 64))
        let library = try Fix.library([giant], played: Array(repeating: giant.id, count: 256))
        #expect(throws: ShowTransitionWalkRefusal.tooManyStops(16_384)) { try Fix.digest(library) }
    }

    @Test
    func showTransitionWalkCapCountsTheNamedSetlistNotTheLibrary() throws {
        let library = try Fix.wideLibrary(Fix.capCounts(lastSong: 9))
        #expect(throws: ShowTransitionWalkRefusal.tooManyStops(2_049)) { try Fix.digest(library) }
        let small = try Fix.digest(library, Fix.small)
        #expect(small.setlist == Fix.small)
        #expect(small.stopCount == 8)
    }

    @Test
    func showTransitionWalkIsRepeatableForEqualInputs() throws {
        let first = try mainDigest(startingWith: Fix.loaded(Fix.keys))
        let second = try mainDigest(startingWith: Fix.loaded(Fix.keys))
        #expect(first == second)
    }

    @Test
    func showTransitionWalkAcceptsOneStopUnderTheCap() throws {
        let library = try Fix.wideLibrary(Fix.capCounts(lastSong: 7))
        let digest = try Fix.digest(library)
        #expect(digest.stopCount == 2_047)
        #expect(digest.plannerRuns == 2_047)
        #expect(digest.blockedCount == 0)
    }
}
