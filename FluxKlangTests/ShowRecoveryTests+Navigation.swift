import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// One cursor walk over the main setlist: every stop the cursor reported and, when a press was refused at the first or
/// the last entry, that refusal (`nil` when the walk ended some other way).
struct ShowRecoveryWalk {
    let stops: [ShowStop]
    let ended: ShowRefusal?

    var positions: [ShowPosition] { stops.map(\.position) }
    var missingCount: Int { stops.filter(ShowRecoveryTestFixture.isMissing).count }
}

extension ShowRecoveryTestFixture {
    static let foot = ShowInputSourceID(validated: "src.foot")

    /// A catalog in which every asset is a usable document, so no chart can be missing.
    static func everythingAvailable() throws -> ShowLinkCatalog {
        let every = [okAsset, okAsset2, staleAsset, staleAsset2, midiAsset, audioAsset, goneAsset, goneAsset2]
        return try ShowLinkCatalog.make(
            patches: [(keysPatch, [wetVariation])],
            assets: every.map { asset($0, .document) },
            availableContent: every
        )
    }

    /// Every stop of the main setlist: the first one, then one `nextPart` press at a time up to the end.
    static func walk(_ library: ShowLibrary, catalog: ShowLinkCatalog) throws -> [ShowStop] {
        try trace(library, catalog: catalog, pressing: .nextPart).stops
    }

    /// The position of entry `ent.<number>` of the main setlist; `part` is `nil` for a song without parts.
    static func spot(_ number: Int, _ part: SongPartID?) throws -> ShowPosition {
        try ShowPosition(setlist: mainList, entry: SetlistEntryID("ent.\(number)"), part: part)
    }

    static func jumpCommand(_ number: Int, _ part: SongPartID?) throws -> ShowNavigationCommand {
        try ShowNavigationCommand.jump(SetlistEntryID("ent.\(number)"), part)
    }

    /// The 12 stops of the main setlist in playing order: A (4 parts), B (2), A again (4), C (no parts) and D (1).
    static func playingOrder() throws -> [ShowPosition] {
        try [
            spot(1, partA1), spot(1, partA2), spot(1, partA3), spot(1, partA4), spot(2, partB1), spot(2, partB2),
            spot(3, partA1), spot(3, partA2), spot(3, partA3), spot(3, partA4), spot(4, nil), spot(5, partD1)
        ]
    }

    /// The first stop of each of the five entries of the main setlist.
    static func songStarts() throws -> [ShowPosition] {
        try [spot(1, partA1), spot(2, partB1), spot(3, partA1), spot(4, nil), spot(5, partD1)]
    }

    /// Presses `command` on a cursor of the main setlist until a press does not move it, after an optional first
    /// `start` command (a jump). Sequences and ticks increase by one per press and the cursor has no bounce window.
    static func trace(_ library: ShowLibrary, catalog: ShowLinkCatalog, pressing command: ShowNavigationCommand,
                      after start: ShowNavigationCommand? = nil) throws -> ShowRecoveryWalk {
        var cursor = try ShowCursor.make(setlist: mainList, bounceTicks: 0, sources: [foot], in: library)
        var serial: UInt64 = 0
        if let start {
            serial += 1
            let input = ShowNavigationInput(start, source: foot, sequence: serial, tick: serial)
            _ = try cursor.navigate(input, in: library, catalog: catalog)
        }
        var stops: [ShowStop] = []
        if let first = try cursor.currentStop(in: library, catalog: catalog) { stops.append(first) }
        for _ in 0..<64 {
            serial += 1
            let press = ShowNavigationInput(command, source: foot, sequence: serial, tick: serial)
            do {
                guard case let .moved(stop) = try cursor.navigate(press, in: library, catalog: catalog) else { break }
                stops.append(stop)
            } catch ShowRefusal.atEnd {
                return ShowRecoveryWalk(stops: stops, ended: .atEnd)
            } catch ShowRefusal.atStart {
                return ShowRecoveryWalk(stops: stops, ended: .atStart)
            }
        }
        return ShowRecoveryWalk(stops: stops, ended: nil)
    }

    static func isMissing(_ stop: ShowStop) -> Bool {
        guard let chart = stop.links.chart else { return false }
        if case .missing = chart { return true }
        return false
    }
}

