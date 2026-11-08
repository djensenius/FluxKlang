import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension InterruptedTakeSalvageTests {
    @Test
    func finalizedContainerCoveringTheJournalIsIntactAndKeepsEverySegment() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 175, finalized: true))
        let expectedLost: Int64 = 0
        let expectedUntracked: Int64 = 0
        #expect(plan.verdict == .intact)
        #expect(plan.keptSegments == segments)
        #expect(plan.lostJournaledFrames == expectedLost)
        #expect(plan.untrackedTailFrames == expectedUntracked)
        #expect(!plan.needsHeaderRepair)
        #expect(!plan.interrupted)
    }

    @Test
    func unfinalizedContainerCoveringTheJournalNeedsOnlyHeaderRepair() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 175, finalized: false))
        let expectedLost: Int64 = 0
        let expectedUntracked: Int64 = 0
        #expect(plan.verdict == .headerRepairOnly)
        #expect(plan.keptSegments == segments)
        #expect(plan.lostJournaledFrames == expectedLost)
        #expect(plan.untrackedTailFrames == expectedUntracked)
        #expect(plan.needsHeaderRepair)
        #expect(plan.interrupted)
    }

    @Test
    func durableFramesOneShortOfTheJournalTrimTheLastSegmentByOneFrame() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 174, finalized: false))
        let lastSpec = InterruptedTakeSegmentSpec(fileStart: 150, frames: 24, startFrame: 5_150)
        let clippedLast = try lastSpec.build()
        let firstSegment = try #require(segments.first)
        let secondSegment = try #require(segments.dropFirst().first)
        let expectedKept: [RecordingSegment] = [firstSegment, secondSegment, clippedLast]
        let expectedLost: Int64 = 1
        let expectedUntracked: Int64 = 0
        #expect(plan.verdict == .trimmed)
        #expect(plan.keptSegments == expectedKept)
        #expect(plan.lostJournaledFrames == expectedLost)
        #expect(plan.untrackedTailFrames == expectedUntracked)
        #expect(plan.needsHeaderRepair)
        #expect(plan.interrupted)
    }

    @Test
    func durableFramesOneBeyondTheJournalAreReportedUntrackedAndNeverKept() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let expectedUntracked: Int64 = 1
        let expectedLost: Int64 = 0
        for finalized in [true, false] {
            let plan = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 176, finalized: finalized))
            let expectedVerdict: TakeSalvageVerdict = finalized ? .intact : .headerRepairOnly
            let expectedRepair: Bool = !finalized
            #expect(plan.verdict == expectedVerdict)
            #expect(plan.keptSegments == segments)
            #expect(plan.untrackedTailFrames == expectedUntracked)
            #expect(plan.lostJournaledFrames == expectedLost)
            #expect(plan.needsHeaderRepair == expectedRepair)
            #expect(plan.interrupted == expectedRepair)
        }
    }

    @Test
    func finalizedContainerShorterThanTheJournalIsStillTrimmedAndInterrupted() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 174, finalized: true))
        #expect(plan.verdict == .trimmed)
        #expect(plan.needsHeaderRepair)
        #expect(plan.interrupted)
    }

    @Test
    func zeroDurableFramesWithJournaledSegmentsKeepNothingAndLoseTheWholeJournal() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let expectedKept: [RecordingSegment] = []
        let expectedLost: Int64 = 175
        let expectedUntracked: Int64 = 0
        for finalized in [true, false] {
            let plan = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 0, finalized: finalized))
            #expect(plan.verdict == .nothingDurable)
            #expect(plan.keptSegments == expectedKept)
            #expect(plan.lostJournaledFrames == expectedLost)
            #expect(plan.untrackedTailFrames == expectedUntracked)
            #expect(!plan.needsHeaderRepair)
            #expect(plan.interrupted)
        }
    }

    @Test
    func noJournaledSegmentsReportEveryDurableFrameAsUntrackedAndKeepNothing() throws {
        let expectedKept: [RecordingSegment] = []
        let expectedLost: Int64 = 0
        let expectedUntracked: Int64 = 7
        for finalized in [true, false] {
            let plan = try InterruptedTakeSalvage.plan(Fixture.facts([], durable: 7, finalized: finalized))
            #expect(plan.verdict == .nothingDurable)
            #expect(plan.keptSegments == expectedKept)
            #expect(plan.lostJournaledFrames == expectedLost)
            #expect(plan.untrackedTailFrames == expectedUntracked)
            #expect(!plan.needsHeaderRepair)
            #expect(plan.interrupted)
        }
    }

    @Test
    func noJournaledSegmentsAndNoDurableFramesIsALegalEmptyPlan() throws {
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts([], durable: 0, finalized: true))
        let expectedUntracked: Int64 = 0
        let expectedLost: Int64 = 0
        let expectedKept: [RecordingSegment] = []
        #expect(plan.verdict == .nothingDurable)
        #expect(plan.keptSegments == expectedKept)
        #expect(plan.untrackedTailFrames == expectedUntracked)
        #expect(plan.lostJournaledFrames == expectedLost)
        #expect(!plan.needsHeaderRepair)
        #expect(plan.interrupted)
    }

    @Test
    func aCutExactlyOnASegmentBoundaryKeepsEarlierSegmentsWholeAndClipsNothing() throws {
        let segments = try Fixture.chain([100, 50, 25])
        let atSecondBoundary = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 150))
        let firstSegment = try #require(segments.first)
        let secondSegment = try #require(segments.dropFirst().first)
        let expectedTwo: [RecordingSegment] = [firstSegment, secondSegment]
        let lostAfterTwo: Int64 = 25
        #expect(atSecondBoundary.verdict == .trimmed)
        #expect(atSecondBoundary.keptSegments == expectedTwo)
        #expect(atSecondBoundary.lostJournaledFrames == lostAfterTwo)
        let atFirstBoundary = try InterruptedTakeSalvage.plan(Fixture.facts(segments, durable: 100))
        let expectedOne: [RecordingSegment] = [firstSegment]
        let lostAfterOne: Int64 = 75
        #expect(atFirstBoundary.keptSegments == expectedOne)
        #expect(atFirstBoundary.lostJournaledFrames == lostAfterOne)
    }

    @Test
    func overflowsOfSegmentsWhollyBeforeTheCutAreKeptUnchanged() throws {
        var firstSpec = InterruptedTakeSegmentSpec(fileStart: 0, frames: 100, startFrame: 5_000)
        firstSpec.overflows = [try Fixture.overflow(5_010, 4)]
        let first = try firstSpec.build()
        let second = try InterruptedTakeSegmentSpec(fileStart: 100, frames: 50, startFrame: 5_100).build()
        let plan = try InterruptedTakeSalvage.plan(Fixture.facts([first, second], durable: 120))
        let kept = try #require(plan.keptSegments.first)
        let expectedPadded: Int64 = 4
        #expect(kept == first)
        #expect(kept.paddedFrames == expectedPadded)
    }
}
