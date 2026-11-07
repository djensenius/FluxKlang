import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMixerTests {
    struct Scenario {
        let name: String
        let old: SpatialRenderPlan
        let unionKeys: Int
        let changes: Bool
        let new: SpatialRenderPlan
    }

    static let base: [Source] = [source("a", -0.8), source("b", 0.1, channels: 2), source("c", 0.9)]

    static func baseScenarios() throws -> [Scenario] {
        let old = try plan([0, 1, 2], of: 3, base)
        let sources = base
        let moved = [sources[0], source("b", -0.6, channels: 2), sources[2]]
        return try [
            Scenario(name: "mute", old: old, unionKeys: 4, changes: true,
                     new: plan([0, 1, 2], of: 3, base, masks: [mute(1)], renormalize: true)),
            Scenario(name: "solo", old: old, unionKeys: 4, changes: true,
                     new: plan([0, 1, 2], of: 3, base, masks: [solo(2)])),
            Scenario(name: "loss", old: old, unionKeys: 4, changes: true,
                     new: plan([0, 1, 2], of: 3, base, renormalize: true, lost: [0])),
            Scenario(name: "permuted", old: old, unionKeys: 4, changes: false,
                     new: plan([0, 1, 2], of: 3, [sources[2], sources[0], sources[1]])),
            Scenario(name: "speakersReversed", old: old, unionKeys: 4, changes: false,
                     new: plan([2, 1, 0], of: 3, base)),
            Scenario(name: "removedSource", old: old, unionKeys: 4, changes: true,
                     new: plan([0, 1, 2], of: 3, [sources[0], sources[2]])),
            Scenario(name: "addedSource", old: old, unionKeys: 5, changes: true,
                     new: plan([0, 1, 2], of: 3, base + [source("d", -0.2)])),
            Scenario(name: "removedSpeaker", old: old, unionKeys: 4, changes: true,
                     new: plan([0, 2], of: 3, base)),
            Scenario(name: "addedSpeaker", old: plan([0, 2], of: 3, base), unionKeys: 4, changes: true, new: old),
            Scenario(name: "channelDropped", old: old, unionKeys: 4, changes: true,
                     new: plan([0, 1, 2], of: 3, [sources[0], source("b", 0.1), sources[2]])),
            Scenario(name: "channelAdded", old: plan([0, 1, 2], of: 3, [sources[0], source("b", 0.1), sources[2]]),
                     unionKeys: 4, changes: true, new: old),
            Scenario(name: "moved", old: old, unionKeys: 4, changes: true, new: plan([0, 1, 2], of: 3, moved))
        ]
    }

    /// Per union key, then speaker ID: the effective gain on every frame, probed with a constant 1 on one row.
    static func effective(
        _ scenario: Scenario, ramp: Int, frames: Int
    ) throws -> [String: [String: [Float]]] {
        var table: [String: [String: [Float]]] = [:]
        var probe = try mixer(scenario.old)
        try probe.transition(to: scenario.new, rampFrames: ramp)
        let keys = probe.inputRowKeys.map { "\($0.source.rawValue)#\($0.channel)" }
        for (index, key) in keys.enumerated() {
            var fresh = try mixer(scenario.old)
            try fresh.transition(to: scenario.new, rampFrames: ramp)
            let ids = fresh.outputSpeakerIDs.map(\.rawValue)
            let rows = keys.indices.map { constant($0 == index ? 1 : 0, frames) }
            let block = run(&fresh, rows, frames: frames)
            table[key] = Dictionary(uniqueKeysWithValues: zip(ids, block.columns))
        }
        return table
    }

    static func violations(_ scenario: Scenario, ramp: Int) throws -> [String] {
        let frames = ramp + 4
        let table = try effective(scenario, ramp: ramp, frames: frames)
        var bad: [String] = []
        if table.count != scenario.unionKeys { bad.append("keys \(table.count)") }
        for (key, columns) in table {
            let parts = key.split(separator: "#")
            try #require(parts.count == 2)
            let channel = Int(parts[1]) ?? -1
            for (speaker, samples) in columns {
                let number = Int(speaker.dropFirst(4)) ?? -1
                let from = gain(scenario.old, String(parts[0]), channel, number)
                let target = gain(scenario.new, String(parts[0]), channel, number)
                for (frame, value) in samples.enumerated() {
                    let tooHigh = value > max(from, target) || value < min(from, target)
                    let wrongEnd = (frame == 0 && value != from) || (frame >= ramp && value != target)
                    if tooHigh || wrongEnd { bad.append("\(scenario.name) \(key) \(speaker) f\(frame) \(value)") }
                }
            }
        }
        return bad
    }

    @Test func theFixtureGivesEachChannelOfASourceItsOwnGains() throws {
        let plan = try Self.plan([0, 1, 2], of: 3, Self.base)
        let differing = (0..<3).filter { Self.gain(plan, "b", 0, $0) != Self.gain(plan, "b", 1, $0) }
        #expect(!differing.isEmpty)
        #expect(Self.gain(plan, "b", 2, 0) == 0 && Self.gain(plan, "zz", 0, 0) == 0 && Self.gain(plan, "a", 0, 9) == 0)
    }

    @Test func everyAlignedGainStaysBetweenItsOldAndNewValueOnEveryFrame() throws {
        for scenario in try Self.baseScenarios() {
            let bad = try Self.violations(scenario, ramp: 8)
            #expect(bad == [], "\(scenario.name)")
        }
    }

    @Test func everyScenarioReallyChangesOrKeepsTheGainsItClaims() throws {
        for scenario in try Self.baseScenarios() {
            let changed = scenario.old.gains != scenario.new.gains
                || scenario.old.rowSources != scenario.new.rowSources
                || scenario.old.speakerIDs != scenario.new.speakerIDs
            #expect(changed, "\(scenario.name) differs structurally")
            let table = try Self.effective(scenario, ramp: 8, frames: 3)
            let moves = table.contains { entry in entry.value.contains { Set($0.value).count > 1 } }
            #expect(moves == scenario.changes, "\(scenario.name)")
        }
    }

    @Test func aMissingKeyRampsToOrFromZeroAndNeverOvershoots() throws {
        let old = try Self.plan([0, 1, 2], of: 3, Self.base)
        let new = try Self.plan([0, 1, 2], of: 3, [Self.base[0], Self.base[2], Self.source("d", -0.2)])
        let scenario = Scenario(name: "swap", old: old, unionKeys: 5, changes: true, new: new)
        let table = try Self.effective(scenario, ramp: 4, frames: 6)
        let oldOnly = try #require(table["b#0"]?["spk.0"])
        let newOnly = try #require(table["d#0"]?["spk.0"])
        let from = Self.gain(old, "b", 0, 0)
        let target = Self.gain(new, "d", 0, 0)
        #expect(from > 0 && target > 0)
        #expect(oldOnly == [from, from * 0.75, from * 0.5, from * 0.25, 0, 0])
        #expect(newOnly == [0, target * 0.25, target * 0.5, target * 0.75, target, target])
    }

    @Test func aMutedSourceFadesAsAnExactStaircase() throws {
        let loud = try Self.unitPlan([Self.source("a", 0)])
        var mixer = try Self.mixer(loud)
        try mixer.transition(to: Self.plan([0], of: 1, [Self.source("a", 0)], masks: [Self.mute(0)]), rampFrames: 4)
        let block = Self.run(&mixer, [Self.constant(1, 6)], frames: 6)
        #expect(block.columns == [[1, 0.75, 0.5, 0.25, 0, 0]])
        let state = Self.snapshot(mixer)
        #expect(state.ramp == 4 && state.progress == 4 && !state.transitioning)
        #expect(Self.run(&mixer, [Self.constant(1, 2)], frames: 2).columns == [[0, 0]])
        let muted = try Self.plan([0], of: 1, [Self.source("a", 0)], masks: [Self.mute(0)])
        var rising = try Self.mixer(muted)
        try rising.transition(to: loud, rampFrames: 4)
        #expect(Self.run(&rising, [Self.constant(1, 6)], frames: 6).columns == [[0, 0.25, 0.5, 0.75, 1, 1]])
        #expect(Self.run(&rising, [Self.constant(1, 2)], frames: 2).columns == [[1, 1]])
    }

    @Test func rampsOfZeroAndOneSwitchOnTheFirstAndSecondFrame() throws {
        let muted = try Self.plan([0], of: 1, [Self.source("a", 0)], masks: [Self.mute(0)])
        var instant = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        try instant.transition(to: muted, rampFrames: 0)
        #expect(Self.run(&instant, [Self.constant(1, 3)], frames: 3).columns == [[0, 0, 0]])
        #expect(!Self.snapshot(instant).transitioning)
        var short = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        try short.transition(to: muted, rampFrames: 1)
        #expect(Self.snapshot(short).transitioning)
        #expect(Self.run(&short, [Self.constant(1, 3)], frames: 3).columns == [[1, 0, 0]])
        #expect(!Self.snapshot(short).transitioning)
        var shrinking = try Self.mixer(Self.plan([0, 1], of: 2, [Self.source("a", 0), Self.source("b", 0.5)]))
        try shrinking.transition(to: Self.plan([1], of: 2, [Self.source("a", 0)]), rampFrames: 0)
        let shrunk = Self.snapshot(shrinking)
        #expect(shrunk.keys == ["a#0"] && shrunk.speakers == ["spk.1"] && shrunk.rows == 1 && shrunk.columns == 1)
    }

    @Test func aRampOfFortyEightThousandFramesRunsToItsExactMidpointAndEnd() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        let muted = try Self.plan([0], of: 1, [Self.source("a", 0)], masks: [Self.mute(0)])
        try mixer.transition(to: muted, rampFrames: 48_000)
        let ones = [Self.constant(1, 64)]
        for _ in 0..<375 { _ = Self.run(&mixer, ones, frames: 64) }
        #expect(Self.snapshot(mixer).progress == 24_000)
        #expect(Self.run(&mixer, ones, frames: 1).columns == [[0.5]])
        for _ in 0..<374 { _ = Self.run(&mixer, ones, frames: 64) }
        _ = Self.run(&mixer, ones, frames: 62)
        let late = Self.snapshot(mixer)
        #expect(late.progress == 47_999 && late.transitioning)
        _ = Self.run(&mixer, ones, frames: 1)
        let done = Self.snapshot(mixer)
        #expect(done.progress == 48_000 && !done.transitioning)
    }

    @Test func progressCountsSamplesAndCollapsesTheUnionExactlyAtTheRampEnd() throws {
        var mixer = try Self.mixer(Self.plan([0, 1], of: 2, [Self.source("a", 0), Self.source("b", 0.5)]))
        try mixer.transition(to: Self.plan([1], of: 2, [Self.source("a", 0)]), rampFrames: 8)
        #expect(Self.snapshot(mixer).keys == ["a#0", "b#0"] && Self.snapshot(mixer).speakers == ["spk.1", "spk.0"])
        _ = Self.run(&mixer, [[], []], frames: 7)
        let seven = Self.snapshot(mixer)
        #expect(seven.progress == 7 && seven.ramp == 8 && seven.transitioning)
        #expect(seven.keys.count == 2 && seven.speakers.count == 2)
        _ = Self.run(&mixer, [[], []], frames: 1)
        let eight = Self.snapshot(mixer)
        #expect(eight.progress == 8 && !eight.transitioning)
        #expect(eight.keys == ["a#0"] && eight.speakers == ["spk.1"] && eight.rows == 1 && eight.columns == 1)
    }

    @Test func progressNeverPassesTheRampLengthWhenABlockOvershoots() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        try mixer.transition(to: Self.plan([0], of: 1, [Self.source("a", 0.5)]), rampFrames: 10)
        for expected in [4, 8, 10] {
            _ = Self.run(&mixer, [Self.constant(1, 4)], frames: 4)
            #expect(Self.snapshot(mixer).progress == expected)
        }
    }

    @Test func theUnionListsNewRowsAndSpeakersFirstThenTheOldOnlyOnesInOldOrder() throws {
        var mixer = try Self.mixer(
            Self.plan([0, 1, 2], of: 4, [Self.source("a", 0), Self.source("b", 0.5, channels: 2),
                                         Self.source("d", -0.5, channels: 2)])
        )
        let new = try Self.plan([2, 3], of: 4, [Self.source("c", 0), Self.source("b", 0.5, channels: 2)])
        try mixer.transition(to: new, rampFrames: 4)
        let state = Self.snapshot(mixer)
        #expect(state.keys == ["c#0", "b#0", "b#1", "a#0", "d#0", "d#1"] && state.rows == 6)
        #expect(state.speakers == ["spk.2", "spk.3", "spk.0", "spk.1"] && state.columns == 4)
        #expect(state.plan == new)
        _ = Self.run(&mixer, [[], [], [], [], [], []], frames: 4)
        let after = Self.snapshot(mixer)
        #expect(after.keys == ["c#0", "b#0", "b#1"] && after.speakers == ["spk.2", "spk.3"])
    }

    @Test func aTransitionBlockEqualsTheStaticOutputWhenOnlyTheSourceOrderChanges() throws {
        let sources = Self.base
        let natural = try Self.plan([0, 1, 2], of: 3, sources, delays: [Delay(speaker: 1, frames: 3)])
        let reordered = try Self.plan([0, 1, 2], of: 3, [sources[2], sources[0], sources[1]],
                                      delays: [Delay(speaker: 1, frames: 3)])
        var moving = try Self.mixer(natural)
        var fixed = try Self.mixer(natural)
        _ = Self.stream(&moving, total: 12, block: 12)
        _ = Self.stream(&fixed, total: 12, block: 12)
        try moving.transition(to: reordered, rampFrames: 16)
        let one = Self.stream(&moving, total: 40, block: 5)
        let two = Self.stream(&fixed, total: 40, block: 5)
        #expect(one == two)
        #expect(one["spk.1"]?.contains { $0 != 0 } == true)
    }

    @Test func theDelayTapCrossfadesLinearlyFromTheOldToTheNewDelay() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        _ = Self.run(&mixer, [Self.counting(8)], frames: 8)
        try mixer.transition(to: Self.unitPlan([Self.source("a", 0)], delay: 4), rampFrames: 4)
        let rows = [(9...15).map { Float($0) }]
        #expect(Self.run(&mixer, rows, frames: 7).columns == [[9, 9, 9, 9, 9, 10, 11]])
    }

    @Test func theDelayTapCrossfadesFromALongDelayBackToNone() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)], delay: 4))
        _ = Self.run(&mixer, [Self.counting(8)], frames: 8)
        try mixer.transition(to: Self.unitPlan([Self.source("a", 0)]), rampFrames: 4)
        let rows = [(9...15).map { Float($0) }]
        #expect(Self.run(&mixer, rows, frames: 7).columns == [[5, 7, 9, 11, 13, 14, 15]])
    }

    @Test func aSpeakerLeavingTheLayoutKeepsItsOldDelayUntilTheRampEndsAndThenIsCut() throws {
        let old = try Self.plan([0, 1], of: 2, [Self.source("a", 0.5)], delays: [Delay(speaker: 1, frames: 4)])
        let new = try Self.plan([0], of: 2, [Self.source("a", 0.5)])
        let leaving = Self.gain(old, "a", 0, 1)
        #expect(leaving > 0 && Self.gain(new, "a", 0, 1) == 0)
        #expect(Self.gain(old, "a", 0, 0) != leaving)
        var mixer = try Self.mixer(old)
        _ = Self.run(&mixer, [Self.counting(8)], frames: 8)
        try mixer.transition(to: new, rampFrames: 4)
        let block = Self.run(&mixer, [(9...14).map { Float($0) }, []], frames: 6)
        #expect(Self.snapshot(mixer).speakers == ["spk.0"])
        let expected: [Float] = [leaving * 5, leaving * 6, leaving * 7, leaving * 8, 0, 0]
        try #require(block.columns.count == 2 && block.columns.allSatisfy { $0.count == 6 })
        #expect(block.columns[1] == expected)
        let stayer = block.columns[0]
        #expect(stayer[0] == Self.gain(old, "a", 0, 0) * 9)
        #expect(stayer[4] == Self.gain(new, "a", 0, 0) * 13 && stayer[5] == Self.gain(new, "a", 0, 0) * 14)
    }

    @Test func aSpeakerThatReturnsStartsFromSilenceNotFromStaleRingContents() throws {
        let both = try Self.plan([0, 1], of: 2, [Self.source("a", 0)], delays: [Delay(speaker: 1, frames: 4)])
        let alone = try Self.plan([0], of: 2, [Self.source("a", 0)])
        var mixer = try Self.mixer(both)
        _ = Self.run(&mixer, [Self.constant(1, 16)], frames: 16)
        try mixer.transition(to: alone, rampFrames: 0)
        _ = Self.run(&mixer, [Self.constant(1, 2)], frames: 2)
        try mixer.transition(to: both, rampFrames: 0)
        let block = Self.run(&mixer, [Self.constant(1, 6)], frames: 6)
        let gain = Self.gain(both, "a", 0, 1)
        try #require(block.columns.count == 2)
        #expect(block.columns[1] == [0, 0, 0, 0, gain, gain])
    }

    @Test func aZeroFrameRampMidRampKeepsTheDelayHistoryOfTheSpeakersThatStay() throws {
        let loud = try Self.unitPlan([Self.source("a", 0)], delay: 4)
        let muted = try Self.plan(
            [0], of: 1, [Self.source("a", 0)], masks: [Self.mute(0)], delays: [Delay(speaker: 0, frames: 4)]
        )
        var mixer = try Self.mixer(loud)
        _ = Self.run(&mixer, [Self.counting(8)], frames: 8)
        try mixer.transition(to: muted, rampFrames: 8)
        _ = Self.run(&mixer, [[9, 10, 11]], frames: 3)
        try mixer.transition(to: loud, rampFrames: 0)
        let state = Self.snapshot(mixer)
        #expect(state.ramp == 0 && state.progress == 0 && !state.transitioning && state.keys == ["a#0"])
        #expect(Self.run(&mixer, [[12, 13, 14, 15]], frames: 4).columns == [[8, 9, 8.75, 8.25]])
    }

    @Test func aSpeakerKeepsItsDelayLineWhenTheLayoutOrderIsReversed() throws {
        let delays = [Delay(speaker: 0, frames: 1), Delay(speaker: 1, frames: 2), Delay(speaker: 2, frames: 3)]
        let forward = try Self.plan([0, 1, 2], of: 3, Self.base, delays: delays)
        let reversed = try Self.plan([2, 1, 0], of: 3, Self.base, delays: delays)
        for ramp in [0, 8] {
            var moving = try Self.mixer(forward)
            var fixed = try Self.mixer(forward)
            _ = Self.stream(&moving, total: 20, block: 20)
            _ = Self.stream(&fixed, total: 20, block: 20)
            try moving.transition(to: reversed, rampFrames: ramp)
            let one = Self.stream(&moving, total: 30, block: 4)
            #expect(one == Self.stream(&fixed, total: 30, block: 4), "ramp \(ramp)")
            #expect(one["spk.2"]?.contains { $0 != 0 } == true)
        }
    }

    @Test func outputIsBitIdenticalForEveryBlockSizeAcrossAFullTransition() throws {
        let sources = Self.base
        let oldDelays = [Delay(speaker: 0, frames: 3), Delay(speaker: 2, frames: 5)]
        let newDelays = [Delay(speaker: 1, frames: 2), Delay(speaker: 2, frames: 5), Delay(speaker: 3, frames: 7)]
        let old = try Self.plan([0, 1, 2], of: 4, sources, delays: oldDelays)
        let new = try Self.plan([1, 2, 3], of: 4, [sources[2], Self.source("d", -0.2), sources[0]], delays: newDelays)
        func bits(_ block: Int) throws -> [String: [UInt32]] {
            var mixer = try Self.mixer(old, maxFrames: 128)
            _ = Self.stream(&mixer, total: 24, block: 24)
            try mixer.transition(to: new, rampFrames: 40)
            return Self.stream(&mixer, total: 100, block: block).mapValues { $0.map(\.bitPattern) }
        }
        let whole = try bits(100)
        #expect(Set(whole.keys) == ["spk.0", "spk.1", "spk.2", "spk.3"])
        #expect(whole["spk.0"]?.contains { $0 != 0 } == true && whole["spk.3"]?.contains { $0 != 0 } == true)
        for block in [1, 7, 40, 64] { #expect(try bits(block) == whole, "block \(block)") }
    }

    @Test func aSecondRampIsRefusedWhileOneRunsAndAllowedOnceItHasFinishedOrWhenInstant() throws {
        let next = try Self.plan([0, 1, 2], of: 3, [Self.base[0]])
        var mixer = try Self.mixer(Self.plan([0, 1, 2], of: 3, Self.base))
        try mixer.transition(to: next, rampFrames: 8)
        _ = Self.run(&mixer, Self.base.map { _ in [] } + [[]], frames: 7)
        let busy = Self.snapshot(mixer)
        #expect(busy.progress == 7)
        #expect(throws: SpatialMixerRefusal.transitionInProgress) { try mixer.transition(to: next, rampFrames: 1) }
        #expect(Self.snapshot(mixer) == busy)
        _ = Self.run(&mixer, [[], [], [], []], frames: 1)
        #expect(!Self.snapshot(mixer).transitioning)
        try mixer.transition(to: next, rampFrames: 9)
        #expect(Self.snapshot(mixer).progress == 0 && Self.snapshot(mixer).transitioning)
        _ = Self.run(&mixer, [[]], frames: 3)
        try mixer.transition(to: next, rampFrames: 0)
        #expect(!Self.snapshot(mixer).transitioning && Self.snapshot(mixer).progress == 0)
        try mixer.transition(to: next, rampFrames: 9)
        _ = Self.run(&mixer, [[]], frames: 9)
        try mixer.transition(to: next, rampFrames: 0)
        #expect(!Self.snapshot(mixer).transitioning)
    }

    @Test func aZeroFrameRampAfterAFullUnionGivesEveryNewSpeakerItsOwnRing() throws {
        let sources = [Self.source("a", -0.9)]
        var mixer = try Self.mixer(Self.plan([0, 1, 2], of: 9, sources), maxFrames: 16, rows: 2, speakers: 3)
        try mixer.transition(to: Self.plan([3, 4, 5], of: 9, sources), rampFrames: 8)
        _ = Self.run(&mixer, [Self.constant(1, 3)], frames: 3)
        let delays = [Delay(speaker: 6, frames: 0), Delay(speaker: 7, frames: 3), Delay(speaker: 8, frames: 5)]
        let final = try Self.plan([6, 7, 8], of: 9, sources, delays: delays)
        try mixer.transition(to: final, rampFrames: 0)
        let state = Self.snapshot(mixer)
        #expect(state.speakers == ["spk.6", "spk.7", "spk.8"] && !state.transitioning)
        let gains = (6...8).map { Self.gain(final, "a", 0, $0) }
        #expect(gains.allSatisfy { $0 > 0 } && Set(gains).count == 3)
        let block = Self.run(&mixer, [Self.impulse(at: 0, count: 10)], frames: 10)
        try #require(block.columns.count == 3)
        for (column, delay) in [0, 3, 5].enumerated() {
            #expect(block.columns[column] == Self.impulse(at: delay, gains[column], count: 10))
        }
    }
}