extension ShowRecoveryTests {
    @Test
    func navigationVisitsTheSameStopsBeforeAndAfterRecovery() throws {
        let before = try Fix.walk(library, catalog: catalog)
        let recovered = try recover(Fix.recoverEverything())
        let after = try Fix.walk(recovered.library, catalog: catalog)
        let ideal = try Fix.walk(library, catalog: Fix.everythingAvailable())
        // Songs A (4 parts), B (2), A again (4), C (no parts) and D (1).
        #expect(before.count == 12)
        #expect(after.map(\.position) == before.map(\.position))
        #expect(ideal.map(\.position) == before.map(\.position))
        #expect(after.map(\.song) == before.map(\.song))
        #expect(ideal.map(\.song) == before.map(\.song))
    }

    @Test
    func theStopsThatShowAMissingChartAreTheOnesRecoveryRepairs() throws {
        let before = try Fix.walk(library, catalog: catalog)
        let recovered = try recover(Fix.recoverEverything())
        let after = try Fix.walk(recovered.library, catalog: catalog)
        let ideal = try Fix.walk(library, catalog: Fix.everythingAvailable())
        // A/a1, a2 and a3 (twice), B/b1 and b2, D/d1; A/a4 and song C are healthy.
        #expect(before.filter(Fix.isMissing).count == 9)
        #expect(after.filter(Fix.isMissing).isEmpty)
        #expect(ideal.filter(Fix.isMissing).isEmpty)
        // b1 lost its chart and its song has none left to fall back to.
        let withoutChart = after.filter { $0.links.chart == nil }
        #expect(withoutChart.count == 1)
        #expect(withoutChart.first?.position.part == Fix.partB1)
    }

    @Test
    func aJumpToAPartWithAMissingChartStillMovesAndReportsIt() throws {
        var cursor = try ShowCursor.make(setlist: Fix.mainList, bounceTicks: 0, sources: [Fix.foot], in: library)
        let entry = try SetlistEntryID("ent.2")
        let jump = ShowNavigationInput(.jump(entry, Fix.partB2), source: Fix.foot, sequence: 1, tick: 1)
        let result = try cursor.navigate(jump, in: library, catalog: catalog)
        guard case let .moved(stop) = result else {
            Issue.record("A jump to a part whose chart is missing must still move, got \(result)")
            return
        }
        let midi = try Fix.chart(Fix.midiAsset, page: 1)
        #expect(stop.position == ShowPosition(setlist: Fix.mainList, entry: entry, part: Fix.partB2))
        #expect(stop.links.chart == .missing(midi, .notDocument(.midi)))
        #expect(stop.links.problems.contains(.chart(midi, .notDocument(.midi))))
    }

    @Test
    func aClearedPartChartFallsBackToTheSongChartOnNavigation() throws {
        let recovered = try recover([.clearTarget(Fix.target(Fix.songA, Fix.partA1))])
        let stops = try Fix.walk(recovered.library, catalog: catalog)
        let first = try #require(stops.first)
        let songChart = try Fix.chart(Fix.staleAsset, page: 1)
        #expect(first.position.part == Fix.partA1)
        #expect(first.links.chart == .missing(songChart, .contentUnavailable))
        let before = try Fix.walk(library, catalog: catalog)
        #expect(stops.map(\.position) == before.map(\.position))
    }

    @Test
    func aRelinkedPartShowsTheNewAvailableChartOnNavigation() throws {
        let fresh = try Fix.chart(Fix.okAsset2, page: 3)
        let recovered = try recover([.relinkTarget(Fix.target(Fix.songA, Fix.partA1), to: fresh)])
        let stops = try Fix.walk(recovered.library, catalog: catalog)
        let first = try #require(stops.first)
        #expect(first.links.chart == .available(fresh))
        #expect(first.links.links.chart == fresh)
    }

