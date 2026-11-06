import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Songs A (a1, a2, a3), B (b1, b2) and C (c1); setlist `set.main` plays e1 A, e2 B, e3 C, e4 A. Footswitch `n` is
/// control source `ctl.foot-n`, speaking for show source `src.foot-n`. Bindings: foot 1 next part (with release
/// commands) and, on the same control, a toggle on a non-navigation target; foot 2 previous part; foot 3 next
/// song; foot 4 previous song; foot 5 two jumps; foot 6 next part again.
enum ShowFootInputFixture {
    static let main = SetlistID(validated: "set.main")
    static let songA = SongID(validated: "song.a")
    static let songB = SongID(validated: "song.b")
    static let songC = SongID(validated: "song.c")
    static let nextPart = ControlTriggerTargetID(validated: "trg.nav.next-part")
    static let previousPart = ControlTriggerTargetID(validated: "trg.nav.previous-part")
    static let nextSong = ControlTriggerTargetID(validated: "trg.nav.next-song")
    static let previousSong = ControlTriggerTargetID(validated: "trg.nav.previous-song")
    static let jumpChorus = ControlTriggerTargetID(validated: "trg.nav.jump-chorus")
    static let jumpEncore = ControlTriggerTargetID(validated: "trg.nav.jump-encore")
    static let fire = ControlTriggerTargetID(validated: "trg.action.fire")

    static func entry(_ raw: String) -> SetlistEntryID { SetlistEntryID(rawValue: raw)! }
    static func part(_ raw: String) -> SongPartID { SongPartID(rawValue: raw)! }
    static func control(_ number: Int) -> ControlSourceID { ControlSourceID(rawValue: "ctl.foot-\(number)")! }
    static func show(_ number: Int) -> ShowInputSourceID { ShowInputSourceID(rawValue: "src.foot-\(number)")! }

    static var commands: [ControlTriggerTargetID: ShowNavigationCommand] {
        [nextPart: .nextPart, previousPart: .previousPart, nextSong: .nextSong, previousSong: .previousSong,
         jumpChorus: .jump(entry("e2"), part("b2")), jumpEncore: .jump(entry("e4"), nil)]
    }

    /// Footswitches 1…6, each onto its own show source.
    static func map(sources: ClosedRange<Int> = 1...6) throws -> ShowFootswitchMap {
        try ShowFootswitchMap.make(commands: commands,
                                   sources: Dictionary(uniqueKeysWithValues: sources.map { (control($0), show($0)) }))
    }

    static func binding(_ id: String, foot: Int, target: ControlTriggerTargetID, mode: ControlTriggerMode = .momentary,
                        emitsRelease: Bool? = nil) throws -> ControlTriggerBinding {
        try ControlTriggerBinding(ControlTriggerBindingFields(
            id: BindingID(id), source: control(foot), target: target, profile: .absolute(resolution: 128),
            mode: mode, pressAt: 0.5, releaseAt: 0.25, emitsRelease: emitsRelease))
    }

    static func bindings() throws -> [ControlTriggerBinding] {
        [try binding("bnd.foot-1", foot: 1, target: nextPart, emitsRelease: true),
         try binding("bnd.foot-1-fire", foot: 1, target: fire, mode: .toggle),
         try binding("bnd.foot-2", foot: 2, target: previousPart),
         try binding("bnd.foot-3", foot: 3, target: nextSong),
         try binding("bnd.foot-4", foot: 4, target: previousSong),
         try binding("bnd.foot-5", foot: 5, target: jumpChorus),
         try binding("bnd.foot-5-encore", foot: 5, target: jumpEncore),
         try binding("bnd.foot-6", foot: 6, target: nextPart)]
    }

    /// Footswitches 1…9 are current and every target is `.live`.
    static func truth() throws -> ControlTriggerHostTruth {
        try ControlTriggerHostTruth(sources: Set((1...9).map(control)),
                                    targets: Dictionary(uniqueKeysWithValues: (Array(commands.keys) + [fire])
                                        .map { ($0, ControlClass.live) }))
    }

