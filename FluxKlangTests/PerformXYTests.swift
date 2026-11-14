//
//  PerformXYTests.swift
//  FluxKlangTests
//
//  The integer XY pad model (#102 XYP1): the builders every PerformXYTests+*.swift file shares, and the axis range:
//  its magnitude limit with the value on the limit and one beyond it, its order, and `contains` and `clamped` on a
//  signed range and a one-value range. The pad is a pure value: nothing here draws, sends or reads a clock.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct PerformXYTests {
    static func point(_ pointX: Int, _ pointY: Int) -> PerformXYPoint {
        PerformXYPoint(x: pointX, y: pointY)
    }

    static func range(_ lower: Int, _ upper: Int) throws(PerformXYRefusal) -> PerformXYAxisRange {
        try PerformXYAxisRange.make(lower: lower, upper: upper)
    }

    /// A pad over x -100...100 and y -50...50.
    static func pad(
        _ positionX: Int, _ positionY: Int, _ pickup: PerformXYPickup, radius: Int = 5
    ) throws -> PerformXYPad {
        try PerformXYPad.make(
            xRange: range(-100, 100), yRange: range(-50, 50), position: point(positionX, positionY),
            pickup: pickup, captureRadius: radius
        )
    }

    static func refusalOfRange(_ lower: Int, _ upper: Int) -> PerformXYRefusal? {
        do {
            _ = try PerformXYAxisRange.make(lower: lower, upper: upper)
            return nil
        } catch {
            return error
        }
    }

    static func move(of outcome: PerformXYOutcome) -> PerformXYMove? {
        if case let .moved(move) = outcome { return move }
        return nil
    }

    static func hold(of outcome: PerformXYOutcome) -> PerformXYHold? {
        if case let .held(hold) = outcome { return hold }
        return nil
    }

    static func expectMove(
        _ outcome: PerformXYOutcome, to target: PerformXYPoint, _ xClamp: PerformXYClamp?, _ yClamp: PerformXYClamp?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let move = move(of: outcome) else {
            Issue.record("expected a move", sourceLocation: sourceLocation)
            return
        }
        #expect(move.pad.position == target, sourceLocation: sourceLocation)
        #expect(move.pad.pickup == .engaged, sourceLocation: sourceLocation)
        #expect(move.xClamp == xClamp, sourceLocation: sourceLocation)
        #expect(move.yClamp == yClamp, sourceLocation: sourceLocation)
    }

    static func expectHold(
        _ outcome: PerformXYOutcome, requested: PerformXYPoint, current: PerformXYPoint,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let hold = hold(of: outcome) else {
            Issue.record("expected a hold", sourceLocation: sourceLocation)
            return
        }
        #expect(hold.requested == requested, sourceLocation: sourceLocation)
        #expect(hold.current == current, sourceLocation: sourceLocation)
    }

    // MARK: - Range limits and order

    @Test
    func rangeAcceptsBoundsOnTheMagnitudeLimitAndRefusesOneBeyondEitherSide() throws {
        let widest = try Self.range(-1_000_000, 1_000_000)
        #expect(widest.lower == -1_000_000)
        #expect(widest.upper == 1_000_000)
        let highest = try Self.range(1_000_000, 1_000_000)
        #expect(highest.lower == 1_000_000)
        let lowest = try Self.range(-1_000_000, -1_000_000)
        #expect(lowest.upper == -1_000_000)
        #expect(Self.refusalOfRange(-1_000_001, 0) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(0, 1_000_001) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(-1_000_001, 1_000_001) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(1_000_001, 1_000_001) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(-1_000_001, -1_000_001) == .boundOutOfLimit)
    }

    @Test
    func rangeRefusesIntMinAndIntMaxBoundsWithoutTrapping() {
        #expect(Self.refusalOfRange(Int.min, 0) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(0, Int.max) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(Int.min, Int.max) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(Int.max, Int.min) == .boundOutOfLimit)
    }

    @Test
    func rangeRefusesALowerBoundAboveTheUpperBoundAndAcceptsEqualBounds() throws {
        #expect(Self.refusalOfRange(5, 4) == .rangeInverted)
        #expect(Self.refusalOfRange(1, 0) == .rangeInverted)
        #expect(Self.refusalOfRange(0, -1) == .rangeInverted)
        #expect(Self.refusalOfRange(1_000_000, -1_000_000) == .rangeInverted)
        let one = try Self.range(7, 7)
        #expect(one.lower == 7)
        #expect(one.upper == 7)
        let zero = try Self.range(0, 0)
        #expect(zero.lower == 0)
    }

    @Test
    func rangeReportsABoundBeyondTheLimitBeforeAnInvertedRange() {
        #expect(Self.refusalOfRange(5_000_000, 1) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(1, -5_000_000) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(Int.max, Int.min) == .boundOutOfLimit)
        #expect(Self.refusalOfRange(5, 1) == .rangeInverted)
    }

    @Test
    func signedRangeHoldsNegativeZeroAndPositiveSteps() throws {
        let signed = try Self.range(-1, 1)
        #expect(signed.contains(-1))
        #expect(signed.contains(0))
        #expect(signed.contains(1))
        #expect(!signed.contains(-2))
        #expect(!signed.contains(2))
        let single = try Self.range(0, 0)
        #expect(single.contains(0))
        #expect(!single.contains(-1))
        #expect(!single.contains(1))
        #expect(signed.clamped(-1) == PerformXYClampedValue(value: -1, clamp: nil))
        #expect(signed.clamped(0) == PerformXYClampedValue(value: 0, clamp: nil))
        #expect(signed.clamped(1) == PerformXYClampedValue(value: 1, clamp: nil))
    }
}
