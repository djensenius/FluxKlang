import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowStageProjectionTests {
    private func lineAt(_ library: ShowLibrary, entry: String, part: String?) throws -> ShowStageLine {
        let cursor = try Fix.cursor(library, at: entry, part: part)
        let projection = try ShowStageProjection.make(library: library, cursor: cursor, catalog: Fix.catalog())
        return try #require(projection.now)
    }

    private func distinct(_ phrases: [String]) -> Bool {
        var seen = Set<String>()
        for phrase in phrases where !seen.insert(phrase).inserted { return false }
        return !phrases.isEmpty
    }

    @Test
    func everyStatusStateChartReasonAndProblemCountHasItsOwnNonEmptyPhrase() throws {
        let entry = Fix.entryID("e1")
        let statuses: [ShowCursorStatus] = [.current, .setlistRemoved(Fix.list), .entryRemoved(entry),
                                            .partRemoved(Fix.partID("p1")), .partsAdded(Fix.songA)]
        let spokenStatuses: [String] = statuses.map { ShowStageFormat.stale($0) }
        #expect(distinct(spokenStatuses))
        #expect(!spokenStatuses.contains(""))
        let states: [ShowStageProjection.CursorState] = [.positioned, .unpositioned, .stale(.setlistRemoved(Fix.list)),
                                                         .stale(.entryRemoved(entry)),
                                                         .stale(.partRemoved(Fix.partID("p1"))),
                                                         .stale(.partsAdded(Fix.songA))]
        let spokenStates: [String] = states.map { ShowStageFormat.cursorState($0) }
        #expect(distinct(spokenStates))
        #expect(!spokenStates.contains(""))
        let reference = try ChartReference.make(asset: AssetID(validated: "ast.chart"))
        let chartPhrases: [String] = [ShowStageFormat.chart(.none), ShowStageFormat.chart(.available(reference)),
                                      ShowStageFormat.missing(.notInProject),
                                      ShowStageFormat.missing(.notDocument(.audio)),
                                      ShowStageFormat.missing(.contentUnavailable)]
        #expect(distinct(chartPhrases))
        #expect(!chartPhrases.contains(""))
        let chartWords: [String] = ["No chart.", "Chart available.", "Chart missing: not in the project.",
                                    "Chart missing: the asset is not a document.",
                                    "Chart missing: content unavailable."]
        #expect(chartPhrases == chartWords)
        let counts = [ShowStageFormat.problems(count: 0), ShowStageFormat.problems(count: 1),
                      ShowStageFormat.problems(count: 2), ShowStageFormat.problems(count: 12)]
        #expect(distinct(counts))
        let names = ShowStageDestination.allCases.map { ShowStageFormat.destination($0, line: nil) }
        #expect(distinct(names))
        #expect(names.count == 4)
    }

    @Test
    func everyStaleStatusAndCursorStateIsSpokenWithItsExactWording() {
        let entry = Fix.entryID("e1")
        let statuses: [ShowCursorStatus] = [.current, .setlistRemoved(Fix.list), .entryRemoved(entry),
                                            .partRemoved(Fix.partID("p1")), .partsAdded(Fix.songA)]
        let spokenStatuses: [String] = statuses.map { ShowStageFormat.stale($0) }
        let entryWords = "The song entry was removed. Jump to another song entry, if the setlist has one, to continue."
        let statusWords: [String] = ["The cursor target is current.",
                                     "The setlist was removed. Choose another setlist or restore this one to continue.",
                                     entryWords,
                                     "The part was removed. Jump to the song or to one of its parts to continue.",
                                     "The song gained parts. Jump to a part to continue."]
        #expect(spokenStatuses == statusWords)
        let states: [ShowStageProjection.CursorState] = [.positioned, .unpositioned,
                                                         .stale(.setlistRemoved(Fix.list)),
                                                         .stale(.partsAdded(Fix.songA))]
        let spokenStates: [String] = states.map { ShowStageFormat.cursorState($0) }
        let stateWords: [String] = ["The cursor is on a song.", "The cursor is not on a song yet.",
                                    "The setlist was removed. Choose another setlist or restore this one to continue.",
                                    "The song gained parts. Jump to a part to continue."]
        #expect(spokenStates == stateWords)
    }

    @Test
    func theRecoveryAdviceInTheStalePhrasesMatchesWhatTheRealCursorsJumpDoes() throws {
        let catalog = try Fix.catalog()
        let library = try Fix.mainLibrary()
        let jumpTo: (SetlistEntryID, SongPartID?) -> ShowNavigationInput = { entry, part in
            ShowNavigationInput(.jump(entry, part), source: Fix.foot, sequence: 2, tick: 0)
        }

        let gone = try library.removingSetlist(Fix.list)
        let removedStatus = ShowCursorStatus.setlistRemoved(Fix.list)
        let jumps: [ShowNavigationInput] = [jumpTo(Fix.entryID("e1"), nil), jumpTo(Fix.entryID("e1"), Fix.partID("a1")),
                                            jumpTo(Fix.entryID("e3"), nil)]
        for jump in jumps {
            var cursor = try Fix.cursor(library, at: "e1", part: "a1")
            let result = Fix.attempt(&cursor, jump, in: gone, catalog: catalog)
            #expect(result == .refused(.cursorTargetRemoved(removedStatus)))
        }
        #expect(!ShowStageFormat.stale(removedStatus).contains("Jump"))

        let setlist = try #require(library.setlist(Fix.list))
        let withoutE2 = try library.replacingSetlist(setlist.removing(Fix.entryID("e2")))
        var entryCursor = try Fix.cursor(library, at: "e2", part: "b1")
        let entryResult = Fix.attempt(&entryCursor, jumpTo(Fix.entryID("e3"), nil), in: withoutE2, catalog: catalog)
        #expect(entryResult == .moved(Fix.pos("e3", "a1")))
        #expect(entryCursor.status(in: withoutE2) == .current)

        let single = try Fix.song(Fix.songA, parts: ["p1"])
        let other = try Fix.song(Fix.songB, parts: ["q1"])
        let small = try Fix.library(songs: [single, other],
                                    entries: [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB)])
        let lost = try small.upsertingSong(single.removingPart(Fix.partID("p1")), in: catalog)
        var lostCursor = try Fix.cursor(small, at: "e1", part: "p1")
        #expect(lostCursor.status(in: lost) == .partRemoved(Fix.partID("p1")))
        let lostResult = Fix.attempt(&lostCursor, jumpTo(Fix.entryID("e1"), nil), in: lost, catalog: catalog)
        #expect(lostResult == .moved(Fix.pos("e1", nil)))
        #expect(lostCursor.status(in: lost) == .current)

        let songC = try #require(library.song(Fix.songC))
        let grown = try library.upsertingSong(songC.insertingPart(Fix.part("c1"), in: catalog), in: catalog)
        var grownCursor = try Fix.cursor(library, at: "e4", part: nil)
        #expect(grownCursor.status(in: grown) == .partsAdded(Fix.songC))
        let grownResult = Fix.attempt(&grownCursor, jumpTo(Fix.entryID("e4"), nil), in: grown, catalog: catalog)
        #expect(grownResult == .moved(Fix.pos("e4", "c1")))
        #expect(grownCursor.status(in: grown) == .current)
    }

    @Test
    func aTitleAtTheByteLimitIsCarriedByteForByteAndHostileTitlesNeverReachALine() throws {
        let hostile: [String] = ["Title\u{202E}Gnirts", "First\nSecond", "Nul\u{0}Byte", "\u{200B}Hidden", " Padded"]
        for title in hostile {
            #expect(throws: ShowRefusal.self) { try ShowSong.make(id: Fix.songA, title: title, parts: []) }
        }
        let wide = String(repeating: "\u{E9}", count: 128)
        let tooWide = wide + "x"
        #expect(wide.utf8.count == 256)
        #expect(tooWide.utf8.count == 257)
        #expect(throws: ShowRefusal.self) { try ShowSong.make(id: Fix.songA, title: tooWide, parts: []) }
        let song = try ShowSong.make(id: Fix.songA, title: wide, parts: [Fix.part("p1", title: wide)])
        let library = try Fix.library(songs: [song], entries: [Fix.entry("e1", Fix.songA)])
        let line = try lineAt(library, entry: "e1", part: "p1")
        #expect(Array(line.songTitle.utf8) == Array(wide.utf8))
        let spoken = ShowStageFormat.line(line)
        let prefix = "Song 1 of 1, \(wide). Part 1 of 1, \(wide)."
        #expect(Array(spoken.utf8) == Array("\(prefix) No chart. No link problems.".utf8))
        #expect(spoken.utf8.count == prefix.utf8.count + 28)
    }

    @Test
    func aMissingChartIsSpokenWithItsReasonButNotWithTheAssetMediaOrReference() throws {
        let reference = try ChartReference.make(asset: AssetID(validated: "ast.midi"), page: 5)
        let audio = ShowStageFormat.chart(.missing(reference, .notDocument(.audio)))
        let midi = ShowStageFormat.chart(.missing(reference, .notDocument(.midi)))
        #expect(audio == midi)
        #expect(audio == ShowStageFormat.missing(.notDocument(.audio)))
        let other = try ChartReference.make(asset: AssetID(validated: "ast.chart"))
        #expect(ShowStageFormat.chart(.missing(other, .notInProject)) == ShowStageFormat.missing(.notInProject))
        #expect(!audio.contains("ast.midi"))
    }

    @Test
    func theCountOfLinkProblemsIsSpokenAsANumberWithItsOwnSingularPhrase() {
        #expect(ShowStageFormat.problems(count: 0) == "No link problems.")
        #expect(ShowStageFormat.problems(count: 1) == "1 link problem.")
        #expect(ShowStageFormat.problems(count: 2) == "2 link problems.")
        #expect(ShowStageFormat.problems(count: 17) == "17 link problems.")
    }

    @Test
    func aLinePhraseNamesTheNumbersTitlesChartAndProblemsInAFixedOrder() throws {
        let library = try Fix.mainLibrary()
        let line = try lineAt(library, entry: "e2", part: "b1")
        let expected = "Song 2 of 4, Song song.b. Part 1 of 2, Part b1. No chart. No link problems."
        #expect(ShowStageFormat.line(line) == expected)
        let partless = try lineAt(library, entry: "e4", part: nil)
        #expect(ShowStageFormat.line(partless) == "Song 4 of 4, Song song.c. No parts. No chart. No link problems.")
        let spoken = ShowStageFormat.destination(.previousPart, line: line)
        let expectedSpoken = "Previous part: \(expected)"
        #expect(spoken == expectedSpoken)
        #expect(ShowStageFormat.destination(.nextSong, line: nil) == "Next song: none.")
        #expect(ShowStageFormat.destination(.nextPart, line: nil) == "Next part: none.")
        #expect(ShowStageFormat.destination(.previousSong, line: nil) == "Previous song: none.")
        #expect(ShowStageFormat.destination(.previousPart, line: nil) == "Previous part: none.")
    }

    @Test
    func aTitleThatQuotesAChartPhraseChangesTheTitleTextOnlyNotTheChartOrProblemPhrases() throws {
        let reference = try ChartReference.make(asset: AssetID(validated: "ast.chart"))
        let tricky = "\"Chart available.\" Part 9 of 9 No link problems."
        let song = try ShowSong.make(id: Fix.songA, title: tricky, parts: [Fix.part("p1", title: tricky)])
        let chart = try ShowSong.make(id: Fix.songB, title: "Plain", parts: [Fix.part("q1")], chart: reference)
        let library = try Fix.library(songs: [song, chart],
                                      entries: [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB)])
        let trickyLine = try lineAt(library, entry: "e1", part: "p1")
        let plainLine = try lineAt(library, entry: "e2", part: "q1")
        #expect(trickyLine.chart == ShowStageChart.none)
        #expect(plainLine.chart == .available(reference))
        let spokenTricky = ShowStageFormat.line(trickyLine)
        let spokenPlain = ShowStageFormat.line(plainLine)
        #expect(spokenTricky.hasSuffix(" No chart. No link problems."))
        #expect(spokenPlain.hasSuffix(" Chart available. No link problems."))
        #expect(spokenTricky.hasPrefix("Song 1 of 2, \"Chart available.\" Part 9 of 9 No link problems.."))
        #expect(ShowStageFormat.chart(trickyLine.chart) == "No chart.")
        #expect(ShowStageFormat.problems(count: trickyLine.problems.count) == "No link problems.")
    }

    @Test
    func aLinePhraseOfAOneSongOneEntrySetlistIsOneExactSentenceSequenceOfItsByteCount() throws {
        let part = try Fix.part("p1")
        let song = try ShowSong.make(id: Fix.songA, title: "Title", parts: [part])
        let library = try Fix.library(songs: [song], entries: [Fix.entry("e1", Fix.songA)])
        let line = try lineAt(library, entry: "e1", part: "p1")
        let spoken = ShowStageFormat.line(line)
        #expect(spoken == "Song 1 of 1, Title. Part 1 of 1, Part p1. No chart. No link problems.")
        #expect(spoken.utf8.count == 69)
    }

    @Test
    func aLineWithAMissingChartAndTwoProblemsSpeaksTheReasonAndTheCountInItsPhrase() throws {
        let gone = try ChartReference.make(asset: AssetID(validated: "ast.gone"))
        let links = try SongPartLinks.make(patch: Self.unknownPatch, chart: gone)
        let song = try ShowSong.make(id: Fix.songA, title: "Linked", parts: [Fix.part("p1", links: links)])
        let library = try Fix.library(songs: [song], entries: [Fix.entry("e1", Fix.songA)])
        let line = try lineAt(library, entry: "e1", part: "p1")
        #expect(line.problems.count == 2)
        let expected = "Song 1 of 1, Linked. Part 1 of 1, Part p1. Chart missing: not in the project. 2 link problems."
        #expect(ShowStageFormat.line(line) == expected)
    }

    private static var productionDirectory: URL? {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let parent = here.deletingLastPathComponent()
        let candidates = [parent.appendingPathComponent("Shared/Views/Show/Stage"),
                          parent.deletingLastPathComponent()
                              .appendingPathComponent("Sources/FluxKlang/Shared/Views/Show/Stage")]
        let manager = FileManager.default
        return candidates.first { manager.fileExists(atPath: $0.path) }
    }

    static let sourcesAreReachable = productionDirectory != nil

    @Test(.enabled(if: Self.sourcesAreReachable, "the stage sources are not next to the tests"))
    func theThreeStageSourcesNameNoUserInterfaceClockTaskOrQueueSymbol() throws {
        let directory = try #require(Self.productionDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["ShowStageFormat.swift", "ShowStageLine.swift", "ShowStageProjection.swift"])
        let forbidden = ["import SwiftUI", "Date(", "Clock", "Task", "DispatchQueue", "Combine", "random"]
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for word in forbidden {
                #expect(!text.contains(word), "\(name) \(word)")
            }
        }
    }
}
