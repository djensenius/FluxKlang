import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Automation block rendering: tempo, curves and gestures")
struct AutomationRenderTempoTests {
    typealias Fixture = AutomationRenderTests

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
        /// The curve's largest one-frame change over the segment.
        let step: Double
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
        var error = 0.0, step = 0.0, previous: Double?
        for frame in 0..<end {
            let curve = try #require(try lane.value(at: Fixture.position(clock, frame)))
            error = max(error, abs(values[Int(frame)] - curve))
            if let previous { step = max(step, abs(curve - previous)) }
            previous = curve
        }
        return PowerError(error: error / 0.8, step: step / 0.8, ramps: events.count { $0.rampFrames > 0 })
    }

    @Test(arguments: [0.125, 0.25, 0.5, 0.8, 1, 1.5, 3, 8])
    func powerSegmentsStayWithinTheStatedBoundInAtMostEightSubRamps(exponent: Double) throws {
        for rate in [44_100, 96_000] {
            let long = try Self.powerError(exponent: exponent, ticks: 4 * Fixture.quarter, rate: rate, seed: 3)
            #expect(long.error <= AutomationPowerApproximation.errorBound, "p \(exponent) at \(rate) Hz")
            // Owner ruling Q-T2: at most eight linear sub-ramps per power segment.
            #expect(long.ramps <= 8)
            for ticks in [Int64(5), 40, 300] {
                let short = try Self.powerError(exponent: exponent, ticks: ticks, rate: rate, seed: 4)
                #expect(short.error <= AutomationPowerApproximation.errorBound + short.step,
                        "p \(exponent), \(ticks) ticks at \(rate) Hz")
                #expect(short.ramps <= 8)
            }
        }
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
