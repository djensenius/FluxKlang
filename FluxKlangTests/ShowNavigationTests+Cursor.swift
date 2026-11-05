import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ShowNavigationCursorTests {
    typealias Fix = ShowNavigationTestFixture

    struct Rig {
        var library: ShowLibrary
        var cursor: ShowCursor
        var sequence: UInt64 = 0
        let catalog: ShowLinkCatalog

        init(bounce: UInt64 = 100, catalog: ShowLinkCatalog? = nil) throws {
            library = try Fix.library()
            cursor = try Fix.cursor(library, bounce: bounce)
            self.catalog = try catalog ?? ShowLinkCatalog.make()
        }

        mutating func press(_ command: ShowNavigationCommand, tick: UInt64? = nil, sequence explicit: UInt64? = nil,
                            expected: ShowPosition? = nil, from source: ShowInputSourceID = Fix.foot) throws
            -> ShowNavigationResult {
            sequence = explicit ?? sequence + 1
            let input = ShowNavigationInput(command, source: source, sequence: sequence,
                                            tick: tick ?? sequence * 1_000, expected: expected)
            return try cursor.navigate(input, in: library, catalog: catalog)
        }

        var here: String { [cursor.position?.entry.rawValue, cursor.position?.part?.rawValue ?? "-"]
            .compactMap(\.self).joined(separator: "/") }
    }

    @Test
    func startsAtTheFirstPartAndBoundsTheBounceWindow() throws {
        let rig = try Rig()
        #expect(rig.here == "e1/a1")
        #expect(try Fix.cursor(rig.library, bounce: ShowLimits.maximumBounceTicks).bounceTicks == 10_000_000_000)
        #expect(throws: ShowRefusal.bounceOutOfRange(10_000_000_001)) {
            try Fix.cursor(rig.library, bounce: 10_000_000_001)
        }
        #expect(throws: ShowRefusal.unknownSetlist(SetlistID(validated: "set.z"))) {
            try ShowCursor.make(setlist: SetlistID(validated: "set.z"), bounceTicks: 0, sources: [Fix.foot],
                                in: rig.library)
        }
        let empty = try rig.library.replacingSetlist(ShowSetlist.make(id: Fix.main, title: "Main"))
        var cursor = try Fix.cursor(empty)
        #expect(cursor.position == nil)
        #expect(throws: ShowRefusal.emptySetlist(Fix.main)) {
            try cursor.navigate(ShowNavigationInput(.nextSong, source: Fix.foot, sequence: 1, tick: 1), in: empty,
                                catalog: rig.catalog)
        }
    }

    @Test
    func partsCrossIntoTheNextEntryAndNothingWraps() throws {
        var rig = try Rig()
        var visited = [rig.here]
        for _ in 0..<8 {
            _ = try rig.press(.nextPart)
            visited.append(rig.here)
        }
        #expect(visited == ["e1/a1", "e1/a2", "e1/a3", "e2/b1", "e2/b2", "e3/a1", "e3/a2", "e3/a3", "e4/-"])
        #expect(throws: ShowRefusal.atEnd) { try rig.press(.nextPart) }
        #expect(throws: ShowRefusal.atEnd) { try rig.press(.nextSong) }
        _ = try rig.press(.previousPart)
        #expect(rig.here == "e3/a3")
        _ = try rig.press(.previousSong)
        #expect(rig.here == "e2/b1")
        _ = try rig.press(.previousPart)
        #expect(rig.here == "e1/a3")
        #expect(throws: ShowRefusal.atStart) { try rig.press(.previousSong) }
        _ = try rig.press(.previousPart)
        #expect(rig.here == "e1/a2")
        _ = try rig.press(.jump(Fix.entries[0], nil))
        #expect(throws: ShowRefusal.atStart) { try rig.press(.previousPart) }
        #expect(rig.here == "e1/a1")
    }

    @Test
    func aRedeliveredSequenceIsIgnoredAndIdempotent() throws {
        var rig = try Rig()
        _ = try rig.press(.nextSong, sequence: 7)
        #expect(try rig.press(.nextSong, sequence: 7) == .ignored(.duplicateSequence(7)))
        #expect(rig.here == "e2/b1")
        #expect(throws: ShowRefusal.staleSequence(last: 7, received: 6)) { try rig.press(.nextSong, sequence: 6) }
    }

    @Test
    func bounceCountsFromTheLastAcceptedPress() throws {
        var rig = try Rig()
        _ = try rig.press(.nextSong, tick: 1_000)
        #expect(try rig.press(.nextSong, tick: 1_050) == .ignored(.bounce(ticksSinceAccepted: 50)))
        #expect(try rig.press(.nextSong, tick: 1_099) == .ignored(.bounce(ticksSinceAccepted: 99)))
        #expect(rig.here == "e2/b1")
        guard case .moved = try rig.press(.nextSong, tick: 1_100) else { Issue.record("not accepted"); return }
        #expect(rig.here == "e3/a1")
        guard case .moved = try rig.press(.nextPart, tick: 1_101) else { Issue.record("other command"); return }
        guard case .moved = try rig.press(.jump(Fix.entries[0], nil), tick: 1_102),
              case .moved = try rig.press(.jump(Fix.entries[0], nil), tick: 1_103) else {
            Issue.record("jump bounced")
            return
        }
        #expect(throws: ShowRefusal.ticksWentBackwards(last: 1_103, received: 1_102)) {
            try rig.press(.nextSong, tick: 1_102)
        }
        _ = try rig.press(.nextSong, tick: 2_000)
        _ = try rig.press(.nextSong, tick: 2_010)
        #expect(throws: ShowRefusal.ticksWentBackwards(last: 2_010, received: 2_005)) {
            try rig.press(.nextSong, tick: 2_005)
        }
    }

    @Test
    func aZeroBounceWindowAcceptsEveryPress() throws {
        var rig = try Rig(bounce: 0)
        guard case .moved = try rig.press(.nextSong, tick: 5), case .moved = try rig.press(.nextSong, tick: 5) else {
            Issue.record("bounced with a zero window")
            return
        }
        #expect(rig.here == "e3/a1")
    }

    @Test
    func eachInputSourceKeepsItsOwnSequence() throws {
        var rig = try Rig()
        let screen = Fix.screen
        guard case .moved = try rig.press(.nextPart, tick: 1_000, sequence: 10),
              case .moved = try rig.press(.nextPart, tick: 2_000, sequence: 1, from: screen),
              case .moved = try rig.press(.nextPart, tick: 3_000, sequence: 11),
              case .moved = try rig.press(.nextPart, tick: 4_000, sequence: 2, from: screen) else {
            Issue.record("interleaved sources were not independent")
            return
        }
        #expect(rig.here == "e2/b2")
        #expect(throws: ShowRefusal.staleSequence(last: 11, received: 9)) { try rig.press(.nextPart, sequence: 9) }
        #expect(throws: ShowRefusal.staleSequence(last: 2, received: 1)) {
            try rig.press(.nextPart, tick: 5_000, sequence: 1, from: screen)
        }
        #expect(try rig.press(.nextPart, tick: 5_000, sequence: 2, from: screen) == .ignored(.duplicateSequence(2)))
        #expect(throws: ShowRefusal.ticksWentBackwards(last: 4_000, received: 3_999)) {
            try rig.press(.nextPart, tick: 3_999, sequence: 12)
        }
        let pedal = ShowInputSourceID(validated: "src.pedal")
        #expect(throws: ShowRefusal.unknownInputSource(pedal)) { try rig.press(.nextPart, sequence: 12, from: pedal) }
        #expect(rig.here == "e2/b2")
    }

    @Test
    func bounceIsPerCommandAcrossSources() throws {
        var rig = try Rig()
        _ = try rig.press(.nextSong, tick: 1_000, sequence: 1)
        #expect(try rig.press(.nextSong, tick: 1_050, sequence: 1, from: Fix.screen)
            == .ignored(.bounce(ticksSinceAccepted: 50)))
        guard case .moved = try rig.press(.nextPart, tick: 1_060, sequence: 2, from: Fix.screen) else {
            Issue.record("another command bounced")
            return
        }
        #expect(rig.here == "e2/b2")
    }

    @Test
    func inputSourcesAreBoundedAndDistinct() throws {
        let library = try Fix.library()
        let sources = (0...ShowLimits.maximumInputSources).map { ShowInputSourceID(rawValue: "src.\($0)")! }
        let make = { (sources: [ShowInputSourceID]) throws(ShowRefusal) in
            try ShowCursor.make(setlist: Fix.main, bounceTicks: 0, sources: sources, in: library)
        }
        #expect(try make(Array(sources.dropLast())).sources == Array(sources.dropLast()))
        #expect(throws: ShowRefusal.inputSourceCountOutOfRange(9)) { try make(sources) }
        #expect(throws: ShowRefusal.inputSourceCountOutOfRange(0)) { try make([]) }
        #expect(try make([Fix.foot]).sources == [Fix.foot])
        #expect(throws: ShowRefusal.duplicateInputSource(Fix.foot)) { try make([Fix.foot, Fix.screen, Fix.foot]) }
    }

    @Test
    func eachCommandKeepsItsOwnBounceSlotThroughInterleaving() throws {
        var rig = try Rig()
        _ = try rig.press(.nextSong, tick: 1_000)
        _ = try rig.press(.nextPart, tick: 1_010)
        #expect(rig.here == "e2/b2")
        #expect(try rig.press(.nextSong, tick: 1_020) == .ignored(.bounce(ticksSinceAccepted: 20)))
        #expect(rig.here == "e2/b2")
        guard case .moved = try rig.press(.previousPart, tick: 1_030) else {
            Issue.record("a different command bounced")
            return
        }
        #expect(rig.here == "e2/b1")
        #expect(try rig.press(.nextPart, tick: 1_040, from: Fix.screen) == .ignored(.bounce(ticksSinceAccepted: 30)))
        #expect(try rig.press(.nextSong, tick: 1_050, from: Fix.screen) == .ignored(.bounce(ticksSinceAccepted: 50)))
        _ = try rig.press(.jump(Fix.entries[0], nil), tick: 1_060)
        #expect(try rig.press(.nextSong, tick: 1_070) == .ignored(.bounce(ticksSinceAccepted: 70)))
        guard case .moved = try rig.press(.nextSong, tick: 1_100, from: Fix.screen) else {
            Issue.record("the window did not close")
            return
        }
        #expect(rig.here == "e2/b1")
    }

    @Test
    func refusedAndIgnoredPressesLeaveTheBounceSlotsAlone() throws {
        var rig = try Rig()
        #expect(throws: ShowRefusal.atStart) { try rig.press(.previousPart, tick: 1_000) }
        _ = try rig.press(.nextPart, tick: 1_010)
        guard case .moved = try rig.press(.previousPart, tick: 1_020) else {
            Issue.record("a refused press opened a bounce window")
            return
        }
        #expect(rig.here == "e1/a1")
    }

    @Test
    func aRefusedPressConsumesNothing() throws {
        var rig = try Rig()
        #expect(throws: ShowRefusal.atStart) { try rig.press(.previousSong, tick: 5_000, sequence: 5) }
        guard case .moved = try rig.press(.nextSong, tick: 5_000, sequence: 5) else {
            Issue.record("refused sequence was remembered")
            return
        }
        #expect(rig.here == "e2/b1")
    }

    @Test
    func anExpectedPositionMustStillHold() throws {
        var rig = try Rig()
        let start = try #require(rig.cursor.position)
        _ = try rig.press(.nextSong, expected: start)
        #expect(throws: ShowRefusal.positionMismatch(expected: start, actual: rig.cursor.position)) {
            try rig.press(.nextSong, expected: start)
        }
        #expect(rig.here == "e2/b1")
    }

    @Test
    func reorderingKeepsTheCursorOnItsEntry() throws {
        var rig = try Rig()
        _ = try rig.press(.nextSong)
        let setlist = try #require(rig.library.setlist(Fix.main))
        rig.library = try rig.library.replacingSetlist(setlist.moving(Fix.entries[1], before: Fix.entries[0]))
        #expect(Fix.entryOrder(rig.library) == ["e2", "e1", "e3", "e4"])
        #expect(rig.cursor.status(in: rig.library) == .current)
        _ = try rig.press(.nextSong)
        #expect(rig.here == "e1/a1")
    }

    @Test
    func aRemovedEntryRefusesRelativeCommandsUntilAJump() throws {
        var rig = try Rig()
        _ = try rig.press(.nextSong)
        let setlist = try #require(rig.library.setlist(Fix.main))
        rig.library = try rig.library.replacingSetlist(setlist.removing(Fix.entries[1]))
        #expect(rig.cursor.status(in: rig.library) == .entryRemoved(Fix.entries[1]))
        for command in [ShowNavigationCommand.nextSong, .previousSong, .nextPart, .previousPart] {
            #expect(throws: ShowRefusal.cursorTargetRemoved(.entryRemoved(Fix.entries[1]))) {
                try rig.press(command)
            }
        }
        #expect(throws: ShowRefusal.cursorTargetRemoved(.entryRemoved(Fix.entries[1]))) {
            try rig.cursor.currentStop(in: rig.library, catalog: rig.catalog)
        }
        #expect(rig.cursor.position?.entry == Fix.entries[1])
        _ = try rig.press(.jump(Fix.entries[2], Fix.partID("a2")))
        #expect(rig.here == "e3/a2")
        _ = try rig.press(.nextSong)
        #expect(rig.here == "e4/-")
    }

    @Test
    func removedPartsAndSetlistsAndBadJumpsAreTyped() throws {
        var rig = try Rig()
        _ = try rig.press(.nextPart)
        let songA = try #require(rig.library.song(Fix.songA))
        rig.library = try rig.library.upsertingSong(songA.removingPart(Fix.partID("a2")), in: rig.catalog)
        #expect(rig.cursor.status(in: rig.library) == .partRemoved(Fix.partID("a2")))
        #expect(throws: ShowRefusal.cursorTargetRemoved(.partRemoved(Fix.partID("a2")))) { try rig.press(.nextPart) }
        #expect(throws: ShowRefusal.unknownEntry(Fix.entryID("e9"))) { try rig.press(.jump(Fix.entryID("e9"), nil)) }
        #expect(throws: ShowRefusal.unknownPart(Fix.partID("b1"))) {
            try rig.press(.jump(Fix.entries[0], Fix.partID("b1")))
        }
        rig.library = try rig.library.removingSetlist(Fix.main)
        #expect(rig.cursor.status(in: rig.library) == .setlistRemoved(Fix.main))
        #expect(throws: ShowRefusal.cursorTargetRemoved(.setlistRemoved(Fix.main))) {
            try rig.press(.jump(Fix.entries[0], nil))
        }
    }

    @Test
    func aPartlessSongThatGainsPartsNeedsAJump() throws {
        let patch = PatchID(validated: "pat.c")
        let links = try SongPartLinks.make(patch: patch)
        for viaInsertingPart in [true, false] {
            var rig = try Rig(catalog: ShowLinkCatalog.make(patches: [(patch, [])]))
            _ = try rig.press(.jump(Fix.entries[3], nil))
            #expect(try rig.cursor.currentStop(in: rig.library, catalog: rig.catalog)?.position.part == nil)
            let songC = try #require(rig.library.song(Fix.songC))
            let parts = try [Fix.part("c1", links: links), Fix.part("c2")]
            let grown = try viaInsertingPart ? songC.insertingPart(parts[0], in: rig.catalog)
                : ShowSong.make(id: Fix.songC, title: songC.title, parts: parts)
            rig.library = try rig.library.upsertingSong(grown, in: rig.catalog)
            let stale = ShowCursorStatus.partsAdded(Fix.songC)
            #expect(rig.cursor.status(in: rig.library) == stale)
            #expect(throws: ShowRefusal.cursorTargetRemoved(stale)) {
                try rig.cursor.currentStop(in: rig.library, catalog: rig.catalog)
            }
            for command in [ShowNavigationCommand.nextPart, .previousPart, .nextSong, .previousSong] {
                #expect(throws: ShowRefusal.cursorTargetRemoved(stale)) { try rig.press(command) }
            }
            #expect(rig.here == "e4/-")
            #expect(try rig.cursor.status(in: rig.library.upsertingSong(songC, in: rig.catalog)) == .current)
            guard case let .moved(stop) = try rig.press(.jump(Fix.entries[3], nil)) else {
                Issue.record("the jump did not recover")
                return
            }
            #expect(rig.here == "e4/c1")
            #expect(stop.links.links == links)
            #expect(try rig.cursor.currentStop(in: rig.library, catalog: rig.catalog) == stop)
        }
    }

    @Test
    func aSongThatLosesItsLastPartNeedsAJump() throws {
        var rig = try Rig()
        _ = try rig.press(.jump(Fix.entries[1], Fix.partID("b2")))
        let lastOnly = try #require(rig.library.song(Fix.songB)).removingPart(Fix.partID("b1"))
        rig.library = try rig.library.upsertingSong(lastOnly, in: rig.catalog)
        #expect(rig.cursor.status(in: rig.library) == .current)
        rig.library = try rig.library.upsertingSong(lastOnly.removingPart(Fix.partID("b2")), in: rig.catalog)
        let stale = ShowCursorStatus.partRemoved(Fix.partID("b2"))
        #expect(rig.cursor.status(in: rig.library) == stale)
        #expect(throws: ShowRefusal.cursorTargetRemoved(stale)) {
            try rig.cursor.currentStop(in: rig.library, catalog: rig.catalog)
        }
        for command in [ShowNavigationCommand.nextPart, .previousPart, .nextSong, .previousSong] {
            #expect(throws: ShowRefusal.cursorTargetRemoved(stale)) { try rig.press(command) }
        }
        #expect(rig.here == "e2/b2")
        _ = try rig.press(.jump(Fix.entries[1], nil))
        #expect(rig.here == "e2/-")
        #expect(try rig.cursor.currentStop(in: rig.library, catalog: rig.catalog)?.position.part == nil)
        _ = try rig.press(.nextPart)
        #expect(rig.here == "e3/a1")
    }

    @Test
    func aRemovedTargetRefusesInsideTheBounceWindowAndConsumesNothing() throws {
        var rig = try Rig(bounce: 100)
        _ = try rig.press(.nextSong, tick: 1_000, sequence: 1)
        let setlist = try #require(rig.library.setlist(Fix.main))
        rig.library = try rig.library.replacingSetlist(setlist.removing(Fix.entries[1]))
        #expect(throws: ShowRefusal.cursorTargetRemoved(.entryRemoved(Fix.entries[1]))) {
            try rig.press(.nextSong, tick: 1_050, sequence: 2)
        }
        #expect(rig.here == "e2/b1")
        guard case .moved = try rig.press(.jump(Fix.entries[2], nil), tick: 1_040, sequence: 2) else {
            Issue.record("the refusal consumed its sequence or tick")
            return
        }
        #expect(rig.here == "e3/a1")
        #expect(try rig.press(.nextSong, tick: 1_070, sequence: 3) == .ignored(.bounce(ticksSinceAccepted: 70)))
        guard case .moved = try rig.press(.nextSong, tick: 1_100, sequence: 4) else {
            Issue.record("the refusal moved the bounce slot")
            return
        }
        #expect(rig.here == "e4/-")
    }

    /// Pins `navigate`'s order: source, sequence, tick, status (relative only), bounce, expected, target.
    @Test
    func navigationChecksRunInTheDocumentedOrder() throws {
        var rig = try Rig()
        let pedal = ShowInputSourceID(validated: "src.pedal")
        let elsewhere = ShowPosition(setlist: Fix.main, entry: Fix.entries[2], part: Fix.partID("a1"))
        _ = try rig.press(.nextSong, tick: 1_000, sequence: 5)
        let stored = rig.cursor.position
        #expect(throws: ShowRefusal.unknownInputSource(pedal)) { try rig.press(.nextSong, tick: 999, from: pedal) }
        #expect(try rig.press(.nextSong, tick: 999, sequence: 5) == .ignored(.duplicateSequence(5)))
        #expect(throws: ShowRefusal.staleSequence(last: 5, received: 4)) {
            try rig.press(.nextSong, tick: 999, sequence: 4)
        }
        #expect(try rig.press(.nextSong, tick: 1_050, sequence: 6, expected: elsewhere)
            == .ignored(.bounce(ticksSinceAccepted: 50)))
        #expect(throws: ShowRefusal.positionMismatch(expected: elsewhere, actual: stored)) {
            try rig.press(.jump(Fix.entryID("e9"), nil), tick: 1_060, sequence: 7, expected: elsewhere)
        }
        let setlist = try #require(rig.library.setlist(Fix.main))
        rig.library = try rig.library.replacingSetlist(setlist.removing(Fix.entries[1]))
        let removed = ShowRefusal.cursorTargetRemoved(.entryRemoved(Fix.entries[1]))
        #expect(throws: ShowRefusal.ticksWentBackwards(last: 1_050, received: 1_049)) {
            try rig.press(.nextSong, tick: 1_049, sequence: 7)
        }
        #expect(try rig.press(.nextSong, tick: 1_060, sequence: 6) == .ignored(.duplicateSequence(6)))
        #expect(throws: removed) { try rig.press(.nextSong, tick: 1_060, sequence: 7, expected: elsewhere) }
        #expect(throws: removed) { try rig.press(.previousPart, tick: 1_060, sequence: 7, expected: elsewhere) }
        #expect(throws: ShowRefusal.positionMismatch(expected: elsewhere, actual: stored)) {
            try rig.press(.jump(Fix.entries[2], nil), tick: 1_060, sequence: 7, expected: elsewhere)
        }
        guard case .moved = try rig.press(.jump(Fix.entries[2], nil), tick: 1_060, sequence: 7, expected: stored) else {
            Issue.record("a jump checked the cursor status")
            return
        }
        #expect(rig.here == "e3/a1")
    }
}

