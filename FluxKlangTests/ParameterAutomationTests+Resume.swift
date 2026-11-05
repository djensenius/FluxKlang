import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ParameterAutomationTests {
    @Test
    func touchReleaseGlidesBackWithoutAJump() throws {
        var arbiter = try Self.arbiter(.touch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.move(Self.fader, to: 0.9, at: 400)
        let released = try arbiter.release(Self.fader, at: 500)
        #expect(released == .init(outcome: .applied, owner: .gliding(from: 0.9, start: 500), value: 0.9))
        var previous = 0.9
        for ticks in stride(from: 510.0, through: 590, by: 10) {
            let value = try #require(try arbiter.advance(to: ticks).value)
            #expect(abs(value - previous) < 0.05)
            previous = value
        }
        #expect(try Self.close(arbiter.advance(to: 595).value, 0.9 + (0.595 - 0.9) * 0.95))
        #expect(try arbiter.advance(to: 600) == .init(outcome: .applied, owner: .automation, value: 0.6))
    }

    @Test
    func catchResumeWaitsForTheCurveToReachTheHeldValue() throws {
        var arbiter = try Self.arbiter(.touch, .catch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.move(Self.fader, to: 0.7, at: 300)
        let released = try arbiter.release(Self.fader, at: 400)
        #expect(released == .init(outcome: .applied, owner: .catching, value: 0.7))
        var coarse = arbiter
        #expect(try arbiter.advance(to: 600) == .init(outcome: .applied, owner: .catching, value: 0.7))
        #expect(try arbiter.advance(to: 699) == .init(outcome: .applied, owner: .catching, value: 0.7))
        #expect(try arbiter.advance(to: 800) == .init(outcome: .applied, owner: .automation, value: 0.8))
        #expect(try coarse.advance(to: 800) == .init(outcome: .applied, owner: .automation, value: 0.8))
    }

    @Test
    func catchEngagesAtOnceWhenEqualAndAcrossJumps() throws {
        var equal = try Self.arbiter(.touch, .catch)
        _ = try equal.touch(Self.fader, priority: 0, at: 500)
        #expect(try equal.release(Self.fader, at: 500) == .init(outcome: .applied, owner: .automation, value: 0.5))
        var jump = try Self.arbiter(.touch, .catch)
        _ = try jump.touch(Self.fader, priority: 0, at: 1_500)
        _ = try jump.move(Self.fader, to: 0.5, at: 1_500)
        #expect(try jump.release(Self.fader, at: 1_600).owner == .catching)
        #expect(try jump.advance(to: 1_999) == .init(outcome: .applied, owner: .catching, value: 0.5))
        #expect(try jump.advance(to: 2_000) == .init(outcome: .applied, owner: .automation, value: 0.2))
    }

    @Test
    func latchHoldsUntilTheNextBreakpointThenGlidesFromIt() throws {
        var arbiter = try Self.arbiter(.latch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.move(Self.fader, to: 0.9, at: 300)
        let released = try arbiter.release(Self.fader, at: 500)
        #expect(released == .init(outcome: .applied, owner: .latched(until: 1_000), value: 0.9))
        var coarse = arbiter
        #expect(try arbiter.advance(to: 999.5) == .init(outcome: .applied, owner: .latched(until: 1_000), value: 0.9))
        let fine = try arbiter.advance(to: 1_050)
        #expect(fine.owner == .gliding(from: 0.9, start: 1_000))
        #expect(Self.close(fine.value, 0.95))
        #expect(try coarse.advance(to: 1_050) == fine)
        #expect(try arbiter.advance(to: 1_100) == .init(outcome: .applied, owner: .automation, value: 1))
        var exact = try Self.arbiter(.latch)
        _ = try exact.touch(Self.fader, priority: 0, at: 300)
        _ = try exact.release(Self.fader, at: 500)
        #expect(try exact.advance(to: 1_000) == .init(outcome: .applied, owner: .gliding(from: 0.3, start: 1_000),
                                                      value: 0.3))
    }

    @Test
    func latchCatchResumesWhenTheCurveCrossesAfterTheBreakpoint() throws {
        var arbiter = try Self.arbiter(.latch, .catch)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 300)
        _ = try arbiter.move(Self.fader, to: 0.9, at: 300)
        #expect(try arbiter.release(Self.fader, at: 500).owner == .latched(until: 1_000))
        #expect(try arbiter.advance(to: 1_500) == .init(outcome: .applied, owner: .catching, value: 0.9))
        #expect(try arbiter.advance(to: 2_000) == .init(outcome: .applied, owner: .automation, value: 0.2))
    }

    @Test
    func extremeGlidesStayFiniteMonotoneAndExactAtTheirEnds() throws {
        #expect(AutomationLane.blend(-1e308, 1e308, at: 0).bitPattern == (-1e308).bitPattern)
        #expect(AutomationLane.blend(-1e308, 1e308, at: 1).bitPattern == (1e308).bitPattern)
        #expect(AutomationLane.blend(-1e308, 1e308, at: 0.5) == 0)
        #expect(AutomationLane.blend(0.1, 0.1, at: 0.3) == 0.1)
        let wide = try Self.descriptor(unit: .decibels, range: -1e308...1e308)
        for (held, target) in [(-1e308, 1e308), (1e308, -1e308)] {
            let lane = try Self.lane([.init(ticks: 0, value: target)], wide)
            var arbiter = try Self.arbiter(.touch, .glide(ticks: 100), lane: lane)
            _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
            _ = try arbiter.move(Self.fader, to: held, at: 0)
            let released = try arbiter.release(Self.fader, at: 10)
            #expect(released.owner == .gliding(from: held, start: 10))
            #expect(try #require(released.value).bitPattern == held.bitPattern)
            var previous = held
            for ticks in stride(from: 11.0, through: 109, by: 1) {
                let value = try #require(try arbiter.advance(to: ticks).value)
                #expect(value.isFinite && (target > held ? value >= previous : value <= previous))
                if ticks == 60 { #expect(value == 0) }
                previous = value
            }
            let landed = try arbiter.advance(to: 110)
            #expect(landed.owner == .automation)
            #expect(try #require(landed.value).bitPattern == target.bitPattern)
        }
    }

    @Test
    func flatGlidesHoldTheirValueExactly() throws {
        var arbiter = try Self.arbiter(.touch, .glide(ticks: 100), lane: Self.lane([.init(ticks: 0, value: 0.1)]))
        _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
        _ = try arbiter.release(Self.fader, at: 0)
        for ticks in stride(from: 1.0, through: 100, by: 1) { #expect(try arbiter.advance(to: ticks).value == 0.1) }
    }

    @Test
    func emptyLaneResumeKeepsTheGestureValue() throws {
        for resume in [AutomationResume.glide(ticks: 100), .catch] {
            var arbiter = try Self.arbiter(.touch, resume, lane: Self.lane([]))
            #expect(try arbiter.advance(to: 0) == .init(outcome: .applied, owner: .automation, value: nil))
            _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
            _ = try arbiter.move(Self.fader, to: 0.5, at: 10)
            #expect(try arbiter.release(Self.fader, at: 20) == .init(outcome: .applied, owner: .automation, value: 0.5))
            #expect(try arbiter.advance(to: 1_000).value == 0.5)
        }
    }

    @Test
    func steppedGlidesStayOnSteps() throws {
        let colour = try Self.descriptor(unit: .index, range: 1...12, curve: .stepped)
        let lane = try Self.lane([.init(ticks: 0, value: 10, interpolation: .step)], colour)
        var arbiter = try Self.arbiter(.touch, lane: lane)
        _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
        _ = try arbiter.move(Self.fader, to: 2, at: 0)
        _ = try arbiter.release(Self.fader, at: 100)
        #expect(try arbiter.advance(to: 130).value == 4)
        #expect(try arbiter.advance(to: 200) == .init(outcome: .applied, owner: .automation, value: 10))
    }

    @Test
    func resultsDoNotDependOnBlockSplitting() throws {
        for mode in [AutomationMode.touch, .latch] {
            for resume in [AutomationResume.glide(ticks: 100), .glide(ticks: 7_680), .catch] {
                let arbiter = try Self.arbiter(mode, resume)
                let reference = try Self.run(arbiter, every: nil)
                for block in [7.0, 50, 333, 1_024] { #expect(try Self.run(arbiter, every: block) == reference) }
            }
        }
    }

    enum Step { case touch(ControlSourceID), move(ControlSourceID, Double), release(ControlSourceID), probe }

    static let script: [(ticks: Double, step: Step)] = [
        (300, .touch(fader)), (400, .move(fader, 0.9)), (500, .release(fader)), (550, .probe), (999, .probe),
        (1_000, .probe), (1_050, .probe), (1_500, .probe), (2_000, .probe), (2_100, .touch(knob)),
        (2_150, .move(knob, 0.1)), (2_200, .release(knob)), (2_250, .probe), (2_600, .probe), (3_200, .probe)
    ]

    /// Replays `script`, optionally advancing at every multiple of `block` between events.
    static func run(_ start: ParameterArbiter, every block: Double?) throws -> [ArbitrationResult] {
        var arbiter = start
        var position = 0.0
        var results: [ArbitrationResult] = []
        for (ticks, step) in script {
            if let block {
                var next = (position / block).rounded(.down) * block + block
                while next < ticks {
                    _ = try arbiter.advance(to: next)
                    next += block
                }
            }
            position = ticks
            switch step {
            case .touch(let source): results.append(try arbiter.touch(source, priority: 0, at: ticks))
            case .move(let source, let value): results.append(try arbiter.move(source, to: value, at: ticks))
            case .release(let source): results.append(try arbiter.release(source, at: ticks))
            case .probe: results.append(try arbiter.advance(to: ticks))
            }
        }
        return results
    }
}

extension ParameterAutomationTests {
    /// Copilot's lane: rounding between adjacent values must not make a later sample smaller, or a
    /// catch would depend on where the render blocks split the segment.
    @Test
    func adjacentValueSegmentsCatchTheSameWayInAnyBlocks() throws {
        let lane = try Self.lane([.init(ticks: 0, value: 0.5), .init(ticks: 100, value: 0.5.nextUp),
                                  .init(ticks: 100, value: 0)])
        let middle = try #require(try lane.value(at: 75))
        #expect(try middle <= #require(try lane.value(at: Double(100).nextDown)))
        let splits: [[Double]] = [[100, 200], [75, 100, 200], [25, 75, 99, Double(100).nextDown, 100, 150, 200]]
        let runs = try splits.map { ticks in
            var arbiter = try Self.arbiter(.touch, .catch, lane: lane)
            _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
            _ = try arbiter.move(Self.fader, to: 0.5.nextUp, at: 0)
            _ = try arbiter.release(Self.fader, at: 0)
            let results = try ticks.map { try ($0, arbiter.advance(to: $0)) }
            return results.filter { $0.0 == 100 || $0.0 == 200 }.map(\.1)
        }
        #expect(runs[0] == runs[1] && runs[1] == runs[2], "\(runs)")
    }

    /// Seeded endpoints: adjacent values, opposite signs, the largest finite and subnormal magnitudes,
    /// zero-length spans. Sampled at sorted fractions, `blend` must not turn back, must stay between
    /// its ends, must hit them exactly and must track the exact line.
    @Test
    func blendIsMonotoneBoundedExactAndAccurate() {
        var random = AutomationMonotoneDraw(state: 0x108_0004)
        for _ in 0..<3_000 {
            let from = random.value()
            let adjacent = random.int(0...1) == 0 ? from.nextUp : from.nextDown
            let to = random.int(0...3) == 0 ? adjacent : random.value()
            guard to.isFinite else { continue }
            let steps = [1, 2, 3, 7, 64, 1_000][random.int(0...5)]
            let tolerance = max(abs(from), abs(to)) * 1e-12 + 4 * Double.leastNonzeroMagnitude
            var previous = from
            var failures = 0
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                let value = AutomationLane.blend(from, to, at: fraction)
                let halfLine = from * 0.5 + (to * 0.5 - from * 0.5) * fraction
                let turned = to >= from ? value < previous : value > previous
                let outside = value < min(from, to) || value > max(from, to)
                if turned || outside || abs(value * 0.5 - halfLine) > tolerance {
                    failures += 1
                }
                previous = value
            }
            let exact = AutomationLane.blend(from, to, at: 0) == from && AutomationLane.blend(from, to, at: 1) == to
            #expect(failures == 0 && exact, "\(from) → \(to) over \(steps)")
        }
        for fraction in [Double.nan, .infinity, -.infinity] {
            #expect(AutomationLane.blend(-1e308, 1e308, at: fraction) == -1e308)
        }
    }

    /// Seeded lanes: each segment samples monotonically within its ends, and in touch and latch modes a
    /// catch or glide gives the same results at shared positions however the advances are split into
    /// blocks, including splits that skip the breakpoint where a latch ends.
    @Test
    func lanesStayMonotoneAndArbitrationIgnoresBlockSplits() throws {
        let wide = try Self.descriptor(unit: .decibels, range: -1e308...1e308)
        var random = AutomationMonotoneDraw(state: 0x108_0005)
        var latchesEndingOnBreakpoints = 0
        for _ in 0..<300 {
            var points: [AutomationBreakpoint] = []
            var ticks: Int64 = 0
            for index in 0..<random.int(2...5) {
                let tripled = index > 1 && points[index - 2].ticks == ticks
                if index > 0 { ticks += Int64(random.int(tripled ? 1...9 : 0...9)) }
                let shapes: [AutomationInterpolation] = [.linear, .linear, .step, .power(0.5), .power(3)]
                let previous = points.last?.value ?? 0
                let near = random.int(0...1) == 0 && previous.nextUp.isFinite ? previous.nextUp : previous
                let value = random.int(0...2) == 0 ? near : random.value()
                points.append(.init(ticks: ticks, value: value, interpolation: shapes[random.int(0...4)]))
            }
            let lane = try Self.lane(points, wide)
            for (start, end) in zip(lane.breakpoints, lane.breakpoints.dropFirst()) where start.ticks < end.ticks {
                let span = Double(start.ticks)...Double(end.ticks).nextDown
                let samples = Array(stride(from: span.lowerBound, to: span.upperBound, by: 0.25)) + [span.upperBound]
                let values = try samples.map { try #require(try lane.value(at: $0)) }
                let rising = end.value >= start.value
                let ordered = zip(values, values.dropFirst()).allSatisfy { rising ? $0 <= $1 : $0 >= $1 }
                let ends = min(start.value, end.value)...max(start.value, end.value)
                let bounded = values.allSatisfy { ends.contains($0) }
                #expect(ordered && bounded, "\(points) segment at \(start.ticks)")
            }
            let fine = (1...Int(ticks + 4) * 4).map { Double($0) / 4 }.flatMap { [$0.nextDown, $0] }
            let shared = Set(fine.filter { _ in random.int(0...3) == 0 } + [fine[fine.count - 1]])
            let sampled = try #require(try lane.value(at: Double(random.int(0...Int(ticks)))))
            let held = random.int(0...1) == 0 ? sampled : random.value()
            // A latch ends exactly at a breakpoint: one split lands on it, another skips every breakpoint.
            let coarse = shared.subtracting(lane.breakpoints.map { Double($0.ticks) })
            let released = Double(random.int(0...Int(ticks)))
            for mode in [AutomationMode.touch, .latch] {
                for resume in [AutomationResume.catch, .glide(ticks: Int64(random.int(1...20)))] {
                    let runs = try [fine, fine.filter(shared.contains), fine.filter(coarse.contains)].map { positions in
                        var arbiter = try Self.arbiter(mode, resume, lane: lane)
                        _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
                        _ = try arbiter.move(Self.fader, to: held, at: 0)
                        let release = try arbiter.release(Self.fader, at: released)
                        if case .latched(let until?) = release.owner, positions.contains(Double(until)) {
                            latchesEndingOnBreakpoints += 1
                        }
                        let results = try positions.filter { $0 > released }.map { try ($0, arbiter.advance(to: $0)) }
                        return [release] + results.filter { coarse.contains($0.0) }.map(\.1)
                    }
                    #expect(runs[0] == runs[1] && runs[1] == runs[2], "\(points) held \(held) \(mode) \(resume)")
                }
            }
        }
        #expect(latchesEndingOnBreakpoints > 100)
    }
}

/// SplitMix64 draws for the monotonicity properties, private to this file.
private struct AutomationMonotoneDraw {
    var state: UInt64

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return range.lowerBound + Int((mixed ^ (mixed >> 31)) % UInt64(range.count))
    }

    /// A finite value: a special magnitude or one drawn across the whole exponent range.
    mutating func value() -> Double {
        let special: [Double] = [0, -0.0, 0.5, 0.1, 0.3, -1, 1, 1e308, -1e308, .leastNormalMagnitude,
                                 .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                                 .leastNonzeroMagnitude, -.leastNonzeroMagnitude]
        if int(0...1) == 0 { return special[int(0...special.count - 1)] }
        let significand = 1 + Double(int(0...(1 << 52) - 1)) * 0x1p-52
        let sign: FloatingPointSign = int(0...1) == 0 ? .plus : .minus
        return Double(sign: sign, exponent: int(-1_074...1_023), significand: significand)
    }
}
