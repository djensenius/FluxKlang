// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Songs A (parts a1 a2 a3), B (b1 b2), C (no parts) and D (d1). Setlist `set.main` plays e1 A, e2 B, e3 A, e4 C,
/// e5 D; `set.alt` plays f1 B and f2 D.
@Suite(.productionAccessAudit)
struct ShowResumePlannerTests {
    enum Fixture {
        static let songA = SongID(validated: "song.a")
        static let songB = SongID(validated: "song.b")
        static let songC = SongID(validated: "song.c")
        static let songD = SongID(validated: "song.d")
        static let a1 = SongPartID(validated: "part.a1")
        static let a2 = SongPartID(validated: "part.a2")
        static let a3 = SongPartID(validated: "part.a3")
        static let b1 = SongPartID(validated: "part.b1")
        static let b2 = SongPartID(validated: "part.b2")
        static let c1 = SongPartID(validated: "part.c1")
        static let d1 = SongPartID(validated: "part.d1")
        static let unknownPart = SongPartID(validated: "part.zz")
        static let main = SetlistID(validated: "set.main")
        static let alt = SetlistID(validated: "set.alt")
        static let e1 = SetlistEntryID(validated: "ent.1")
        static let e2 = SetlistEntryID(validated: "ent.2")
        static let e3 = SetlistEntryID(validated: "ent.3")
        static let e4 = SetlistEntryID(validated: "ent.4")
        static let e5 = SetlistEntryID(validated: "ent.5")
        static let f1 = SetlistEntryID(validated: "ent.f1")
        static let f2 = SetlistEntryID(validated: "ent.f2")
        static let foot = ShowInputSourceID(validated: "src.foot")

        /// The point captured at e3, part a2, in the standard library; each field can be changed before `point`.
        struct Spec { // swiftlint:disable:this nesting
            var entry = Fixture.e3
            var song = Fixture.songA
            var part: SongPartID? = Fixture.a2
            var ordinal = 2
            var previous: SetlistEntryID? = Fixture.e2
            var next: SetlistEntryID? = Fixture.e4

            var point: ShowResumePoint {
                ShowResumePoint(setlist: Fixture.main, entry: entry, song: song, part: part, entryOrdinal: ordinal,
                                previousEntry: previous, nextEntry: next)
            }
        }

        static func song(_ id: SongID, title: String = "Song", parts: [SongPartID] = []) throws -> ShowSong {
            let built = try parts.map { try SongPart.make(id: $0, title: "Part") }
            return try ShowSong.make(id: id, title: title, parts: built)
        }

        static func standardSongs(title: String = "Song") throws -> [ShowSong] {
            [try song(songA, title: title, parts: [a1, a2, a3]), try song(songB, title: title, parts: [b1, b2]),
             try song(songC, title: title), try song(songD, title: title, parts: [d1])]
        }

        static func entry(_ id: SetlistEntryID, _ song: SongID) -> SetlistEntry {
            SetlistEntry.make(id: id, song: song)
        }

        static func standardEntries() -> [SetlistEntry] {
            [entry(e1, songA), entry(e2, songB), entry(e3, songA), entry(e4, songC), entry(e5, songD)]
        }

        /// `set.main` holds `main`; `set.alt` always plays f1 and f2.
        static func library(main entries: [SetlistEntry], songs: [ShowSong]? = nil,
                            title: String = "Set") throws -> ShowLibrary {
            let available = try songs ?? standardSongs()
            let mainList = try ShowSetlist.make(id: main, title: title, entries: entries)
            let altList = try ShowSetlist.make(id: alt, title: title, entries: [entry(f1, songB), entry(f2, songD)])
            return try ShowLibrary.make(songs: available, setlists: [mainList, altList])
        }

        static func standardLibrary() throws -> ShowLibrary { try library(main: standardEntries()) }

        static func withoutEntries(_ removed: [SetlistEntryID]) throws -> ShowLibrary {
            let kept = standardEntries().filter { !removed.contains($0.id) }
            return try library(main: kept)
        }

        /// A cursor on `set.main`, moved to `entry` and `part` when given (a jump accepted by the real cursor).
        static func cursor(in library: ShowLibrary, at entry: SetlistEntryID? = nil,
                           part: SongPartID? = nil) throws -> ShowCursor {
            var cursor = try ShowCursor.make(setlist: main, bounceTicks: 0, sources: [foot], in: library)
            guard let entry else { return cursor }
            let input = ShowNavigationInput(.jump(entry, part), source: foot, sequence: 1, tick: 0)
            _ = try cursor.navigate(input, in: library, catalog: ShowLinkCatalog.make())
            return cursor
        }
    }

    // MARK: - Validation

