import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private enum StageResumeError: Error {
    case notAnOffer
    case notMoved
}

/// The main library plays e1 song.a, e2 song.b, e3 song.a, e4 song.c (parts a1 a2 a3, b1 b2, none).
private enum StageResumeKit {
    typealias Fix = ShowStageFixture

    static func point(entry: String, song: SongID, part: String?, ordinal: Int, previous: String? = nil,
                      next: String? = nil, setlist: SetlistID = Fix.list) -> ShowResumePoint {
        ShowResumePoint(setlist: setlist, entry: Fix.entryID(entry), song: song, part: part.map { Fix.partID($0) },
                        entryOrdinal: ordinal, previousEntry: previous.map { Fix.entryID($0) },
                        nextEntry: next.map { Fix.entryID($0) })
    }

    /// The standard point: entry e3 of song A at part a2.
    static func standard(part: String? = "a2") -> ShowResumePoint {
        point(entry: "e3", song: Fix.songA, part: part, ordinal: 2, previous: "e2", next: "e4")
    }

    static func resume(_ point: ShowResumePoint?, cursor: ShowCursor, library: ShowLibrary) throws -> ShowStageResume? {
        try ShowStageProjection.make(library: library, cursor: cursor, catalog: Fix.catalog(), resume: point).resume
    }

    static func offer(_ resume: ShowStageResume?) throws -> ShowStageResumeOffer {
        guard case let .offer(offer)? = resume else { throw StageResumeError.notAnOffer }
        return offer
    }

    static func library(songs shapes: [SongID: [String]], entries: [SetlistEntry]) throws -> ShowLibrary {
        try Fix.library(songs: Fix.songs(shapes), entries: entries)
    }

    static var mainEntries: [SetlistEntry] {
        [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB), Fix.entry("e3", Fix.songA),
         Fix.entry("e4", Fix.songC)]
    }
}

extension ShowStageProjectionTests {
    private typealias Kit = StageResumeKit

