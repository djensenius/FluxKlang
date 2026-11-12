import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("Automation block rendering: loops", .productionAccessAudit)
#else
@Suite("Automation block rendering: loops")
#endif
struct AutomationRenderLoopTests {
    typealias Fixture = AutomationRenderTests
    typealias Hand = AutomationRenderHandbackTests

    @Test(arguments: [44_100, 48_000, 96_000])
    func aWrapInsideABlockRestartsTheLaneAtTheLoopStart(rate: Int) throws {
        let loop = try LoopRange(startTicks: 500, endTicks: 2_500)
        let lane = try Fixture.ramp()
        let clock = try Fixture.clock(rate: rate)
        var renderer = try Fixture.renderer(lane, loop: loop)
        let wrap = try clock.frame(atTicks: loop.endTicks)
        #expect(Int128(wrap) == (try MusicalTiming.wrapFrame(clock, loop: loop)))
        let events = try renderer.render(from: 0, to: wrap + 100, clock: clock, current: Fixture.live)
        let wrapped = try #require(events.first { $0.reason == .loopWrap })
        let restart = try #require(try lane.value(at: 500))
        #expect(wrapped == AutomationRampEvent(frame: wrap, offset: Int(wrap), value: restart, rampFrames: 0,
                                               reason: .loopWrap))
        #expect(events.allSatisfy { $0.frame < wrap || $0.reason == .loopWrap })
        let last = try #require(events.last { $0.frame < wrap && $0.rampFrames > 0 })
        #expect(last.frame + last.rampFrames == wrap)
        #expect(last.value == (try lane.value(at: Double(loop.endTicks))))
        // The ramp across the loop end is split there, so the pass ends on the curve.
        let values = Fixture.trajectory(events, from: 0, to: wrap)
        let ending = try #require(try lane.value(at: Fixture.position(clock, wrap - 1)))
        #expect(abs(values[Int(wrap) - 1] - ending) < 1e-3)
        #expect(renderer.arbiter.position.map { $0 < 600 } == true)
    }

    @Test(arguments: [UInt64(11), 12, 13, 14])
    func passesRepeatExactlyWhateverTheBlockSplit(seed: UInt64) throws {
        let loop = try LoopRange(startTicks: 500, endTicks: 2_500)
        let lane = try Fixture.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1, interpolation: .power(3)),
                                     .init(ticks: 2_200, value: 0.2), .init(ticks: 2_600, value: 0.6)])
        let clock = try Fixture.clock(rate: 44_100, segments: [(0, 500_000), (1_700, 410_000)])
        let first = try clock.frame(atTicks: loop.endTicks)
        let total: Int64 = 40_000
        var whole = try Fixture.renderer(lane, loop: loop)
        let expected = try whole.render(from: 0, to: total, clock: clock, current: Fixture.live)
        var split = try Fixture.renderer(lane, loop: loop)
        var blocks = Fixture.splits(total, seed: seed, maximum: 1_500)
        // Force a block boundary exactly on the first wrap.
        var sum: Int64 = 0
        blocks = blocks.flatMap { length -> [Int64] in
            defer { sum += length }
            return sum < first && first < sum + length ? [first - sum, sum + length - first] : [length]
        }
        let events = try Fixture.render(&split, from: 0, blocks: blocks, clock: clock)
        // Offsets are relative to each block, so compare everything else.
        #expect(events.map(\.frame) == expected.map(\.frame))
        #expect(events.map(\.rampFrames) == expected.map(\.rampFrames))
        #expect(events.map(\.value) == expected.map(\.value))
        #expect(events.map(\.reason) == expected.map(\.reason))
        let wraps = expected.filter { $0.reason == .loopWrap && $0.rampFrames == 0 }.map(\.frame)
        #expect(wraps.count >= 3)
        let period = wraps[1] - wraps[0]
        #expect(wraps[2] - wraps[1] == period)
        let second = expected.filter { $0.frame >= wraps[0] && $0.frame < wraps[1] }
        let third = expected.filter { $0.frame >= wraps[1] && $0.frame < wraps[2] }
        #expect(second.map { $0.frame + period } == third.map(\.frame))
        #expect(second.map(\.value) == third.map(\.value))
        #expect(second.map(\.rampFrames) == third.map(\.rampFrames))
    }

    @Test func positionsStayBelowTheLoopEndUpToTheWrapFrame() throws {
        let loop = try LoopRange(startTicks: 0, endTicks: 4_000)
        let clock = try Fixture.clock()
        var renderer = try Fixture.renderer(Fixture.ramp(), loop: loop)
        let wrap = try clock.frame(atTicks: loop.endTicks)
        _ = try renderer.render(from: 0, to: wrap, clock: clock, current: Fixture.live)
        #expect(renderer.arbiter.position.map { $0 < Double(loop.endTicks) } == true)
        let events = try renderer.render(from: wrap, to: wrap + 10, clock: clock, current: Fixture.live)
        #expect(events.first == AutomationRampEvent(frame: wrap, offset: 0, value: 0, rampFrames: 0, reason: .loopWrap))
        #expect(renderer.arbiter.position.map { $0 < 10 } == true)
    }

    @Test func aGestureHeldAcrossTheWrapKeepsItsValue() throws {
        let loop = try LoopRange(startTicks: 0, endTicks: 1_000)
        let clock = try Fixture.clock()
        var renderer = try Fixture.renderer(Fixture.ramp(), loop: loop)
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 0.4))
        let events = try renderer.render(from: 1_000, to: 3_000, clock: clock, current: Fixture.live)
        #expect(events.allSatisfy { $0.reason == .hold && $0.value == 0.4 })
        #expect(renderer.arbiter.value == 0.4)
    }

    enum Handback: CaseIterable { case catchUp, glide, latch }

    struct HandbackRun {
        let whole: [AutomationRampEvent]
        let split: [AutomationRampEvent]
        let owner: ParameterOwnership
    }

    /// Renders `[1000, total)` after a gesture released at frame 1000, in one block and split at every wrap.
    static func handback(_ kind: Handback, total: Int64) throws -> HandbackRun {
        let loop = try LoopRange(startTicks: 0, endTicks: 2_000)
        let clock = try Fixture.clock()
        let points: [AutomationBreakpoint] = kind == .latch
            ? [.init(ticks: 0, value: 0), .init(ticks: 1_500, value: 0.6), .init(ticks: 4_000, value: 1)]
            : [.init(ticks: 0, value: 0), .init(ticks: 4_000, value: 1)]
        // The glide outlasts the first pass; the latch ends at 1500 and its short glide ends before the wrap.
        let resume: AutomationResume = switch kind {
        case .catchUp: .catch
        case .glide: .glide(ticks: 1_500)
        case .latch: .glide(ticks: 100)
        }
        var renderer = try Fixture.renderer(Fixture.lane(points), mode: kind == .latch ? .latch : .touch,
                                            resume: resume, loop: loop)
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: kind == .catchUp ? 0.3 : 0.9))
        _ = try renderer.perform(.release(Fixture.fader))
        var whole = renderer
        let events = try whole.render(from: 1_000, to: total, clock: clock, current: Fixture.live)
        var split = renderer
        // Wraps fall at frames 3125 and 6250.
        let wrap = try clock.frame(atTicks: loop.endTicks)
        let blocks = [wrap - 1_000, wrap, total - 2 * wrap]
        let others = try Fixture.render(&split, from: 1_000, blocks: blocks, clock: clock)
        #expect(split.arbiter == whole.arbiter)
        return HandbackRun(whole: events, split: others, owner: whole.arbiter.owner)
    }

    @Test(arguments: Handback.allCases)
    func aHandBackAcrossAWrapInsideABlockMatchesASplitAtTheWrap(kind: Handback) throws {
        let run = try Self.handback(kind, total: 8_000)
        #expect(run.split.map(\.frame) == run.whole.map(\.frame))
        #expect(run.split.map(\.value) == run.whole.map(\.value))
        #expect(run.split.map(\.rampFrames) == run.whole.map(\.rampFrames))
        #expect(run.split.map(\.reason) == run.whole.map(\.reason))
        // The arbiter's own change is rendered up to the first wrap, as a wrap on a block boundary renders it.
        let held = try #require(run.whole.last { $0.frame < 3_125 })
        #expect(held.reason == .hold && held.frame + held.rampFrames == 3_125)
        #expect(run.whole.contains { $0.frame == 6_250 && $0.reason == .loopWrap })
        #expect(run.owner == .automation)
    }

    @Test func aShortGlideReleasedBeforeABreakpointInALaterPassShowsTheArbitersValueOnItsFrame() throws {
        // After the wrap at frame 3125 tick 1000 falls on frame 4688 (3125 + 1562.5), whose position is 1000.32.
        let loop = try LoopRange(startTicks: 0, endTicks: 2_000)
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(loop.endTicks, on: clock)
            + AutomationRenderMath.frame(1_000, on: clock)
        let lane = try Hand.indexLane([(0, 2), (1_000, 9)])
        var failures: [String] = []
        for glide: Int64 in [1, 2, 7] {
            for moved in [12.0, 1] {
                for when in (step - 2)...(step + 1) {
                    let release = Hand.Release(resume: .glide(ticks: glide), moved: moved, frame: when)
                    failures += try Hand.disagreements(lane, release, to: step + 60, around: [step], clock: clock,
                                                       loop: loop)
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
    }

    @Test func wrapsUpToTheLimitRenderAndOneMoreIsRefused() throws {
        // Loop [0, 40) at 120 BPM and 48 kHz: a 62.5-frame pass, so wraps fall every 63 frames.
        let loop = try LoopRange(startTicks: 0, endTicks: 40)
        let clock = try Fixture.clock()
        let limit = Int64(AutomationBlockRenderer.maximumWraps)
        var renderer = try Fixture.renderer(Fixture.lane([.init(ticks: 0, value: 0.5)]), loop: loop)
        _ = try renderer.render(from: 0, to: 1, clock: clock, current: Fixture.live)
        // A gesture holds the value, so no wrap emits an event.
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        var full = renderer
        #expect(try full.render(from: 1, to: 63 * limit + 1, clock: clock, current: Fixture.live).isEmpty)
        #expect(full.cursor == 63 * limit + 1)
        let before = renderer
        #expect(throws: AutomationRenderRefusal.tooManyWraps(limit: AutomationBlockRenderer.maximumWraps)) {
            try renderer.render(from: 1, to: 63 * (limit + 1) + 1, clock: clock, current: Fixture.live)
        }
        #expect(renderer == before)
    }

    @Test func aLoopShorterThanAFrameIsRefused() throws {
        let loop = try LoopRange(startTicks: 0, endTicks: 1)
        let clock = try Fixture.clock(rate: 44_100, segments: [(0, 60_000)])
        var renderer = try Fixture.renderer(Fixture.ramp(), loop: loop)
        let before = renderer
        #expect(throws: AutomationRenderRefusal.nonAdvancingLoop) {
            try renderer.render(from: 0, to: 64, clock: clock, current: Fixture.live)
        }
        #expect(renderer == before)
    }
}
