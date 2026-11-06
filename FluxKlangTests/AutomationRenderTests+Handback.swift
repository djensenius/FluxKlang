import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Automation block rendering: hand-back")
struct AutomationRenderHandbackTests {
    typealias Fixture = AutomationRenderTests

    /// 0.2 until a step to 0.8 at tick 1000 (frame 1563 at 48 kHz and 120 BPM, position 1000.32).
    static func stepAtOneThousand() throws -> AutomationLane {
        try Fixture.lane([.init(ticks: 0, value: 0.2, interpolation: .step), .init(ticks: 1_000, value: 0.8)])
    }

    @Test func aGlideEndingJustBeforeAStepHandsItToTheNextBlock() throws {
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(1_000, on: clock)
        var renderer = try Fixture.renderer(Self.stepAtOneThousand(), resume: .glide(ticks: 100))
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 0.6))
        _ = try renderer.perform(.release(Fixture.fader))
        // The block ends on the step's frame: the glide completes at the last position before the step.
        _ = try renderer.render(from: 1_000, to: step, clock: clock, current: Fixture.live)
        #expect(renderer.arbiter.owner == .automation && renderer.arbiter.value == 0.2)
        #expect(renderer.arbiter.position.map { $0 < 1_000 } == true)
        let events = try renderer.render(from: step, to: step + 1_000, clock: clock, current: Fixture.live)
        #expect(events == [AutomationRampEvent(frame: step, offset: 0, value: 0.8, rampFrames: 0, reason: .curve)])
        #expect(renderer.arbiter.value == 0.8)
    }

    @Test func aCatchEndingJustBeforeAStepHandsItToTheNextBlock() throws {
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(1_000, on: clock)
        var renderer = try Fixture.renderer(Self.stepAtOneThousand(), resume: .catch)
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        #expect(try renderer.render(from: 1_000, to: step, clock: clock, current: Fixture.live).isEmpty)
        // Held at the curve's own value, the catch completes at once, just before the step.
        #expect(try renderer.perform(.release(Fixture.fader)).owner == .automation)
        let events = try renderer.render(from: step, to: step + 1_000, clock: clock, current: Fixture.live)
        #expect(events == [AutomationRampEvent(frame: step, offset: 0, value: 0.8, rampFrames: 0, reason: .curve)])
    }

    @Test func coincidentBreakpointsAfterAHandBackStillJumpOnTheNextBlocksFirstFrame() throws {
        let lane = try Fixture.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1),
                                     .init(ticks: 1_000, value: 0.2), .init(ticks: 2_000, value: 0.8)])
        let clock = try Fixture.clock()
        let jump = try AutomationRenderMath.frame(1_000, on: clock)
        let end = try AutomationRenderMath.frame(2_000, on: clock)
        var renderer = try Fixture.renderer(lane, resume: .glide(ticks: 100))
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 0.5))
        _ = try renderer.perform(.release(Fixture.fader))
        _ = try renderer.render(from: 1_000, to: jump, clock: clock, current: Fixture.live)
        #expect(renderer.arbiter.owner == .automation && !renderer.isRenderingLane)
        let events = try renderer.render(from: jump, to: jump + 2_000, clock: clock, current: Fixture.live)
        // The glide reached the curve just short of 1, so the shadowed breakpoint is set first; then the jump.
        #expect(events == [
            AutomationRampEvent(frame: jump, offset: 0, value: 1, rampFrames: 0, reason: .curve),
            AutomationRampEvent(frame: jump, offset: 0, value: 0.2, rampFrames: 0, reason: .curve),
            AutomationRampEvent(frame: jump, offset: 0, value: 0.8, rampFrames: end - jump, reason: .curve)
        ])
    }

    @Test func aStartRoundedDownOntoABreakpointsFrameStillReachesIt() throws {
        // Tick 2 maps to frame 3.125, rounded to 3, whose position is 1.92 ticks: the start is short of it.
        let lane = try Fixture.lane([.init(ticks: 0, value: 0), .init(ticks: 2, value: 1)])
        let clock = try Fixture.clock()
        let start = try #require(try lane.value(at: Fixture.position(clock, 3)))
        #expect(start < 1)
        let expected = [AutomationRampEvent(frame: 3, offset: 0, value: start, rampFrames: 0, reason: .start),
                        AutomationRampEvent(frame: 3, offset: 0, value: 1, rampFrames: 0, reason: .curve)]
        var renderer = try Fixture.renderer(lane)
        #expect(try renderer.render(from: 3, to: 100, clock: clock, current: Fixture.live) == expected)
        renderer.reset()
        #expect(try renderer.render(from: 3, to: 100, clock: clock, current: Fixture.live) == expected)
    }

    @Test func touchingAPowerRampWithoutMovingHoldsTheValueTheHostShows() throws {
        let ticks = 4 * Fixture.quarter
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.1, interpolation: .power(3)),
                                     .init(ticks: ticks, value: 0.9)])
        let clock = try Fixture.clock()
        let end = try AutomationRenderMath.frame(ticks, on: clock)
        var reference = try Fixture.renderer(lane)
        let full = try Fixture.render(&reference, from: 0, blocks: Fixture.splits(end, seed: 5), clock: clock)
        let shown = Fixture.trajectory(full, from: 0, to: end)
        let curve = try (0..<end).map { try #require(try lane.value(at: Fixture.position(clock, $0))) }
        // Touch where the sub-ramps are furthest from the curve.
        let deviation = zip(shown, curve).map { abs($0 - $1) }
        let frame = try #require(deviation.indices.max { deviation[$0] < deviation[$1] })
        #expect(deviation[frame] > 1e-3)
        var renderer = try Fixture.renderer(lane)
        var events = try Fixture.render(&renderer, from: 0, blocks: Fixture.splits(Int64(frame), seed: 6),
                                        clock: clock)
        #expect(try renderer.perform(.touch(Fixture.fader, priority: 1)).owner == .gesture(Fixture.fader))
        let held = try #require(renderer.arbiter.value)
        #expect(abs(held - shown[frame]) < 1e-12)
        events += try renderer.render(from: Int64(frame), to: Int64(frame) + 1_000, clock: clock,
                                      current: Fixture.live)
        let values = Fixture.trajectory(events, from: 0, to: Int64(frame) + 1_000)
        // No jump: the host takes its sub-ramp's last step onto the held value, then holds; the exact curve is
        // further away than that.
        #expect(abs((values[frame] - values[frame - 1]) - (shown[frame] - shown[frame - 1])) < 1e-12)
        #expect(values[frame...].allSatisfy { $0 == held })
        #expect(abs(curve[frame] - held) > 10 * abs(shown[frame] - shown[frame - 1]))
    }

    @Test func aTouchOverAnotherGestureKeepsTheValueItMoved() throws {
        let knob = ControlSourceID(validated: "ctl.knob")
        var renderer = try Fixture.renderer(Fixture.ramp())
        _ = try renderer.render(from: 0, to: 1_000, clock: Fixture.clock(), current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 0.4))
        // Only a touch taking the value from automation holds what the host shows; this one keeps the fader's move.
        let result = try renderer.perform(.touch(knob, priority: 2))
        #expect(result.owner == .gesture(knob) && result.value == 0.4)
        let events = try renderer.render(from: 1_000, to: 1_100, clock: Fixture.clock(), current: Fixture.live)
        #expect(events == [AutomationRampEvent(frame: 1_000, offset: 0, value: 0.4, rampFrames: 0, reason: .hold)])
    }

    @Test func aSteppedGlideSetsEachWholeStepAtTheFrameTheArbiterTakesIt() throws {
        let descriptor = try ParameterDescriptor(.init(
            id: Fixture.level, unit: .index, lower: 1, upper: 12, defaultValue: 1, ceiling: nil, curve: .stepped,
            ramp: .step, controlClass: .live, verification: .unverified
        ))
        let lane = try AutomationLane(descriptor: descriptor,
                                      breakpoints: [.init(ticks: 0, value: 10, interpolation: .step)])
        let clock = try Fixture.clock()
        var renderer = try Fixture.renderer(lane, resume: .glide(ticks: 100))
        _ = try renderer.render(from: 0, to: 100, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 2))
        _ = try renderer.perform(.release(Fixture.fader))
        // The arbiter advanced frame by frame: each change of its value is where a step belongs.
        var oracle = renderer.arbiter
        var expected: [(Int64, Double)] = []
        var previous = 10.0
        for frame in Int64(100)..<600 {
            let value = try #require(try oracle.advance(to: Fixture.position(clock, frame)).value)
            if value != previous { expected.append((frame, value)) }
            previous = value
        }
        #expect(expected.map(\.1) == (2...10).map(Double.init))
        var whole = renderer
        let events = try whole.render(from: 100, to: 600, clock: clock, current: Fixture.live)
        #expect(events.map(\.frame) == expected.map(\.0))
        #expect(events.map(\.value) == expected.map(\.1))
        #expect(events.allSatisfy { $0.rampFrames == 0 && $0.reason == .hold })
        // Random splits, and one whose blocks end on every step's frame (the step belongs to the next block).
        let onSteps = zip(expected.map(\.0).dropFirst() + [600], expected.map(\.0)).map { $0 - $1 }
        for blocks in [UInt64(7), 8, 9].map({ Fixture.splits(500, seed: $0, maximum: 60) }) + [onSteps] {
            var split = renderer
            let others = try Fixture.render(&split, from: 100, blocks: blocks, clock: clock)
            #expect(others.map(\.frame) == expected.map(\.0))
            #expect(others.map(\.value) == expected.map(\.1))
            #expect(others.allSatisfy { $0.rampFrames == 0 })
        }
    }

    /// A glide released at frame 1000 (tick 640) toward `lane`, lasting 1000 ticks, so it crosses the step at tick
    /// 1000 (frame 1563). Returns the arbiter just after the release and the events of `[1000, 4000)` rendered in
    /// one block and split on the step's frame − 1, the frame itself and + 1, in that order.
    private static func glideOverStep(_ lane: AutomationLane, from moved: Double, clock: MusicalClockMap,
                                      step: Int64) throws -> (oracle: ParameterArbiter, runs: [[AutomationRampEvent]]) {
        var renderer = try Fixture.renderer(lane, resume: .glide(ticks: 1_000))
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: moved))
        _ = try renderer.perform(.release(Fixture.fader))
        let splits = [[3_000]] + [step - 1, step, step + 1].map { [$0 - 1_000, 4_000 - $0] }
        let runs = try splits.map { blocks in
            var split = renderer
            return try Fixture.render(&split, from: 1_000, blocks: blocks, clock: clock)
        }
        return (renderer.arbiter, runs)
    }

    @Test func aGlideAcrossAStepHoldsTheArbitersValueThenJumpsOnTheStep() throws {
        // The step at tick 1000, then a flat ramp into tick 1999 (frame 3123, position 1998.72) after the glide
        // ends at tick 1640: automation takes the value back just short of that knot, on its frame.
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.2, interpolation: .step), .init(ticks: 1_000, value: 0.8),
                                     .init(ticks: 1_999, value: 0.8), .init(ticks: 3_000, value: 0.4)])
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(1_000, on: clock)
        let flat = try AutomationRenderMath.frame(1_999, on: clock)
        let next = try AutomationRenderMath.frame(3_000, on: clock)
        let (oracle, runs) = try Self.glideOverStep(lane, from: 0.6, clock: clock, step: step)
        var probe = oracle
        let before = try #require(try probe.advance(to: Fixture.position(clock, step - 2)).value)
        let last = try #require(try probe.advance(to: Fixture.position(clock, step - 1)).value)
        let reached = try #require(try probe.advance(to: Double(1_000).nextDown).value)
        let jumped = try #require(try probe.advance(to: 1_000).value)
        #expect(jumped > 0.6 && last < 0.6)
        // Exact events: the glide ramps to its value just before the step, jumps on the step's frame, then ramps to
        // the value it hands back; the flat knot only departs (its value is already held).
        let held = { (frame: Int64, value: Double, ramp: Int64) in
            AutomationRampEvent(frame: frame, offset: Int(frame - 1_000), value: value, rampFrames: ramp, reason: .hold)
        }
        let departure = AutomationRampEvent(frame: flat, offset: Int(flat - 1_000), value: 0.4,
                                            rampFrames: next - flat, reason: .curve)
        #expect(runs[0] == [held(1_000, 0.6, 0), held(1_000, reached, step - 1_000), held(step, jumped, 0),
                            held(step, 0.8, flat - step), departure])
        // Offsets depend on the split, so the per-split checks compare the other fields.
        let shape = { (event: AutomationRampEvent) in
            "\(event.frame) \(event.value) \(event.rampFrames) \(event.reason)"
        }
        for events in runs {
            let values = Fixture.trajectory(events, from: 1_000, to: 4_000, initial: 0.2)
            // The ramp ending on the step's frame reaches the value at tick 1000, not at the frame's own position
            // (1000.32): a chord within one frame's change of the arbiter.
            #expect(abs(values[Int(step - 1_001)] - last) <= abs(last - before))
            #expect(values[Int(step - 1_000)] == jumped)
            #expect(events.filter { $0.frame >= flat }.map(shape) == [shape(departure)])
            #expect(events.first { $0.frame == step }.map(shape) == shape(held(step, jumped, 0)))
        }
        // With a block ending on step − 1, the host holds the arbiter's value there exactly.
        #expect(Fixture.trajectory(runs[1], from: 1_000, to: step, initial: 0.2).last == last)
    }

    @Test func aSteppedGlideAcrossAStepJumpsOnTheStepWhateverTheSplit() throws {
        let descriptor = try ParameterDescriptor(.init(
            id: Fixture.level, unit: .index, lower: 1, upper: 12, defaultValue: 1, ceiling: nil, curve: .stepped,
            ramp: .step, controlClass: .live, verification: .unverified
        ))
        let lane = try AutomationLane(descriptor: descriptor,
                                      breakpoints: [.init(ticks: 0, value: 2, interpolation: .step),
                                                    .init(ticks: 1_000, value: 9, interpolation: .step)])
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(1_000, on: clock)
        let (oracle, runs) = try Self.glideOverStep(lane, from: 12, clock: clock, step: step)
        var probe = oracle
        var expected: [(Int64, Double)] = []
        var previous = 2.0
        for frame in Int64(1_000)..<4_000 {
            let value = try #require(try probe.advance(to: Fixture.position(clock, frame)).value)
            if value != previous { expected.append((frame, value)) }
            previous = value
        }
        var onStep = oracle
        let jumped = try #require(try onStep.advance(to: 1_000).value)
        let last = try #require(expected.last { $0.0 < step }?.1)
        // The glide steps down toward 2, jumps up on the step's frame, then steps down to 9.
        #expect(expected.contains { $0 == (step, jumped) } && jumped > last && jumped > 9)
        #expect(expected.last?.1 == 9)
        for events in runs {
            #expect(events.map(\.frame) == expected.map(\.0))
            #expect(events.map(\.value) == expected.map(\.1))
            #expect(events.allSatisfy { $0.rampFrames == 0 && $0.reason == .hold })
            let values = Fixture.trajectory(events, from: 1_000, to: 4_000, initial: 2)
            #expect(values[Int(step - 1_001)] == last)
            #expect(values[Int(step - 1_000)] == jumped)
        }
        #expect(runs.dropFirst().allSatisfy { $0.map(\.rampFrames) == runs[0].map(\.rampFrames) })
    }

    @Test func aWrapCarriedIntoARenderCountsTowardTheWrapLimit() throws {
        // Loop [0, 40) at 120 BPM and 48 kHz wraps every 63 frames; the first block ends on the first wrap.
        let loop = try LoopRange(startTicks: 0, endTicks: 40)
        let clock = try Fixture.clock()
        let limit = Int64(AutomationBlockRenderer.maximumWraps)
        var renderer = try Fixture.renderer(Fixture.lane([.init(ticks: 0, value: 0.5)]), loop: loop)
        _ = try renderer.render(from: 0, to: 1, clock: clock, current: Fixture.live)
        // A gesture holds the value, so no wrap emits an event.
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        #expect(try renderer.render(from: 1, to: 63, clock: clock, current: Fixture.live).isEmpty)
        // The wrap carried to frame 63 is the first of the limit.
        var full = renderer
        #expect(try full.render(from: 63, to: 63 * limit + 1, clock: clock, current: Fixture.live).isEmpty)
        #expect(full.cursor == 63 * limit + 1)
        let before = renderer
        #expect(throws: AutomationRenderRefusal.tooManyWraps(limit: AutomationBlockRenderer.maximumWraps)) {
            try renderer.render(from: 63, to: 63 * (limit + 1) + 1, clock: clock, current: Fixture.live)
        }
        #expect(renderer == before)
    }
}
