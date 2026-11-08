import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ShowStageProjectionTests {
    struct StaleCase {
        let name: String
        let edited: ShowLibrary
        let status: ShowCursorStatus
        let entry: String
        let part: String?
    }

    private func project(_ library: ShowLibrary, entry: String, part: String?) throws -> ShowStageProjection {
        let cursor = try Fix.cursor(library, at: entry, part: part)
        return try ShowStageProjection.make(library: library, cursor: cursor, catalog: Fix.catalog())
    }

    @Test
    func theMainSetlistsBoundariesPutEachCommandOnItsOwnTargetAndOmitTheOnesPastTheEnds() throws {
        let library = try Fix.mainLibrary()
        let first = try project(library, entry: "e1", part: "a1")
        #expect(first.previousPart == nil)
        #expect(first.previousSong == nil)
        #expect(first.nextPart?.position == Fix.pos("e1", "a2"))
        #expect(first.nextSong?.position == Fix.pos("e2", "b1"))

        let lastPart = try project(library, entry: "e1", part: "a3")
        #expect(lastPart.nextPart?.position == Fix.pos("e2", "b1"))
        #expect(lastPart.nextSong?.position == Fix.pos("e2", "b1"))
        #expect(lastPart.previousPart?.position == Fix.pos("e1", "a2"))

        let second = try project(library, entry: "e2", part: "b1")
        #expect(second.previousPart?.position == Fix.pos("e1", "a3"))
        #expect(second.previousSong?.position == Fix.pos("e1", "a1"))
        #expect(second.nextPart?.position == Fix.pos("e2", "b2"))

        let third = try project(library, entry: "e3", part: "a1")
        #expect(third.previousPart?.position == Fix.pos("e2", "b2"))
        #expect(third.previousSong?.position == Fix.pos("e2", "b1"))
        #expect(third.nextSong?.position == Fix.pos("e4", nil))

        let last = try project(library, entry: "e4", part: nil)
        #expect(last.nextPart == nil)
        #expect(last.nextSong == nil)
        #expect(last.previousPart?.position == Fix.pos("e3", "a3"))
        #expect(last.previousSong?.position == Fix.pos("e3", "a1"))
    }

    @Test
    func nextPartOfALastPartAndNextSongReachTheSameLineButAMiddlePartStaysInItsSong() throws {
        let library = try Fix.mainLibrary()
        let lastPart = try project(library, entry: "e2", part: "b2")
        #expect(lastPart.nextPart == lastPart.nextSong)
        let middle = try project(library, entry: "e1", part: "a2")
        #expect(middle.nextPart?.position == Fix.pos("e1", "a3"))
        #expect(middle.nextSong?.position == Fix.pos("e2", "b1"))
        #expect(middle.previousPart?.position == Fix.pos("e1", "a1"))
        #expect(middle.previousSong == nil)
    }

    @Test
    func aSetlistOfPartlessSongsMovesEntryByEntryWithNoParts() throws {
        let songs = try Fix.songs([Fix.songC: [], Fix.songE: []])
        let library = try Fix.library(songs: songs, entries: [Fix.entry("e1", Fix.songC), Fix.entry("e2", Fix.songE),
                                                              Fix.entry("e3", Fix.songC)])
        let middle = try project(library, entry: "e2", part: nil)
        #expect(middle.nextPart?.position == Fix.pos("e3", nil))
        #expect(middle.nextSong?.position == Fix.pos("e3", nil))
        #expect(middle.previousPart?.position == Fix.pos("e1", nil))
        #expect(middle.previousSong?.position == Fix.pos("e1", nil))
        let now = try #require(middle.now)
        #expect(now.partNumber == nil)
        #expect(now.partTitle == nil)
        #expect(now.mark == nil)
        #expect(now.partCount == 0)
    }

    @Test
    func aRepeatedSongGivesEveryEntryItsOwnNumberAndEachJumpToItIsANewSong() throws {
        let library = try Fix.mainLibrary()
        let atFirst = try project(library, entry: "e1", part: "a3")
        let atThird = try project(library, entry: "e3", part: "a1")
        #expect(atFirst.now?.songNumber == 1)
        #expect(atThird.now?.songNumber == 3)
        #expect(atThird.now?.song == atFirst.now?.song)
        #expect(atThird.nextSong?.songNumber == 4)
        #expect(atThird.previousSong?.songNumber == 2)

        let single = try Fix.library(songs: Fix.songs([Fix.songD: ["d1"]]),
                                     entries: [Fix.entry("e1", Fix.songD), Fix.entry("e2", Fix.songD)])
        let repeated = try project(single, entry: "e1", part: "d1")
        let next = try #require(repeated.nextPart)
        #expect(next.position == Fix.pos("e2", "d1"))
        #expect(next.songNumber == 2)
        #expect(next.startsNewSong)
        #expect(repeated.nextSong == next)
        #expect(repeated.now?.startsNewSong == false)
    }

    @Test
    func startsNewSongIsTrueOnlyWhenTheEntryDiffersFromTheCursorsEntry() throws {
        let library = try Fix.mainLibrary()
        let middle = try project(library, entry: "e1", part: "a2")
        #expect(middle.nextPart?.startsNewSong == false)
        #expect(middle.previousPart?.startsNewSong == false)
        #expect(middle.nextSong?.startsNewSong == true)
        let atSecond = try project(library, entry: "e2", part: "b1")
        #expect(atSecond.previousPart?.startsNewSong == true)
        #expect(atSecond.previousSong?.startsNewSong == true)
        #expect(atSecond.nextPart?.startsNewSong == false)
    }

    @Test
    func aStaleCursorShowsNoLineAndNoSongStatusAndTheStatusIsTheOneNavigateRefusesWith() throws {
        let catalog = try Fix.catalog()
        let library = try Fix.mainLibrary()
        let setlist = try #require(library.setlist(Fix.list))
        let removedEntry = try library.replacingSetlist(setlist.removing(Fix.entryID("e2")))
        let songA = try #require(library.song(Fix.songA))
        let removedPart = try library.upsertingSong(songA.removingPart(Fix.partID("a2")), in: catalog)
        let songC = try #require(library.song(Fix.songC))
        let addedParts = try library.upsertingSong(songC.insertingPart(Fix.part("c1"), in: catalog), in: catalog)
        let cases: [StaleCase] = [
            StaleCase(name: "setlist", edited: try library.removingSetlist(Fix.list),
                      status: .setlistRemoved(Fix.list), entry: "e1", part: "a1"),
            StaleCase(name: "entry", edited: removedEntry, status: .entryRemoved(Fix.entryID("e2")),
                      entry: "e2", part: "b1"),
            StaleCase(name: "part", edited: removedPart, status: .partRemoved(Fix.partID("a2")),
                      entry: "e1", part: "a2"),
            StaleCase(name: "parts", edited: addedParts, status: .partsAdded(Fix.songC), entry: "e4", part: nil)
        ]
        for item in cases {
            let (name, edited, status) = (item.name, item.edited, item.status)
            let cursor = try Fix.cursor(library, at: item.entry, part: item.part)
            let projection = try ShowStageProjection.make(library: edited, cursor: cursor, catalog: catalog)
            #expect(projection.cursorState == .stale(status), "\(name)")
            #expect(projection.now == nil, "\(name)")
            for destination in ShowStageDestination.allCases {
                #expect(projection.line(for: destination) == nil, "\(name) \(destination)")
                let reach = Fix.reach(destination, from: cursor, in: edited, catalog: catalog)
                #expect(reach == .refused(.cursorTargetRemoved(status)), "\(name) \(destination)")
            }
            let gone = name == "setlist"
            #expect((projection.setlistTitle == nil) == gone, "\(name)")
            #expect((projection.entryCount == nil) == gone, "\(name)")
            #expect(projection.setlist == Fix.list, "\(name)")
        }
    }

    @Test
    func aStaleCursorKeepsTheSetlistTitleAndEntryCountWhileItsTargetIsGone() throws {
        let catalog = try Fix.catalog()
        let library = try Fix.mainLibrary()
        let setlist = try #require(library.setlist(Fix.list))
        let edited = try library.replacingSetlist(setlist.removing(Fix.entryID("e2")))
        let cursor = try Fix.cursor(library, at: "e2", part: "b1")
        let projection = try ShowStageProjection.make(library: edited, cursor: cursor, catalog: catalog)
        #expect(projection.setlistTitle == "Stage")
        #expect(projection.entryCount == 3)
    }

    @Test
    func aJumpRecoversAStaleCursorAndTheProjectionIsPositionedAgain() throws {
        let catalog = try Fix.catalog()
        let library = try Fix.mainLibrary()
        let setlist = try #require(library.setlist(Fix.list))
        let edited = try library.replacingSetlist(setlist.removing(Fix.entryID("e2")))
        var cursor = try Fix.cursor(library, at: "e2", part: "b1")
        let jump = ShowNavigationInput(.jump(Fix.entryID("e3"), nil), source: Fix.foot, sequence: 2, tick: 0)
        _ = try cursor.navigate(jump, in: edited, catalog: catalog)
        let projection = try ShowStageProjection.make(library: edited, cursor: cursor, catalog: catalog)
        #expect(projection.cursorState == .positioned)
        #expect(projection.now?.position == Fix.pos("e3", "a1"))
        #expect(projection.now?.songNumber == 2)
        #expect(projection.previousSong?.position == Fix.pos("e1", "a1"))
    }

    @Test
    func aCursorOnAnEntryKeepsItAcrossAMoveAndTheLinesFollowTheNewNeighboursAndNumbers() throws {
        let catalog = try Fix.catalog()
        let library = try Fix.mainLibrary()
        let setlist = try #require(library.setlist(Fix.list))
        let cursor = try Fix.cursor(library, at: "e3", part: "a2")
        let before = try ShowStageProjection.make(library: library, cursor: cursor, catalog: catalog)
        #expect(before.now?.songNumber == 3)
        #expect(before.previousSong?.position == Fix.pos("e2", "b1"))

        let toFront = try library.replacingSetlist(setlist.moving(Fix.entryID("e3"), before: Fix.entryID("e1")))
        let front = try ShowStageProjection.make(library: toFront, cursor: cursor, catalog: catalog)
        #expect(front.now?.position == Fix.pos("e3", "a2"))
        #expect(front.now?.songNumber == 1)
        #expect(front.previousSong == nil)
        #expect(front.previousPart?.position == Fix.pos("e3", "a1"))
        #expect(front.nextSong?.position == Fix.pos("e1", "a1"))
        #expect(front.nextSong?.songNumber == 2)

        let toBack = try library.replacingSetlist(setlist.moving(Fix.entryID("e1"), before: nil))
        let back = try ShowStageProjection.make(library: toBack, cursor: cursor, catalog: catalog)
        #expect(back.now?.songNumber == 2)
        #expect(back.previousSong?.position == Fix.pos("e2", "b1"))
        #expect(back.nextSong?.position == Fix.pos("e4", nil))
        for destination in ShowStageDestination.allCases {
            let reach = Fix.reach(destination, from: cursor, in: toBack, catalog: catalog)
            if let line = back.line(for: destination) {
                #expect(reach == .moved(line.position), "\(destination)")
            } else {
                #expect(reach == .refused(Fix.boundary(destination)), "\(destination)")
            }
        }
    }

    @Test
    func librariesBuiltFromTheSameSongsInAnotherOrderGiveEqualProjections() throws {
        let catalog = try Fix.catalog()
        let songA = try Fix.song(Fix.songA, parts: ["a1", "a2", "a3"])
        let songB = try Fix.song(Fix.songB, parts: ["b1", "b2"])
        let songC = try Fix.song(Fix.songC, parts: [])
        let entries = [Fix.entry("e1", Fix.songA), Fix.entry("e2", Fix.songB), Fix.entry("e3", Fix.songA),
                       Fix.entry("e4", Fix.songC)]
        let forward = try Fix.library(songs: [songA, songB, songC], entries: entries)
        let reversed = try Fix.library(songs: [songC, songB, songA], entries: entries)
        let rotated = try Fix.library(songs: [songB, songC, songA], entries: entries)
        let spots = Fix.spots(forward)
        #expect(spots.count == 9)
        for spot in spots {
            let one = try Fix.cursor(forward, at: spot.entry.rawValue, part: spot.part?.rawValue)
            let two = try Fix.cursor(reversed, at: spot.entry.rawValue, part: spot.part?.rawValue)
            let three = try Fix.cursor(rotated, at: spot.entry.rawValue, part: spot.part?.rawValue)
            let left = try ShowStageProjection.make(library: forward, cursor: one, catalog: catalog)
            let right = try ShowStageProjection.make(library: reversed, cursor: two, catalog: catalog)
            let turned = try ShowStageProjection.make(library: rotated, cursor: three, catalog: catalog)
            #expect(left == right, "\(spot.entry)")
            #expect(left == turned, "\(spot.entry)")
        }
    }
}
