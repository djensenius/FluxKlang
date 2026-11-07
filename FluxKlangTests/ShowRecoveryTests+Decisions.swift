import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowRecoveryTests {
    /// Replacement assets a recovery must refuse, each with the catalog's own reason.
    static func unavailableReplacements() -> [(AssetID, ChartMissingReason)] {
        [(Fix.goneAsset2, .notInProject), (Fix.midiAsset, .notDocument(.midi)),
         (Fix.audioAsset, .notDocument(.audio)), (Fix.staleAsset2, .contentUnavailable)]
    }

    @Test
    func relinkAssetMovesEveryMissingReferenceAndKeepsItsPage() throws {
        let outcome = try recover([.relinkAsset(from: Fix.staleAsset, to: Fix.okAsset)])
        var expected = Fix.chartMap(library)
        expected[Fix.target(Fix.songA)] = try Fix.chart(Fix.okAsset, page: 1)
        expected[Fix.target(Fix.songA, Fix.partA2)] = try Fix.chart(Fix.okAsset, page: 2)
        expected[Fix.target(Fix.songD, Fix.partD1)] = try Fix.chart(Fix.okAsset, page: 9_999)
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.relinkedTargetCount == 3)
        #expect(outcome.clearedTargetCount == 0)
        #expect(outcome.worklist.groups.map(\.asset) == [Fix.goneAsset, Fix.midiAsset])
        #expect(outcome.worklist.targetCount == 4)
    }

    @Test
    func relinkAssetKeepsAnAbsentPageAbsent() throws {
        let outcome = try recover([.relinkAsset(from: Fix.goneAsset, to: Fix.okAsset2)])
        var expected = Fix.chartMap(library)
        expected[Fix.target(Fix.songA, Fix.partA1)] = try Fix.chart(Fix.okAsset2, page: 3)
        expected[Fix.target(Fix.songB)] = try Fix.chart(Fix.okAsset2)
        expected[Fix.target(Fix.songB, Fix.partB1)] = try Fix.chart(Fix.okAsset2)
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.relinkedTargetCount == 3)
        #expect(outcome.clearedTargetCount == 0)
        #expect(outcome.worklist.groups.map(\.asset) == [Fix.staleAsset, Fix.midiAsset])
    }

    @Test
    func relinkTargetTakesTheExplicitAssetAndPage() throws {
        let part = Fix.target(Fix.songB, Fix.partB2)
        let song = Fix.target(Fix.songB)
        let chosen = try Fix.chart(Fix.okAsset2, page: 7)
        let bare = try Fix.chart(Fix.okAsset)
        let outcome = try recover([.relinkTarget(part, to: chosen), .relinkTarget(song, to: bare)])
        var expected = Fix.chartMap(library)
        expected[part] = chosen
        expected[song] = bare
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.relinkedTargetCount == 2)
        #expect(outcome.clearedTargetCount == 0)
        // The other references to the gone asset stay missing; the midi asset has no reference left.
        #expect(outcome.worklist.groups.map(\.asset) == [Fix.staleAsset, Fix.goneAsset])
        #expect(outcome.worklist.group(for: Fix.goneAsset)?.items.count == 2)
    }

    @Test
    func clearAssetRemovesEveryMissingReferenceToTheAsset() throws {
        let outcome = try recover([.clearAsset(Fix.goneAsset)])
        var expected = Fix.chartMap(library)
        expected[Fix.target(Fix.songA, Fix.partA1)] = nil
        expected[Fix.target(Fix.songB)] = nil
        expected[Fix.target(Fix.songB, Fix.partB1)] = nil
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.clearedTargetCount == 3)
        #expect(outcome.relinkedTargetCount == 0)
        #expect(outcome.worklist.groups.map(\.asset) == [Fix.staleAsset, Fix.midiAsset])
    }

    @Test
    func clearTargetRemovesOnlyThatReference() throws {
        let stale = Fix.target(Fix.songA, Fix.partA2)
        let outcome = try recover([.clearTarget(stale)])
        var expected = Fix.chartMap(library)
        expected[stale] = nil
        #expect(Fix.chartMap(outcome.library) == expected)
        #expect(outcome.clearedTargetCount == 1)
        #expect(outcome.relinkedTargetCount == 0)
        #expect(outcome.worklist.group(for: Fix.staleAsset)?.items.map(\.target)
            == [Fix.target(Fix.songA), Fix.target(Fix.songD, Fix.partD1)])
        #expect(outcome.worklist.targetCount == 6)
    }

    @Test
    func relinkAssetRefusesAReplacementThatIsNotAvailable() throws {
        for (replacement, reason) in Self.unavailableReplacements() {
            let missing = try Fix.chart(replacement)
            let decision = ShowRecoveryDecision.relinkAsset(from: Fix.staleAsset, to: replacement)
            let expected = ShowRecoveryRefusal(index: 0, reason: .show(.chartUnavailable(missing, reason)))
            #expect(refusal([decision]) == expected)
        }
    }

    @Test
    func relinkTargetRefusesAReplacementThatIsNotAvailable() throws {
        let target = Fix.target(Fix.songA, Fix.partA2)
        for (replacement, reason) in Self.unavailableReplacements() {
            let chosen = try Fix.chart(replacement, page: 4)
            let expected = ShowRecoveryRefusal(index: 0, reason: .show(.chartUnavailable(chosen, reason)))
            #expect(refusal([.relinkTarget(target, to: chosen)]) == expected)
        }
    }

    @Test
    func relinkingAMissingChartToItselfIsRefusedAsStillMissing() throws {
        let asset = try Fix.chart(Fix.staleAsset)
        let assetRefusal = ShowRecoveryRefusal(index: 0, reason: .show(.chartUnavailable(asset, .contentUnavailable)))
        #expect(refusal([.relinkAsset(from: Fix.staleAsset, to: Fix.staleAsset)]) == assetRefusal)
        let target = Fix.target(Fix.songA, Fix.partA2)
        let again = try Fix.chart(Fix.staleAsset, page: 2)
        let targetRefusal = ShowRecoveryRefusal(index: 0, reason: .show(.chartUnavailable(again, .contentUnavailable)))
        #expect(refusal([.relinkTarget(target, to: again)]) == targetRefusal)
    }

    @Test
    func healthyChartsAreRefusedAsNotMissing() throws {
        let cases: [(ShowRecoveryDecision, AssetID)] = try [
            (.clearAsset(Fix.okAsset), Fix.okAsset),
            (.relinkAsset(from: Fix.okAsset, to: Fix.okAsset2), Fix.okAsset),
            (.clearTarget(Fix.target(Fix.songC)), Fix.okAsset),
            (.relinkTarget(Fix.target(Fix.songA, Fix.partA4), to: Fix.chart(Fix.okAsset2)), Fix.okAsset)
        ]
        for (decision, asset) in cases {
            #expect(refusal([decision]) == ShowRecoveryRefusal(index: 0, reason: .notMissing(asset)))
        }
    }

    @Test
    func unknownTargetsAreRefusedAsNoSuchTarget() throws {
        let okChart = try Fix.chart(Fix.okAsset)
        // An unknown song, an unknown part, a part of another song, a part and a song without a chart.
        let targets = [Fix.target(Fix.unknownSong), Fix.target(Fix.songA, Fix.unknownPart),
                       Fix.target(Fix.songA, Fix.partB1), Fix.target(Fix.songA, Fix.partA3),
                       Fix.target(Fix.songD)]
        for target in targets {
            let expected = ShowRecoveryRefusal(index: 0, reason: .noSuchTarget(target))
            #expect(refusal([.clearTarget(target)]) == expected)
            #expect(refusal([.relinkTarget(target, to: okChart)]) == expected)
        }
    }

    @Test
    func aPartWithoutAChartIsNoSuchTargetEvenWithAHealthySongChart() throws {
        let song = try ShowSong.make(id: Fix.songC, title: "Song C", parts: [Fix.part(Fix.partA1)],
                                     chart: Fix.chart(Fix.okAsset, page: 4))
        let healthy = try ShowLibrary.make(songs: [song])
        let bare = Fix.target(Fix.songC, Fix.partA1)
        let okChart = try Fix.chart(Fix.okAsset)
        let noChart = ShowRecoveryRefusal(index: 0, reason: .noSuchTarget(bare))
        #expect(Fix.refusal(of: [.clearTarget(bare)], in: healthy, catalog: catalog) == noChart)
        #expect(Fix.refusal(of: [.relinkTarget(bare, to: okChart)], in: healthy, catalog: catalog) == noChart)
        // The song's own chart is a slot, but a healthy one, so it is refused for that reason instead.
        let own = Fix.refusal(of: [.clearTarget(Fix.target(Fix.songC))], in: healthy, catalog: catalog)
        #expect(own == ShowRecoveryRefusal(index: 0, reason: .notMissing(Fix.okAsset)))
    }

    @Test
    func assetsWithNoMissingReferenceAreRefusedAsNotMissing() {
        // Not referenced at all (gone2, audio, stale2) or healthy (ok2): nothing to recover.
        for asset in [Fix.goneAsset2, Fix.audioAsset, Fix.staleAsset2, Fix.okAsset2] {
            let expected = ShowRecoveryRefusal(index: 0, reason: .notMissing(asset))
            #expect(refusal([.clearAsset(asset)]) == expected)
            #expect(refusal([.relinkAsset(from: asset, to: Fix.okAsset)]) == expected)
        }
    }

    @Test
    func theSelectionIsCheckedBeforeTheReplacement() throws {
        let missing = try Fix.chart(Fix.goneAsset2)
        let ghost = Fix.target(Fix.unknownSong)
        let healthy = ShowRecoveryRefusal(index: 0, reason: .notMissing(Fix.okAsset))
        #expect(refusal([.relinkAsset(from: Fix.okAsset, to: Fix.goneAsset2)]) == healthy)
        #expect(refusal([.relinkTarget(Fix.target(Fix.songC), to: missing)]) == healthy)
        #expect(refusal([.relinkAsset(from: Fix.goneAsset2, to: Fix.goneAsset2)])
            == ShowRecoveryRefusal(index: 0, reason: .notMissing(Fix.goneAsset2)))
        #expect(refusal([.relinkTarget(ghost, to: missing)])
            == ShowRecoveryRefusal(index: 0, reason: .noSuchTarget(ghost)))
    }

    @Test
    func chartPageBoundsAreEnforcedByTheChartFactory() throws {
        #expect(throws: ShowRefusal.invalidChartPage(0)) { try ChartReference.make(asset: Fix.okAsset, page: 0) }
        #expect(throws: ShowRefusal.invalidChartPage(10_000)) {
            try ChartReference.make(asset: Fix.okAsset, page: 10_000)
        }
        let first = try Fix.chart(Fix.okAsset, page: 1)
        let last = try Fix.chart(Fix.okAsset, page: 9_999)
        let song = Fix.target(Fix.songA)
        let part = Fix.target(Fix.songA, Fix.partA2)
        let outcome = try recover([.relinkTarget(part, to: first), .relinkTarget(song, to: last)])
        #expect(Fix.chartMap(outcome.library)[part] == first)
        #expect(Fix.chartMap(outcome.library)[song] == last)
    }
}
