import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias SessionFix = ShowFootInputFixture

private enum ShowFootSessionTestFailure: Error {
    case notMoved(ShowFootSessionOutcome)
}

/// A real B4 detector feeding a `ShowFootSession`; the library and catalog are per-call arguments of the session.
private struct SessionRig {
    var detector: ControlTriggerDetector
    var session: ShowFootSession
    var library: ShowLibrary
    let catalog: ShowLinkCatalog

    init(bounce: UInt64 = 0, extra: [ShowInputSourceID] = []) throws {
        let bindings = try SessionFix.bindings()
        let map = try SessionFix.map()
        detector = try ControlTriggerDetector(bindings: bindings)
        library = try SessionFix.library()
        catalog = try ShowLinkCatalog.make()
        var sources = map.showSources
        sources.append(contentsOf: extra)
        let cursor = try ShowCursor.make(setlist: SessionFix.main, bounceTicks: bounce, sources: sources, in: library)
        session = try ShowFootSession(map: map, bindings: bindings, cursor: cursor)
    }

    mutating func feed(_ id: String, _ position: Double) throws -> ControlTriggerCommand? {
        try SessionFix.feed(&detector, id, position)
    }

    mutating func deliver(_ command: ControlTriggerCommand, at tick: UInt64,
                          expected: ShowPosition? = nil) throws -> ShowFootSessionOutcome {
        try session.deliver(command, tick: tick, expected: expected, in: library, catalog: catalog)
    }

    mutating func navigate(_ input: ShowNavigationInput) throws -> ShowFootSessionOutcome {
        try session.navigate(input, in: library, catalog: catalog)
    }

    /// Presses and lifts the footswitch of binding `id` at `tick`; returns the session's answer to the press.
    mutating func tap(_ id: String, at tick: UInt64) throws -> ShowFootSessionOutcome {
        let press = try #require(try feed(id, 1))
        let outcome = try deliver(press, at: tick)
        if let release = try feed(id, 0) {
            let lifted = try deliver(release, at: tick)
            #expect(lifted == .notNavigation(.release))
        }
        return outcome
    }

    mutating func expectRefused(_ command: ControlTriggerCommand, at tick: UInt64, expected: ShowPosition? = nil,
                                as refusal: ShowFootSessionRefusal) {
        let before = session
        #expect(throws: refusal) { try deliver(command, at: tick, expected: expected) }
        #expect(session == before)
    }

    var here: String {
        [session.cursor.position?.entry.rawValue, session.cursor.position?.part?.rawValue ?? "-"].compactMap(\.self)
            .joined(separator: "/")
    }
}

/// The session next to the test rig of the adapter lane, fed the same commands and ticks.
private struct ParityRig {
    var rig: SessionRig
    var reference: ShowFootInputRig

    init(bounce: UInt64) throws {
        rig = try SessionRig(bounce: bounce)
        reference = try ShowFootInputRig(bounce: bounce)
    }

    mutating func step(_ command: ControlTriggerCommand, at tick: UInt64) throws {
        var answer: ShowNavigationResult?
        var refused: ShowRefusal?
        do {
            answer = try reference.deliver(command, at: tick)
        } catch let error as ShowRefusal {
            refused = error
        }
        if let refused {
            rig.expectRefused(command, at: tick, as: .show(refused))
        } else {
            let outcome = try rig.deliver(command, at: tick)
            #expect(Self.matches(outcome, answer))
        }
        #expect(rig.session.cursor == reference.cursor)
    }

    private static func matches(_ outcome: ShowFootSessionOutcome, _ answer: ShowNavigationResult?) -> Bool {
        guard let answer else {
            if case .notNavigation = outcome { return true }
            return false
        }
        switch answer {
        case .moved(let stop): return outcome == .moved(stop)
        case .ignored(let ignoral): return outcome == .ignored(ignoral)
        }
    }
}

private func makeCursor(_ sources: [ShowInputSourceID]) throws -> ShowCursor {
    try ShowCursor.make(setlist: SessionFix.main, bounceTicks: 0, sources: sources, in: SessionFix.library())
}

