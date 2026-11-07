import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowRecoveryTestFixture {
    /// `songCount` songs of 64 parts each; the song and every part carry the gone chart, so a song holds 65 targets.
    static func goneLibrary(songCount: Int) throws -> ShowLibrary {
        let gone = try chart(goneAsset)
        let parts = try (0..<ShowLimits.maximumPartsPerSong).map {
            try SongPart.make(id: SongPartID("p\($0)"), title: "Part", links: makeLinks(chart: gone))
        }
        let songs = try (0..<songCount).map {
            try ShowSong.make(id: SongID("s\($0)"), title: "Song", parts: parts, chart: gone)
        }
        return try ShowLibrary.make(songs: songs)
    }

    /// One `clearTarget` for each song and its first 63 parts of `goneLibrary`: 64 decisions per song.
    static func clearDecisions(songCount: Int) throws -> [ShowRecoveryDecision] {
        var decisions: [ShowRecoveryDecision] = []
        for number in 0..<songCount {
            let song = try SongID("s\(number)")
            decisions.append(.clearTarget(target(song)))
            for index in 0..<(ShowLimits.maximumPartsPerSong - 1) {
                let part = try SongPartID("p\(index)")
                decisions.append(.clearTarget(target(song, part)))
            }
        }
        return decisions
    }

    /// The library with every chart removed, so what recovery must leave alone can be compared.
    static func stripped(_ library: ShowLibrary) throws -> ShowLibrary {
        let songs = try library.songs.map { song -> ShowSong in
            let parts = song.parts.map { $0.replacingLinks($0.links.replacingChart(nil)) }
            return try ShowSong.make(id: song.id, title: song.title, parts: parts, chart: nil)
        }
        return try ShowLibrary.make(songs: songs, setlists: library.setlists)
    }

    /// Two songs, `songA` then `songB`, that share the part IDs `partA1` and `partA2`; every chart is the gone asset.
    /// The first song's own chart is on page 1 and its parts' on pages 2 and 3; the second song's are on pages 4 to 6.
    static func twinLibrary() throws -> ShowLibrary {
        try ShowLibrary.make(songs: [twinSong(songA, firstPage: 1), twinSong(songB, firstPage: 4)])
    }

    private static func twinSong(_ id: SongID, firstPage: Int) throws -> ShowSong {
        let first = try part(partA1, links: makeLinks(chart: chart(goneAsset, page: firstPage + 1)))
        let second = try part(partA2, links: makeLinks(chart: chart(goneAsset, page: firstPage + 2)))
        let own = try chart(goneAsset, page: firstPage)
        return try ShowSong.make(id: id, title: "Twin", parts: [first, second], chart: own)
    }
}

