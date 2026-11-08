//
//  SpatialMotionTests+Sampling.swift
//  FluxKlangTests
//
//  `SpatialMotionPath.samples`: the count, step and overflow limits at their boundaries, the order of those checks
//  (each order fixture holds two defects) and frames computed from the first frame, the step and the index.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMotionTests {
    static func samplesRefusal(
        _ path: SpatialMotionPath,
        first: Int64,
        step: Int64,
        count: Int
    ) -> SpatialMotionRefusal? {
        do throws(SpatialMotionRefusal) {
            _ = try path.samples(firstFrame: first, stepFrames: step, count: count)
            return nil
        } catch {
            return error
        }
    }

    static func unitPath(mode: SpatialMotionMode = .once) throws -> SpatialMotionPath {
        try build([pin(0, 0), pin(10, 1)], mode: mode)
    }

    @Test func aSampleCountOfZeroAndOfFourThousandNinetySixAreAcceptedAndOneOutsideIsRefusedWithItsCount() throws {
        let path = try Self.unitPath()
        let empty = try path.samples(firstFrame: 0, stepFrames: 1, count: 0)
        let full = try path.samples(firstFrame: 0, stepFrames: 1, count: 4096)
        let counts: [Int] = [-1, 4097, Int.min, Int.max]
        let refusals = counts.map { Self.samplesRefusal(path, first: 0, step: 1, count: $0) }
        let expected: [SpatialMotionRefusal?] = [
            .sampleCountOutOfRange(-1), .sampleCountOutOfRange(4097),
            .sampleCountOutOfRange(Int.min), .sampleCountOutOfRange(Int.max)
        ]
        #expect(empty.isEmpty)
        #expect(full.count == 4096)
        #expect(refusals == expected)
    }

    @Test func aStepOfOneIsAcceptedAndZeroMinusOneAndInt64MinAreRefusedEvenForACountOfZero() throws {
        let path = try Self.unitPath()
        let accepted = try path.samples(firstFrame: 0, stepFrames: 1, count: 2)
        let steps: [Int64] = [0, -1, Int64.min]
        let refusals = steps.map { Self.samplesRefusal(path, first: 0, step: $0, count: 3) }
        let emptyRefusals = steps.map { Self.samplesRefusal(path, first: 0, step: $0, count: 0) }
        let expected: [SpatialMotionRefusal?] = [.stepNotPositive(0), .stepNotPositive(-1), .stepNotPositive(Int64.min)]
        #expect(accepted.count == 2)
        #expect(refusals == expected)
        #expect(emptyRefusals == expected)
    }

    @Test func aCountOfZeroGivesAnEmptyRunForFirstFramesOfInt64MinInt64MaxAndFiveWithoutAnOverflowCheck() throws {
        let path = try Self.unitPath(mode: .loop)
        let least = try path.samples(firstFrame: Int64.min, stepFrames: 1, count: 0)
        let greatest = try path.samples(firstFrame: Int64.max, stepFrames: Int64.max, count: 0)
        let ordinary = try path.samples(firstFrame: 5, stepFrames: 2, count: 0)
        #expect(least.isEmpty)
        #expect(greatest.isEmpty)
        #expect(ordinary.isEmpty)
    }

    @Test func aLastFrameOfInt64MaxIsAcceptedAndOneMoreOrAMultiplicationOverflowIsRefused() throws {
        let path = try Self.unitPath()
        let exact = try path.samples(firstFrame: Int64.max - 1, stepFrames: 1, count: 2)
        let wide = try path.samples(firstFrame: 0, stepFrames: Int64.max, count: 2)
        let negative = try path.samples(firstFrame: Int64.min, stepFrames: Int64.max, count: 2)
        let addition: SpatialMotionRefusal? = Self.samplesRefusal(path, first: Int64.max, step: 1, count: 2)
        let multiplication: SpatialMotionRefusal? = Self.samplesRefusal(path, first: 0, step: Int64.max, count: 3)
        let expected: SpatialMotionRefusal? = .frameOverflow
        #expect(exact.count == 2)
        #expect(wide.count == 2)
        #expect(negative.count == 2)
        #expect(addition == expected)
        #expect(multiplication == expected)
    }

    @Test func aSampleCountAboveTheLimitIsReportedBeforeAStepBelowOne() throws {
        let path = try Self.unitPath()
        let both: SpatialMotionRefusal? = Self.samplesRefusal(path, first: 0, step: 0, count: 4097)
        let expected: SpatialMotionRefusal? = .sampleCountOutOfRange(4097)
        #expect(both == expected)
    }

    @Test func aStepBelowOneIsReportedBeforeAnOverflowOfTheLastFrame() throws {
        let path = try Self.unitPath()
        let both: SpatialMotionRefusal? = Self.samplesRefusal(path, first: Int64.min, step: -1, count: 2)
        let expected: SpatialMotionRefusal? = .stepNotPositive(-1)
        #expect(both == expected)
    }

    @Test func samplesAtFramesZeroThreeSixNineAndTwelveReadTheDecimalTenthsAndTheHeldEnd() throws {
        let path = try Self.unitPath()
        let points = try path.samples(firstFrame: 0, stepFrames: 3, count: 5)
        let actual: [Double] = points.map(\.x)
        let expected: [Double] = [0.0, 0.3, 0.6, 0.9, 1.0]
        #expect(actual == expected)
    }

    @Test func aNegativeFirstFrameHoldsTheFirstWaypointUntilTheFirstWaypointFrameIsReached() throws {
        let path = try Self.unitPath()
        let points = try path.samples(firstFrame: -2, stepFrames: 1, count: 5)
        let actual: [Double] = points.map(\.x)
        let expected: [Double] = [0.0, 0.0, 0.0, 0.1, 0.2]
        #expect(actual == expected)
    }

    @Test func aLoopRunWrapsAtTheLastFrameAndContinuesFromTheFirstWaypoint() throws {
        let path = try Self.unitPath(mode: .loop)
        let points = try path.samples(firstFrame: 8, stepFrames: 1, count: 4)
        let actual: [Double] = points.map(\.x)
        let expected: [Double] = [0.8, 0.9, 0.0, 0.1]
        #expect(actual == expected)
    }

    @Test func theSixSamplesOfAWideStepEqualThePointsAtSixHandTypedFrames() throws {
        let path = try Self.build([Self.pin(0, -1, 1), Self.pin(1 << 40, 1, -1)])
        let step: Int64 = 1 << 38
        let points = try path.samples(firstFrame: 0, stepFrames: step, count: 6)
        let frames: [Int64] = [0, 1 << 38, 1 << 39, 3 << 38, 1 << 40, 5 << 38]
        let direct = frames.map { path.point(at: $0) }
        #expect(points == direct)
        #expect(points.count == 6)
    }
}