@Suite("Show foot session")
struct ShowFootSessionTests {
    @Test
    func showFootSessionGoldenWalkMovesThroughNineFootPresses() throws {
        var rig = try SessionRig()
        var visited = [rig.here]
        let script = ["bnd.foot-1", "bnd.foot-6", "bnd.foot-1", "bnd.foot-3", "bnd.foot-2", "bnd.foot-4",
                      "bnd.foot-3", "bnd.foot-3", "bnd.foot-2"]
        for (tick, id) in script.enumerated() {
            let outcome = try rig.tap(id, at: UInt64(tick))
            guard case .moved(let stop) = outcome else { throw ShowFootSessionTestFailure.notMoved(outcome) }
            #expect(stop.position == rig.session.cursor.position)
            visited.append(rig.here)
        }
        #expect(visited == ["e1/a1", "e1/a2", "e1/a3", "e2/b1", "e3/c1", "e2/b2", "e1/a1", "e2/b1", "e3/c1",
                            "e2/b2"])
    }

    @Test
    func showFootSessionMatchesTheTestRigStepForStep() throws {
        var parity = try ParityRig(bounce: 100)
        let first = try #require(try parity.rig.feed("bnd.foot-1", 1))
        try parity.step(first, at: 1_000)
        let lift = try #require(try parity.rig.feed("bnd.foot-1", 0))
        try parity.step(lift, at: 1_000)
        try parity.step(first, at: 1_010)
        let bounced = try #require(try parity.rig.feed("bnd.foot-6", 1))
        try parity.step(bounced, at: 1_050)
        _ = try parity.rig.feed("bnd.foot-6", 0)
        let fireOn = try #require(try parity.rig.feed("bnd.foot-1-fire", 1))
        try parity.step(fireOn, at: 1_060)
        _ = try parity.rig.feed("bnd.foot-1-fire", 0)
        let fireOff = try #require(try parity.rig.feed("bnd.foot-1-fire", 1))
        try parity.step(fireOff, at: 1_070)
        let song = try #require(try parity.rig.feed("bnd.foot-3", 1))
        try parity.step(song, at: 1_200)
        let held = try #require(try parity.rig.feed("bnd.foot-1", 1))
        try parity.step(held, at: 1_400)
        let forgotten = try #require(try parity.rig.detector.forgetHeld(on: [SessionFix.control(1)]).first)
        try parity.step(forgotten, at: 1_450)
        let again = try #require(try parity.rig.feed("bnd.foot-6", 1))
        try parity.step(again, at: 1_500)
        try parity.step(bounced, at: 1_600)
        let previous = try #require(try parity.rig.feed("bnd.foot-4", 1))
        try parity.step(previous, at: 1_700)
        // e1/a1 -> a2 (foot 1), duplicate and bounce stay, song step -> e2/b1, part -> b2, part falls to song -> c1,
        // the stale re-delivery is refused, previous song -> start of e2.
        #expect(parity.rig.here == "e2/b1")
    }

    @Test
    func showFootSessionNotNavigationLeavesTheSessionEqual() throws {
        var rig = try SessionRig()
        let press = try #require(try rig.feed("bnd.foot-1", 1))
        _ = try rig.deliver(press, at: 100)
        let release = try #require(try rig.feed("bnd.foot-1", 0))
        var before = rig.session
        // Tick 50 is lower than the last accepted tick: a release never reaches the cursor.
        #expect(try rig.deliver(release, at: 50) == .notNavigation(.release))
        #expect(rig.session == before)
        let again = try #require(try rig.feed("bnd.foot-1", 1))
        _ = try rig.deliver(again, at: 101)
        let forgotten = try #require(try rig.detector.forgetHeld(on: [SessionFix.control(1)]).first)
        before = rig.session
        #expect(try rig.deliver(forgotten, at: 102) == .notNavigation(.hostCause))
        #expect(rig.session == before)
        var other = try SessionRig()
        let switchedOn = try #require(try other.feed("bnd.foot-1-fire", 1))
        before = other.session
        #expect(try other.deliver(switchedOn, at: 1) == .notNavigation(.unmappedTarget))
        #expect(other.session == before)
        _ = try other.feed("bnd.foot-1-fire", 0)
        let switchedOff = try #require(try other.feed("bnd.foot-1-fire", 1))
        #expect(switchedOff.action == .switchedOff)
        #expect(try other.deliver(switchedOff, at: 2) == .notNavigation(.unmappedTarget))
        #expect(other.session == before)
    }

    @Test
    func showFootSessionIgnoredPressesChangeOnlyWhatTheCursorRecords() throws {
        var rig = try SessionRig()
        let press = try #require(try rig.feed("bnd.foot-1", 1))
        _ = try rig.deliver(press, at: 10)
        let moved = rig.session
        #expect(try rig.deliver(press, at: 10) == .ignored(.duplicateSequence(press.sequence)))
        #expect(try rig.deliver(press, at: 500) == .ignored(.duplicateSequence(press.sequence)))
        #expect(rig.session == moved)
        var windowed = try SessionRig(bounce: 100)
        _ = try windowed.tap("bnd.foot-1", at: 1_000)
        let accepted = windowed.session
        let bounced = try #require(try windowed.feed("bnd.foot-6", 1))
        #expect(try windowed.deliver(bounced, at: 1_050) == .ignored(.bounce(ticksSinceAccepted: 50)))
        #expect(windowed.session != accepted)
        #expect(windowed.here == "e1/a2")
        _ = try windowed.feed("bnd.foot-6", 0)
        let later = try #require(try windowed.feed("bnd.foot-6", 1))
        _ = try windowed.deliver(later, at: 1_100)
        #expect(windowed.here == "e1/a3")
    }

    @Test
    func showFootSessionRefusalsLeaveTheSessionEqual() throws {
        var rig = try SessionRig()
        let start = try #require(try rig.feed("bnd.foot-4", 1))
        rig.expectRefused(start, at: 1, as: .show(.atStart))
        let song = try #require(try rig.feed("bnd.foot-3", 1))
        _ = try rig.deliver(song, at: 100)
        let here = try #require(rig.session.cursor.position)
        let step = try #require(try rig.feed("bnd.foot-2", 1))
        _ = try rig.deliver(step, at: 120, expected: here)
        _ = try rig.feed("bnd.foot-2", 0)
        let stalePosition = try #require(try rig.feed("bnd.foot-2", 1))
        rig.expectRefused(stalePosition, at: 130, expected: here,
                          as: .show(.positionMismatch(expected: here, actual: rig.session.cursor.position)))
        _ = try rig.feed("bnd.foot-2", 0)
        let backwards = try #require(try rig.feed("bnd.foot-2", 1))
        rig.expectRefused(backwards, at: 50, as: .show(.ticksWentBackwards(last: 120, received: 50)))
        // The adapter refuses first: this command also has a backwards tick.
        let unknown = try SessionFix.binding("bnd.unknown", foot: 2, target: SessionFix.nextSong)
        var foreign = try ControlTriggerDetector(bindings: [unknown])
        let unknownPress = try #require(try SessionFix.feed(&foreign, "bnd.unknown", 1))
        rig.expectRefused(unknownPress, at: 50, as: .foot(.bindingTargetUnknown(unknown.id)))
        let stray = try SessionFix.binding("bnd.foot-7", foot: 7, target: SessionFix.previousSong)
        var other = try ControlTriggerDetector(bindings: [stray])
        let strayPress = try #require(try SessionFix.feed(&other, "bnd.foot-7", 1))
        rig.expectRefused(strayPress, at: 200, as: .foot(.unmappedSource(SessionFix.control(7))))
        var rebuilt = try ControlTriggerDetector(bindings: SessionFix.bindings())
        let reissued = try #require(try SessionFix.feed(&rebuilt, "bnd.foot-3", 1))
        #expect(reissued.sequence == 1)
        rig.expectRefused(reissued, at: 200, as: .show(.staleSequence(last: song.sequence, received: 1)))
    }

    @Test
    func showFootSessionTicksReachTheCursorUnchangedAtTheLargestTick() throws {
        var rig = try SessionRig()
        _ = try rig.tap("bnd.foot-1", at: 1)
        #expect(rig.here == "e1/a2")
        let song = try #require(try rig.feed("bnd.foot-3", 1))
        let outcome = try rig.deliver(song, at: UInt64.max)
        guard case .moved = outcome else { throw ShowFootSessionTestFailure.notMoved(outcome) }
        #expect(rig.here == "e2/b1")
        let step = try #require(try rig.feed("bnd.foot-2", 1))
        _ = try rig.deliver(step, at: UInt64.max)
        #expect(rig.here == "e1/a3")
    }

    @Test
    func showFootSessionSequenceContractNeedsAResumedDetector() throws {
        var rig = try SessionRig()
        _ = try rig.tap("bnd.foot-1", at: 1)
        _ = try rig.tap("bnd.foot-3", at: 2)
        #expect(rig.detector.lastSequence == 3)
        var resumed = try ControlTriggerDetector(bindings: SessionFix.bindings(), after: rig.detector.lastSequence)
        let resumedPress = try #require(try SessionFix.feed(&resumed, "bnd.foot-2", 1))
        #expect(resumedPress.sequence == 4)
        _ = try rig.deliver(resumedPress, at: 10)
        #expect(rig.here == "e1/a3")
        var restartedThree = try ControlTriggerDetector(bindings: SessionFix.bindings())
        let usedThree = try #require(try SessionFix.feed(&restartedThree, "bnd.foot-3", 1))
        rig.expectRefused(usedThree, at: 20, as: .show(.staleSequence(last: 3, received: 1)))
        var restartedOne = try ControlTriggerDetector(bindings: SessionFix.bindings())
        let usedOne = try #require(try SessionFix.feed(&restartedOne, "bnd.foot-1", 1))
        let before = rig.session
        #expect(try rig.deliver(usedOne, at: 20) == .ignored(.duplicateSequence(1)))
        #expect(rig.session == before)
        var restartedFive = try ControlTriggerDetector(bindings: SessionFix.bindings())
        let unusedFive = try #require(try SessionFix.feed(&restartedFive, "bnd.foot-5", 1))
        _ = try rig.deliver(unusedFive, at: 20)
        #expect(rig.here == "e2/b2")
    }

    @Test
    func showFootSessionInitAndOnscreenNavigationShareTheCursor() throws {
        let map = try SessionFix.map()
        let bindings = try SessionFix.bindings()
        // The adapter refusal wins: this fixture also has a cursor that lacks five footswitch sources.
        let duplicate = try SessionFix.binding("bnd.foot-3", foot: 3, target: SessionFix.nextSong)
        let bare = try makeCursor([SessionFix.show(1)])
        #expect(throws: ShowFootSessionRefusal.foot(.duplicateBinding(duplicate.id))) {
            try ShowFootSession(map: map, bindings: bindings + [duplicate], cursor: bare)
        }
        let fiveSources = try makeCursor((1...5).map(SessionFix.show))
        #expect(throws: ShowFootSessionRefusal.cursorMissingSource(SessionFix.show(6))) {
            try ShowFootSession(map: map, bindings: bindings, cursor: fiveSources)
        }
        let fourSources = try makeCursor((1...4).map(SessionFix.show))
        #expect(throws: ShowFootSessionRefusal.cursorMissingSource(SessionFix.show(5))) {
            try ShowFootSession(map: map, bindings: bindings, cursor: fourSources)
        }
        let screen = ShowInputSourceID(validated: "src.screen")
        var rig = try SessionRig(bounce: 100, extra: [screen])
        _ = try rig.tap("bnd.foot-1", at: 1_000)
        let nextPart = ShowNavigationInput(.nextPart, source: screen, sequence: 1, tick: 1_050)
        #expect(try rig.navigate(nextPart) == .ignored(.bounce(ticksSinceAccepted: 50)))
        let nextSong = ShowNavigationInput(.nextSong, source: screen, sequence: 2, tick: 1_060)
        let outcome = try rig.navigate(nextSong)
        guard case .moved(let stop) = outcome else { throw ShowFootSessionTestFailure.notMoved(outcome) }
        #expect(stop.position == rig.session.cursor.position)
        #expect(rig.here == "e2/b1")
        _ = try rig.tap("bnd.foot-2", at: 1_100)
        #expect(rig.here == "e1/a3")
        let before = rig.session
        let owned = ShowNavigationInput(.nextPart, source: SessionFix.show(1), sequence: 9, tick: 2_000)
        #expect(throws: ShowFootSessionRefusal.footSource(SessionFix.show(1))) { try rig.navigate(owned) }
        #expect(rig.session == before)
        let ownedLast = ShowNavigationInput(.nextPart, source: SessionFix.show(6), sequence: 9, tick: 2_000)
        #expect(throws: ShowFootSessionRefusal.footSource(SessionFix.show(6))) { try rig.navigate(ownedLast) }
        #expect(rig.session == before)
        let withoutFirst = try makeCursor((2...6).map(SessionFix.show))
        #expect(throws: ShowFootSessionRefusal.cursorMissingSource(SessionFix.show(1))) {
            try ShowFootSession(map: map, bindings: bindings, cursor: withoutFirst)
        }
        let other = ShowInputSourceID(validated: "src.other")
        let undeclared = ShowNavigationInput(.nextPart, source: other, sequence: 1, tick: 2_000)
        #expect(throws: ShowFootSessionRefusal.show(.unknownInputSource(other))) { try rig.navigate(undeclared) }
        #expect(rig.session == before)
        let eightMap = try SessionFix.map(sources: 1...8)
        let eight = try makeCursor((1...8).map(SessionFix.show))
        let full = try ShowFootSession(map: eightMap, bindings: bindings, cursor: eight)
        #expect(full.cursor.sources.count == 8)
        let seven = try makeCursor((1...7).map(SessionFix.show))
        #expect(throws: ShowFootSessionRefusal.cursorMissingSource(SessionFix.show(8))) {
            try ShowFootSession(map: eightMap, bindings: bindings, cursor: seven)
        }
    }

    @Test
    func showFootSessionJumpSurvivesReorderAndRecoversARemovedEntry() throws {
        var rig = try SessionRig()
        _ = try rig.tap("bnd.foot-5", at: 1)
        #expect(rig.here == "e2/b2")
        _ = try rig.tap("bnd.foot-4", at: 2)
        #expect(rig.here == "e1/a1")
        let setlist = try #require(rig.library.setlist(SessionFix.main))
        rig.library = try rig.library.replacingSetlist(setlist.moving(SessionFix.entry("e2"), before: nil)
            .moving(SessionFix.entry("e4"), before: SessionFix.entry("e1")))
        _ = try rig.tap("bnd.foot-5", at: 3)
        #expect(rig.here == "e2/b2")
        var removed = try SessionRig()
        removed.library = try removed.library.replacingSetlist(setlist.removing(SessionFix.entry("e1")))
        let press = try #require(try removed.feed("bnd.foot-1", 1))
        let gone = ShowCursorStatus.entryRemoved(SessionFix.entry("e1"))
        removed.expectRefused(press, at: 1, as: .show(.cursorTargetRemoved(gone)))
        _ = try removed.tap("bnd.foot-5", at: 2)
        #expect(removed.here == "e2/b2")
        _ = try removed.tap("bnd.foot-6", at: 3)
        #expect(removed.here == "e3/c1")
    }

    @Test
    func showFootSessionEqualInputsGiveEqualSessionsAndCopiesAreIndependent() throws {
        var left = try SessionRig(bounce: 20)
        var right = try SessionRig(bounce: 20)
        let script = ["bnd.foot-1", "bnd.foot-3", "bnd.foot-6", "bnd.foot-2", "bnd.foot-5", "bnd.foot-4"]
        for (index, id) in script.enumerated() {
            let tick = UInt64(index) * 30
            let leftOutcome = try left.tap(id, at: tick)
            let rightOutcome = try right.tap(id, at: tick)
            #expect(leftOutcome == rightOutcome)
            #expect(left.session == right.session)
        }
        var copy = left.session
        let press = try #require(try left.feed("bnd.foot-3", 1))
        let original = try left.deliver(press, at: 500)
        let copied = try copy.deliver(press, tick: 500, in: left.library, catalog: left.catalog)
        #expect(original == copied)
        #expect(copy == left.session)
        #expect(copy != right.session)
    }
}