extension ShowRecoveryTests {
    @Test
    func decisionsApplyInOrderAndLaterOnesSeeTheEarlierEdits() throws {
        let songChart = Fix.target(Fix.songA)
        let staleToOk: ShowRecoveryDecision = .relinkAsset(from: Fix.staleAsset, to: Fix.okAsset)
        let outcome = try recover([.clearTarget(songChart), staleToOk])
        var expected = Fix.chartMap(library)
        expected[songChart] = nil
        expected[Fix.target(Fix.songA, Fix.partA2)] = try Fix.chart(Fix.okAsset, page: 2)
        expected[Fix.target(Fix.songD, Fix.partD1)] = try Fix.chart(Fix.okAsset, page: 9_999)
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.clearedTargetCount == 1)
        #expect(outcome.relinkedTargetCount == 2)
        // Reversed, the song chart is already healthy when it is cleared.
        let reversed = refusal([staleToOk, .clearTarget(songChart)])
        #expect(reversed == ShowRecoveryRefusal(index: 1, reason: .notMissing(Fix.okAsset)))
    }

    @Test
    func aTargetEditedByAnEarlierDecisionIsNotEditedAgain() throws {
        let part = Fix.target(Fix.songA, Fix.partA2)
        let first = try Fix.chart(Fix.okAsset2, page: 1)
        let second = try Fix.chart(Fix.okAsset, page: 2)
        let cleared = ShowRecoveryRefusal(index: 1, reason: .noSuchTarget(part))
        let healthy = ShowRecoveryRefusal(index: 1, reason: .notMissing(Fix.okAsset2))
        #expect(refusal([.clearTarget(part), .clearTarget(part)]) == cleared)
        #expect(refusal([.clearTarget(part), .relinkTarget(part, to: second)]) == cleared)
        #expect(refusal([.relinkTarget(part, to: first), .relinkTarget(part, to: second)]) == healthy)
        #expect(refusal([.relinkTarget(part, to: first), .clearTarget(part)]) == healthy)
        let gone = ShowRecoveryRefusal(index: 1, reason: .notMissing(Fix.goneAsset))
        #expect(refusal([.clearAsset(Fix.goneAsset), .clearAsset(Fix.goneAsset)]) == gone)
    }

    @Test
    func aLaterSongsDecisionLandsOnItsOwnSongWhenPartIDsAreShared() throws {
        let twins = try Fix.twinLibrary()
        let secondOwn = Fix.target(Fix.songB)
        let secondPart = Fix.target(Fix.songB, Fix.partA1)
        let healthy = try Fix.chart(Fix.okAsset, page: 7)
        let decisions: [ShowRecoveryDecision] = [
            .clearTarget(Fix.target(Fix.songA)), .relinkTarget(secondPart, to: healthy), .clearTarget(secondOwn)
        ]
        let outcome = try ShowChartRecovery.apply(decisions, to: twins, in: catalog)
        // Both songs hold the part IDs `partA1` and `partA2`, so an edit that reached the first song instead of the
        // second is still accepted; only the exact chart map shows where each decision landed.
        var expected = Fix.chartMap(twins)
        expected[Fix.target(Fix.songA)] = nil
        expected[secondPart] = healthy
        expected[secondOwn] = nil
        #expect(Fix.chartMap(outcome.library) == expected)
        let remaining = outcome.worklist.groups.flatMap { $0.items.map(\.target) }
        let firstSong = [Fix.target(Fix.songA, Fix.partA1), Fix.target(Fix.songA, Fix.partA2)]
        #expect(remaining == firstSong + [Fix.target(Fix.songB, Fix.partA2)])
        #expect(outcome.relinkedTargetCount == 1)
        #expect(outcome.clearedTargetCount == 2)
    }

    @Test
    func theRefusalNamesTheFirstBadDecisionOfTheBatch() {
        let valid: [ShowRecoveryDecision] = [
            .clearTarget(Fix.target(Fix.songA)), .clearTarget(Fix.target(Fix.songA, Fix.partA1)),
            .clearTarget(Fix.target(Fix.songA, Fix.partA2)), .clearTarget(Fix.target(Fix.songB, Fix.partB1))
        ]
        let tail: [ShowRecoveryDecision] = [.clearAsset(Fix.okAsset), .clearAsset(Fix.audioAsset)]
        for count in 0...valid.count {
            let batch = Array(valid.prefix(count)) + tail
            #expect(refusal(batch) == ShowRecoveryRefusal(index: count, reason: .notMissing(Fix.okAsset)))
        }
        #expect(refusal(valid) == nil)
    }

    @Test
    func aRefusedBatchNamesItsBadDecisionAndItsPrefixAppliesAlone() throws {
        // A refusal is a typed throw that returns no outcome, and the caller's library is a value, so "nothing is
        // applied" holds by construction and has no assertion here. What can fail is checked: the refusal names
        // the bad third decision, and the same two decisions without it apply to exactly the expected result.
        let prefix: [ShowRecoveryDecision] = [.clearTarget(Fix.target(Fix.songA)), .clearAsset(Fix.goneAsset)]
        let bad: ShowRecoveryDecision = .clearAsset(Fix.okAsset)
        #expect(refusal(prefix + [bad]) == ShowRecoveryRefusal(index: 2, reason: .notMissing(Fix.okAsset)))
        let outcome = try recover(prefix)
        let cleared = [
            Fix.target(Fix.songA), Fix.target(Fix.songA, Fix.partA1),
            Fix.target(Fix.songB), Fix.target(Fix.songB, Fix.partB1)
        ]
        var expected = Fix.chartMap(library)
        for target in cleared { expected[target] = nil }
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.clearedTargetCount == 4)
        #expect(outcome.relinkedTargetCount == 0)
        #expect(outcome.worklist.groups.map(\.asset) == [Fix.staleAsset, Fix.midiAsset])
        #expect(outcome.worklist.targetCount == 3)
    }

    @Test
    func aBatchOfExactlyTheMaximumIsAccepted() throws {
        let big = try Fix.goneLibrary(songCount: 16)
        let decisions = try Fix.clearDecisions(songCount: 16)
        #expect(ShowChartRecovery.maximumDecisions == 1_024)
        #expect(decisions.count == ShowChartRecovery.maximumDecisions)
        #expect(ShowRecoveryWorklist.make(library: big, catalog: catalog).targetCount == 1_040)
        let outcome = try ShowChartRecovery.apply(decisions, to: big, in: catalog)
        #expect(outcome.clearedTargetCount == 1_024)
        #expect(outcome.relinkedTargetCount == 0)
        #expect(outcome.worklist.targetCount == 16)
        #expect(outcome.worklist.groups.map(\.asset) == [Fix.goneAsset])
    }

    @Test
    func aBatchOneOverTheMaximumIsRefusedBeforeAnyDecisionIsRead() throws {
        let big = try Fix.goneLibrary(songCount: 16)
        var decisions = try Fix.clearDecisions(songCount: 16)
        let song = try SongID("s0")
        let last = try SongPartID("p63")
        decisions.append(.clearTarget(Fix.target(song, last)))
        #expect(decisions.count == 1_025)
        let over = ShowRecoveryRefusal(index: 1_024, reason: .tooManyDecisions(1_025))
        #expect(Fix.refusal(of: decisions, in: big, catalog: catalog) == over)
        // The size is judged before any decision is read. Each junk decision alone is refused at index 0 as
        // `.notMissing`, so a bound enforced after (or inside) the decision loop would report that instead.
        let junk = [ShowRecoveryDecision](repeating: .clearAsset(Fix.okAsset), count: 3_000)
        let huge = ShowRecoveryRefusal(index: 1_024, reason: .tooManyDecisions(3_000))
        #expect(refusal(junk) == huge)
        let single = ShowRecoveryRefusal(index: 0, reason: .notMissing(Fix.okAsset))
        #expect(refusal([.clearAsset(Fix.okAsset)]) == single)
        let atMaximum = Array(junk.prefix(ShowChartRecovery.maximumDecisions))
        #expect(refusal(atMaximum) == single)
        let justOver = Array(junk.prefix(ShowChartRecovery.maximumDecisions + 1))
        #expect(refusal(justOver) == ShowRecoveryRefusal(index: 1_024, reason: .tooManyDecisions(1_025)))
    }

    @Test
    func anEmptyBatchChangesNothing() throws {
        let outcome = try recover([])
        #expect(outcome.library == library)
        #expect(outcome.worklist == worklist)
        #expect(outcome.relinkedTargetCount == 0)
        #expect(outcome.clearedTargetCount == 0)
    }

    @Test
    func recoveringTwiceIsRefusedBecauseNothingIsMissingAnymore() throws {
        let decisions = try Fix.recoverEverything()
        let first = try recover(decisions)
        let again = Fix.refusal(of: decisions, in: first.library, catalog: catalog)
        #expect(again == ShowRecoveryRefusal(index: 0, reason: .notMissing(Fix.staleAsset)))
        let each: [(ShowRecoveryDecision, AssetID)] = [
            (decisions[0], Fix.staleAsset), (decisions[1], Fix.goneAsset), (decisions[2], Fix.okAsset2)
        ]
        for (decision, asset) in each {
            let expected = ShowRecoveryRefusal(index: 0, reason: .notMissing(asset))
            #expect(Fix.refusal(of: [decision], in: first.library, catalog: catalog) == expected)
        }
    }

    @Test
    func recoveryChangesChartsAndNothingElse() throws {
        let outcome = try recover(Fix.recoverEverything())
        let before = try Fix.stripped(library)
        let after = try Fix.stripped(outcome.library)
        #expect(after == before)
        #expect(outcome.library != library)
        #expect(outcome.library.setlists == library.setlists)
        #expect(outcome.library.songs.map(\.id) == library.songs.map(\.id))
        #expect(outcome.library.songs.map(\.title) == library.songs.map(\.title))
        let partsBefore = library.songs.map { song in song.parts.map(\.id) }
        let partsAfter = outcome.library.songs.map { song in song.parts.map(\.id) }
        #expect(partsAfter == partsBefore)
        var expected = Fix.chartMap(library)
        expected[Fix.target(Fix.songA)] = try Fix.chart(Fix.okAsset, page: 1)
        expected[Fix.target(Fix.songA, Fix.partA1)] = nil
        expected[Fix.target(Fix.songA, Fix.partA2)] = try Fix.chart(Fix.okAsset, page: 2)
        expected[Fix.target(Fix.songB)] = nil
        expected[Fix.target(Fix.songB, Fix.partB1)] = nil
        expected[Fix.target(Fix.songB, Fix.partB2)] = try Fix.chart(Fix.okAsset2, page: 7)
        expected[Fix.target(Fix.songD, Fix.partD1)] = try Fix.chart(Fix.okAsset, page: 9_999)
        #expect(Fix.chartMap(outcome.library) == expected)
    }

    @Test
    func theOutcomeCountsTargetsNotDecisions() throws {
        let outcome = try recover(Fix.recoverEverything())
        #expect(outcome.relinkedTargetCount == 4)
        #expect(outcome.clearedTargetCount == 3)
        let single = try recover([.relinkAsset(from: Fix.goneAsset, to: Fix.okAsset)])
        #expect(single.relinkedTargetCount == 3)
        #expect(single.clearedTargetCount == 0)
    }

    @Test
    func theOutcomeWorklistIsTheWorklistOfTheRecoveredLibrary() throws {
        let outcome = try recover([.relinkAsset(from: Fix.staleAsset, to: Fix.okAsset)])
        let fresh = ShowRecoveryWorklist.make(library: outcome.library, catalog: catalog)
        #expect(outcome.worklist == fresh)
        #expect(outcome.worklist != worklist)
        #expect(outcome.worklist.targetCount == 4)
        #expect(outcome.worklist.nonChartProblemCount == 3)
    }

    @Test
    func theRecoveredLibraryKeepsOnlyTheNonChartProblems() throws {
        let outcome = try recover(Fix.recoverEverything())
        let expected = [
            ShowLinkIssue(song: Fix.songA, part: Fix.partA3, problem: .unknownPatch(Fix.unknownPatch)),
            ShowLinkIssue(song: Fix.songA, part: Fix.partA4, problem: .unknownActionSet(Fix.unknownSet)),
            ShowLinkIssue(song: Fix.songB, part: Fix.partB2,
                          problem: .unknownVariation(Fix.keysPatch, Fix.unknownVariation))
        ]
        #expect(outcome.library.linkReport(in: catalog) == expected)
        #expect(outcome.worklist.isEmpty)
        #expect(outcome.worklist.nonChartProblemCount == 3)
        // Before recovery the report lists the same three problems and seven chart problems.
        #expect(library.linkReport(in: catalog).count == 10)
    }

    @Test
    func chartsNoDecisionMentionsStayMissing() throws {
        let outcome = try recover([.clearAsset(Fix.goneAsset)])
        let remaining = outcome.library.linkReport(in: catalog).compactMap { issue -> ChartReference? in
            guard case let .chart(chart, _) = issue.problem else { return nil }
            return chart
        }
        #expect(remaining.count == 4)
        #expect(Set(remaining.map(\.asset)) == [Fix.staleAsset, Fix.midiAsset])
    }

    @Test
    func clearingASongChartAlsoClearsWhatItsPartsInherit() throws {
        let song = try #require(library.song(Fix.songA))
        let inherited = try ShowLibrary.resolvedLinks(song: song, part: Fix.partA3, in: catalog)
        let stale = try Fix.chart(Fix.staleAsset, page: 1)
        #expect(inherited.chart == .missing(stale, .contentUnavailable))
        let outcome = try recover([.clearTarget(Fix.target(Fix.songA))])
        let cleared = try #require(outcome.library.song(Fix.songA))
        let after = try ShowLibrary.resolvedLinks(song: cleared, part: Fix.partA3, in: catalog)
        #expect(after.chart == nil)
        #expect(Fix.chartMap(outcome.library)[Fix.target(Fix.songA, Fix.partA3)] == nil)
        // The parts with their own chart keep it.
        let own = try ShowLibrary.resolvedLinks(song: cleared, part: Fix.partA2, in: catalog)
        let ownChart = try Fix.chart(Fix.staleAsset, page: 2)
        #expect(own.chart == .missing(ownChart, .contentUnavailable))
    }
}