    static func library() throws -> ShowLibrary {
        func song(_ id: SongID, _ parts: [String]) throws -> ShowSong {
            try ShowSong.make(id: id, title: "Song \(id)",
                              parts: parts.map { try SongPart.make(id: part($0), title: "Part \($0)") })
        }
        let setlist = try ShowSetlist.make(id: main, title: "Main", entries: [
            SetlistEntry.make(id: entry("e1"), song: songA), SetlistEntry.make(id: entry("e2"), song: songB),
            SetlistEntry.make(id: entry("e3"), song: songC), SetlistEntry.make(id: entry("e4"), song: songA)
        ])
        return try ShowLibrary.make(songs: [song(songA, ["a1", "a2", "a3"]), song(songB, ["b1", "b2"]),
                                            song(songC, ["c1"])], setlists: [setlist])
    }

    /// Feeds one position to binding `id` of `detector` from that binding's own control source.
    static func feed(_ detector: inout ControlTriggerDetector, _ id: String,
                     _ position: Double) throws -> ControlTriggerCommand? {
        let binding = try BindingID(id)
        let source = try #require(detector.bindings.first { $0.id == binding }).source
        return try detector.handle(.absolute(normalized: position), from: source, binding: binding, truth: truth())
    }
}

/// A real B4 detector feeding the adapter, feeding a real SH1 cursor.
struct ShowFootInputRig {
    typealias Fix = ShowFootInputFixture

    var detector: ControlTriggerDetector
    let adapter: ShowFootInputAdapter
    var cursor: ShowCursor
    var library: ShowLibrary
    let catalog: ShowLinkCatalog

    init(bounce: UInt64 = 0, after lastSequence: UInt64 = 0) throws {
        let bindings = try Fix.bindings()
        let map = try Fix.map()
        detector = try ControlTriggerDetector(bindings: bindings, after: lastSequence)
        adapter = try ShowFootInputAdapter(map: map, bindings: bindings)
        library = try Fix.library()
        cursor = try ShowCursor.make(setlist: Fix.main, bounceTicks: bounce, sources: map.showSources, in: library)
        catalog = try ShowLinkCatalog.make()
    }

    mutating func feed(_ id: String, _ position: Double) throws -> ControlTriggerCommand? {
        try Fix.feed(&detector, id, position)
    }

    /// Sends `command` through the adapter and, when it is navigation, the cursor; `nil` when it is not navigation.
    mutating func deliver(_ command: ControlTriggerCommand, at tick: UInt64,
                          expected: ShowPosition? = nil) throws -> ShowNavigationResult? {
        guard case .input(let input) = try adapter.input(for: command, tick: tick, expected: expected) else {
            return nil
        }
        return try cursor.navigate(input, in: library, catalog: catalog)
    }

    /// Presses and lifts the footswitch of binding `id` at `tick`; returns the cursor's answer to the press.
    mutating func tap(_ id: String, at tick: UInt64) throws -> ShowNavigationResult? {
        let press = try #require(try feed(id, 1))
        let result = try deliver(press, at: tick)
        if let release = try feed(id, 0) {
            #expect(try adapter.input(for: release, tick: tick) == .notNavigation(.release))
        }
        return result
    }

    var here: String {
        [cursor.position?.entry.rawValue, cursor.position?.part?.rawValue ?? "-"].compactMap(\.self)
            .joined(separator: "/")
    }
}

@Suite("Show footswitch input end to end")
struct ShowFootInputTests {
    typealias Fix = ShowFootInputFixture