extension ShowNavigationCursorTests {
    /// A cursor made on an empty setlist has no stop while that setlist lives; once it is removed, `currentStop`
    /// and every command refuse with `cursorTargetRemoved` instead of reading as an unpositioned cursor.
    @Test
    func anUnpositionedCursorRefusesOnceItsSetlistIsRemoved() throws {
        let rig = try Rig()
        let empty = try rig.library.replacingSetlist(ShowSetlist.make(id: Fix.main, title: "Main"))
        var cursor = try Fix.cursor(empty)
        let created = cursor
        #expect(cursor.status(in: empty) == .current)
        #expect(try cursor.currentStop(in: empty, catalog: rig.catalog) == nil)
        let gone = try empty.removingSetlist(Fix.main)
        let removed = ShowRefusal.cursorTargetRemoved(.setlistRemoved(Fix.main))
        #expect(cursor.status(in: gone) == .setlistRemoved(Fix.main))
        #expect(throws: removed) { try cursor.currentStop(in: gone, catalog: rig.catalog) }
        let commands: [ShowNavigationCommand] = [.nextPart, .previousPart, .nextSong, .previousSong,
                                                 .jump(Fix.entries[0], nil)]
        for command in commands {
            let input = ShowNavigationInput(command, source: Fix.foot, sequence: 1, tick: 1)
            #expect(throws: removed) { try cursor.navigate(input, in: gone, catalog: rig.catalog) }
        }
        #expect(cursor == created)
        #expect(cursor.position == nil)
        #expect(try cursor.currentStop(in: empty, catalog: rig.catalog) == nil)
    }

