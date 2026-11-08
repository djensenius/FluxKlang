import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowResumePlannerTests {
    @Test func captureReadsTheCursorsEntryPartAndTheLibrarysSongOrdinalAndBothNeighbours() throws {
        let library = try Fixture.standardLibrary()
        let cursor = try Fixture.cursor(in: library, at: Fixture.e3, part: Fixture.a2)
        let point = try ShowResumePoint.capture(from: cursor, in: library)
        let expected = Fixture.Spec().point
        #expect(point == expected)
        #expect(point.isValid)
    }

    @Test func captureTakesTheSongOfTheEntryAndNoNeighbourBeyondTheFirstAndLastEntry() throws {
        let library = try Fixture.standardLibrary()
        let firstCursor = try Fixture.cursor(in: library)
        let secondCursor = try Fixture.cursor(in: library, at: Fixture.e2, part: Fixture.b2)
        let lastCursor = try Fixture.cursor(in: library, at: Fixture.e5)
        let first = try ShowResumePoint.capture(from: firstCursor, in: library)
        let second = try ShowResumePoint.capture(from: secondCursor, in: library)
        let last = try ShowResumePoint.capture(from: lastCursor, in: library)
        let expectedFirst = ShowResumePoint(setlist: Fixture.main, entry: Fixture.e1, song: Fixture.songA,
                                            part: Fixture.a1, entryOrdinal: 0, previousEntry: nil,
                                            nextEntry: Fixture.e2)
        let expectedSecond = ShowResumePoint(setlist: Fixture.main, entry: Fixture.e2, song: Fixture.songB,
                                             part: Fixture.b2, entryOrdinal: 1, previousEntry: Fixture.e1,
                                             nextEntry: Fixture.e3)
        let expectedLast = ShowResumePoint(setlist: Fixture.main, entry: Fixture.e5, song: Fixture.songD,
                                           part: Fixture.d1, entryOrdinal: 4, previousEntry: Fixture.e4,
                                           nextEntry: nil)
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
        #expect(last == expectedLast)
    }

    @Test func capturingAPartlessSongGivesNoPart() throws {
        let library = try Fixture.standardLibrary()
        let cursor = try Fixture.cursor(in: library, at: Fixture.e4)
        let point = try ShowResumePoint.capture(from: cursor, in: library)
        let expected = ShowResumePoint(setlist: Fixture.main, entry: Fixture.e4, song: Fixture.songC, part: nil,
                                       entryOrdinal: 3, previousEntry: Fixture.e3, nextEntry: Fixture.e5)
        #expect(point == expected)
    }

    @Test func captureRefusesACursorThatHasNoPositionYet() throws {
        let library = try Fixture.library(main: [])
        let cursor = try Fixture.cursor(in: library)
        let expected = ShowResumeRefusal.cursorNotPositioned
        let position = cursor.position
        #expect(position == nil)
        #expect(throws: expected) { try ShowResumePoint.capture(from: cursor, in: library) }
    }

    @Test func captureRefusesACursorWhoseTargetIsGoneOrStaleAndNamesTheStatus() throws {
        let library = try Fixture.standardLibrary()
        let cursor = try Fixture.cursor(in: library, at: Fixture.e3, part: Fixture.a2)
        let partless = try Fixture.cursor(in: library, at: Fixture.e4)
        let entryGone = try Fixture.withoutEntries([Fixture.e3])
        let withoutA2 = try Fixture.library(
            main: Fixture.standardEntries(),
            songs: [Fixture.song(Fixture.songA, parts: [Fixture.a1, Fixture.a3]), Fixture.song(Fixture.songB),
                    Fixture.song(Fixture.songC), Fixture.song(Fixture.songD)])
        let withC1 = try Fixture.library(
            main: Fixture.standardEntries(),
            songs: [Fixture.song(Fixture.songA), Fixture.song(Fixture.songB),
                    Fixture.song(Fixture.songC, parts: [Fixture.c1]), Fixture.song(Fixture.songD)])
        let withoutMain = try library.removingSetlist(Fixture.main)
        let entryRemoved = ShowResumeRefusal.cursorNotCurrent(.entryRemoved(Fixture.e3))
        let partRemoved = ShowResumeRefusal.cursorNotCurrent(.partRemoved(Fixture.a2))
        let partsAdded = ShowResumeRefusal.cursorNotCurrent(.partsAdded(Fixture.songC))
        let setlistRemoved = ShowResumeRefusal.cursorNotCurrent(.setlistRemoved(Fixture.main))
        #expect(throws: entryRemoved) { try ShowResumePoint.capture(from: cursor, in: entryGone) }
        #expect(throws: partRemoved) { try ShowResumePoint.capture(from: cursor, in: withoutA2) }
        #expect(throws: partsAdded) { try ShowResumePoint.capture(from: partless, in: withC1) }
        #expect(throws: setlistRemoved) { try ShowResumePoint.capture(from: cursor, in: withoutMain) }
    }

    @Test func aStaleStatusIsReportedBeforeAMissingPositionWhenBothApply() throws {
        let library = try Fixture.library(main: [])
        let cursor = try Fixture.cursor(in: library)
        let withoutMain = try library.removingSetlist(Fixture.main)
        let position = cursor.position
        let expected = ShowResumeRefusal.cursorNotCurrent(.setlistRemoved(Fixture.main))
        #expect(position == nil)
        #expect(throws: expected) { try ShowResumePoint.capture(from: cursor, in: withoutMain) }
    }

    @Test func theLastEntryOfAFullSetlistCapturesOrdinalTwoHundredFiftyFiveAndNoNext() throws {
        var entries: [SetlistEntry] = []
        for number in 0..<ShowLimits.maximumEntriesPerSetlist {
            let id = try SetlistEntryID("ent.n\(number)")
            entries.append(Fixture.entry(id, Fixture.songB))
        }
        let library = try Fixture.library(main: entries)
        let lastID = try SetlistEntryID("ent.n255")
        let previousID = try SetlistEntryID("ent.n254")
        let cursor = try Fixture.cursor(in: library, at: lastID)
        let point = try ShowResumePoint.capture(from: cursor, in: library)
        let ordinal = point.entryOrdinal
        let previous = point.previousEntry
        let next = point.nextEntry
        #expect(ordinal == 255)
        #expect(previous == previousID)
        #expect(next == nil)
        #expect(point.isValid)
    }
}
