//
//  PerformXYTests+Golden.swift
//  FluxKlangTests
//
//  Hand-typed tables for the pad: the clamp of an entry, the catch table of a waiting pad, a pointer far outside the
//  ranges, adjusting one axis, typed entry, and an engaged pad that takes a pointer wherever it is. Every expected
//  value is typed out; none is computed with the code under test.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformXYTests {
    @Test
    func clampGoldenForTheXRangeMinusHundredToHundred() throws {
        let axis = try Self.range(-100, 100)
        #expect(axis.clamped(-101) == PerformXYClampedValue(value: -100, clamp: .belowRange))
        #expect(axis.clamped(-100) == PerformXYClampedValue(value: -100, clamp: nil))
        #expect(axis.clamped(0) == PerformXYClampedValue(value: 0, clamp: nil))
        #expect(axis.clamped(100) == PerformXYClampedValue(value: 100, clamp: nil))
        #expect(axis.clamped(101) == PerformXYClampedValue(value: 100, clamp: .aboveRange))
        #expect(axis.clamped(Int.max) == PerformXYClampedValue(value: 100, clamp: .aboveRange))
        #expect(axis.clamped(Int.min) == PerformXYClampedValue(value: -100, clamp: .belowRange))
    }

    @Test
    func oneStepRangesClampBelowOnAndAboveTheirValue() throws {
        let seven = try Self.range(7, 7)
        #expect(seven.clamped(6) == PerformXYClampedValue(value: 7, clamp: .belowRange))
        #expect(seven.clamped(7) == PerformXYClampedValue(value: 7, clamp: nil))
        #expect(seven.clamped(8) == PerformXYClampedValue(value: 7, clamp: .aboveRange))
        let zero = try Self.range(0, 0)
        #expect(zero.clamped(-1) == PerformXYClampedValue(value: 0, clamp: .belowRange))
        #expect(zero.clamped(0) == PerformXYClampedValue(value: 0, clamp: nil))
        #expect(zero.clamped(1) == PerformXYClampedValue(value: 0, clamp: .aboveRange))
    }

    @Test
    func pointerReportsTheClampOfEachAxisSeparately() throws {
        let pad = try Self.pad(0, 0, .engaged)
        Self.expectMove(pad.pointer(Self.point(500, 10)), to: Self.point(100, 10), .aboveRange, nil)
        Self.expectMove(pad.pointer(Self.point(10, -500)), to: Self.point(10, -50), nil, .belowRange)
        Self.expectMove(pad.pointer(Self.point(-500, 500)), to: Self.point(-100, 50), .belowRange, .aboveRange)
        Self.expectMove(pad.pointer(Self.point(-100, 50)), to: Self.point(-100, 50), nil, nil)
    }

    @Test
    func aWaitingPadCatchesAPointerWithinTheRadiusOnBothAxes() throws {
        let pad = try Self.pad(0, 0, .waiting, radius: 5)
        Self.expectMove(pad.pointer(Self.point(5, 5)), to: Self.point(5, 5), nil, nil)
        Self.expectMove(pad.pointer(Self.point(-5, -5)), to: Self.point(-5, -5), nil, nil)
        Self.expectMove(pad.pointer(Self.point(0, 0)), to: Self.point(0, 0), nil, nil)
        Self.expectHold(pad.pointer(Self.point(6, 0)), requested: Self.point(6, 0), current: Self.point(0, 0))
        Self.expectHold(pad.pointer(Self.point(5, 6)), requested: Self.point(5, 6), current: Self.point(0, 0))
        Self.expectHold(pad.pointer(Self.point(0, -6)), requested: Self.point(0, -6), current: Self.point(0, 0))
        Self.expectHold(pad.pointer(Self.point(-6, -6)), requested: Self.point(-6, -6), current: Self.point(0, 0))
    }

    @Test
    func aRadiusOfZeroCatchesTheExactPositionAndHoldsOneStepAway() throws {
        let pad = try Self.pad(0, 0, .waiting, radius: 0)
        Self.expectMove(pad.pointer(Self.point(0, 0)), to: Self.point(0, 0), nil, nil)
        Self.expectHold(pad.pointer(Self.point(1, 0)), requested: Self.point(1, 0), current: Self.point(0, 0))
        Self.expectHold(pad.pointer(Self.point(0, 1)), requested: Self.point(0, 1), current: Self.point(0, 0))
    }

    @Test
    func aPointerFarOutsideClampsOntoAnEdgePadAndIsCaughtThereOrHeldAtTheCentre() throws {
        let edge = try Self.pad(100, -50, .waiting, radius: 0)
        Self.expectMove(edge.pointer(Self.point(1000, -1000)), to: Self.point(100, -50), .aboveRange, .belowRange)
        let centre = try Self.pad(0, 0, .waiting, radius: 5)
        Self.expectHold(
            centre.pointer(Self.point(1000, -1000)), requested: Self.point(100, -50), current: Self.point(0, 0)
        )
    }

    @Test
    func aCaughtPadStaysEngagedForAFarPointerAfterwards() throws {
        let waiting = try Self.pad(0, 0, .waiting, radius: 5)
        let caught = try #require(Self.move(of: waiting.pointer(Self.point(3, 3))))
        Self.expectMove(caught.pad.pointer(Self.point(90, 40)), to: Self.point(90, 40), nil, nil)
    }

    @Test
    func anEngagedPadAppliesAPointerWithoutARadiusCheck() throws {
        let pad = try Self.pad(0, 0, .engaged, radius: 5)
        Self.expectMove(pad.pointer(Self.point(50, -20)), to: Self.point(50, -20), nil, nil)
        Self.expectMove(pad.pointer(Self.point(1000, -1000)), to: Self.point(100, -50), .aboveRange, .belowRange)
    }

    @Test
    func theSameFarPointersAreHeldByAWaitingPadAtTheCentre() throws {
        let pad = try Self.pad(0, 0, .waiting, radius: 5)
        Self.expectHold(pad.pointer(Self.point(50, -20)), requested: Self.point(50, -20), current: Self.point(0, 0))
        Self.expectHold(
            pad.pointer(Self.point(1000, -1000)), requested: Self.point(100, -50), current: Self.point(0, 0)
        )
    }

    @Test
    func adjustingMovesOneAxisAndReportsTheClampGolden() throws {
        let pad = try Self.pad(80, 0, .engaged)
        Self.expectMove(try pad.adjusting(.x, by: 30), to: Self.point(100, 0), .aboveRange, nil)
        Self.expectMove(try pad.adjusting(.x, by: 20), to: Self.point(100, 0), nil, nil)
        Self.expectMove(try pad.adjusting(.y, by: -60), to: Self.point(80, -50), nil, .belowRange)
        Self.expectMove(try pad.adjusting(.x, by: -1), to: Self.point(79, 0), nil, nil)
        Self.expectMove(try pad.adjusting(.y, by: 50), to: Self.point(80, 50), nil, nil)
        Self.expectMove(try pad.adjusting(.y, by: 51), to: Self.point(80, 50), nil, .aboveRange)
    }

    @Test
    func adjustingByIntMaxAndIntMinClampsWithoutTrapping() throws {
        let pad = try Self.pad(80, 0, .engaged)
        Self.expectMove(try pad.adjusting(.x, by: Int.max), to: Self.point(100, 0), .aboveRange, nil)
        Self.expectMove(try pad.adjusting(.y, by: Int.min), to: Self.point(80, -50), nil, .belowRange)
        Self.expectMove(try pad.adjusting(.x, by: Int.min), to: Self.point(-100, 0), .belowRange, nil)
        Self.expectMove(try pad.adjusting(.y, by: Int.max), to: Self.point(80, 50), nil, .aboveRange)
    }

    @Test
    func adjustingChangesTheNamedAxisAcrossAGridAndLeavesTheOther() throws {
        let starts = [Self.point(-100, -50), Self.point(0, 0), Self.point(100, 50), Self.point(-7, 33)]
        let steps = [-3, -1, 1, 3]
        let expectedX: [[Int]] = [[-100, -100, -99, -97], [-3, -1, 1, 3], [97, 99, 100, 100], [-10, -8, -6, -4]]
        let expectedY: [[Int]] = [[-50, -50, -49, -47], [-3, -1, 1, 3], [47, 49, 50, 50], [30, 32, 34, 36]]
        for (start, expected) in zip(starts, zip(expectedX, expectedY)) {
            let pad = try Self.pad(start.x, start.y, .engaged)
            for (step, results) in zip(steps, zip(expected.0, expected.1)) {
                let movedX = try #require(Self.move(of: try pad.adjusting(.x, by: step)))
                #expect(movedX.pad.position == Self.point(results.0, start.y))
                let movedY = try #require(Self.move(of: try pad.adjusting(.y, by: step)))
                #expect(movedY.pad.position == Self.point(start.x, results.1))
            }
        }
    }

    @Test
    func enteringClampsAGivenAxisAndKeepsTheOtherAtItsPosition() throws {
        let pad = try Self.pad(0, 10, .engaged)
        Self.expectMove(try pad.entering(x: 500, y: nil), to: Self.point(100, 10), .aboveRange, nil)
        Self.expectMove(try pad.entering(x: nil, y: -500), to: Self.point(0, -50), nil, .belowRange)
        Self.expectMove(try pad.entering(x: -20, y: 30), to: Self.point(-20, 30), nil, nil)
        Self.expectMove(try pad.entering(x: 0, y: nil), to: Self.point(0, 10), nil, nil)
        let offsetPad = try Self.pad(7, -3, .engaged)
        Self.expectMove(try offsetPad.entering(x: nil, y: 20), to: Self.point(7, 20), nil, nil)
        Self.expectMove(try offsetPad.entering(x: 30, y: nil), to: Self.point(30, -3), nil, nil)
        Self.expectMove(try pad.entering(x: Int.min, y: Int.max), to: Self.point(-100, 50), .belowRange, .aboveRange)
    }
}
