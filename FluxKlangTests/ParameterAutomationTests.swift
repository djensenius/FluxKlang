import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ParameterAutomationTests {
    static let level = ParameterID(validated: "par.auto.level")
    static let fader = ControlSourceID(validated: "ctl.fader")
    static let knob = ControlSourceID(validated: "ctl.knob")
    static let pad = ControlSourceID(validated: "ctl.pad")

    @Test
    func emptyLaneHasNoValueOrBreakpoints() throws {
        let lane = try Self.lane([])
        #expect(try lane.value(at: 0) == nil)
        #expect(try lane.value(at: 1_000_000) == nil)
        #expect(try lane.nextBreakpoint(after: -1) == nil)
        #expect(try !lane.reaches(0.5, from: 0, through: 100))
    }

    @Test
    func singlePointHoldsEverywhere() throws {
        let lane = try Self.lane([.init(ticks: 960, value: 0.4)])
        for ticks in [-1_000.0, 0, 959.5, 960, 961, 1e12] { #expect(try lane.value(at: ticks) == 0.4) }
    }

    @Test
    func holdsFirstValueBeforeAndLastValueAfter() throws {
        let lane = try Self.lane([.init(ticks: 100, value: 0.2), .init(ticks: 200, value: 0.6)])
        #expect(try lane.value(at: -50) == 0.2)
        #expect(try lane.value(at: 99.999) == 0.2)
        #expect(try lane.value(at: 200.001) == 0.6)
        #expect(try lane.value(at: 1e15) == 0.6)
    }

    @Test
    func breakpointsAreExactWhateverTheirInterpolation() throws {
        let lane = try Self.lane([
            .init(ticks: 0, value: 0.1), .init(ticks: 1_000, value: 0.7, interpolation: .power(3)),
            .init(ticks: 3_000, value: 0.3, interpolation: .step), .init(ticks: 3_001, value: 0.9)
        ])
        #expect(try lane.value(at: 0) == 0.1)
        #expect(try lane.value(at: 1_000) == 0.7)
        #expect(try lane.value(at: 3_000) == 0.3)
        #expect(try lane.value(at: 3_001) == 0.9)
    }

    @Test
    func linearPowerAndStepSegmentsInterpolate() throws {
        let linear = try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1)])
        #expect(try linear.value(at: 250) == 0.25)
        #expect(try linear.value(at: 500) == 0.5)
        let slow = try Self.lane([.init(ticks: 0, value: 0, interpolation: .power(2)), .init(ticks: 1_000, value: 1)])
        #expect(try slow.value(at: 500) == 0.25)
        let fast = try Self.lane([.init(ticks: 0, value: 0, interpolation: .power(0.5)),
                                  .init(ticks: 1_000, value: 1)])
        #expect(try fast.value(at: 250) == 0.5)
        let falling = try Self.lane([.init(ticks: 0, value: 1, interpolation: .power(2)),
                                     .init(ticks: 1_000, value: 0)])
        #expect(try falling.value(at: 500) == 0.75)
        let step = try Self.lane([.init(ticks: 0, value: 0.2, interpolation: .step), .init(ticks: 1_000, value: 0.8)])
        #expect(try step.value(at: 999.999) == 0.2)
        #expect(try step.value(at: 1_000) == 0.8)
    }

    @Test
    func flatAndExtremeSegmentsStayBetweenTheirEnds() throws {
        let flat = try Self.lane([.init(ticks: 0, value: 0.1), .init(ticks: 1_000, value: 0.1)])
        for ticks in 0...1_000 { #expect(try flat.value(at: Double(ticks)) == 0.1) }
        let wide = try Self.descriptor(unit: .decibels, range: -1e308...1e308)
        let extreme = try Self.lane([.init(ticks: 0, value: -1e308), .init(ticks: 1_000, value: 1e308)], wide)
        #expect(try extreme.value(at: 500) == 0)
        #expect(try extreme.value(at: 999)?.isFinite == true)
    }

    @Test
    func equalTicksDescribeADiscontinuity() throws {
        let lane = try Self.lane([
            .init(ticks: 0, value: 0), .init(ticks: 1_000, value: 0.5), .init(ticks: 1_000, value: 0.9),
            .init(ticks: 2_000, value: 0.1)
        ])
        #expect(try Self.close(lane.value(at: 999), 0.4995))
        #expect(try lane.value(at: 1_000) == 0.9)
        #expect(try Self.close(lane.value(at: 1_500), 0.5))
        let atStart = try Self.lane([.init(ticks: 0, value: 0.3), .init(ticks: 0, value: 0.6)])
        #expect(try atStart.value(at: -1) == 0.3)
        #expect(try atStart.value(at: 0) == 0.6)
        #expect(try atStart.value(at: 1) == 0.6)
        #expect(throws: AutomationRefusal.tooManyAtTick(1_000)) {
            try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 0.5),
                           .init(ticks: 1_000, value: 0.6), .init(ticks: 1_000, value: 0.7)])
        }
    }

    @Test
    func unsortedBreakpointsAreRefusedNotSorted() throws {
        #expect(throws: AutomationRefusal.unsorted(index: 2)) {
            try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 20, value: 0), .init(ticks: 10, value: 0)])
        }
    }

    @Test
    func breakpointCountAndTicksAreBounded() throws {
        let maximum = AutomationLane.maximumBreakpoints
        let full = (0..<maximum).map { AutomationBreakpoint(ticks: Int64($0), value: 0.5) }
        #expect(try Self.lane(full).breakpoints.count == maximum)
        #expect(throws: AutomationRefusal.tooManyBreakpoints(maximum + 1)) {
            try Self.lane(full + [.init(ticks: Int64(maximum), value: 0.5)])
        }
        let last = AutomationLane.maximumTicks
        #expect(try Self.lane([.init(ticks: 0, value: 0), .init(ticks: last, value: 1)]).breakpoints.count == 2)
        #expect(throws: AutomationRefusal.ticksOutOfRange(last + 1)) {
            try Self.lane([.init(ticks: last + 1, value: 1)])
        }
        #expect(throws: AutomationRefusal.ticksOutOfRange(-1)) { try Self.lane([.init(ticks: -1, value: 1)]) }
    }

    @Test
    func nonFiniteValuesAndPositionsAreRefused() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(throws: AutomationRefusal.nonFinite) { try Self.lane([.init(ticks: 0, value: bad)]) }
        }
        let lane = try Self.lane([.init(ticks: 0, value: 0.5)])
        #expect(throws: AutomationRefusal.nonFinite) { try lane.value(at: .nan) }
        #expect(throws: AutomationRefusal.nonFinite) { try lane.value(at: .infinity) }
        #expect(throws: AutomationRefusal.nonFinite) { try lane.nextBreakpoint(after: .nan) }
        #expect(throws: AutomationRefusal.nonFinite) { try lane.admit(.nan) }
        #expect(throws: AutomationRefusal.nonFinite) { try lane.reaches(.nan, from: 0, through: 1) }
        #expect(throws: AutomationRefusal.nonFinite) { try lane.reaches(0.5, from: 0, through: .infinity) }
    }

    @Test
    func powerExponentIsBounded() throws {
        let bounds = AutomationInterpolation.exponentRange
        for exponent in [bounds.lowerBound, 1, bounds.upperBound] {
            _ = try Self.lane([.init(ticks: 0, value: 0, interpolation: .power(exponent))])
        }
        for exponent in [0.1, 8.5, 0, -1, .nan] {
            #expect(throws: AutomationRefusal.self) {
                try Self.lane([.init(ticks: 0, value: 0, interpolation: .power(exponent))])
            }
        }
        #expect(throws: AutomationRefusal.invalidExponent(9)) {
            try Self.lane([.init(ticks: 0, value: 0, interpolation: .power(9))])
        }
    }

    @Test
    func valuesClampIntoTheWritableRangeAndCeiling() throws {
        let capped = try Self.descriptor(unit: .normalized, range: 0...1, ceiling: 0.8)
        let lane = try Self.lane([.init(ticks: 0, value: 1.5), .init(ticks: 10, value: -2),
                                  .init(ticks: 20, value: 0.5)], capped)
        #expect(lane.breakpoints.map(\.value) == [0.8, 0, 0.5])
        #expect(lane.range == 0...0.8)
        #expect(try lane.admit(0.9) == 0.8)
        #expect(try lane.admit(-0.1) == 0)
        #expect(try lane.admit(0.25) == 0.25)
        let gain = try Self.descriptor(unit: .decibels, range: -90...10, ceiling: 0)
        #expect(try Self.lane([.init(ticks: 0, value: 6)], gain).breakpoints[0].value == 0)
    }

    @Test
    func steppedLanesOnlyProduceWritableSteps() throws {
        let trim = try Self.descriptor(unit: .decibels, range: -0.5...3, curve: .stepped, defaultValue: 0)
        let lane = try Self.lane([.init(ticks: 0, value: -1, interpolation: .step),
                                  .init(ticks: 100, value: 3, interpolation: .step),
                                  .init(ticks: 200, value: 2, interpolation: .step)], trim)
        #expect(lane.range == 0...3)
        #expect(lane.breakpoints.map(\.value) == [0, 3, 2])
        #expect(try lane.admit(-3) == 0)
        let fractional = try Self.descriptor(unit: .decibels, range: 0.5...2.5, curve: .stepped, defaultValue: 1)
        #expect(try Self.lane([], fractional).range == 1...2)
        let negative = try Self.descriptor(unit: .decibels, range: -3.5...(-0.5), curve: .stepped, defaultValue: -1)
        #expect(try Self.lane([], negative).range == -3...(-1))
        var arbiter = try ParameterArbiter(lane: lane, mode: .touch, resume: .glide(ticks: 90))
        _ = try arbiter.touch(Self.fader, priority: 0, at: 0)
        _ = try arbiter.move(Self.fader, to: -2, at: 0)
        _ = try arbiter.release(Self.fader, at: 50)
        for ticks in stride(from: 50.0, through: 300, by: 2.5) {
            let curve = try #require(try lane.value(at: ticks))
            let held = try #require(try arbiter.advance(to: ticks).value)
            for value in [curve, held] { try trim.check(ParameterValue(value: value, unit: .decibels)) }
        }
    }

    @Test
    func steppedParametersAcceptOnlyIntegralSteps() throws {
        let colour = try Self.descriptor(unit: .index, range: 1...12, curve: .stepped, ceiling: 5.5)
        let lane = try Self.lane([.init(ticks: 0, value: 12, interpolation: .step),
                                  .init(ticks: 10, value: 3, interpolation: .step)], colour)
        #expect(lane.isStepped)
        #expect(lane.range == 1...5)
        #expect(lane.breakpoints.map(\.value) == [5, 3])
        #expect(try lane.value(at: 5) == 5)
        #expect(throws: AutomationRefusal.notIntegral(2.5)) { try lane.admit(2.5) }
        #expect(throws: AutomationRefusal.notIntegral(2.5)) {
            try Self.lane([.init(ticks: 0, value: 2.5, interpolation: .step)], colour)
        }
        #expect(throws: AutomationRefusal.interpolationNotAllowed(.linear)) {
            try Self.lane([.init(ticks: 0, value: 2)], colour)
        }
        #expect(throws: AutomationRefusal.interpolationNotAllowed(.power(2))) {
            try Self.lane([.init(ticks: 0, value: 2, interpolation: .power(2))], colour)
        }
    }

    @Test
    func onlyLiveParametersAreAutomated() throws {
        for controlClass in [ControlClass.structural, .hazardous] {
            let descriptor = try Self.descriptor(unit: .normalized, range: 0...1, controlClass: controlClass)
            #expect(throws: AutomationRefusal.unautomatableClass(controlClass)) { try Self.lane([], descriptor) }
        }
        let lane = try Self.lane([])
        #expect(lane.parameter == Self.level)
        #expect(lane.unit == .normalized)
    }

    @Test
    func nextBreakpointIsStrictlyAfter() throws {
        let lane = try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 0.5),
                                  .init(ticks: 1_000, value: 0.9), .init(ticks: 2_000, value: 0.1)])
        #expect(try lane.nextBreakpoint(after: -5) == 0)
        #expect(try lane.nextBreakpoint(after: 0) == 1_000)
        #expect(try lane.nextBreakpoint(after: 999.5) == 1_000)
        #expect(try lane.nextBreakpoint(after: 1_000) == 2_000)
        #expect(try lane.nextBreakpoint(after: 2_000) == nil)
    }

    @Test
    func reachesDetectsCrossingsInsideSegmentsAndAtJumps() throws {
        let ramp = try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1)])
        #expect(try !ramp.reaches(0.5, from: 0, through: 400))
        #expect(try ramp.reaches(0.5, from: 0, through: 600))
        #expect(try ramp.reaches(0.5, from: 500, through: 500))
        #expect(try !ramp.reaches(0.5, from: 600, through: 900))
        let peak = try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 500, value: 1),
                                  .init(ticks: 1_000, value: 0)])
        #expect(try peak.reaches(0.9, from: 0, through: 1_000))
        let steps = try Self.lane([.init(ticks: 0, value: 0.2, interpolation: .step),
                                   .init(ticks: 1_000, value: 0.8, interpolation: .step),
                                   .init(ticks: 2_000, value: 0.3)])
        #expect(try steps.reaches(0.5, from: 0, through: 1_000))
        #expect(try !steps.reaches(0.5, from: 1_200, through: 1_999))
        #expect(try steps.reaches(0.5, from: 1_200, through: 2_000))
        for target in [0.25, 0.5, 0.75, 0.9] {
            for split in [100.0, 450, 500, 777] {
                let whole = try peak.reaches(target, from: 0, through: 1_000)
                let parts = try peak.reaches(target, from: 0, through: split)
                    || peak.reaches(target, from: split, through: 1_000)
                #expect(whole == parts)
            }
        }
    }

    static func descriptor(
        unit: ParameterUnit = .normalized, range: ClosedRange<Double> = 0...1, curve: ParameterCurve = .linear,
        ceiling: Double? = nil, controlClass: ControlClass = .live, defaultValue: Double? = nil
    ) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: level, unit: unit, lower: range.lowerBound, upper: range.upperBound,
            defaultValue: defaultValue ?? range.lowerBound,
            ceiling: ceiling, curve: curve, ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    static func lane(_ points: [AutomationBreakpoint],
                     _ descriptor: ParameterDescriptor? = nil) throws -> AutomationLane {
        try AutomationLane(descriptor: descriptor ?? Self.descriptor(), breakpoints: points)
    }

    /// 0 → 1 linear over 0…1000, holds 1 until it jumps to 0.2 at 2000, then 0.2 → 0.8 linear to 3000.
    static func ramp() throws -> AutomationLane {
        try lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1, interpolation: .step),
                  .init(ticks: 2_000, value: 0.2), .init(ticks: 3_000, value: 0.8)])
    }

    static func arbiter(_ mode: AutomationMode, _ resume: AutomationResume = .glide(ticks: 100),
                        lane: AutomationLane? = nil, playing: Bool = true) throws -> ParameterArbiter {
        try ParameterArbiter(lane: lane ?? ramp(), mode: mode, resume: resume, playing: playing)
    }

    static func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-12
    }
}
