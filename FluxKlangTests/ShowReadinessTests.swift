import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Pre-show readiness verdicts built from hand-made facts. The library has one setlist, `set.main`; each test chooses
/// its songs and entries. Charts name `ast.gone` (the catalog lists no such asset, so the chart is missing) or
/// `ast.ok` (a document with content, so the chart is available).
struct ShowReadinessTests {
    enum Fixture {
        static let songA = SongID(validated: "song.a")
        static let songB = SongID(validated: "song.b")
        static let songOutside = SongID(validated: "song.x")
        static let partOne = SongPartID(validated: "part.1")
        static let partTwo = SongPartID(validated: "part.2")
        static let partThree = SongPartID(validated: "part.3")
        static let partFour = SongPartID(validated: "part.4")
        static let mainList = SetlistID(validated: "set.main")
        static let unknownList = SetlistID(validated: "set.zz")
        static let setOne = ActionSetID(validated: "as.1")
        static let setTwo = ActionSetID(validated: "as.2")
        static let setThree = ActionSetID(validated: "as.3")
        static let goneAsset = AssetID(validated: "ast.gone")
        static let goneAsset2 = AssetID(validated: "ast.gone2")
        static let okAsset = AssetID(validated: "ast.ok")
        static let unknownPatch = PatchID(validated: "pat.none")
        static let memberAction = ActionID(validated: "act.member")
        static let entryOne = SetlistEntryID(validated: "ent.1")
        static let entryTwo = SetlistEntryID(validated: "ent.2")
        static let entryThree = SetlistEntryID(validated: "ent.3")

        static func chart(_ asset: AssetID) throws -> ChartReference {
            try ChartReference.make(asset: asset)
        }

        static func part(_ id: SongPartID, set: ActionSetID? = nil, chart asset: AssetID? = nil,
                         patch: PatchID? = nil) throws -> SongPart {
            let reference = try asset.map { try chart($0) }
            let links = try SongPartLinks.make(patch: patch, actionSet: set, chart: reference)
            return try SongPart.make(id: id, title: "Part", links: links)
        }

        static func song(_ id: SongID, chart asset: AssetID? = nil, parts: [SongPart] = []) throws -> ShowSong {
            try ShowSong.make(id: id, title: "Song", parts: parts, chart: asset.map { try chart($0) })
        }

        static func entry(_ id: SetlistEntryID, _ song: SongID) -> SetlistEntry {
            SetlistEntry.make(id: id, song: song)
        }

        static func library(songs: [ShowSong], entries: [SetlistEntry]) throws -> ShowLibrary {
            let setlist = try ShowSetlist.make(id: mainList, title: "Main", entries: entries)
            return try ShowLibrary.make(songs: songs, setlists: [setlist])
        }

        /// Knows `knownSets` as action sets and `ast.ok` as an available document; nothing else.
        static func catalog(knownSets: [ActionSetID] = []) throws -> ShowLinkCatalog {
            let sets = try knownSets.map { try PerformanceActionSet(id: $0, members: [memberAction]) }
            let digest = "sha256:" + String(repeating: "a", count: 64)
            let asset = ProjectAsset(id: okAsset, label: "Chart", media: .document, contentDigest: digest)
            return try ShowLinkCatalog.make(actionSets: PerformanceActionSetLibrary(sets: sets), assets: [asset],
                                            availableContent: [okAsset])
        }

        /// A report with one member that carries `memberState`, which is the report's own state unless given.
        static func report(_ set: ActionSetID, _ state: ReadinessState = .ready,
                           memberState: ReadinessState? = nil) -> ActionSetReadinessReport {
            let member = ActionSetMemberStatus(action: memberAction, state: memberState ?? state, reason: nil)
            return ActionSetReadinessReport(set: set, state: state, members: [member])
        }

        /// One ready report for each of `as.1` ... `as.<count>`; `count` must be at least 1.
        static func manyReports(_ count: Int) throws -> [ActionSetReadinessReport] {
            try (1...count).map { report(try ActionSetID("as.\($0)")) }
        }

        static func facts(_ library: ShowLibrary, reports: [ActionSetReadinessReport] = [],
                          knownSets: [ActionSetID] = [], setlist: SetlistID? = nil) throws -> ShowReadinessFacts {
            let worklist = try ShowRecoveryWorklist.make(library: library, catalog: catalog(knownSets: knownSets))
            return ShowReadinessFacts(library: library, setlist: setlist ?? mainList, reports: reports,
                                      worklist: worklist)
        }

        static func target(_ song: SongID, _ part: SongPartID? = nil) -> ShowRecoveryTarget {
            ShowRecoveryTarget(song: song, part: part)
        }

        /// One song with one part that links `setOne`, played by one entry.
        static func oneSongLibrary() throws -> ShowLibrary {
            try library(songs: [song(songA, parts: [part(partOne, set: setOne)])], entries: [entry(entryOne, songA)])
        }
    }

    // MARK: - Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Performance/Shows/Readiness",
            "../../Sources/FluxKlang/Shared/Performance/Shows/Readiness"
        ]
        let marker = "ShowReadinessVerdict.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Built from pieces so these literals do not match themselves; only the readiness sources are scanned.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["Dou", "ble"].joined(), ["Flo", "at"].joined(), ["Da", "te("].joined(), ["Cl", "ock"].joined(),
            ["Ta", "sk"].joined(), ["import Swift", "UI"].joined(), ["Dispatch", "Queue"].joined(),
            ["defa", "ult:"].joined(), ["try", "!"].joined(), ["mut", "ating"].joined(),
            ["static", " var"].joined()
        ]
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the readiness sources are not next to the tests"))
    func theReadinessFilesContainNoDoubleFloatDateClockTaskSwiftUIDispatchQueueDefaultTryBangMutatingOrStaticVarWords()
        throws {
        let directory = try #require(Self.sourceDirectory(), "the readiness sources are not next to the tests")
        let names = ["ShowReadinessEvaluator.swift", "ShowReadinessVerdict.swift", "ShowReadinessRefusal.swift"]
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            for word in Self.forbiddenSourceWords() where text.contains(word) { hits.append("\(name): \(word)") }
        }
        #expect(hits.isEmpty)
    }
}
