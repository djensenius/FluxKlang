//
//  SpatialMotionTests.swift
//  FluxKlangTests
//
//  Spatial motion paths (#116 SPM1): the builders every SpatialMotionTests+*.swift file shares and the limits of
//  `SpatialMotionPath.make`, each with the value on the limit and the value one outside it. A path is a pure value:
//  nothing here reads a clock, an engine or a device.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct SpatialMotionTests {
    static let source = SpatialSourceID(validated: "source")
    /// 2^53, the largest accepted frame.
    static let topFrame: Int64 = 9_007_199_254_740_992

    static func pin(_ frame: Int64, _ horizontal: Double, _ vertical: Double = 0) -> SpatialMotionWaypoint {
        SpatialMotionWaypoint(frame: frame, x: horizontal, y: vertical)
    }

    /// `count` waypoints at frames 0, 1, 2 ... on x = 0.
    static func ramp(count: Int) -> [SpatialMotionWaypoint] {
        (0..<count).map { pin(Int64($0), 0) }
    }

    static func build(
        _ waypoints: [SpatialMotionWaypoint],
        mode: SpatialMotionMode = .once
    ) throws -> SpatialMotionPath {
        try SpatialMotionPath.make(source: source, mode: mode, waypoints: waypoints)
    }

    /// The refusal `make` throws for these waypoints, or nil when it builds a path.
    static func refusal(
        _ waypoints: [SpatialMotionWaypoint],
        mode: SpatialMotionMode = .once
    ) -> SpatialMotionRefusal? {
        do throws(SpatialMotionRefusal) {
            _ = try SpatialMotionPath.make(source: source, mode: mode, waypoints: waypoints)
            return nil
        } catch {
            return error
        }
    }

    static func xValues(_ path: SpatialMotionPath, at frames: [Int64]) -> [Double] {
        frames.map { path.point(at: $0).x }
    }

    // MARK: Waypoint count

    @Test func twoWaypointsAreAcceptedAndZeroOrOneAreRefusedWithTheirCount() {
        let none: SpatialMotionRefusal? = Self.refusal([])
        let one: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0)])
        let two: SpatialMotionRefusal? = Self.refusal(Self.ramp(count: 2))
        let expectedNone: SpatialMotionRefusal? = .tooFewWaypoints(0)
        let expectedOne: SpatialMotionRefusal? = .tooFewWaypoints(1)
        let accepted: SpatialMotionRefusal? = nil
        #expect(none == expectedNone)
        #expect(one == expectedOne)
        #expect(two == accepted)
    }

    @Test func twoHundredFiftySixWaypointsAreAcceptedAndTwoHundredFiftySevenAreRefusedWithTheirCount() {
        let atLimit: SpatialMotionRefusal? = Self.refusal(Self.ramp(count: 256))
        let overLimit: SpatialMotionRefusal? = Self.refusal(Self.ramp(count: 257))
        let accepted: SpatialMotionRefusal? = nil
        let expected: SpatialMotionRefusal? = .tooManyWaypoints(257)
        #expect(atLimit == accepted)
        #expect(overLimit == expected)
    }

    // MARK: Frames

    @Test func framesZeroAndTwoToThe53AreAcceptedAndOneOutsideEitherEndIsRefusedWithItsIndex() {
        let ends: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(Self.topFrame, 0)])
        let below: SpatialMotionRefusal? = Self.refusal([Self.pin(-1, 0), Self.pin(5, 0)])
        let aboveFrames = [Self.pin(0, 0), Self.pin(1, 0), Self.pin(Self.topFrame + 1, 0)]
        let above: SpatialMotionRefusal? = Self.refusal(aboveFrames)
        let accepted: SpatialMotionRefusal? = nil
        let expectedBelow: SpatialMotionRefusal? = .frameOutOfRange(index: 0)
        let expectedAbove: SpatialMotionRefusal? = .frameOutOfRange(index: 2)
        #expect(ends == accepted)
        #expect(below == expectedBelow)
        #expect(above == expectedAbove)
    }

    @Test func theExtremeInt64FramesAreRefusedWithTheirIndex() {
        let least: SpatialMotionRefusal? = Self.refusal([Self.pin(Int64.min, 0), Self.pin(5, 0)])
        let greatest: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(Int64.max, 0)])
        let expectedLeast: SpatialMotionRefusal? = .frameOutOfRange(index: 0)
        let expectedGreatest: SpatialMotionRefusal? = .frameOutOfRange(index: 1)
        #expect(least == expectedLeast)
        #expect(greatest == expectedGreatest)
    }

    @Test func aFrameEqualToThePreviousOrBelowItIsRefusedAndOneAboveIsAccepted() {
        let equal: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(4, 0), Self.pin(4, 0)])
        let below: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(4, 0), Self.pin(3, 0)])
        let above: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(4, 0), Self.pin(5, 0)])
        let expected: SpatialMotionRefusal? = .frameNotIncreasing(index: 2)
        let accepted: SpatialMotionRefusal? = nil
        #expect(equal == expected)
        #expect(below == expected)
        #expect(above == accepted)
    }

    @Test func aFirstFrameOf100AndAPairEndingAtTheTopFrameAreAccepted() {
        let shifted: SpatialMotionRefusal? = Self.refusal([Self.pin(100, 0), Self.pin(101, 0)])
        let atTop: SpatialMotionRefusal? = Self.refusal([Self.pin(Self.topFrame - 1, 0), Self.pin(Self.topFrame, 0)])
        let accepted: SpatialMotionRefusal? = nil
        #expect(shifted == accepted)
        #expect(atTop == accepted)
    }

    // MARK: Coordinates

    @Test func coordinatesOnTheEdgesAndZeroOfBothSignsAreAcceptedOnEachAxis() {
        let edges: SpatialMotionRefusal? = Self.refusal([Self.pin(0, -1, 1), Self.pin(1, 1, -1)])
        let zeros: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0.0, -0.0), Self.pin(1, -0.0, 0.0)])
        let accepted: SpatialMotionRefusal? = nil
        #expect(edges == accepted)
        #expect(zeros == accepted)
    }

    @Test func coordinatesOneUlpOutsideTheEdgesAreRefusedOnEachAxisAndNeverClamped() {
        let high = 1.0.nextUp
        let low = (-1.0).nextDown
        let xHigh: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(1, high)])
        let xLow: SpatialMotionRefusal? = Self.refusal([Self.pin(0, low), Self.pin(1, 0)])
        let yHigh: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(1, 0), Self.pin(2, 0, high)])
        let yLow: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0, low), Self.pin(1, 0)])
        let expectedFirst: SpatialMotionRefusal? = .coordinateOutOfRange(index: 0)
        let expectedSecond: SpatialMotionRefusal? = .coordinateOutOfRange(index: 1)
        let expectedThird: SpatialMotionRefusal? = .coordinateOutOfRange(index: 2)
        #expect(xHigh == expectedSecond)
        #expect(xLow == expectedFirst)
        #expect(yHigh == expectedThird)
        #expect(yLow == expectedFirst)
    }

    @Test func nanAndInfiniteCoordinatesAreRefusedOnEachAxisWithTheirIndex() {
        let expected: SpatialMotionRefusal? = .nonFiniteCoordinate(index: 1)
        let xNaN: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(1, Double.nan)])
        let yNaN: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(1, 0, Double.nan)])
        let xInfinite: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(1, Double.infinity)])
        let yInfinite: SpatialMotionRefusal? = Self.refusal([Self.pin(0, 0), Self.pin(1, 0, -Double.infinity)])
        #expect(xNaN == expected)
        #expect(yNaN == expected)
        #expect(xInfinite == expected)
        #expect(yInfinite == expected)
    }

    // MARK: Stored values

    @Test func aBuiltPathKeepsTheSourceModeCallerOrderAndNegativeZeroBits() throws {
        let waypoints = [Self.pin(5, -0.0, 0.5), Self.pin(9, 1, -0.0), Self.pin(12, 0.25, 0.75)]
        let path = try Self.build(waypoints, mode: .loop)
        let sameSource: Bool = path.source == Self.source
        let mode: SpatialMotionMode = path.mode
        let frames: [Int64] = path.waypoints.map(\.frame)
        let firstSign: FloatingPointSign = try #require(path.waypoints.first).x.sign
        let secondSign: FloatingPointSign = try #require(path.waypoints.dropFirst().first).y.sign
        #expect(sameSource)
        #expect(mode == .loop)
        #expect(frames == [5, 9, 12])
        #expect(firstSign == .minus)
        #expect(secondSign == .minus)
    }
}
