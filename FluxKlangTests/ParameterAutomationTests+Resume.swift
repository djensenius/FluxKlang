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