    @Test
    func footswitchesWalkPartsAndSongs() throws {
        var rig = try ShowFootInputRig()
        var visited = [rig.here]
        for (tick, id) in ["bnd.foot-1", "bnd.foot-6", "bnd.foot-1", "bnd.foot-3", "bnd.foot-2", "bnd.foot-4",
                           "bnd.foot-3", "bnd.foot-3", "bnd.foot-2"].enumerated() {
            let result = try #require(try rig.tap(id, at: UInt64(tick)))
            guard case .moved(let stop) = result else { throw ShowFootInputTestFailure.notMoved(result) }
            #expect(stop.position == rig.cursor.position)
            visited.append(rig.here)
        }
        #expect(visited == ["e1/a1", "e1/a2", "e1/a3", "e2/b1", "e3/c1", "e2/b2", "e1/a1", "e2/b1", "e3/c1",
                            "e2/b2"])
        #expect(throws: ShowRefusal.atStart) {
            var start = try ShowFootInputRig()
            _ = try start.tap("bnd.foot-4", at: 0)
        }
    }

    @Test
    func pressPassesTheDetectorSequenceTickAndSourceThrough() throws {
        var rig = try ShowFootInputRig(after: 41)
        let first = try #require(try rig.feed("bnd.foot-3", 1))
        #expect(first.sequence == 42)
        #expect(try rig.adapter.input(for: first, tick: 7) ==
                .input(ShowNavigationInput(.nextSong, source: Fix.show(3), sequence: 42, tick: 7)))
        // The release of footswitch 1 takes sequence 44, so its next press (45) leaves a gap the cursor accepts.
        let held = try #require(try rig.feed("bnd.foot-1", 1))
        let release = try #require(try rig.feed("bnd.foot-1", 0))
        let again = try #require(try rig.feed("bnd.foot-1", 1))
        #expect([held.sequence, release.sequence, again.sequence] == [43, 44, 45])
        #expect(try rig.deliver(held, at: 100) != nil)
        #expect(try rig.deliver(release, at: 100) == nil)
        #expect(try rig.adapter.input(for: again, tick: 101) ==
                .input(ShowNavigationInput(.nextPart, source: Fix.show(1), sequence: 45, tick: 101)))
        #expect(try rig.deliver(again, at: 101) != nil)
        #expect(rig.here == "e1/a3")
    }

    @Test
    func jumpSurvivesASetlistReorderBetweenPresses() throws {
        var rig = try ShowFootInputRig()
        #expect(try rig.tap("bnd.foot-5", at: 1) != nil)
        #expect(rig.here == "e2/b2")
        _ = try rig.tap("bnd.foot-4", at: 2)
        #expect(rig.here == "e1/a1")
        let setlist = try #require(rig.library.setlist(Fix.main))
        rig.library = try rig.library.replacingSetlist(setlist.moving(Fix.entry("e2"), before: nil)
            .moving(Fix.entry("e4"), before: Fix.entry("e1")))
        #expect(rig.library.setlist(Fix.main)?.entries.map(\.id.rawValue) == ["e4", "e1", "e3", "e2"])
        _ = try rig.tap("bnd.foot-5", at: 3)
        #expect(rig.here == "e2/b2")
        _ = try rig.tap("bnd.foot-5-encore", at: 4)
        #expect(rig.here == "e4/a1")
        _ = try rig.tap("bnd.foot-1", at: 5)
        #expect(rig.here == "e4/a2")
        #expect(rig.adapter.map == (try Fix.map()))
    }

    @Test
    func redeliveredCommandIsADuplicateSequence() throws {
        var rig = try ShowFootInputRig()
        let press = try #require(try rig.feed("bnd.foot-1", 1))
        let firstInput = try rig.adapter.input(for: press, tick: 10)
        #expect(try rig.adapter.input(for: press, tick: 10) == firstInput)
        #expect(try rig.deliver(press, at: 10) != nil)
        let moved = rig.cursor
        #expect(try rig.deliver(press, at: 10) == .ignored(.duplicateSequence(press.sequence)))
        #expect(try rig.deliver(press, at: 500) == .ignored(.duplicateSequence(press.sequence)))
        #expect(rig.cursor == moved)
        #expect(rig.here == "e1/a2")
    }

    @Test
    func twoFootswitchesOnOneCommandShareItsBounceWindow() throws {
        var rig = try ShowFootInputRig(bounce: 100)
        #expect(try rig.tap("bnd.foot-1", at: 1_000) != nil)
        #expect(rig.here == "e1/a2")
        let bounced = try #require(try rig.feed("bnd.foot-6", 1))
        guard case .input(let input) = try rig.adapter.input(for: bounced, tick: 1_050) else {
            throw ShowFootInputTestFailure.notInput(bounced)
        }
        #expect(input.source == Fix.show(6))
        #expect(input.source != Fix.show(1))
        #expect(try rig.deliver(bounced, at: 1_050) == .ignored(.bounce(ticksSinceAccepted: 50)))
        #expect(rig.here == "e1/a2")
        // Another command has its own window; the bounced footswitch moves once the window has passed.
        _ = try rig.feed("bnd.foot-6", 0)
        #expect(try rig.tap("bnd.foot-3", at: 1_060) != nil)
        #expect(rig.here == "e2/b1")
        #expect(try rig.tap("bnd.foot-6", at: 1_099) == .ignored(.bounce(ticksSinceAccepted: 99)))
        #expect(try rig.tap("bnd.foot-6", at: 1_100) != nil)
        #expect(rig.here == "e2/b2")
    }

    @Test
    func releaseEdgeIsNotNavigation() throws {
        var rig = try ShowFootInputRig()
        _ = try #require(try rig.feed("bnd.foot-1", 1))
        let release = try #require(try rig.feed("bnd.foot-1", 0))
        #expect(release.action == .release)
        #expect(release.cause == .input)
        #expect(try rig.adapter.input(for: release, tick: 3) == .notNavigation(.release))
        #expect(try rig.deliver(release, at: 3) == nil)
        #expect(rig.here == "e1/a1")
        // Footswitch 2 does not ask for release commands, so its release edge emits nothing at all.
        _ = try #require(try rig.feed("bnd.foot-2", 1))
        #expect(try rig.feed("bnd.foot-2", 0) == nil)
    }

    @Test
    func forgetHeldReleaseIsHostCausedNotNavigation() throws {
        var rig = try ShowFootInputRig()
        let press = try #require(try rig.feed("bnd.foot-1", 1))
        #expect(try rig.deliver(press, at: 1) != nil)
        let forgotten = try rig.detector.forgetHeld(on: [Fix.control(1)])
        #expect(forgotten.map(\.action) == [.release])
        #expect(forgotten.map(\.cause) == [.disconnect])
        let release = try #require(forgotten.first)
        #expect(try rig.adapter.input(for: release, tick: 2) == .notNavigation(.hostCause))
        let before = rig.cursor
        #expect(try rig.deliver(release, at: 2) == nil)
        #expect(rig.cursor == before)
        // The footswitch presses again as an edge after reconnecting and navigates as usual.
        let next = try #require(try rig.feed("bnd.foot-1", 1))
        #expect(try rig.deliver(next, at: 3) != nil)
        #expect(rig.here == "e1/a3")
    }

    @Test
    func unmappedTriggerPassesThroughForEveryAction() throws {
        var rig = try ShowFootInputRig()
        let switchedOn = try #require(try rig.feed("bnd.foot-1-fire", 1))
        _ = try rig.feed("bnd.foot-1-fire", 0)
        let switchedOff = try #require(try rig.feed("bnd.foot-1-fire", 1))
        #expect([switchedOn.action, switchedOff.action] == [.switchedOn, .switchedOff])
        for command in [switchedOn, switchedOff] {
            #expect(try rig.adapter.input(for: command, tick: 1) == .notNavigation(.unmappedTarget))
        }
        // A momentary press on a target the map does not name passes through too, even from a control source the
        // map does not know: another consumer owns it.
        var other = try ControlTriggerDetector(bindings: [
            Fix.binding("bnd.foot-9", foot: 9, target: Fix.fire, emitsRelease: true)
        ])
        let press = try #require(try Fix.feed(&other, "bnd.foot-9", 1))
        let release = try #require(try Fix.feed(&other, "bnd.foot-9", 0))
        let forgotten = try other.forgetHeld(on: [Fix.control(9)])
        #expect(forgotten.isEmpty)
        for command in [press, release] {
            #expect(try rig.adapter.input(for: command, tick: 1) == .notNavigation(.unmappedTarget))
        }
        #expect(rig.here == "e1/a1")
    }

    @Test
    func expectedPositionPassesThroughToTheCursor() throws {
        var rig = try ShowFootInputRig()
        let here = try #require(rig.cursor.position)
        let press = try #require(try rig.feed("bnd.foot-3", 1))
        guard case .input(let input) = try rig.adapter.input(for: press, tick: 1, expected: here) else {
            throw ShowFootInputTestFailure.notInput(press)
        }
        #expect(input.expected == here)
        #expect(try rig.deliver(press, at: 1, expected: here) != nil)
        _ = try rig.feed("bnd.foot-3", 0)
        let stale = try #require(try rig.feed("bnd.foot-3", 1))
        let moved = rig.cursor
        #expect(throws: ShowRefusal.positionMismatch(expected: here, actual: rig.cursor.position)) {
            try rig.deliver(stale, at: 2, expected: here)
        }
        #expect(rig.cursor == moved)
        #expect(rig.here == "e2/b1")
    }

    /// Foot input through the detector and adapter answers exactly as onscreen input with the same commands,
    /// sequences and ticks, across seeded presses, releases, re-deliveries and bounce.
    @Test
    func footInputMatchesOnscreenNavigationAcrossSeededRuns() throws {
        let ids = ["bnd.foot-1", "bnd.foot-2", "bnd.foot-3", "bnd.foot-4", "bnd.foot-5", "bnd.foot-5-encore",
                   "bnd.foot-6", "bnd.foot-1-fire"]
        let targets = Dictionary(uniqueKeysWithValues: try Fix.bindings().map { ($0.id.rawValue, $0.target) })
        var seen: Set<String> = []
        for seed in UInt64(1)...8 {
            var random = ShowFootInputSplitMix(seed: seed)
            var rig = try ShowFootInputRig(bounce: 40)
            var onscreen = rig.cursor
            var tick: UInt64 = 0
            var delivered: [ControlTriggerCommand] = []
            for _ in 0..<120 {
                tick += random.next() % 60
                let id = ids[Int(random.next() % UInt64(ids.count))]
                let redeliver = random.next() % 8 == 0 && !delivered.isEmpty
                let command: ControlTriggerCommand?
                if redeliver {
                    command = delivered[Int(random.next() % UInt64(delivered.count))]
                } else {
                    command = try rig.feed(id, random.next() % 2 == 0 ? 1 : 0)
                }
                guard let command else { continue }
                if !redeliver { delivered.append(command) }
                let foot = Result<ShowNavigationResult?, any Error>(catching: { try rig.deliver(command, at: tick) })
                var expected: Result<ShowNavigationResult?, any Error> = .success(nil)
                let isPress = command.action == .press && command.cause == .input
                if isPress, let navigation = Fix.commands[try #require(targets[command.binding.rawValue])] {
                    let show = Fix.show(Int(String(command.source.rawValue.last!))!)
                    let input = ShowNavigationInput(navigation, source: show, sequence: command.sequence, tick: tick)
                    expected = Result(catching: { try onscreen.navigate(input, in: rig.library, catalog: rig.catalog) })
                }
                #expect(String(describing: foot) == String(describing: expected))
                seen.insert(Self.kind(of: foot))
                #expect(rig.cursor == onscreen)
            }
        }
        #expect(seen == ["notNavigation", "moved", "bounce", "duplicate", "refused"])
    }

    private static func kind(of result: Result<ShowNavigationResult?, any Error>) -> String {
        switch result {
        case .success(nil): "notNavigation"
        case .success(.moved): "moved"
        case .success(.ignored(.bounce)): "bounce"
        case .success(.ignored(.duplicateSequence)): "duplicate"
        case .failure: "refused"
        }
    }
}

enum ShowFootInputTestFailure: Error {
    case notMoved(ShowNavigationResult)
    case notInput(ControlTriggerCommand)
}

/// SplitMix64, seeded per run.
struct ShowFootInputSplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
