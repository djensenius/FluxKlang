import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowReadinessTests {
    @Test func aMixedSetlistListsBlockersPerEntryInEntryOrder() throws {
        typealias Fix = Fixture
        let songA = try Fix.song(Fix.songA, chart: Fix.goneAsset, parts: [Fix.part(Fix.partOne, set: Fix.setOne)])
        let songB = try Fix.song(Fix.songB)
        let entries = [Fix.entry(Fix.entryOne, Fix.songA), Fix.entry(Fix.entryTwo, Fix.songB),
                       Fix.entry(Fix.entryThree, Fix.songA)]
        let library = try Fix.library(songs: [songA, songB], entries: entries)
        let facts = try Fix.facts(library, reports: [Fix.report(Fix.setOne, .preparing)], knownSets: [Fix.setOne])
        #expect(facts.worklist.nonChartProblemCount == 0)
        #expect(facts.worklist.targetCount == 1)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        let blockedEntry: [ShowReadinessBlocker] = [
            .actionSetNotReady(Fix.setOne, .preparing), .chartMissing(Fix.target(Fix.songA))
        ]
        #expect(verdict.setlist == Fix.mainList)
        #expect(verdict.entries.map(\.entry) == [Fix.entryOne, Fix.entryTwo, Fix.entryThree])
        #expect(verdict.entries.map(\.song) == [Fix.songA, Fix.songB, Fix.songA])
        #expect(verdict.entries.map(\.blockers) == [blockedEntry, [], blockedEntry])
        #expect(verdict.entries.map(\.isReady) == [false, true, false])
        #expect(verdict.setBlockers.isEmpty)
        #expect(!verdict.isReadyToStart)
    }

    @Test func aSetlistWhoseActionSetsAreReadyAndWhoseChartsAreAvailableIsReadyToStart() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, chart: Fix.okAsset, parts: [
            Fix.part(Fix.partOne, set: Fix.setOne, chart: Fix.okAsset), Fix.part(Fix.partTwo, set: Fix.setTwo)
        ])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let reports = [Fix.report(Fix.setTwo), Fix.report(Fix.setOne)]
        let facts = try Fix.facts(library, reports: reports, knownSets: [Fix.setOne, Fix.setTwo])
        #expect(facts.worklist.isEmpty)
        #expect(facts.worklist.nonChartProblemCount == 0)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[]])
        #expect(verdict.setBlockers.isEmpty)
        #expect(verdict.isReadyToStart)
    }

    @Test func anEmptySetlistIsAVerdictThatIsNotReadyAndNamesTheEmptySetlist() throws {
        let library = try Fixture.library(songs: [], entries: [])
        let verdict = try ShowReadinessEvaluator.evaluate(Fixture.facts(library))
        #expect(verdict.setlist == Fixture.mainList)
        #expect(verdict.entries.isEmpty)
        #expect(verdict.setBlockers == [.emptySetlist])
        #expect(!verdict.isReadyToStart)
    }

    @Test func unresolvedLinksOfTheLibraryBlockASetlistWhoseEntriesAreReady() throws {
        typealias Fix = Fixture
        let broken = try Fix.song(Fix.songOutside, parts: [
            Fix.part(Fix.partOne, patch: Fix.unknownPatch), Fix.part(Fix.partTwo, patch: Fix.unknownPatch)
        ])
        let library = try Fix.library(songs: [broken, Fix.song(Fix.songA)],
                                      entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let facts = try Fix.facts(library)
        #expect(facts.worklist.nonChartProblemCount == 2)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[]])
        #expect(verdict.setBlockers == [.unresolvedLinks(count: 2)])
        #expect(!verdict.isReadyToStart)
    }

    @Test func anEmptySetlistWithUnresolvedLinksListsTheEmptySetlistBeforeTheLinks() throws {
        typealias Fix = Fixture
        let broken = try Fix.song(Fix.songOutside, parts: [
            Fix.part(Fix.partOne, patch: Fix.unknownPatch), Fix.part(Fix.partTwo, patch: Fix.unknownPatch)
        ])
        let library = try Fix.library(songs: [broken], entries: [])
        let facts = try Fix.facts(library)
        #expect(facts.worklist.nonChartProblemCount == 2)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.setBlockers == [.emptySetlist, .unresolvedLinks(count: 2)])
        #expect(!verdict.isReadyToStart)
    }

    @Test func anUnresolvedLinkIsCountedAndNoUnresolvedLinkAddsNoSetBlocker() throws {
        typealias Fix = Fixture
        let oneBroken = try Fix.song(Fix.songOutside, parts: [Fix.part(Fix.partOne, patch: Fix.unknownPatch)])
        let entries = [Fix.entry(Fix.entryOne, Fix.songA)]
        let withOne = try Fix.facts(Fix.library(songs: [oneBroken, Fix.song(Fix.songA)], entries: entries))
        let withNone = try Fix.facts(Fix.library(songs: [Fix.song(Fix.songA)], entries: entries))
        #expect(withOne.worklist.nonChartProblemCount == 1)
        #expect(withNone.worklist.nonChartProblemCount == 0)
        #expect(try ShowReadinessEvaluator.evaluate(withOne).setBlockers == [.unresolvedLinks(count: 1)])
        #expect(try ShowReadinessEvaluator.evaluate(withNone).setBlockers.isEmpty)
    }

    @Test func chartBlockersFollowTheSongChartThenThePartsInPartOrder() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, chart: Fix.goneAsset, parts: [
            Fix.part(Fix.partOne, chart: Fix.goneAsset), Fix.part(Fix.partTwo, chart: Fix.goneAsset2)
        ])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let facts = try Fix.facts(library)
        #expect(facts.worklist.groups.count == 2)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        let expected: [ShowReadinessBlocker] = [
            .chartMissing(Fix.target(Fix.songA)), .chartMissing(Fix.target(Fix.songA, Fix.partOne)),
            .chartMissing(Fix.target(Fix.songA, Fix.partTwo))
        ]
        #expect(verdict.entries.map(\.blockers) == [expected])
    }

    @Test func nineMissingChartSlotsAreListedInSlotOrder() throws {
        typealias Fix = Fixture
        let ids = try (1...8).map { try SongPartID("part.n\($0)") }
        let parts = try ids.map { try Fix.part($0, chart: Fix.goneAsset) }
        let song = try Fix.song(Fix.songA, chart: Fix.goneAsset, parts: parts)
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let verdict = try ShowReadinessEvaluator.evaluate(Fix.facts(library))
        let expected = [ShowReadinessBlocker.chartMissing(Fix.target(Fix.songA))]
            + ids.map { ShowReadinessBlocker.chartMissing(Fix.target(Fix.songA, $0)) }
        #expect(verdict.entries.map(\.blockers) == [expected])
        #expect(expected.count == 9)
    }

    @Test func aSetLinkedByTwoPartsGivesOneBlockerForIt() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, parts: [
            Fix.part(Fix.partOne, set: Fix.setOne), Fix.part(Fix.partTwo, set: Fix.setOne)
        ])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let verdict = try ShowReadinessEvaluator.evaluate(Fix.facts(library, knownSets: [Fix.setOne]))
        #expect(verdict.entries.map(\.blockers) == [[.actionSetUnreported(Fix.setOne)]])
    }

    @Test func aReadyReportOverAFailedMemberIsInconsistentAndAFailedReportIsNotReady() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, parts: [
            Fix.part(Fix.partOne, set: Fix.setOne), Fix.part(Fix.partTwo, set: Fix.setTwo)
        ])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let reports = [Fix.report(Fix.setOne, .ready, memberState: .failed),
                       Fix.report(Fix.setTwo, .failed, memberState: .failed)]
        let facts = try Fix.facts(library, reports: reports, knownSets: [Fix.setOne, Fix.setTwo])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        let expected: [ShowReadinessBlocker] = [
            .actionSetReportInconsistent(Fix.setOne), .actionSetNotReady(Fix.setTwo, .failed)
        ]
        #expect(reports.map(\.isReady) == [true, false])
        #expect(verdict.entries.map(\.blockers) == [expected])
    }

    @Test func aWorklistTargetOfASongOutsideTheSetlistIsIgnored() throws {
        typealias Fix = Fixture
        let outside = try Fix.song(Fix.songOutside, chart: Fix.goneAsset)
        let library = try Fix.library(songs: [outside, Fix.song(Fix.songA, chart: Fix.okAsset)],
                                      entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let facts = try Fix.facts(library)
        #expect(facts.worklist.targetCount == 1)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[]])
        #expect(verdict.isReadyToStart)
    }

    @Test func aWorklistTargetNamingASlotWithoutAChartReferenceIsNotABlocker() throws {
        typealias Fix = Fixture
        let withCharts = try Fix.song(Fix.songA, chart: Fix.goneAsset, parts: [
            Fix.part(Fix.partOne, chart: Fix.goneAsset)
        ])
        let withoutCharts = try Fix.song(Fix.songA, parts: [Fix.part(Fix.partOne)])
        let entries = [Fix.entry(Fix.entryOne, Fix.songA)]
        let worklist = try Fix.facts(Fix.library(songs: [withCharts], entries: entries)).worklist
        #expect(worklist.targetCount == 2)
        let library = try Fix.library(songs: [withoutCharts], entries: entries)
        let facts = ShowReadinessFacts(library: library, setlist: Fix.mainList, reports: [], worklist: worklist)
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[]])
        #expect(verdict.isReadyToStart)
    }
}