    /// A cursor made on an empty setlist stays unpositioned when entries are added: `currentStop` is still `nil`,
    /// the previous commands refuse with `atStart` and change nothing, and a next command starts at the first entry.
    @Test
    func anUnpositionedCursorStartsAtTheFirstEntryOnceItsSetlistGainsEntries() throws {
        let rig = try Rig()
        let empty = try rig.library.replacingSetlist(ShowSetlist.make(id: Fix.main, title: "Main"))
        let created = try Fix.cursor(empty)
        let grown = try empty.replacingSetlist(#require(rig.library.setlist(Fix.main)))
        #expect(created.status(in: grown) == .current)
        #expect(try created.currentStop(in: grown, catalog: rig.catalog) == nil)
        var cursor = created
        for command: ShowNavigationCommand in [.previousPart, .previousSong] {
            let input = ShowNavigationInput(command, source: Fix.foot, sequence: 1, tick: 1)
            #expect(throws: ShowRefusal.atStart) { try cursor.navigate(input, in: grown, catalog: rig.catalog) }
        }
        #expect(cursor == created)
        let first = ShowPosition(setlist: Fix.main, entry: Fix.entries[0], part: Fix.partID("a1"))
        for command: ShowNavigationCommand in [.nextSong, .nextPart] {
            cursor = created
            let result = try cursor.navigate(ShowNavigationInput(command, source: Fix.foot, sequence: 1, tick: 1),
                                             in: grown, catalog: rig.catalog)
            let stop = try #require(try cursor.currentStop(in: grown, catalog: rig.catalog))
            #expect(result == .moved(stop))
            #expect(stop.position == first)
            #expect(stop.song == Fix.songA)
            #expect(cursor.position == first)
        }
    }
}
