// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowResumePlannerTests.Fixture {
    static let e6 = SetlistEntryID(validated: "ent.6")

    /// The standard entries over songs whose parts are chosen; B and D keep their parts.
    static func library(partsOfA: [SongPartID], partsOfC: [SongPartID] = [],
                        title: String = "Song") throws -> ShowLibrary {
        let songs = [try song(songA, title: title, parts: partsOfA), try song(songB, title: title, parts: [b1, b2]),
                     try song(songC, title: title, parts: partsOfC), try song(songD, title: title, parts: [d1])]
        return try library(main: standardEntries(), songs: songs, title: title)
    }

    /// The point captured at e2, part b2, in the standard library.
    static func secondEntrySpec() -> Spec {
        var spec = Spec()
        spec.entry = e2
        spec.song = songB
        spec.part = b2
        spec.ordinal = 1
        spec.previous = e1
        spec.next = e3
        return spec
    }
}

extension ShowResumePlannerTests {
    private func confirmed(_ target: ShowPosition, _ jump: ShowNavigationCommand,
                           _ basis: ShowResumeBasis) -> ShowResumeDecision {
        .confirm(ShowResumeProposal(target: target, jump: jump, basis: basis))
    }

    // MARK: - Exact

    @Test func anUnchangedLibraryResumesExactlyAtTheSavedPartWithoutTheOperator() throws {
        let library = try Fixture.standardLibrary()
        let decision = try ShowResumePlanner.plan(Fixture.Spec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a2)
        let jump = ShowNavigationCommand.jump(Fixture.e3, Fixture.a2)
        let expected = ShowResumeDecision.exact(target: target, jump: jump)
        #expect(decision == expected)
        #expect(!decision.needsOperator)
        #expect(decision.jumpCommand == jump)
        #expect(decision.target == target)
    }

    @Test func aPartlessSongThatStillHasNoPartsResumesExactlyWithAJumpToNoPart() throws {
        var spec = Fixture.Spec()
        spec.entry = Fixture.e4
        spec.song = Fixture.songC
        spec.part = nil
        spec.ordinal = 3
        spec.previous = Fixture.e3
        spec.next = Fixture.e5
        let library = try Fixture.standardLibrary()
        let decision = try ShowResumePlanner.plan(spec.point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e4, part: nil)
        let jump = ShowNavigationCommand.jump(Fixture.e4, nil)
        let expected = ShowResumeDecision.exact(target: target, jump: jump)
        #expect(decision == expected)
    }

    @Test func aReorderedSetlistResumesExactlyByEntryIDAlthoughTheSavedOrdinalAndNeighboursNoLongerMatch() throws {
        let order = [Fixture.e3, Fixture.e1, Fixture.e5, Fixture.e2, Fixture.e4]
        let byID = Dictionary(uniqueKeysWithValues: Fixture.standardEntries().map { ($0.id, $0) })
        let reordered = order.compactMap { byID[$0] }
        let library = try Fixture.library(main: reordered)
        let decision = try ShowResumePlanner.plan(Fixture.Spec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a2)
        let expected = ShowResumeDecision.exact(target: target, jump: .jump(Fixture.e3, Fixture.a2))
        #expect(reordered.count == 5)
        #expect(decision == expected)
    }

