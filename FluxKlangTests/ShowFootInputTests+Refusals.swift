import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Show footswitch input refusals")
struct ShowFootInputRefusalTests {
    typealias Fix = ShowFootInputFixture

    private static func targets(_ count: Int) -> [ControlTriggerTargetID: ShowNavigationCommand] {
        Dictionary(uniqueKeysWithValues: (0..<count).map {
            (ControlTriggerTargetID(rawValue: "trg.nav.\($0)")!, ShowNavigationCommand.nextPart)
        })
    }

    private static func sources(_ count: Int) -> [ControlSourceID: ShowInputSourceID] {
        Dictionary(uniqueKeysWithValues: (1...count).map { (Fix.control($0), Fix.show($0)) })
    }

    @Test
    func mapBoundsAcceptNAndRefuseNPlusOne() throws {
        #expect(ShowFootswitchMap.maximumTargets == 64)
        #expect(ShowFootswitchMap.maximumSources == ShowLimits.maximumInputSources)
        #expect(try ShowFootswitchMap.make(commands: Self.targets(64), sources: [:]).commands.count == 64)
        #expect(throws: ShowFootInputRefusal.tooManyTargets(65)) {
            try ShowFootswitchMap.make(commands: Self.targets(65), sources: Self.sources(9))
        }
        #expect(try ShowFootswitchMap.make(commands: [:], sources: Self.sources(8)).sources.count == 8)
        #expect(throws: ShowFootInputRefusal.tooManySources(9)) {
            try ShowFootswitchMap.make(commands: [:], sources: Self.sources(9))
        }
        let empty = try ShowFootswitchMap.make(commands: [:], sources: [:])
        #expect(empty.commands.isEmpty && empty.showSources.isEmpty)
    }

    @Test
    func mapLookupsAndShowSourceOrderFollowControlSourceIDs() throws {
        let map = try ShowFootswitchMap.make(commands: Fix.commands, sources: [
            Fix.control(3): Fix.show(1), Fix.control(1): Fix.show(3), Fix.control(2): Fix.show(2)
        ])
        #expect(map.showSources == [Fix.show(3), Fix.show(2), Fix.show(1)])
        #expect(map.showSource(for: Fix.control(1)) == Fix.show(3))
        #expect(map.showSource(for: Fix.control(4)) == nil)
        #expect(map.command(for: Fix.jumpChorus) == .jump(Fix.entry("e2"), Fix.part("b2")))
        #expect(map.command(for: Fix.fire) == nil)
        #expect(map.commands == Fix.commands)
    }

    @Test
    func twoControlSourcesOnOneShowSourceAreRefused() throws {
        #expect(throws: ShowFootInputRefusal.duplicateShowSource(Fix.show(1), first: Fix.control(2),
                                                                 second: Fix.control(5))) {
            try ShowFootswitchMap.make(commands: Fix.commands, sources: [
                Fix.control(5): Fix.show(1), Fix.control(3): Fix.show(3), Fix.control(2): Fix.show(1)
            ])
        }
        // Three claimants of one show source and a second shared source: the first repeat in control ID order.
        #expect(throws: ShowFootInputRefusal.duplicateShowSource(Fix.show(7), first: Fix.control(1),
                                                                 second: Fix.control(2))) {
            try ShowFootswitchMap.make(commands: [:], sources: [
                Fix.control(4): Fix.show(7), Fix.control(3): Fix.show(8), Fix.control(2): Fix.show(7),
                Fix.control(1): Fix.show(7), Fix.control(6): Fix.show(8)
            ])
        }
    }

    @Test
    func statefulBindingOnANavigationTargetIsRefusedAtInit() throws {
        let map = try Fix.map()
        let toggle = try Fix.binding("bnd.toggle", foot: 2, target: Fix.nextSong, mode: .toggle)
        let latch = try Fix.binding("bnd.latch", foot: 3, target: Fix.jumpChorus, mode: .latch)
        #expect(throws: ShowFootInputRefusal.statefulNavigationBinding(toggle.id, .toggle)) {
            try ShowFootInputAdapter(map: map, bindings: Fix.bindings() + [toggle])
        }
        #expect(throws: ShowFootInputRefusal.statefulNavigationBinding(latch.id, .latch)) {
            try ShowFootInputAdapter(map: map, bindings: [latch] + Fix.bindings())
        }
        // The mode is checked before the source: a toggle from an unmapped footswitch is still a stateful refusal.
        let unmappedToggle = try Fix.binding("bnd.toggle-9", foot: 9, target: Fix.nextPart, mode: .toggle)
        #expect(throws: ShowFootInputRefusal.statefulNavigationBinding(unmappedToggle.id, .toggle)) {
            try ShowFootInputAdapter(map: map, bindings: [unmappedToggle])
        }
        // Stateful bindings on other targets are not navigation and stay allowed, from any control source.
        let other = [try Fix.binding("bnd.fire-latch", foot: 9, target: Fix.fire, mode: .latch),
                     try Fix.binding("bnd.fire-toggle", foot: 1, target: Fix.fire, mode: .toggle)]
        let adapter = try ShowFootInputAdapter(map: map, bindings: Fix.bindings() + other)
        #expect(adapter.map == map)
    }

    @Test
    func unmappedSourceIsRefusedAtInitAndOnInput() throws {
        let map = try Fix.map()
        let stray = try Fix.binding("bnd.foot-7", foot: 7, target: Fix.previousSong)
        #expect(throws: ShowFootInputRefusal.unmappedSource(Fix.control(7))) {
            try ShowFootInputAdapter(map: map, bindings: Fix.bindings() + [stray])
        }
        // A command from a detector the adapter did not validate, on a navigation target from footswitch 7.
        let adapter = try ShowFootInputAdapter(map: map, bindings: Fix.bindings())
        var foreign = try ControlTriggerDetector(bindings: [stray])
        let press = try #require(try Fix.feed(&foreign, "bnd.foot-7", 1))
        #expect(throws: ShowFootInputRefusal.unmappedSource(Fix.control(7))) {
            try adapter.input(for: press, tick: 1)
        }
        // The source refusal comes before the binding check, so an unknown binding ID is reported by its source.
        let renamed = try Fix.binding("bnd.unknown", foot: 8, target: Fix.nextPart, emitsRelease: true)
        var other = try ControlTriggerDetector(bindings: [renamed])
        let held = try #require(try Fix.feed(&other, "bnd.unknown", 1))
        let forgotten = try #require(try other.forgetHeld(on: [Fix.control(8)]).first)
        for command in [held, forgotten] {
            #expect(throws: ShowFootInputRefusal.unmappedSource(Fix.control(8))) {
                try adapter.input(for: command, tick: 1)
            }
        }
    }

    @Test
    func commandFromAnUnvalidatedBindingIsRefused() throws {
        let adapter = try ShowFootInputAdapter(map: Fix.map(), bindings: Fix.bindings())
        let foreign = [
            // Unknown ID on a navigation target from a mapped footswitch.
            try Fix.binding("bnd.unknown", foot: 2, target: Fix.nextSong),
            // A validated ID on another navigation target, and on another mapped footswitch.
            try Fix.binding("bnd.foot-3", foot: 3, target: Fix.previousSong),
            try Fix.binding("bnd.foot-4", foot: 1, target: Fix.previousSong),
            // A validated ID that is a toggle in this detector: its switch-on and switch-off are no momentary press.
            try Fix.binding("bnd.foot-2", foot: 2, target: Fix.previousPart, mode: .toggle),
            // A validated ID that is a latch here: its clear is host-caused, which comes before the action check.
            try Fix.binding("bnd.foot-6", foot: 6, target: Fix.nextPart, mode: .latch)
        ]
        var detector = try ControlTriggerDetector(bindings: foreign)
        for id in ["bnd.unknown", "bnd.foot-3", "bnd.foot-4"] {
            let press = try #require(try Fix.feed(&detector, id, 1))
            #expect(throws: ShowFootInputRefusal.bindingTargetUnknown(press.binding)) {
                try adapter.input(for: press, tick: 1)
            }
        }
        let switchedOn = try #require(try Fix.feed(&detector, "bnd.foot-2", 1))
        _ = try Fix.feed(&detector, "bnd.foot-2", 0)
        let switchedOff = try #require(try Fix.feed(&detector, "bnd.foot-2", 1))
        #expect([switchedOn.action, switchedOff.action] == [.switchedOn, .switchedOff])
        for command in [switchedOn, switchedOff] {
            #expect(throws: ShowFootInputRefusal.bindingTargetUnknown(command.binding)) {
                try adapter.input(for: command, tick: 1)
            }
        }
        _ = try #require(try Fix.feed(&detector, "bnd.foot-6", 1))
        let cleared = try #require(try detector.clear(BindingID("bnd.foot-6")))
        #expect(cleared.cause == .clear)
        #expect(try adapter.input(for: cleared, tick: 1) == .notNavigation(.hostCause))
    }

    @Test
    func adapterBindingBoundsAndDuplicates() throws {
        let map = try Fix.map()
        let maximum = ControlTriggerDetector.maximumBindings
        let many = try (0...maximum).map {
            try ControlTriggerBinding(ControlTriggerBindingFields(
                id: BindingID("bnd.n\($0)"), source: Fix.control(9), target: Fix.fire,
                profile: .absolute(resolution: 128), mode: .momentary, pressAt: 0.5, releaseAt: 0.25))
        }
        _ = try ShowFootInputAdapter(map: map, bindings: Array(many.dropLast()))
        #expect(throws: ShowFootInputRefusal.tooManyBindings(maximum + 1)) {
            try ShowFootInputAdapter(map: map, bindings: many)
        }
        // Duplicate IDs are refused on any target, navigation or not, at the second occurrence.
        let duplicateFire = try Fix.binding("bnd.foot-1-fire", foot: 9, target: Fix.fire, mode: .latch)
        #expect(throws: ShowFootInputRefusal.duplicateBinding(duplicateFire.id)) {
            try ShowFootInputAdapter(map: map, bindings: Fix.bindings() + [duplicateFire])
        }
        let duplicateNext = try Fix.binding("bnd.foot-3", foot: 3, target: Fix.nextSong)
        #expect(throws: ShowFootInputRefusal.duplicateBinding(duplicateNext.id)) {
            try ShowFootInputAdapter(map: map, bindings: Fix.bindings() + [duplicateNext])
        }
        #expect(try ShowFootInputAdapter(map: map, bindings: []).map == map)
    }
}
