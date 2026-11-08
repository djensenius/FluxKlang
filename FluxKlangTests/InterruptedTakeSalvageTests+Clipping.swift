import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension InterruptedTakeSalvageTests {
    private static func crossingSpec() -> InterruptedTakeSegmentSpec {
        InterruptedTakeSegmentSpec(fileStart: 100, frames: 50, startFrame: 7_000,
                                   placement: .placed(startOffsetNs: 123_456), openedBy: .sampleJump)
    }

    /// Plans `[segment 0 (100 frames), spec]` with `durable` file frames and returns the planned second segment.
    private static func keptCrossing(_ spec: InterruptedTakeSegmentSpec, durable: Int64) throws -> RecordingSegment {
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: 100, startFrame: 5_000).build()
        let facts = Fixture.facts([first, try spec.build()], durable: durable)
        let plan = try InterruptedTakeSalvage.plan(facts)
        try #require(plan.keptSegments.count == 2)
        return plan.keptSegments[1]
    }

    private static func expectedClip(frames: Int64, overflows: [OverflowInterval] = []) throws -> RecordingSegment {
        var spec = crossingSpec()
        spec.frames = frames
        spec.overflows = overflows
        return try spec.build()
    }

    @Test
    func cutOneFrameIntoTheCrossingSegmentClipsItToOneFrame() throws {
        let kept = try Self.keptCrossing(Self.crossingSpec(), durable: 101)
        let expected = try Self.expectedClip(frames: 1)
        #expect(kept == expected)
    }

    @Test
    func cutInTheMiddleOfTheCrossingSegmentClipsItToTheDurableFrames() throws {
        let kept = try Self.keptCrossing(Self.crossingSpec(), durable: 125)
        let expected = try Self.expectedClip(frames: 25)
        #expect(kept == expected)
    }

    @Test
    func cutOneFrameBeforeTheCrossingSegmentsEndClipsOffOnlyItsLastFrame() throws {
        let kept = try Self.keptCrossing(Self.crossingSpec(), durable: 149)
        let expected = try Self.expectedClip(frames: 49)
        #expect(kept == expected)
    }

    @Test
    func segmentsAfterTheCrossingOneAreDropped() throws {
        let first = try InterruptedTakeSegmentSpec(fileStart: 0, frames: 100, startFrame: 5_000).build()
        let crossing = try Self.crossingSpec().build()
        let after = try InterruptedTakeSegmentSpec(fileStart: 150, frames: 10, startFrame: 9_000).build()
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts([first, crossing, after], durable: 130))
        let expectedClip = try Self.expectedClip(frames: 30)
        let expectedKept: [RecordingSegment] = [first, expectedClip]
        let expectedLost: Int64 = 30
        #expect(plan.keptSegments == expectedKept)
        #expect(plan.lostJournaledFrames == expectedLost)
    }

    @Test
    func clippingKeepsAPlacedSegmentsOffsetAndEveryIdentityField() throws {
        var spec = Self.crossingSpec()
        spec.nominalRate = 44_100
        spec.generationValue = 3
        spec.clock = ClockID(validated: "smp.alt")
        spec.openedBy = .clockRestart(previousFrame: 6_999)
        let keptOverflow = try Fixture.overflow(7_005, 4)
        spec.overflows = [keptOverflow]
        let kept = try Self.keptCrossing(spec, durable: 120)
        let expectedOffset: SegmentPlacement = .placed(startOffsetNs: 123_456)
        let expectedRate: Int? = 44_100
        let expectedGeneration = try Generation(3)
        let expectedOpener: SegmentBoundaryReason? = .clockRestart(previousFrame: 6_999)
        let expectedFileStart: Int64 = 100
        let expectedStartFrame: Int64 = 7_000
        let expectedFrames: Int64 = 20
        let expectedClock = ClockID(validated: "smp.alt")
        let expectedOverflows: [OverflowInterval] = [keptOverflow]
        let expectedPadded: Int64 = 4
        #expect(kept.placement == expectedOffset)
        #expect(kept.overflows == expectedOverflows)
        #expect(kept.paddedFrames == expectedPadded)
        #expect(kept.nominalRate == expectedRate)
        #expect(kept.generation == expectedGeneration)
        #expect(kept.clock == expectedClock)
        #expect(kept.openedBy == expectedOpener)
        #expect(kept.fileFrameStart == expectedFileStart)
        #expect(kept.startFrame == expectedStartFrame)
        #expect(kept.frames == expectedFrames)
    }

    @Test
    func clippingKeepsAnUnplacedSegmentUnplacedWithItsReasonAndNoRate() throws {
        var spec = Self.crossingSpec()
        spec.placement = .unplaced(.anchorRefusedStale)
        spec.nominalRate = nil
        spec.openedBy = nil
        let kept = try Self.keptCrossing(spec, durable: 120)
        let expectedPlacement: SegmentPlacement = .unplaced(.anchorRefusedStale)
        let expectedRate: Int? = nil
        let expectedOpener: SegmentBoundaryReason? = nil
        #expect(kept.placement == expectedPlacement)
        #expect(kept.nominalRate == expectedRate)
        #expect(kept.openedBy == expectedOpener)
        #expect(kept.startOffsetNs == nil)
    }

    @Test
    func anOverflowWhollyBeforeTheCutIsKeptWholeAndCountedAsPadding() throws {
        var spec = Self.crossingSpec()
        let early = try Fixture.overflow(7_005, 5)
        spec.overflows = [early]
        let kept = try Self.keptCrossing(spec, durable: 120)
        let expected = try Self.expectedClip(frames: 20, overflows: [early])
        let expectedPadded: Int64 = 5
        #expect(kept == expected)
        #expect(kept.paddedFrames == expectedPadded)
    }

    @Test
    func anOverflowStraddlingTheCutIsClippedToTheCut() throws {
        var spec = Self.crossingSpec()
        spec.overflows = [try Fixture.overflow(7_015, 10)]
        let kept = try Self.keptCrossing(spec, durable: 120)
        let clippedOverflow = try Fixture.overflow(7_015, 5)
        let expected = try Self.expectedClip(frames: 20, overflows: [clippedOverflow])
        let expectedPadded: Int64 = 5
        #expect(kept == expected)
        #expect(kept.paddedFrames == expectedPadded)
    }

    @Test
    func anOverflowEndingExactlyAtTheCutIsKeptWhole() throws {
        var spec = Self.crossingSpec()
        let ending = try Fixture.overflow(7_015, 5)
        spec.overflows = [ending]
        let kept = try Self.keptCrossing(spec, durable: 120)
        let expected = try Self.expectedClip(frames: 20, overflows: [ending])
        #expect(kept == expected)
    }

    @Test
    func anOverflowStartingAtTheCutOrOneFramePastItIsDropped() throws {
        let expected = try Self.expectedClip(frames: 20)
        let expectedPadded: Int64 = 0
        for startFrame: Int64 in [7_020, 7_021] {
            var spec = Self.crossingSpec()
            spec.overflows = [try Fixture.overflow(startFrame, 5)]
            let kept = try Self.keptCrossing(spec, durable: 120)
            #expect(kept == expected)
            #expect(kept.paddedFrames == expectedPadded)
        }
    }

    @Test
    func paddingIsRecomputedFromKeptWholeClippedAndDroppedOverflows() throws {
        var spec = Self.crossingSpec()
        let whole = try Fixture.overflow(7_002, 2)
        let straddling = try Fixture.overflow(7_018, 12)
        let beyond = try Fixture.overflow(7_035, 5)
        spec.overflows = [whole, straddling, beyond]
        let kept = try Self.keptCrossing(spec, durable: 120)
        let clippedStraddling = try Fixture.overflow(7_018, 2)
        let expected = try Self.expectedClip(frames: 20, overflows: [whole, clippedStraddling])
        let expectedPadded: Int64 = 4
        #expect(kept == expected)
        #expect(kept.paddedFrames == expectedPadded)
    }
}