    @Test
    func anOmittedResumeParameterAndANilPointGiveEqualProjectionsWithNoResume() throws {
        let library = try Fix.mainLibrary()
        let catalog = try Fix.catalog()
        let cursor = try Fix.cursor(library, at: "e2", part: "b1")
        let omitted = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog)
        let explicit = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog, resume: nil)
        #expect(omitted == explicit)
        #expect(omitted.resume == nil)
        #expect(explicit.resume == nil)
    }

    @Test
    func anExactPlanOffersTheSavedLineWithItsOwnJumpAndNoBasis() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let offer = try Kit.offer(Kit.resume(Kit.standard(), cursor: cursor, library: library))
        #expect(offer.line.position == Fix.pos("e3", "a2"))
        #expect(offer.line.songNumber == 3)
        #expect(offer.line.partNumber == 2)
        #expect(offer.line.startsNewSong)
        #expect(offer.jump == .jump(Fix.entryID("e3"), Fix.partID("a2")))
        #expect(offer.basis == nil)
    }

    @Test
    func anExactPlanAtTheCursorsWholePositionOffersNothingButAnotherPartOfTheEntryIsStillOffered() throws {
        let library = try Fix.mainLibrary()
        let atTarget = try Fix.cursor(library, at: "e3", part: "a2")
        #expect(try Kit.resume(Kit.standard(), cursor: atTarget, library: library) == nil)
        let sameEntry = try Fix.cursor(library, at: "e3", part: "a1")
        let offer = try Kit.offer(Kit.resume(Kit.standard(), cursor: sameEntry, library: library))
        #expect(offer.line.position == Fix.pos("e3", "a2"))
        #expect(!offer.line.startsNewSong)
        #expect(offer.basis == nil)
    }

    @Test
    func aMissingSavedPartOffersTheFirstPartOfTheEntryWithThatBasis() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let point = Kit.standard(part: "a9")
        let offer = try Kit.offer(Kit.resume(point, cursor: cursor, library: library))
        #expect(offer.line.position == Fix.pos("e3", "a1"))
        #expect(offer.jump == .jump(Fix.entryID("e3"), nil))
        #expect(offer.basis == .partMissing(Fix.partID("a9")))
    }

    @Test
    func aSongThatGainedPartsOffersItsFirstPartWithThePartsAddedBasis() throws {
        let library = try Kit.library(songs: [Fix.songA: ["a1"], Fix.songB: ["b1"], Fix.songC: ["c1"]],
                                      entries: Kit.mainEntries)
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let point = Kit.point(entry: "e4", song: Fix.songC, part: nil, ordinal: 3, previous: "e3")
        let offer = try Kit.offer(Kit.resume(point, cursor: cursor, library: library))
        #expect(offer.line.position == Fix.pos("e4", "c1"))
        #expect(offer.jump == .jump(Fix.entryID("e4"), nil))
        #expect(offer.basis == .partsAdded)
    }

    @Test
    func aMissingEntryOffersItsNextNeighbourWhenThatOneRemains() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let point = Kit.point(entry: "e9", song: Fix.songA, part: "a2", ordinal: 2, previous: "e2", next: "e4")
        let offer = try Kit.offer(Kit.resume(point, cursor: cursor, library: library))
        #expect(offer.line.position == Fix.pos("e4", nil))
        #expect(offer.jump == .jump(Fix.entryID("e4"), nil))
        #expect(offer.basis == .entryMissingNext(Fix.entryID("e9")))
    }

    @Test
    func aMissingEntryWhoseNextNeighbourIsAlsoMissingOffersThePreviousNeighbour() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let point = Kit.point(entry: "e9", song: Fix.songA, part: "a2", ordinal: 2, previous: "e2", next: "e8")
        let offer = try Kit.offer(Kit.resume(point, cursor: cursor, library: library))
        #expect(offer.line.position == Fix.pos("e2", "b1"))
        #expect(offer.jump == .jump(Fix.entryID("e2"), nil))
        #expect(offer.basis == .entryMissingPrevious(Fix.entryID("e9")))
    }

    @Test
    func aMissingEntryWithNoNeighbourLeftOffersTheSavedIndexClampedToTheLastEntry() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let inside = Kit.point(entry: "e9", song: Fix.songA, part: "a2", ordinal: 2, previous: "e7", next: "e8")
        let offer = try Kit.offer(Kit.resume(inside, cursor: cursor, library: library))
        #expect(offer.line.position == Fix.pos("e3", "a1"))
        #expect(offer.basis == .entryMissingOrdinal(Fix.entryID("e9")))
        let beyond = Kit.point(entry: "e9", song: Fix.songA, part: "a2", ordinal: 255, previous: "e7", next: "e8")
        let clamped = try Kit.offer(Kit.resume(beyond, cursor: cursor, library: library))
        #expect(clamped.line.position == Fix.pos("e4", nil))
        #expect(clamped.line.songNumber == 4)
        #expect(clamped.basis == .entryMissingOrdinal(Fix.entryID("e9")))
    }

    @Test
    func aConfirmWhoseTargetIsTheCursorsPositionOffersNothing() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e3", part: "a1")
        let missingPart = Kit.standard(part: "a9")
        #expect(try Kit.resume(missingPart, cursor: cursor, library: library) == nil)
        let missingEntry = Kit.point(entry: "e9", song: Fix.songA, part: "a2", ordinal: 2, previous: "e7", next: "e8")
        #expect(try Kit.resume(missingEntry, cursor: cursor, library: library) == nil)
    }

    @Test
    func aRemovedSetlistIsBlockedForAStaleCursor() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let gone = try ShowLibrary.make(songs: library.songs, setlists: [])
        let projection = try ShowStageProjection.make(library: gone, cursor: cursor, catalog: Fix.catalog(),
                                                      resume: Kit.standard())
        #expect(projection.cursorState == .stale(.setlistRemoved(Fix.list)))
        #expect(projection.resume == .blocked(.setlistRemoved(Fix.list)))
    }

    @Test
    func anEmptiedSetlistIsBlockedAsEmptyForAStaleCursor() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e3", part: "a2")
        let emptied = try ShowSetlist.make(id: Fix.list, title: "Stage", entries: [])
        let bare = try ShowLibrary.make(songs: library.songs, setlists: [emptied])
        let projection = try ShowStageProjection.make(library: bare, cursor: cursor, catalog: Fix.catalog(),
                                                      resume: Kit.standard())
        #expect(projection.cursorState == .stale(.entryRemoved(Fix.entryID("e3"))))
        #expect(projection.resume == .blocked(.setlistEmpty(Fix.list)))
    }

    @Test
    func aSavedEntryThatNowPlaysAnotherSongIsBlockedEvenOnAPositionedCursor() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let point = Kit.point(entry: "e3", song: Fix.songB, part: "b1", ordinal: 2, previous: "e2", next: "e4")
        let projection = try ShowStageProjection.make(library: library, cursor: cursor, catalog: Fix.catalog(),
                                                      resume: point)
        #expect(projection.cursorState == .positioned)
        #expect(projection.resume == .blocked(.songChanged(Fix.entryID("e3"))))
    }

    @Test
    func aPointThePlannerRefusesIsInvalidWhateverTheRefusalAndTheProjectionStillRenders() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let high = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 256)
        let low = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: -1)
        let itself = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 2, previous: "e3")
        let equal = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 2, previous: "e2", next: "e2")
        for point in [high, low, itself, equal] {
            let projection = try ShowStageProjection.make(library: library, cursor: cursor,
                                                          catalog: Fix.catalog(), resume: point)
            #expect(projection.resume == .invalidPoint)
            #expect(projection.cursorState == .positioned)
            #expect(projection.now?.position == Fix.pos("e1", "a1"))
        }
        let last = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 255)
        #expect(try Kit.resume(last, cursor: cursor, library: library) != .invalidPoint)
    }

    @Test
    func aPointForAnotherSetlistOffersNothingWhateverItsPlan() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let other = SetlistID(validated: "set.other")
        let valid = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 2, setlist: other)
        #expect(try Kit.resume(valid, cursor: cursor, library: library) == nil)
        let gone = try ShowLibrary.make(songs: library.songs, setlists: [])
        #expect(try Kit.resume(valid, cursor: cursor, library: gone) == nil)
    }

    @Test
    func aPointThatIsForAnotherSetlistAndInvalidIsIgnoredBeforeItIsValidated() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let both = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 256,
                             setlist: SetlistID(validated: "set.other"))
        #expect(try Kit.resume(both, cursor: cursor, library: library) == nil)
        let invalidOnly = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: 256)
        #expect(try Kit.resume(invalidOnly, cursor: cursor, library: library) == .invalidPoint)
    }

    @Test
    func aPointThatIsInvalidAndForARemovedSetlistIsInvalidBeforeItIsBlocked() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let gone = try ShowLibrary.make(songs: library.songs, setlists: [])
        let both = Kit.point(entry: "e3", song: Fix.songA, part: "a2", ordinal: -1)
        #expect(try Kit.resume(both, cursor: cursor, library: gone) == .invalidPoint)
        #expect(try Kit.resume(Kit.standard(), cursor: cursor, library: gone) == .blocked(.setlistRemoved(Fix.list)))
    }

    @Test
    func theOfferedJumpAppliedToAStaleCursorLandsOnTheOfferedLineAndTheOfferGoesAway() throws {
        let library = try Fix.mainLibrary()
        let catalog = try Fix.catalog()
        var cursor = try Fix.cursor(library, at: "e3", part: "a3")
        let point = try ShowResumePoint.capture(from: cursor, in: library)
        let shorter = try Kit.library(songs: [Fix.songA: ["a1", "a2"], Fix.songB: ["b1", "b2"], Fix.songC: []],
                                      entries: Kit.mainEntries)
        let before = try ShowStageProjection.make(library: shorter, cursor: cursor, catalog: catalog, resume: point)
        #expect(before.cursorState == .stale(.partRemoved(Fix.partID("a3"))))
        let offer = try Kit.offer(before.resume)
        #expect(offer.basis == .partMissing(Fix.partID("a3")))
        let input = ShowNavigationInput(offer.jump, source: Fix.foot, sequence: 2, tick: 0)
        let result = try cursor.navigate(input, in: shorter, catalog: catalog)
        guard case let .moved(stop) = result else { throw StageResumeError.notMoved }
        #expect(stop.position == offer.line.position)
        let after = try ShowStageProjection.make(library: shorter, cursor: cursor, catalog: catalog, resume: point)
        #expect(after.cursorState == .positioned)
        #expect(after.now?.position == offer.line.position)
        #expect(after.resume == nil)
    }

    @Test
    func theOfferedJumpAppliedToAMovedCursorLandsOnTheSavedPositionAndTheOfferGoesAway() throws {
        let library = try Fix.mainLibrary()
        let catalog = try Fix.catalog()
        let saved = try Fix.cursor(library, at: "e3", part: "a2")
        let point = try ShowResumePoint.capture(from: saved, in: library)
        var cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let before = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog, resume: point)
        let offer = try Kit.offer(before.resume)
        #expect(offer.basis == nil)
        let input = ShowNavigationInput(offer.jump, source: Fix.foot, sequence: 2, tick: 0)
        _ = try cursor.navigate(input, in: library, catalog: catalog)
        let after = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog, resume: point)
        #expect(after.now?.position == Fix.pos("e3", "a2"))
        #expect(after.now?.songTitle == offer.line.songTitle)
        #expect(after.resume == nil)
    }

    @Test
    func anOfferChangesNoProjectionFieldButResume() throws {
        let library = try Fix.mainLibrary()
        let catalog = try Fix.catalog()
        let cursor = try Fix.cursor(library, at: "e2", part: "b2")
        let plain = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog)
        let offered = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog,
                                                   resume: Kit.standard())
        #expect(offered.resume != nil)
        #expect(offered.setlist == plain.setlist)
        #expect(offered.setlistTitle == plain.setlistTitle)
        #expect(offered.entryCount == plain.entryCount)
        #expect(offered.cursorState == plain.cursorState)
        #expect(offered.now == plain.now)
        for destination in ShowStageDestination.allCases {
            #expect(offered.line(for: destination) == plain.line(for: destination))
        }
    }

    @Test
    func theNineBasisBlockAndInvalidPhrasesHaveTheirExactWordingAndAreDistinct() {
        let part = Fix.partID("a9")
        let entry = Fix.entryID("e9")
        let phrases = [
            ShowStageFormat.basis(.partMissing(part)), ShowStageFormat.basis(.partsAdded),
            ShowStageFormat.basis(.entryMissingNext(entry)), ShowStageFormat.basis(.entryMissingPrevious(entry)),
            ShowStageFormat.basis(.entryMissingOrdinal(entry)), ShowStageFormat.block(.setlistRemoved(Fix.list)),
            ShowStageFormat.block(.setlistEmpty(Fix.list)), ShowStageFormat.block(.songChanged(entry)),
            ShowStageFormat.resume(.invalidPoint)
        ]
        #expect(phrases[0] == "The saved part was removed.")
        #expect(phrases[1] == "The song gained parts since the position was saved.")
        #expect(phrases[2] == "The saved song entry was removed; the next entry is proposed.")
        #expect(phrases[3] == "The saved song entry was removed; the previous entry is proposed.")
        let ordinal = "The saved song entry was removed; the entry at the same place in the setlist is proposed."
        #expect(phrases[4] == ordinal)
        #expect(phrases[5] == "Cannot resume: the setlist was removed.")
        #expect(phrases[6] == "Cannot resume: the setlist is empty.")
        #expect(phrases[7] == "Cannot resume: the saved song entry now plays another song.")
        #expect(phrases[8] == "Cannot resume: the saved position is not valid.")
        #expect(Set(phrases).count == 9)
        #expect(ShowStageFormat.resume(.blocked(.setlistEmpty(Fix.list))) == phrases[6])
    }

    @Test
    func anExactOfferAndAConfirmOfferAreSpokenAsOneFullSentenceEach() throws {
        let library = try Fix.mainLibrary()
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let exact = try Kit.resume(Kit.standard(), cursor: cursor, library: library)
        let spokenExact = try ShowStageFormat.resume(#require(exact))
        let expectedExact = "Resume at the saved position. Song 3 of 4, Song song.a. Part 2 of 3, Part a2. "
            + "No chart. No link problems. Accept to jump there."
        #expect(spokenExact == expectedExact)
        let point = Kit.point(entry: "e9", song: Fix.songA, part: "a2", ordinal: 2, previous: "e7", next: "e8")
        let confirm = try Kit.resume(point, cursor: cursor, library: library)
        let spokenConfirm = try ShowStageFormat.resume(#require(confirm))
        let expectedConfirm = "Resume at a nearby position. The saved song entry was removed; the entry at the same "
            + "place in the setlist is proposed. Song 3 of 4, Song song.a. Part 1 of 3, Part a1. No chart. "
            + "No link problems. Accept to jump there."
        #expect(spokenConfirm == expectedConfirm)
        #expect(spokenExact != spokenConfirm)
    }

    @Test
    func aTitleThatQuotesAResumePhraseChangesOnlyTheTitleTextOfTheOffer() throws {
        let tricky = "Resume at a nearby position. The saved part was removed."
        let song = try ShowSong.make(id: Fix.songA, title: tricky, parts: [Fix.part("a1"), Fix.part("a2")])
        let library = try Fix.library(songs: [song], entries: [Fix.entry("e1", Fix.songA)])
        let cursor = try Fix.cursor(library, at: "e1", part: "a1")
        let point = Kit.point(entry: "e1", song: Fix.songA, part: "a2", ordinal: 0)
        let resume = try Kit.resume(point, cursor: cursor, library: library)
        let offer = try Kit.offer(resume)
        #expect(offer.basis == nil)
        let spoken = try ShowStageFormat.resume(#require(resume))
        let expected = "Resume at the saved position. Song 1 of 1, \(tricky). Part 2 of 2, Part a2. No chart. "
            + "No link problems. Accept to jump there."
        #expect(spoken == expected)
    }

    @Test
    func aOneEntrySetlistAndA256EntrySetlistOfferTheirSavedLines() throws {
        let single = try Kit.library(songs: [Fix.songD: ["d1", "d2"]], entries: [Fix.entry("e1", Fix.songD)])
        let singleCursor = try Fix.cursor(single, at: "e1", part: "d1")
        let singlePoint = Kit.point(entry: "e1", song: Fix.songD, part: "d2", ordinal: 0)
        let one = try Kit.offer(Kit.resume(singlePoint, cursor: singleCursor, library: single))
        #expect(one.line.songNumber == 1)
        #expect(one.line.songCount == 1)
        #expect(one.line.partNumber == 2)
        let songs = try Fix.songs([Fix.songA: (0..<ShowLimits.maximumPartsPerSong).map { "p\($0)" }, Fix.songB: ["q0"]])
        var entries: [SetlistEntry] = []
        for index in 0..<ShowLimits.maximumEntriesPerSetlist {
            entries.append(Fix.entry("e\(index)", index.isMultiple(of: 2) ? Fix.songA : Fix.songB))
        }
        let big = try Fix.library(songs: songs, entries: entries)
        let bigCursor = try Fix.cursor(big, at: "e0", part: "p0")
        let last = Kit.point(entry: "e254", song: Fix.songA, part: "p63", ordinal: 254, previous: "e253", next: "e255")
        let far = try Kit.offer(Kit.resume(last, cursor: bigCursor, library: big))
        #expect(far.line.songNumber == 255)
        #expect(far.line.songCount == 256)
        #expect(far.line.partNumber == 64)
        #expect(far.jump == .jump(Fix.entryID("e254"), Fix.partID("p63")))
        let past = Kit.point(entry: "e254", song: Fix.songA, part: "p63", ordinal: 256)
        #expect(try Kit.resume(past, cursor: bigCursor, library: big) == .invalidPoint)
    }
}