    @Test func aSongPlayedByTwoEntriesResumesAtTheSavedEntryAndNotAtTheFirstEntryOfThatSong() throws {
        let library = try Fixture.standardLibrary()
        let decision = try ShowResumePlanner.plan(Fixture.Spec().point, in: library)
        let firstEntryOfTheSong = ShowPosition(setlist: Fixture.main, entry: Fixture.e1, part: Fixture.a2)
        let savedEntry = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a2)
        #expect(decision.target == savedEntry)
        #expect(decision.target != firstEntryOfTheSong)
    }

    // MARK: - Entry gone

    @Test func aGoneEntryProposesItsNextEntryAtThatEntrysFirstPartNotTheSavedPart() throws {
        let library = try Fixture.withoutEntries([Fixture.e2])
        let decision = try ShowResumePlanner.plan(Fixture.secondEntrySpec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a1)
        let expected = confirmed(target, .jump(Fixture.e3, nil), .entryMissingNext(Fixture.e2))
        #expect(decision == expected)
        #expect(decision.needsOperator)
    }

    @Test func aGoneEntryWhoseNextEntryIsAlsoGoneProposesItsPreviousEntry() throws {
        let library = try Fixture.withoutEntries([Fixture.e2, Fixture.e3])
        let decision = try ShowResumePlanner.plan(Fixture.secondEntrySpec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e1, part: Fixture.a1)
        let expected = confirmed(target, .jump(Fixture.e1, nil), .entryMissingPrevious(Fixture.e2))
        #expect(decision == expected)
    }

    @Test func aGoneEntryWhoseNeighboursAreBothGoneProposesTheEntryAtTheSavedIndex() throws {
        let extra = Fixture.entry(Fixture.e6, Fixture.songA)
        let kept = [Fixture.entry(Fixture.e4, Fixture.songC), Fixture.entry(Fixture.e5, Fixture.songD), extra]
        let library = try Fixture.library(main: kept)
        let decision = try ShowResumePlanner.plan(Fixture.secondEntrySpec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e5, part: Fixture.d1)
        let expected = confirmed(target, .jump(Fixture.e5, nil), .entryMissingOrdinal(Fixture.e2))
        #expect(decision == expected)
    }

    @Test func aValidOrdinalBeyondTheEntryCountClampsToTheLastEntry() throws {
        let kept = [Fixture.entry(Fixture.e4, Fixture.songC), Fixture.entry(Fixture.e5, Fixture.songD)]
        let library = try Fixture.library(main: kept)
        var spec = Fixture.secondEntrySpec()
        spec.previous = nil
        spec.next = nil
        spec.ordinal = 200
        let far = try ShowResumePlanner.plan(spec.point, in: library)
        spec.ordinal = 255
        let farthest = try ShowResumePlanner.plan(spec.point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e5, part: Fixture.d1)
        let expected = confirmed(target, .jump(Fixture.e5, nil), .entryMissingOrdinal(Fixture.e2))
        #expect(far == expected)
        #expect(farthest == expected)
    }

    @Test func aSingleEntrySetlistProposesThatEntryForAnyValidOrdinal() throws {
        let library = try Fixture.library(main: [Fixture.entry(Fixture.e5, Fixture.songD)])
        var spec = Fixture.secondEntrySpec()
        spec.previous = nil
        spec.next = nil
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e5, part: Fixture.d1)
        let expected = confirmed(target, .jump(Fixture.e5, nil), .entryMissingOrdinal(Fixture.e2))
        for ordinal in 0...ShowResumePoint.maximumOrdinal {
            spec.ordinal = ordinal
            let decision = try ShowResumePlanner.plan(spec.point, in: library)
            #expect(decision == expected)
        }
    }

    @Test func anEmptiedSetlistIsBlockedAsEmptyWhateverTheOrdinal() throws {
        let library = try Fixture.library(main: [])
        var spec = Fixture.Spec()
        let expected = ShowResumeDecision.blocked(.setlistEmpty(Fixture.main))
        for ordinal in 0...ShowResumePoint.maximumOrdinal {
            spec.ordinal = ordinal
            let decision = try ShowResumePlanner.plan(spec.point, in: library)
            #expect(decision == expected)
        }
        let blocked = try ShowResumePlanner.plan(spec.point, in: library)
        #expect(blocked.jumpCommand == nil)
        #expect(blocked.target == nil)
    }

    @Test func aRemovedSetlistIsBlockedAsRemovedAndNotAsEmpty() throws {
        let library = try Fixture.standardLibrary().removingSetlist(Fixture.main)
        let decision = try ShowResumePlanner.plan(Fixture.Spec().point, in: library)
        let expected = ShowResumeDecision.blocked(.setlistRemoved(Fixture.main))
        #expect(decision == expected)
        #expect(decision.needsOperator)
    }

    @Test func aGoneEntrysNextOrPreviousNeighbourInAnotherSetlistIsSkipped() throws {
        let library = try Fixture.withoutEntries([Fixture.e2])
        var spec = Fixture.secondEntrySpec()
        spec.next = Fixture.f1
        let previousWins = try ShowResumePlanner.plan(spec.point, in: library)
        spec.previous = Fixture.f2
        let ordinalWins = try ShowResumePlanner.plan(spec.point, in: library)
        let previousTarget = ShowPosition(setlist: Fixture.main, entry: Fixture.e1, part: Fixture.a1)
        let ordinalTarget = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a1)
        let expectedPrevious = confirmed(previousTarget, .jump(Fixture.e1, nil), .entryMissingPrevious(Fixture.e2))
        let expectedOrdinal = confirmed(ordinalTarget, .jump(Fixture.e3, nil), .entryMissingOrdinal(Fixture.e2))
        #expect(previousWins == expectedPrevious)
        #expect(ordinalWins == expectedOrdinal)
    }

    // MARK: - Song and part

    @Test func anEntryThatNowPlaysAnotherSongIsBlockedAsSongChangedForAHandBuiltPoint() throws {
        var spec = Fixture.Spec()
        spec.song = Fixture.songB
        let library = try Fixture.standardLibrary()
        let decision = try ShowResumePlanner.plan(spec.point, in: library)
        let expected = ShowResumeDecision.blocked(.songChanged(Fixture.e3))
        #expect(decision == expected)
        #expect(decision.jumpCommand == nil)
    }

    @Test func aChangedSongIsBlockedBeforeAMissingPartIsConsidered() throws {
        var spec = Fixture.Spec()
        spec.song = Fixture.songB
        spec.part = Fixture.unknownPart
        let library = try Fixture.standardLibrary()
        let decision = try ShowResumePlanner.plan(spec.point, in: library)
        let expected = ShowResumeDecision.blocked(.songChanged(Fixture.e3))
        #expect(decision == expected)
    }

    @Test func aMissingPartIsConfirmedAtTheFirstPartWithAJumpToNoPartAndTheSavedPartInTheBasis() throws {
        let library = try Fixture.library(partsOfA: [Fixture.a1, Fixture.a3])
        let decision = try ShowResumePlanner.plan(Fixture.Spec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a1)
        let expected = confirmed(target, .jump(Fixture.e3, nil), .partMissing(Fixture.a2))
        #expect(decision == expected)
        #expect(decision.needsOperator)
    }

    @Test func aPartlessSongThatGainedPartsIsConfirmedAsPartsAddedAtItsFirstPart() throws {
        var spec = Fixture.Spec()
        spec.entry = Fixture.e4
        spec.song = Fixture.songC
        spec.part = nil
        spec.ordinal = 3
        spec.previous = Fixture.e3
        spec.next = Fixture.e5
        let library = try Fixture.library(partsOfA: [Fixture.a1, Fixture.a2, Fixture.a3], partsOfC: [Fixture.c1])
        let decision = try ShowResumePlanner.plan(spec.point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e4, part: Fixture.c1)
        let expected = confirmed(target, .jump(Fixture.e4, nil), .partsAdded)
        #expect(decision == expected)
    }

    @Test func aSavedPartOfASongThatNowHasNoPartsIsConfirmedWithNoPart() throws {
        let library = try Fixture.library(partsOfA: [])
        let decision = try ShowResumePlanner.plan(Fixture.Spec().point, in: library)
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: nil)
        let expected = confirmed(target, .jump(Fixture.e3, nil), .partMissing(Fixture.a2))
        #expect(decision == expected)
    }

    // MARK: - Decision shape and inputs

    @Test func onlyAnExactDecisionNeedsNoOperatorAndOnlyABlockedDecisionHasNoJump() {
        let target = ShowPosition(setlist: Fixture.main, entry: Fixture.e3, part: Fixture.a2)
        let jump = ShowNavigationCommand.jump(Fixture.e3, Fixture.a2)
        let proposal = ShowResumeProposal(target: target, jump: jump, basis: .partsAdded)
        let exact = ShowResumeDecision.exact(target: target, jump: jump)
        let confirm = ShowResumeDecision.confirm(proposal)
        let setlistBlock = ShowResumeDecision.blocked(.setlistRemoved(Fixture.main))
        let emptyBlock = ShowResumeDecision.blocked(.setlistEmpty(Fixture.main))
        let songBlock = ShowResumeDecision.blocked(.songChanged(Fixture.e3))
        let operatorFlags = [exact, confirm, setlistBlock, emptyBlock, songBlock].map(\.needsOperator)
        let jumps = [exact, confirm, setlistBlock, emptyBlock, songBlock].map(\.jumpCommand)
        let targets = [exact, confirm, setlistBlock, emptyBlock, songBlock].map(\.target)
        let expectedFlags = [false, true, true, true, true]
        let expectedJumps: [ShowNavigationCommand?] = [jump, jump, nil, nil, nil]
        let expectedTargets: [ShowPosition?] = [target, target, nil, nil, nil]
        #expect(operatorFlags == expectedFlags)
        #expect(jumps == expectedJumps)
        #expect(targets == expectedTargets)
    }

    @Test func librariesThatDifferOnlyInTitlesGiveEqualDecisions() throws {
        let plain = try Fixture.library(partsOfA: [Fixture.a1, Fixture.a3])
        let retitled = try Fixture.library(partsOfA: [Fixture.a1, Fixture.a3], title: "Another")
        let unchangedPlain = try Fixture.standardLibrary()
        let retitledSongs = try Fixture.standardSongs(title: "Another")
        let unchangedRetitled = try Fixture.library(main: Fixture.standardEntries(), songs: retitledSongs,
                                                    title: "Another")
        let point = Fixture.Spec().point
        let confirmPlain = try ShowResumePlanner.plan(point, in: plain)
        let confirmRetitled = try ShowResumePlanner.plan(point, in: retitled)
        let exactPlain = try ShowResumePlanner.plan(point, in: unchangedPlain)
        let exactRetitled = try ShowResumePlanner.plan(point, in: unchangedRetitled)
        #expect(confirmPlain == confirmRetitled)
        #expect(exactPlain == exactRetitled)
        #expect(confirmPlain != exactPlain)
    }
}
// swiftlint:enable identifier_name
