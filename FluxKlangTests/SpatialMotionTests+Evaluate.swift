//
//  SpatialMotionTests+Evaluate.swift
//  FluxKlangTests
//
//  `SpatialMotionPath.point(at:)`: holds, segment boundaries, the loop wrap, the extreme `Int64` frames, the zero sign
//  and the numeric fixtures. Expected values are literals, not the production formula.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMotionTests {
    @Test func atAndBeforeTheFirstFrameBothModesGiveTheFirstWaypointEvenAtInt64Min() throws {
        let waypoints = [Self.pin(10, -0.5, 0.25), Self.pin(20, 0.5, 0.75)]
        let expected = NeutralPoint(clampingFinite: -0.5, y: 0.25)
        for mode in [SpatialMotionMode.once, SpatialMotionMode.loop] {
            let path = try Self.build(waypoints, mode: mode)
            let atFirst = path.point(at: 10)
            let before = path.point(at: 9)
            let farBefore = path.point(at: Int64.min)
            #expect(atFirst == expected)
            #expect(before == expected)
            #expect(farBefore == expected)
        }
    }

    @Test func inOnceModeTheLastFrameAndFrames11AndInt64MaxGiveTheLastWaypointWithoutWrapping() throws {
        let path = try Self.build([Self.pin(0, 0, -0.5), Self.pin(10, 0.5, 1)])
        let expected = NeutralPoint(clampingFinite: 0.5, y: 1)
        let before = path.point(at: 9)
        let atEnd = path.point(at: 10)
        let after = path.point(at: 11)
        let farAfter = path.point(at: Int64.max)
        let beforeX: Double = before.x
        let expectedBeforeX = 0.45
        #expect(beforeX == expectedBeforeX)
        #expect(atEnd == expected)
        #expect(after == expected)
        #expect(farAfter == expected)
    }

    @Test func aFrameOnAWaypointGivesThatWaypointBecauseABoundaryBelongsToTheLaterSegment() throws {
        let path = try Self.build([Self.pin(0, -1.0), Self.pin(10, -0.3), Self.pin(20, 0.5)])
        let actual = Self.xValues(path, at: [0, 10, 20])
        let expected: [Double] = [-1.0, -0.3, 0.5]
        #expect(actual == expected)
    }

    @Test func eachFrameOfATenFrameUnitSegmentEqualsTheDecimalLiteralOfItsTenth() throws {
        let path = try Self.build([Self.pin(0, 0), Self.pin(10, 1)])
        let frames: [Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let actual = Self.xValues(path, at: frames)
        let expected: [Double] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        #expect(actual == expected)
    }

    @Test func aSevenFrameSegmentAtFrameSixGivesTheValueOfOneDivisionThenOneMultiplyThenOneAdd() throws {
        let path = try Self.build([Self.pin(0, -1.0), Self.pin(7, -0.9)])
        let actual: Double = path.point(at: 6).x
        let expected = -0.9142857142857144
        #expect(actual == expected)
    }

    @Test func aSegmentOfTwoToThe40FramesGivesAQuarterAHalfAndThreeQuartersAtThreeBinaryFrames() throws {
        let top: Int64 = 1 << 40
        let path = try Self.build([Self.pin(0, 0), Self.pin(top, 1)])
        let actual = Self.xValues(path, at: [1 << 38, 1 << 39, 3 << 38])
        let expected: [Double] = [0.25, 0.5, 0.75]
        #expect(actual == expected)
    }

    @Test func aSegmentOfTwoToThe53FramesGivesTheDoublesNextToTheEndsAndZeroInTheMiddle() throws {
        let path = try Self.build([Self.pin(0, -1), Self.pin(Self.topFrame, 1)])
        let low = path.point(at: 1).x
        let middle = path.point(at: 1 << 52).x
        let high = path.point(at: Self.topFrame - 1).x
        let expectedLow = -(1.0 - Double.ulpOfOne)
        let expectedHigh = 1.0 - Double.ulpOfOne
        let middleSign: FloatingPointSign = middle.sign
        #expect(low == expectedLow)
        #expect(middle == 0.0)
        #expect(middleSign == .plus)
        #expect(high == expectedHigh)
    }

    @Test func inLoopModeInt64MaxIsTotalAndReadsTheFrameTwoToThe53MinusOneOfTheCycle() throws {
        let path = try Self.build([Self.pin(0, -1), Self.pin(Self.topFrame, 1)], mode: .loop)
        let actual: Double = path.point(at: Int64.max).x
        let expected = 1.0 - Double.ulpOfOne
        let farBefore = path.point(at: Int64.min)
        let expectedFirst = NeutralPoint(clampingFinite: -1, y: 0)
        #expect(actual == expected)
        #expect(farBefore == expectedFirst)
    }

    @Test func inLoopModeTheLastFrameWrapsToTheFirstWaypointAndOneBeforeItIsStillOnTheLastSegment() throws {
        let path = try Self.build([Self.pin(0, 0, 0), Self.pin(10, 1, 1)], mode: .loop)
        let beforeWrap: Double = path.point(at: 9).x
        let atWrap = path.point(at: 10)
        let secondCycle: Double = path.point(at: 13).x
        let expectedBefore = 0.9
        let expectedFirst = NeutralPoint(clampingFinite: 0, y: 0)
        let expectedSecond = 0.3
        #expect(beforeWrap == expectedBefore)
        #expect(atWrap == expectedFirst)
        #expect(secondCycle == expectedSecond)
    }

    @Test func aLoopStartingAtSevenWrapsByTheDurationOfTenFramesAndNotByTheFrameNumber() throws {
        let path = try Self.build([Self.pin(7, 0), Self.pin(17, 1)], mode: .loop)
        let frames: [Int64] = [6, 7, 12, 16, 17, 22]
        let actual = Self.xValues(path, at: frames)
        let expected: [Double] = [0.0, 0.0, 0.5, 0.9, 0.0, 0.5]
        #expect(actual == expected)
    }

    @Test func aLoopWithAnUnequalLastPointJumpsAtTheWrapWithoutAClosingSegment() throws {
        let path = try Self.build([Self.pin(0, -1), Self.pin(4, 0), Self.pin(8, 0.5)], mode: .loop)
        let actual = Self.xValues(path, at: [7, 8, 9])
        let expected: [Double] = [0.375, -1.0, -0.75]
        #expect(actual == expected)
    }

    @Test func theYAxisIsInterpolatedFromItsOwnWaypointValuesAcrossSeveralSegments() throws {
        let path = try Self.build([Self.pin(0, 0, 1), Self.pin(4, 1, 0), Self.pin(8, 0, -1)])
        let atTwo = path.point(at: 2)
        let atSix = path.point(at: 6)
        let expectedTwo = NeutralPoint(clampingFinite: 0.5, y: 0.5)
        let expectedSix = NeutralPoint(clampingFinite: 0.5, y: -0.5)
        #expect(atTwo == expectedTwo)
        #expect(atSix == expectedSix)
    }

    // MARK: Zero sign

    @Test func aSumOfNegativeZeroOnTheXAxisIsReturnedAsPositiveZero() throws {
        let path = try Self.build([Self.pin(0, -0.0), Self.pin(4, -Double.leastNonzeroMagnitude)])
        let value: Double = path.point(at: 1).x
        let sign: FloatingPointSign = value.sign
        #expect(value == 0.0)
        #expect(sign == .plus)
    }

    @Test func aSumOfNegativeZeroOnTheYAxisIsReturnedAsPositiveZero() throws {
        let path = try Self.build([Self.pin(0, 0, -0.0), Self.pin(4, 0, -Double.leastNonzeroMagnitude)])
        let value: Double = path.point(at: 1).y
        let sign: FloatingPointSign = value.sign
        #expect(value == 0.0)
        #expect(sign == .plus)
    }

    @Test func heldAndBoundaryWaypointsWithNegativeZeroAreReturnedAsPositiveZeroOnBothAxes() throws {
        let path = try Self.build([Self.pin(0, -0.0, -0.0), Self.pin(4, 0.5, 0.5), Self.pin(8, -0.0, -0.0)])
        let first = path.point(at: 0)
        let last = path.point(at: 8)
        let afterLast = path.point(at: 12)
        let looped = try Self.build([Self.pin(0, -0.0, -0.0), Self.pin(4, 0.5, 0.5)], mode: .loop).point(at: 4)
        let signs: [FloatingPointSign] = [
            first.x.sign, first.y.sign, last.x.sign, last.y.sign, afterLast.x.sign, afterLast.y.sign,
            looped.x.sign, looped.y.sign
        ]
        let expected = [FloatingPointSign](repeating: .plus, count: 8)
        #expect(signs == expected)
    }

    // Reads the result only: at the waypoint's own frame the offset is 0, so the sum is +0.0 with or without the
    // normalisation of zero.
    @Test func anInteriorWaypointWithNegativeZeroIsReadAtItsOwnFrameAsPositiveZero() throws {
        let path = try Self.build([Self.pin(0, 0.5, 0.5), Self.pin(4, -0.0, -0.0), Self.pin(8, 0.5, 0.5)])
        let point = path.point(at: 4)
        let signs: [FloatingPointSign] = [point.x.sign, point.y.sign]
        let expected: [FloatingPointSign] = [.plus, .plus]
        #expect(signs == expected)
    }
}
