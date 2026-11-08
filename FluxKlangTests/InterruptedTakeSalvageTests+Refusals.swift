import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension InterruptedTakeSalvageTests {
    private static func oneFrameSegments(_ count: Int) throws -> [RecordingSegment] {
        try Fixture.chain(Array(repeating: Int64(1), count: count))
    }

    /// Two segments whose file ends are representable except the second one's: the first covers `Int64.max - 1`
    /// frames from file frame 0, the second starts there and has `frames` frames.
    private static func nearLimitSegments(secondFrames: Int64) throws -> [RecordingSegment] {
        let reach: Int64 = Int64.max - 1
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: reach, startFrame: 0).build()
        let second = try InterruptedTakeSegmentSpec(fileStart: reach, frames: secondFrames, startFrame: 0).build()
        return [first, second]
    }

    @Test
    func theSegmentLimitIsAcceptedAndOneMoreIsRefusedWithTheCountGiven() throws {
        let atLimit = try Self.oneFrameSegments(1_024)
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts(atLimit, durable: 1_024))
        let expectedCount = 1_024
        #expect(plan.verdict == .intact)
        #expect(plan.keptSegments.count == expectedCount)
        let overLimit = try Self.oneFrameSegments(1_025)
        let refusal = Fixture.refusal(of: Fixture.facts(overLimit, durable: 1_025))
        let expected: TakeSalvageRefusal? = .tooManySegments(1_025)
        #expect(refusal == expected)
    }

    @Test
    func negativeDurableFramesAreRefusedWhileZeroIsAccepted() throws {
        let segments = try Fixture.chain([10])
        let negative: TakeSalvageRefusal? = .negativeDurableFrames
        let minusOne = Fixture.refusal(of: Fixture.facts(segments, durable: -1))
        let minimum = Fixture.refusal(of: Fixture.facts(segments, durable: Int64.min))
        #expect(minusOne == negative)
        #expect(minimum == negative)
        let accepted: TakeSalvageRefusal? = nil
        let zero = Fixture.refusal(of: Fixture.facts(segments, durable: 0))
        let emptyZero = Fixture.refusal(of: Fixture.facts([], durable: 0))
        #expect(zero == accepted)
        #expect(emptyZero == accepted)
    }

    @Test
    func aFirstSegmentNotStartingAtFileFrameZeroIsRefusedAtIndexZero() throws {
        let late = try InterruptedTakeSegmentSpec(fileStart: 1, frames: 10).build()
        let refusal = Fixture.refusal(of: Fixture.facts([late], durable: 11))
        let expected: TakeSalvageRefusal? = .fileNotContiguous(index: 0)
        #expect(refusal == expected)
    }

    @Test
    func aGapOrAnOverlapBetweenSegmentsIsRefusedAtTheLaterSegmentsIndex() throws {
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: 10).build()
        let second = try InterruptedTakeSegmentSpec(fileStart: 10, frames: 10).build()
        let expected: TakeSalvageRefusal? = .fileNotContiguous(index: 2)
        for start: Int64 in [21, 19] {
            let third = try InterruptedTakeSegmentSpec(fileStart: start, frames: 10).build()
            let refusal = Fixture.refusal(of: Fixture.facts([first, second, third], durable: 30))
            #expect(refusal == expected)
        }
    }

    @Test
    func theFirstOfSeveralContinuityViolationsIsTheOneReported() throws {
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: 10).build()
        let early = try InterruptedTakeSegmentSpec(fileStart: 11, frames: 10).build()
        let late = try InterruptedTakeSegmentSpec(fileStart: 40, frames: 10).build()
        let refusal = Fixture.refusal(of: Fixture.facts([first, early, late], durable: 50))
        let expected: TakeSalvageRefusal? = .fileNotContiguous(index: 1)
        #expect(refusal == expected)
    }

    @Test
    func aFileEndAtInt64MaxIsAcceptedAndOneFrameMoreIsRefusedAsOverflow() throws {
        let fitting = try Self.nearLimitSegments(secondFrames: 1)
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts(fitting, durable: Int64.max))
        let expectedUntracked: Int64 = 0
        #expect(plan.verdict == .intact)
        #expect(plan.untrackedTailFrames == expectedUntracked)
        let overflowing = try Self.nearLimitSegments(secondFrames: 2)
        let refusal = Fixture.refusal(of: Fixture.facts(overflowing, durable: 5))
        let expected: TakeSalvageRefusal? = .arithmeticOverflow
        #expect(refusal == expected)
    }

    @Test
    func aSegmentAfterAnUnrepresentableFileEndIsRefusedAsOverflowNotAsAGap() throws {
        let reach: Int64 = Int64.max - 1
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: reach, startFrame: 0).build()
        let second = try InterruptedTakeSegmentSpec(fileStart: reach, frames: 5, startFrame: 0).build()
        let third = try InterruptedTakeSegmentSpec(fileStart: 3, frames: 5, startFrame: 0).build()
        let refusal = Fixture.refusal(of: Fixture.facts([first, second, third], durable: 5))
        let expected: TakeSalvageRefusal? = .arithmeticOverflow
        #expect(refusal == expected)
    }

    @Test
    func tooManySegmentsIsReportedBeforeNegativeDurableFramesWhenBothApply() throws {
        let overLimit = try Self.oneFrameSegments(1_025)
        let refusal = Fixture.refusal(of: Fixture.facts(overLimit, durable: -1))
        let expected: TakeSalvageRefusal? = .tooManySegments(1_025)
        #expect(refusal == expected)
    }

    @Test
    func negativeDurableFramesIsReportedBeforeAContinuityViolationWhenBothApply() throws {
        let late = try InterruptedTakeSegmentSpec(fileStart: 1, frames: 10).build()
        let refusal = Fixture.refusal(of: Fixture.facts([late], durable: -1))
        let expected: TakeSalvageRefusal? = .negativeDurableFrames
        #expect(refusal == expected)
    }

    @Test
    func aContinuityViolationIsReportedBeforeAnOverflowWhenBothApply() throws {
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: 10, startFrame: 0).build()
        let huge = try InterruptedTakeSegmentSpec(fileStart: 99, frames: Int64.max, startFrame: 0).build()
        let refusal = Fixture.refusal(of: Fixture.facts([first, huge], durable: 5))
        let expected: TakeSalvageRefusal? = .fileNotContiguous(index: 1)
        #expect(refusal == expected)
    }
}