    @Test
    func aCursorStaysCurrentAcrossRecovery() throws {
        var cursor = try ShowCursor.make(setlist: Fix.mainList, bounceTicks: 0, sources: [Fix.foot], in: library)
        let entry = try SetlistEntryID("ent.3")
        let jump = ShowNavigationInput(.jump(entry, Fix.partA2), source: Fix.foot, sequence: 1, tick: 1)
        _ = try cursor.navigate(jump, in: library, catalog: catalog)
        let missing = try #require(try cursor.currentStop(in: library, catalog: catalog))
        let stale = try Fix.chart(Fix.staleAsset, page: 2)
        #expect(missing.links.chart == .missing(stale, .contentUnavailable))
        let recovered = try recover(Fix.recoverEverything())
        #expect(cursor.status(in: recovered.library) == .current)
        let after = try #require(try cursor.currentStop(in: recovered.library, catalog: catalog))
        let okChart = try Fix.chart(Fix.okAsset, page: 2)
        #expect(after.position == missing.position)
        #expect(after.links.chart == .available(okChart))
        let cleared = try recover([.clearAsset(Fix.goneAsset), .clearAsset(Fix.staleAsset)])
        #expect(cursor.status(in: cleared.library) == .current)
    }

    /// The same walk over the missing-chart library, over the recovered library and over the original library with
    /// every chart available, in that order.
    func threeWalks(pressing command: ShowNavigationCommand,
                    after start: ShowNavigationCommand? = nil) throws -> [ShowRecoveryWalk] {
        let recovered = try recover(Fix.recoverEverything()).library
        let everything = try Fix.everythingAvailable()
        return try [
            Fix.trace(library, catalog: catalog, pressing: command, after: start),
            Fix.trace(recovered, catalog: catalog, pressing: command, after: start),
            Fix.trace(library, catalog: everything, pressing: command, after: start)
        ]
    }

    @Test
    func previousPartRetracesTheForwardWalkOnEveryCatalog() throws {
        let order = try Fix.playingOrder()
        let forward = try threeWalks(pressing: .nextPart)
        let backward = try threeWalks(pressing: .previousPart, after: Fix.jumpCommand(5, Fix.partD1))
        for walked in forward {
            #expect(walked.positions == order)
            #expect(walked.ended == ShowRefusal.atEnd)
        }
        for walked in backward {
            #expect(walked.positions == Array(order.reversed()))
            #expect(walked.ended == ShowRefusal.atStart)
        }
        // A missing chart never stops a walk: 9 of the 12 stops show one before recovery and none after it.
        #expect(forward.map(\.missingCount) == [9, 0, 0])
        #expect(backward.map(\.missingCount) == [9, 0, 0])
    }

    @Test
    func nextSongVisitsEachEntryOnceAndStopsAtTheEnd() throws {
        let starts = try Fix.songStarts()
        let walks = try threeWalks(pressing: .nextSong)
        for walked in walks {
            #expect(walked.positions == starts)
            #expect(walked.ended == ShowRefusal.atEnd)
        }
        // The first part of A, of B, of A again and of D shows a missing chart; song C's chart is healthy.
        #expect(walks.map(\.missingCount) == [4, 0, 0])
        // After recovery only B's first part has no chart: its own was cleared and its song has none left.
        let bare = try Fix.spot(2, Fix.partB1)
        let withoutChart = walks[1].stops.filter { $0.links.chart == nil }
        #expect(withoutChart.map(\.position) == [bare])
    }

    @Test
    func previousSongVisitsEachEntryOnceAndStopsAtTheStart() throws {
        let walks = try threeWalks(pressing: .previousSong, after: Fix.jumpCommand(5, Fix.partD1))
        let backward = try Array(Fix.songStarts().reversed())
        for walked in walks {
            #expect(walked.positions == backward)
            #expect(walked.ended == ShowRefusal.atStart)
        }
        #expect(walks.map(\.missingCount) == [4, 0, 0])
    }

    @Test
    func neitherEndOfTheSetlistWrapsAroundOnAnyCatalog() throws {
        // At the first part of the first entry the previous commands refuse and the cursor stays where it is.
        let first = try Fix.spot(1, Fix.partA1)
        for command in [ShowNavigationCommand.previousPart, .previousSong] {
            let walks = try threeWalks(pressing: command)
            for walked in walks {
                #expect(walked.positions == [first])
                #expect(walked.ended == ShowRefusal.atStart)
            }
        }
        // At the last part of the last entry the next commands refuse and the cursor stays where it is.
        let last = try Fix.spot(5, Fix.partD1)
        let jump = try Fix.jumpCommand(5, Fix.partD1)
        for command in [ShowNavigationCommand.nextPart, .nextSong] {
            let walks = try threeWalks(pressing: command, after: jump)
            for walked in walks {
                #expect(walked.positions == [last])
                #expect(walked.ended == ShowRefusal.atEnd)
            }
        }
    }
}
