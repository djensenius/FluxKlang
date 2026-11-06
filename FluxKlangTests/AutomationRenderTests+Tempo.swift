import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Automation block rendering: tempo, curves and gestures")
struct AutomationRenderTempoTests {
    typealias Fixture = AutomationRenderTests
    typealias Hand = AutomationRenderHandbackTests

    @Test func aTempoChangeInsideARampSplitsItAtTheMappedFrame() throws {
        let lane = try Fixture.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1)])
        let clock = try Fixture.clock(segments: [(0, 500_000), (500, 250_000)])
        var renderer = try Fixture.renderer(lane)
        let events = try renderer.render(from: 0, to: 4_096, clock: clock, current: Fixture.live)
        let change = try clock.frame(atTicks: 500)
        let end = try clock.frame(atTicks: 1_000)
        #expect(events == [
            AutomationRampEvent(frame: 0, offset: 0, value: 0, rampFrames: 0, reason: .start),
            AutomationRampEvent(frame: 0, offset: 0, value: 0.5, rampFrames: change, reason: .start),
            AutomationRampEvent(frame: change, offset: Int(change), value: 1, rampFrames: end - change,
                                reason: .curve)
        ])
    }

    /// How one rendered power segment compares with its curve, as fractions of the segment's value change.
    struct PowerError {
        /// The largest difference between the rendered trajectory and the curve over the segment's frames.
        let error: Double
        /// The largest difference less the curve's largest one-frame change within the sub-ramp it falls in.
        let excess: Double
        /// The number of ramps rendered.
        let ramps: Int
    }

    static func powerError(exponent: Double, ticks: Int64, rate: Int, seed: UInt64) throws -> PowerError {
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.1, interpolation: .power(exponent)),
                                     .init(ticks: ticks, value: 0.9)])
        let clock = try Fixture.clock(rate: rate)
        let end = try clock.frame(atTicks: ticks) + 1
        var renderer = try Fixture.renderer(lane)
        let events = try Fixture.render(&renderer, from: 0, blocks: Fixture.splits(end, seed: seed), clock: clock)
        let values = Fixture.trajectory(events, from: 0, to: end)
        let curve = try (0..<end).map { try #require(try lane.value(at: Fixture.position(clock, $0))) }
        let error = zip(values, curve).map { abs($0 - $1) }.max() ?? 0
        var excess = 0.0
        for ramp in events where ramp.rampFrames > 0 {
            let frames = Int(ramp.frame)...Int(ramp.frame + ramp.rampFrames)
            let step = zip(curve[frames].dropFirst(), curve[frames]).map { abs($0 - $1) }.max() ?? 0
            for frame in frames { excess = max(excess, abs(values[frame] - curve[frame]) - step) }
        }
        return PowerError(error: error / 0.8, excess: excess / 0.8, ramps: events.count { $0.rampFrames > 0 })
    }

    @Test(arguments: [0.125, 0.25, 0.5, 0.8, 1, 1.5, 3, 8])
    func powerSegmentsStayWithinTheStatedBoundInAtMostEightSubRamps(exponent: Double) throws {
        for rate in [44_100, 96_000] {
            let long = try Self.powerError(exponent: exponent, ticks: 4 * Fixture.quarter, rate: rate, seed: 3)
            #expect(long.error <= AutomationPowerApproximation.errorBound, "p \(exponent) at \(rate) Hz")
            // Owner ruling Q-T2: at most eight linear sub-ramps per power segment.
            #expect(long.ramps <= 8)
            for ticks in [Int64(5), 40, 300] {
                // Knots snap to whole frames: each sub-ramp may also be off by its own largest one-frame change.
                let short = try Self.powerError(exponent: exponent, ticks: ticks, rate: rate, seed: 4)
                #expect(short.excess <= AutomationPowerApproximation.errorBound,
                        "p \(exponent), \(ticks) ticks at \(rate) Hz")
                #expect(short.ramps <= 8)
            }
        }
    }

    @Test func aPowerSegmentAcrossTempoChangesAddsOneExactPointPerChange() throws {
        // Coordinator ruling: each crossing gets the exact mapped frame; the cap of 8 bounds the sub-ramps.
        let ticks = 4 * Fixture.quarter
        let changes: [Int64] = [20_000, 41_000]
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.1, interpolation: .power(3)),
                                     .init(ticks: ticks, value: 0.9)])
        let clock = try Fixture.clock(segments: [(0, 500_000), (changes[0], 380_000), (changes[1], 610_000)])
        var renderer = try Fixture.renderer(lane)
        let end = try clock.frame(atTicks: ticks)
        let events = try Fixture.render(&renderer, from: 0, blocks: Fixture.splits(end + 1, seed: 21), clock: clock)
        let ramps = events.filter { $0.rampFrames > 0 }
        let ends = ramps.map { $0.frame + $0.rampFrames }
        for change in changes {
            let frame = try clock.frame(atTicks: change)
            let ramp = try #require(ramps.first { $0.frame + $0.rampFrames == frame })
            #expect(ramp.value == (try lane.value(at: Double(change))))
        }
        #expect(ends.last == end)
        let mapped = try changes.map { try clock.frame(atTicks: $0) } + [end]
        #expect(ends.count { !mapped.contains($0) } <= AutomationPowerApproximation.maximumSubRamps - 1)
        #expect(ramps.count <= AutomationPowerApproximation.maximumSubRamps + changes.count)
    }

    @Test func powerKnotsAgreeAcrossRatesToWithinOneFramesChange() throws {
        let ticks = 4 * Fixture.quarter
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.1, interpolation: .power(3)),
                                     .init(ticks: ticks, value: 0.9)])
        var rendered: [[AutomationRampEvent]] = []
        for rate in [44_100, 96_000] {
            let clock = try Fixture.clock(rate: rate)
            var renderer = try Fixture.renderer(lane)
            let end = try clock.frame(atTicks: ticks) + 1
            rendered.append(try Fixture.render(&renderer, from: 0, blocks: Fixture.splits(end, seed: 22), clock: clock))
        }
        let (low, high) = (rendered[0], rendered[1])
        #expect(low.count == high.count)
        #expect(low.map(\.reason) == high.map(\.reason))
        // Breakpoint values are identical; interior knots, on whole frames, within the curve's largest change over
        // one 44.1 kHz frame.
        #expect(low.first?.value == high.first?.value && low.last?.value == high.last?.value)
        let clock = try Fixture.clock(rate: 44_100)
        let curve = try (0...clock.frame(atTicks: ticks)).map {
            try #require(try lane.value(at: Fixture.position(clock, $0)))
        }
        let step = zip(curve.dropFirst(), curve).map { $0 - $1 }.max() ?? 0
        #expect(zip(low, high).allSatisfy { abs($0.value - $1.value) <= step })
        #expect(zip(low, high).contains { $0.value != $1.value })
    }

    @Test(arguments: [0.3, 0.7, 2.5, 6])
    func interiorKnotsSitOnTheFrameNearestTheirIdealPosition(exponent: Double) throws {
        let ticks = 2 * Fixture.quarter
        let lane = try Fixture.lane([.init(ticks: 0, value: 0, interpolation: .power(exponent)),
                                     .init(ticks: ticks, value: 1)])
        let clock = try Fixture.clock(rate: 44_100)
        var renderer = try Fixture.renderer(lane)
        let events = try renderer.render(from: 0, to: 65_536, clock: clock, current: Fixture.live)
        let knots = events.filter { $0.rampFrames > 0 }.dropFirst().map(\.frame)
        #expect(knots.count == AutomationPowerApproximation.maximumSubRamps - 1)
        // At 120 BPM and 44.1 kHz one tick is 44_100 / 2 / 15_360 frames.
        let framesPerTick = 44_100.0 / 2 / Double(Fixture.quarter)
        var previous: Int64 = 0
        for (index, frame) in knots.enumerated() {
            let ideal = Double(ticks) * AutomationPowerApproximation.fraction(index + 1, exponent: exponent)
            #expect(abs(Double(frame) - ideal * framesPerTick) <= 0.5 + 1e-6 || frame == previous + 1,
                    "knot \(index + 1) of p \(exponent): \(frame) vs \(ideal * framesPerTick)")
            previous = frame
        }
    }

    @Test func linearSegmentsAreExactAtEveryKnot() throws {
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.3), .init(ticks: 7_000, value: 0.7),
                                     .init(ticks: 9_000, value: 0.1)])
        let clock = try Fixture.clock(rate: 44_100, segments: [(0, 500_000), (3_001, 431_000), (8_000, 900_000)])
        var renderer = try Fixture.renderer(lane)
        let events = try renderer.render(from: 0, to: 30_000, clock: clock, current: Fixture.live)
        for event in events where event.rampFrames > 0 {
            let target = event.frame + event.rampFrames
            let knots: [Int64] = [3_001, 7_000, 8_000, 9_000]
            let tick = try #require(try knots.first { try clock.frame(atTicks: $0) == target })
            #expect(event.value == (try lane.value(at: Double(tick))))
        }
        #expect(events.count { $0.rampFrames > 0 } == 4)
    }

    @Test func aHeldGestureSuppressesTheLaneWithoutAJumpAndAutomationGlidesBack() throws {
        let lane = try Fixture.lane([.init(ticks: 0, value: 0), .init(ticks: 4_000, value: 1)])
        let clock = try Fixture.clock()
        var renderer = try Fixture.renderer(lane)
        var events = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        #expect(try renderer.perform(.touch(Fixture.fader, priority: 1)).outcome == .applied)
        let held = try #require(renderer.arbiter.value)
        let second = try renderer.render(from: 1_000, to: 2_000, clock: clock, current: Fixture.live)
        #expect(second == [AutomationRampEvent(frame: 1_000, offset: 0, value: held, rampFrames: 0, reason: .hold)])
        #expect(!renderer.isRenderingLane)
        _ = try renderer.perform(.move(Fixture.fader, to: 0.1))
        let third = try renderer.render(from: 2_000, to: 3_000, clock: clock, current: Fixture.live)
        #expect(third == [AutomationRampEvent(frame: 2_000, offset: 0, value: 0.1, rampFrames: 0, reason: .hold)])
        _ = try renderer.perform(.release(Fixture.fader))
        events += second + third
        events += try Fixture.render(&renderer, from: 3_000, blocks: Array(repeating: 128, count: 40), clock: clock)
        #expect(renderer.isRenderingLane)
        // The glide ended inside a block and reached the curve, so automation resumes with a ramp, not a jump.
        #expect(events.contains { $0.reason == .resume })
        #expect(events.filter { $0.reason == .resume }.allSatisfy { $0.rampFrames > 0 })
        let values = Fixture.trajectory(events, from: 0, to: 8_120)
        #expect(abs(values[999] - held) < 1e-3)
        for frame in 1..<values.count where frame != 2_000 {
            #expect(abs(values[frame] - values[frame - 1]) < 0.01, "jump at \(frame)")
        }
        let last = try #require(try lane.value(at: Fixture.position(clock, 8_119)))
        #expect(abs(values[8_119] - last) < 1e-3)
    }

    @Test func aGestureCancelsALaneRampInFlightEvenAtItsTarget() throws {
        let lane = try Fixture.lane([.init(ticks: 0, value: 0), .init(ticks: 4_000, value: 1)])
        var renderer = try Fixture.renderer(lane)
        _ = try renderer.render(from: 0, to: 1_000, clock: Fixture.clock(), current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 1))
        let events = try renderer.render(from: 1_000, to: 1_100, clock: Fixture.clock(), current: Fixture.live)
        #expect(events == [AutomationRampEvent(frame: 1_000, offset: 0, value: 1, rampFrames: 0, reason: .hold)])
    }

    @Test func aGlideAcrossKnotsRampsBetweenThemAndResumesWithoutAJump() throws {
        // Power 2 places interior knots every 1000 ticks; the glide lasts 3000 ticks.
        let lane = try Fixture.lane([.init(ticks: 0, value: 0, interpolation: .power(2)),
                                     .init(ticks: 8_000, value: 1)])
        let clock = try Fixture.clock()
        var renderer = try Fixture.renderer(lane, resume: .glide(ticks: 3_000))
        var events = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 1))
        events += try renderer.render(from: 1_000, to: 1_100, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.release(Fixture.fader))
        events += try renderer.render(from: 1_100, to: 14_000, clock: clock, current: Fixture.live)
        #expect(renderer.isRenderingLane)
        let values = Fixture.trajectory(events, from: 0, to: 14_000)
        for frame in 1..<values.count where frame != 1_000 {
            #expect(abs(values[frame] - values[frame - 1]) < 0.01, "jump at \(frame)")
        }
        #expect(events.filter { $0.reason == .hold }.count >= 3)
        #expect(abs(values[13_999] - 1) < 1e-12)
    }

    @Test func aCatchOnABlockStartJumpsToTheCurveItCaught() throws {
        // The step at 2000 crosses the held 0.5; a block starts exactly on its frame.
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.2, interpolation: .step),
                                     .init(ticks: 2_000, value: 0.8, interpolation: .step)])
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(2_000, on: clock)
        var renderer = try Fixture.renderer(lane, resume: .catch)
        _ = try renderer.render(from: 0, to: 1_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 0.5))
        _ = try renderer.render(from: 1_000, to: 2_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.release(Fixture.fader))
        _ = try renderer.render(from: 2_000, to: step, clock: clock, current: Fixture.live)
        #expect(!renderer.isRenderingLane)
        let events = try renderer.render(from: step, to: step + 1_000, clock: clock, current: Fixture.live)
        #expect(events == [AutomationRampEvent(frame: step, offset: 0, value: 0.8, rampFrames: 0, reason: .resume)])
        #expect(renderer.isRenderingLane)
    }

    @Test func aCatchInsideABlockHoldsItsValueUntilTheStepItCaught() throws {
        // The step at 20000 (frame 31250) crosses the held 0.5 inside one long block.
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.2, interpolation: .step),
                                     .init(ticks: 20_000, value: 0.8, interpolation: .step)])
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(20_000, on: clock)
        var renderer = try Fixture.renderer(lane, resume: .catch)
        _ = try renderer.render(from: 0, to: 2_000, clock: clock, current: Fixture.live)
        _ = try renderer.perform(.touch(Fixture.fader, priority: 1))
        _ = try renderer.perform(.move(Fixture.fader, to: 0.5))
        _ = try renderer.perform(.release(Fixture.fader))
        var whole = renderer
        let events = try whole.render(from: 2_000, to: 40_000, clock: clock, current: Fixture.live)
        #expect(events == [
            AutomationRampEvent(frame: 2_000, offset: 0, value: 0.5, rampFrames: 0, reason: .hold),
            AutomationRampEvent(frame: step, offset: Int(step - 2_000), value: 0.8, rampFrames: 0, reason: .resume)
        ])
        var split = renderer
        let others = try Fixture.render(&split, from: 2_000, blocks: [step - 2_000, 40_000 - step], clock: clock)
        #expect(others.map(\.frame) == events.map(\.frame))
        #expect(others.map(\.value) == events.map(\.value))
        #expect(others.map(\.rampFrames) == events.map(\.rampFrames))
        #expect(others.map(\.reason) == events.map(\.reason))
    }

    @Test func aGlideOverStepsOnAContinuousLaneShowsTheArbitersValueOnEachStepsFrame() throws {
        // Steps to 0.8 at tick 1000 (frame 1563, position 1000.32) and to 0.1 at tick 1003 (frame 1567, 1002.88).
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.2, interpolation: .step),
                                     .init(ticks: 1_000, value: 0.8, interpolation: .step),
                                     .init(ticks: 1_003, value: 0.1, interpolation: .step)])
        let clock = try Fixture.clock()
        let frames = try [Int64(1_000), 1_003].map { try clock.frame(atTicks: $0) }
        var failures: [String] = []
        // Between advance points the host ramps straight, so only the steps' frames are compared.
        for glide: Int64 in [1, 5, 50] {
            for moved in [0.6, 0.95] {
                for when in (frames[0] - 3)...(frames[0] + 2) {
                    let release = Hand.Release(resume: .glide(ticks: glide), moved: moved, frame: when)
                    failures += try Hand.disagreements(lane, release, to: frames[1] + 40, around: frames, clock: clock,
                                                       justThere: true)
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
    }

    @Test func aCatchEndingBetweenABreakpointAndItsFramesPositionHandsBackOnTheFrame() throws {
        // The ramp from 0.4 at tick 1000 (frame 1563, position 1000.32) to 0.9 at tick 2000 reaches a held 0.4001 at
        // tick 1000.2: after the breakpoint and before its frame.
        let lane = try Fixture.lane([.init(ticks: 0, value: 0.2, interpolation: .step), .init(ticks: 1_000, value: 0.4),
                                     .init(ticks: 2_000, value: 0.9)])
        let clock = try Fixture.clock()
        let step = try AutomationRenderMath.frame(1_000, on: clock)
        let last = try AutomationRenderMath.frame(2_000, on: clock)
        var failures: [String] = []
        for when in (step - 3)...step {
            let release = Hand.Release(resume: .catch, moved: 0.4001, frame: when)
            failures += try Hand.disagreements(lane, release, to: last + 40, around: [step], clock: clock)
        }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
        var renderer = try Hand.released(lane, Hand.Release(resume: .catch, moved: 0.4001, frame: step - 1),
                                         clock: clock)
        let events = try renderer.render(from: step - 1, to: last + 40, clock: clock, current: Fixture.live)
        let reached = try #require(try lane.value(at: Fixture.position(clock, step)))
        let event = { (frame: Int64, value: Double, ramp: Int64, reason: AutomationRampEvent.Reason) in
            AutomationRampEvent(frame: frame, offset: Int(frame - step + 1), value: value, rampFrames: ramp,
                                reason: reason)
        }
        // Held until the frame, which resumes the ramp from the curve's value at its own position.
        #expect(events == [event(step - 1, 0.4001, 0, .hold), event(step, reached, 0, .resume),
                           event(step, 0.9, last - step, .resume)])
    }

    @Test func aSteppedGlideShowsTheArbitersValueOnABreakpointsFrameAtEveryRateAndTempo() throws {
        let clocks = [try Fixture.clock(rate: 44_100),
                      try Fixture.clock(rate: 44_100, segments: [(0, 500_000), (500, 420_000), (900, 380_000)]),
                      try Fixture.clock(rate: 96_000, segments: [(0, 500_000), (900, 380_000)]),
                      try Fixture.clock(rate: 192_000, segments: [(0, 500_000), (900, 380_000)])]
        for clock in clocks {
            // The breakpoint tick among 1000…1030 that rounds up onto its frame by the most ticks.
            let window = { (tick: Int64) throws -> Double in
                try Fixture.position(clock, clock.frame(atTicks: tick)) - Double(tick)
            }
            let tick = try #require(try (Int64(1_000)...1_030).max { try window($0) < window($1) })
            let frame = try clock.frame(atTicks: tick)
            #expect(try window(tick) > 0.1)
            let lane = try Hand.indexLane([(0, 2), (tick, 9)])
            var failures: [String] = []
            var sensitive = 0
            for glide: Int64 in 1...4 {
                for moved in [12.0, 1, 5] {
                    for when in (frame - 4)...(frame + 1) {
                        let release = Hand.Release(resume: .glide(ticks: glide), moved: moved, frame: when)
                        failures += try Hand.disagreements(lane, release, to: frame + 60, around: [frame], clock: clock)
                        // Whether the glide's value on the breakpoint's tick is not the one at its frame's position.
                        var probe = try Hand.released(lane, release, clock: clock).arbiter
                        let onTick = try probe.advance(to: max(Double(tick), probe.position ?? 0)).value
                        let onFrame = try probe.advance(to: max(Fixture.position(clock, frame), probe.position ?? 0))
                        sensitive += onFrame.value == onTick ? 0 : 1
                    }
                }
            }
            #expect(failures.isEmpty, "\(failures.prefix(3))")
            #expect(sensitive > 0)
        }
    }

    @Test func gesturesNeedARenderAndRefusedGesturesChangeNothing() throws {
        var renderer = try Fixture.renderer(Fixture.ramp())
        #expect(throws: AutomationRenderRefusal.notStarted) { try renderer.perform(.touch(Fixture.fader, priority: 1)) }
        _ = try renderer.render(from: 0, to: 100, clock: Fixture.clock(), current: Fixture.live)
        let before = renderer
        #expect(throws: AutomationRenderRefusal.automation(.notTouched(Fixture.fader))) {
            try renderer.perform(.release(Fixture.fader))
        }
        #expect(renderer == before)
        #expect(try renderer.perform(.setMode(.manual)).owner == .manual)
        let events = try renderer.render(from: 100, to: 4_000, clock: Fixture.clock(), current: Fixture.live)
        #expect(events.allSatisfy { $0.reason == .hold })
    }
}
