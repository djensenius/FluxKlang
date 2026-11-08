import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowReadinessTests {
    @Test func actionSetBlockersComeBeforeChartBlockersWhenBothSlotKindsAreBlocked() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, chart: Fix.goneAsset, parts: [
            Fix.part(Fix.partOne, chart: Fix.goneAsset), Fix.part(Fix.partTwo, set: Fix.setOne)
        ])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let verdict = try ShowReadinessEvaluator.evaluate(Fix.facts(library, knownSets: [Fix.setOne]))
        let expected: [ShowReadinessBlocker] = [
            .actionSetUnreported(Fix.setOne), .chartMissing(Fix.target(Fix.songA)),
            .chartMissing(Fix.target(Fix.songA, Fix.partOne))
        ]
        #expect(verdict.entries.map(\.blockers) == [expected])
    }

    @Test func actionSetBlockersFollowPartOrderAndARepeatedSetKeepsItsFirstPosition() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, parts: [
            Fix.part(Fix.partTwo, set: Fix.setTwo), Fix.part(Fix.partOne, set: Fix.setOne),
            Fix.part(Fix.partThree, set: Fix.setTwo), Fix.part(Fix.partFour, set: Fix.setThree)
        ])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let facts = try Fix.facts(library, knownSets: [Fix.setOne, Fix.setTwo, Fix.setThree])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        let expected: [ShowReadinessBlocker] = [
            .actionSetUnreported(Fix.setTwo), .actionSetUnreported(Fix.setOne), .actionSetUnreported(Fix.setThree)
        ]
        #expect(verdict.entries.map(\.blockers) == [expected])
    }

    @Test func aSetLinkedByTwoSongsIsBlockedInBothSongsEntries() throws {
        typealias Fix = Fixture
        let first = try Fix.song(Fix.songA, parts: [Fix.part(Fix.partOne, set: Fix.setOne)])
        let second = try Fix.song(Fix.songB, parts: [Fix.part(Fix.partTwo, set: Fix.setOne)])
        let entries = [Fix.entry(Fix.entryOne, Fix.songA), Fix.entry(Fix.entryTwo, Fix.songB)]
        let library = try Fix.library(songs: [first, second], entries: entries)
        let facts = try Fix.facts(library, knownSets: [Fix.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        let blocked: [ShowReadinessBlocker] = [.actionSetUnreported(Fix.setOne)]
        #expect(verdict.entries.map(\.blockers) == [blocked, blocked])
    }

    @Test func aSetWithNoReportIsUnreportedAndIsNotTreatedAsReady() throws {
        let library = try Fixture.oneSongLibrary()
        let facts = try Fixture.facts(library, reports: [], knownSets: [Fixture.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[.actionSetUnreported(Fixture.setOne)]])
        #expect(!verdict.isReadyToStart)
    }

    @Test func everyStateOtherThanReadyBlocksWithItsOwnState() throws {
        let library = try Fixture.oneSongLibrary()
        let states: [ReadinessState] = ReadinessState.allCases.filter { $0 != .ready }
        #expect(states.count == 4)
        for state in states {
            let facts = try Fixture.facts(library, reports: [Fixture.report(Fixture.setOne, state)],
                                          knownSets: [Fixture.setOne])
            let verdict = try ShowReadinessEvaluator.evaluate(facts)
            #expect(verdict.entries.map(\.blockers) == [[.actionSetNotReady(Fixture.setOne, state)]])
        }
    }

    @Test func aReadyReportWithACleanMemberAddsNoBlocker() throws {
        let library = try Fixture.oneSongLibrary()
        let facts = try Fixture.facts(library, reports: [Fixture.report(Fixture.setOne)],
                                      knownSets: [Fixture.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(verdict.entries.map(\.blockers) == [[]])
        #expect(verdict.isReadyToStart)
    }

    @Test func aReadyReportWithANotReadyMemberIsInconsistent() throws {
        let library = try Fixture.oneSongLibrary()
        let forged = Fixture.report(Fixture.setOne, .ready, memberState: .preparing)
        let facts = try Fixture.facts(library, reports: [forged], knownSets: [Fixture.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(forged.isReady)
        #expect(verdict.entries.map(\.blockers) == [[.actionSetReportInconsistent(Fixture.setOne)]])
    }

    @Test func aNotReadyStateIsReportedInsteadOfAnInconsistentMember() throws {
        let library = try Fixture.oneSongLibrary()
        let both = Fixture.report(Fixture.setOne, .invalidated, memberState: .failed)
        let facts = try Fixture.facts(library, reports: [both], knownSets: [Fixture.setOne])
        let verdict = try ShowReadinessEvaluator.evaluate(facts)
        #expect(!both.notReady.isEmpty)
        #expect(verdict.entries.map(\.blockers) == [[.actionSetNotReady(Fixture.setOne, .invalidated)]])
    }

    @Test func reportsForSetsNoEntryReferencesDoNotChangeTheVerdict() throws {
        typealias Fix = Fixture
        let library = try Fix.oneSongLibrary()
        let extras = [Fix.report(Fix.setTwo, .failed), Fix.report(Fix.setThree, .ready, memberState: .failed)]
        let none = try Fix.facts(library, reports: [Fix.report(Fix.setOne)], knownSets: [Fix.setOne])
        let withExtras = try Fix.facts(library, reports: [Fix.report(Fix.setOne)] + extras, knownSets: [Fix.setOne])
        let plain = try ShowReadinessEvaluator.evaluate(none)
        let extended = try ShowReadinessEvaluator.evaluate(withExtras)
        #expect(plain.isReadyToStart)
        #expect(extended == plain)
    }

    @Test func aSongRepeatedInThreeEntriesIsEvaluatedPerEntryInEntryOrder() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, chart: Fix.goneAsset)
        let ready = try Fix.song(Fix.songB)
        let entries = [Fix.entry(Fix.entryThree, Fix.songA), Fix.entry(Fix.entryOne, Fix.songB),
                       Fix.entry(Fix.entryTwo, Fix.songA)]
        let library = try Fix.library(songs: [song, ready], entries: entries)
        let verdict = try ShowReadinessEvaluator.evaluate(Fix.facts(library))
        let blocked: [ShowReadinessBlocker] = [.chartMissing(Fix.target(Fix.songA))]
        #expect(verdict.entries.map(\.entry) == [Fix.entryThree, Fix.entryOne, Fix.entryTwo])
        #expect(verdict.entries.map(\.song) == [Fix.songA, Fix.songB, Fix.songA])
        #expect(verdict.entries.map(\.blockers) == [blocked, [], blocked])
    }

    @Test func aSongWithNoPartsNoChartAndNoActionSetHasNoBlockersAndIsReady() throws {
        let library = try Fixture.library(songs: [Fixture.song(Fixture.songA)],
                                          entries: [Fixture.entry(Fixture.entryOne, Fixture.songA)])
        let verdict = try ShowReadinessEvaluator.evaluate(Fixture.facts(library))
        let entry = try #require(verdict.entries.first)
        #expect(entry.blockers.isEmpty)
        #expect(entry.isReady)
        #expect(verdict.isReadyToStart)
    }

    @Test func readyToStartNeedsNoSetBlockerAndNoEntryBlockerAcrossFourLibraries() throws {
        typealias Fix = Fixture
        let broken = try Fix.song(Fix.songOutside, parts: [Fix.part(Fix.partOne, patch: Fix.unknownPatch)])
        let charted = try Fix.song(Fix.songB, chart: Fix.goneAsset)
        let clean = try Fix.song(Fix.songA)
        let entryA = [Fix.entry(Fix.entryOne, Fix.songA)]
        let entryB = [Fix.entry(Fix.entryOne, Fix.songB)]
        let allClear = try ShowReadinessEvaluator.evaluate(Fix.facts(Fix.library(songs: [clean], entries: entryA)))
        let setBlockerOnly = try ShowReadinessEvaluator.evaluate(
            Fix.facts(Fix.library(songs: [clean, broken], entries: entryA)))
        let entryBlockerOnly = try ShowReadinessEvaluator.evaluate(
            Fix.facts(Fix.library(songs: [charted], entries: entryB)))
        let both = try ShowReadinessEvaluator.evaluate(
            Fix.facts(Fix.library(songs: [charted, broken], entries: entryB)))
        #expect(allClear.isReadyToStart)
        #expect(!setBlockerOnly.isReadyToStart)
        #expect(!entryBlockerOnly.isReadyToStart)
        #expect(!both.isReadyToStart)
        #expect(setBlockerOnly.setBlockers == [.unresolvedLinks(count: 1)])
        #expect(setBlockerOnly.entries.map(\.isReady) == [true])
        #expect(entryBlockerOnly.setBlockers.isEmpty)
        #expect(entryBlockerOnly.entries.map(\.isReady) == [false])
    }

    @Test func twoEvaluationsOfTheSameFactsGiveEqualVerdicts() throws {
        typealias Fix = Fixture
        let song = try Fix.song(Fix.songA, chart: Fix.goneAsset, parts: [Fix.part(Fix.partOne, set: Fix.setOne)])
        let library = try Fix.library(songs: [song], entries: [Fix.entry(Fix.entryOne, Fix.songA)])
        let facts = try Fix.facts(library, reports: [Fix.report(Fix.setOne, .failed)], knownSets: [Fix.setOne])
        let first = try ShowReadinessEvaluator.evaluate(facts)
        let second = try ShowReadinessEvaluator.evaluate(facts)
        let counts: [Int] = first.entries.map(\.blockers).map(\.count)
        #expect(first == second)
        #expect(counts == [2])
    }
}