    @Test func validationAcceptsTheOrdinalBoundsZeroAndTwoHundredFiftyFive() throws {
        var spec = Fixture.Spec()
        spec.previous = nil
        spec.next = nil
        spec.ordinal = 0
        let first = spec.point
        spec.ordinal = 255
        let last = spec.point
        try first.validate()
        try last.validate()
        let maximum = ShowResumePoint.maximumOrdinal
        #expect(first.isValid)
        #expect(last.isValid)
        #expect(maximum == 255)
    }

    @Test func validationRefusesAnOrdinalBelowZeroOrAboveTwoHundredFiftyFive() {
        for ordinal in [-1, 256, Int.max, Int.min] {
            var spec = Fixture.Spec()
            spec.ordinal = ordinal
            let point = spec.point
            let expected = ShowResumeRefusal.ordinalOutOfRange(ordinal)
            #expect(throws: expected) { try point.validate() }
            #expect(!point.isValid)
        }
    }

    @Test func validationRefusesAPreviousOrNextEntryThatIsTheEntryItself() {
        var previousSpec = Fixture.Spec()
        previousSpec.previous = Fixture.e3
        var nextSpec = Fixture.Spec()
        nextSpec.next = Fixture.e3
        let previousPoint = previousSpec.point
        let nextPoint = nextSpec.point
        let expected = ShowResumeRefusal.neighbourIsEntry
        #expect(throws: expected) { try previousPoint.validate() }
        #expect(throws: expected) { try nextPoint.validate() }
    }

    @Test func validationRefusesEqualNeighboursAndAcceptsDistinctOrAbsentOnes() throws {
        var equal = Fixture.Spec()
        equal.previous = Fixture.e2
        equal.next = Fixture.e2
        let equalPoint = equal.point
        let expected = ShowResumeRefusal.neighboursEqual
        #expect(throws: expected) { try equalPoint.validate() }
        var onlyPrevious = Fixture.Spec()
        onlyPrevious.next = nil
        var onlyNext = Fixture.Spec()
        onlyNext.previous = nil
        var neither = Fixture.Spec()
        neither.previous = nil
        neither.next = nil
        let onlyPreviousPoint = onlyPrevious.point
        let onlyNextPoint = onlyNext.point
        let neitherPoint = neither.point
        let standardPoint = Fixture.Spec().point
        try onlyPreviousPoint.validate()
        try onlyNextPoint.validate()
        try neitherPoint.validate()
        try standardPoint.validate()
        #expect(standardPoint.isValid)
    }

    @Test func anOrdinalOutOfRangeIsReportedBeforeANeighbourThatIsTheEntry() {
        var spec = Fixture.Spec()
        spec.ordinal = 256
        spec.next = Fixture.e3
        let point = spec.point
        let expected = ShowResumeRefusal.ordinalOutOfRange(256)
        #expect(throws: expected) { try point.validate() }
    }

    @Test func aNeighbourThatIsTheEntryIsReportedBeforeEqualNeighbours() {
        var spec = Fixture.Spec()
        spec.previous = Fixture.e3
        spec.next = Fixture.e3
        let point = spec.point
        let expected = ShowResumeRefusal.neighbourIsEntry
        #expect(throws: expected) { try point.validate() }
    }

    @Test func planRefusesAnInvalidPointEvenWhenItsSetlistIsGoneOrItsEntryIsMissing() throws {
        var spec = Fixture.Spec()
        spec.ordinal = 256
        let point = spec.point
        let standard = try Fixture.standardLibrary()
        let withoutMain = try standard.removingSetlist(Fixture.main)
        let withoutEntry = try Fixture.withoutEntries([Fixture.e3])
        let expected = ShowResumeRefusal.ordinalOutOfRange(256)
        #expect(throws: expected) { try ShowResumePlanner.plan(point, in: standard) }
        #expect(throws: expected) { try ShowResumePlanner.plan(point, in: withoutMain) }
        #expect(throws: expected) { try ShowResumePlanner.plan(point, in: withoutEntry) }
    }

    // MARK: - Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Performance/Shows/Resume",
            "../../Sources/FluxKlang/Shared/Performance/Shows/Resume"
        ]
        let marker = "ShowResumePlanner.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Built from pieces so this file does not contain the words either.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["import Swift", "UI"].joined(), ["Da", "te("].joined(), ["Cl", "ock"].joined(), ["Ta", "sk"].joined(),
            ["Dispatch", "Queue"].joined(), ["User", "Defaults"].joined(), ["defa", "ult:"].joined()
        ]
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the resume sources are not next to the tests"))
    func theThreeResumeFilesUseNoViewTimeTaskQueueStorageOrDefaultCase() throws {
        let directory = try #require(Self.sourceDirectory(), "the resume sources are not next to the tests")
        let names = ["ShowResumePoint.swift", "ShowResumePlanner.swift", "ShowResumeDecision.swift"]
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            for word in Self.forbiddenSourceWords() where text.contains(word) { hits.append("\(name): \(word)") }
        }
        #expect(hits.isEmpty)
    }
}
// swiftlint:enable identifier_name
