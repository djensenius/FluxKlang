import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("Prefetch playhead and underrun", .productionAccessAudit)
#else
@Suite("Prefetch playhead and underrun")
#endif
struct PrefetchPlayheadTests {
    typealias Fixture = PrefetchFixture

    /// Checks one recorded underrun against the runtime discontinuity vocabulary.
    static func expectUnderrun(_ underrun: RuntimeDiscontinuity, frame: Int64, frames: UInt32,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .underrun = underrun.kind else {
            Issue.record("not an underrun: \(underrun.kind)", sourceLocation: sourceLocation)
            return
        }
        #expect(underrun.sample.clock == 3 && underrun.sample.generation == 1, sourceLocation: sourceLocation)
        #expect(underrun.sample.frame == frame, sourceLocation: sourceLocation)
        #expect(underrun.frames == frames, sourceLocation: sourceLocation)
        #expect(underrun.stream == 7 && underrun.host == nil, sourceLocation: sourceLocation)
    }

    @Test
    func residentFramesAreServedWithoutUnderrun() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(0))
        try playhead.insert(Fixture.block(64))
        let render = try playhead.render(frames: 100, at: Fixture.sample(1000))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64), .served(sourceFrame: 64, frames: 36)])
        #expect(render.underruns.isEmpty && playhead.underrunFrames == 0)
        #expect(playhead.position == 100 && Fixture.starts(playhead) == [64])
    }

    @Test
    func blockStartingAtTheRenderEndIsNotTouched() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(0))
        try playhead.insert(Fixture.block(64))
        let render = try playhead.render(frames: 64, at: Fixture.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64)])  // no zero-length segment at 64
        #expect(render.underruns.isEmpty && Fixture.starts(playhead) == [64])
    }

    @Test
    func exampleFiveUnderrunIsSilenceForExactlyTheMissingFrames() throws {
        // Example 05 seq 4: underrun at sample frame 150000, 512 frames, on the backing stream.
        var playhead = try Fixture.playhead(Fixture.examplePlan())
        try playhead.insert(Fixture.block(0, 4096))
        try playhead.insert(Fixture.block(4608, 4096))
        let render = try playhead.render(frames: 8192, at: Fixture.sample(145_904))
        #expect(render.segments == [
            .served(sourceFrame: 0, frames: 4096),
            .silence(sourceFrame: 4096, frames: 512),
            .served(sourceFrame: 4608, frames: 3584)
        ])
        try #require(render.underruns.count == 1)
        Self.expectUnderrun(render.underruns[0], frame: 150_000, frames: 512)
        // The missing source frames are skipped: the position advances by the whole render, staying aligned.
        #expect(playhead.position == 8192 && playhead.underrunFrames == 512)
        #expect(Fixture.starts(playhead) == [4608])
        let next = try playhead.render(frames: 512, at: Fixture.sample(154_096))
        #expect(next.segments == [.served(sourceFrame: 8192, frames: 512)] && next.underruns.isEmpty)
        #expect(playhead.blocks.isEmpty)
    }

    @Test
    func emptyPoolRendersSilenceAndAdvances() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), position: 10)
        let render = try playhead.render(frames: 256, at: Fixture.sample(0))
        #expect(render.segments == [.silence(sourceFrame: 10, frames: 256)])
        try #require(render.underruns.count == 1)
        Self.expectUnderrun(render.underruns[0], frame: 0, frames: 256)
        #expect(playhead.position == 266 && playhead.underrunFrames == 256)
    }

    @Test
    func everyGapIsItsOwnUnderrunInOrder() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(16, 32))
        try playhead.insert(Fixture.block(64, 16))
        let render = try playhead.render(frames: 100, at: Fixture.sample(500))
        #expect(render.segments == [
            .silence(sourceFrame: 0, frames: 16), .served(sourceFrame: 16, frames: 32),
            .silence(sourceFrame: 48, frames: 16), .served(sourceFrame: 64, frames: 16),
            .silence(sourceFrame: 80, frames: 20)
        ])
        try #require(render.underruns.count == 3)
        Self.expectUnderrun(render.underruns[0], frame: 500, frames: 16)
        Self.expectUnderrun(render.underruns[1], frame: 548, frames: 16)
        Self.expectUnderrun(render.underruns[2], frame: 580, frames: 20)
        #expect(playhead.position == 100 && playhead.underrunFrames == 52 && playhead.blocks.isEmpty)
    }

    @Test
    func partlyConsumedBlockServesFromThePlayhead() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(0))
        _ = try playhead.render(frames: 40, at: Fixture.sample(0))
        let render = try playhead.render(frames: 40, at: Fixture.sample(40))
        #expect(render.segments == [.served(sourceFrame: 40, frames: 24), .silence(sourceFrame: 64, frames: 16)])
        try #require(render.underruns.count == 1)
        Self.expectUnderrun(render.underruns[0], frame: 64, frames: 16)
    }

    @Test
    func renderLengthEdgesAreRefusedUnchanged() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(0))
        #expect(Fixture.refusal { try playhead.render(frames: 0, at: Fixture.sample(0)) }
            == .renderLengthOutOfRange(frames: 0, maximum: 256))
        #expect(Fixture.refusal { try playhead.render(frames: 257, at: Fixture.sample(0)) }
            == .renderLengthOutOfRange(frames: 257, maximum: 256))
        #expect(playhead.position == 0 && Fixture.starts(playhead) == [0] && playhead.underrunFrames == 0)
        #expect(try playhead.render(frames: 256, at: Fixture.sample(0)).segments.count == 2)
        #expect(playhead.position == 256)
    }

    @Test
    func frameOverflowIsRefusedNotTrapped() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), position: .max - 10)
        #expect(Fixture.refusal { try playhead.render(frames: 11, at: Fixture.sample(0)) }
            == .frameOverflow(startFrame: .max - 10, frames: 11))
        #expect(Fixture.refusal { try playhead.render(frames: 10, at: Fixture.sample(.max - 9)) }
            == .frameOverflow(startFrame: .max - 9, frames: 10))
        #expect(playhead.position == .max - 10 && playhead.underrunFrames == 0)
        _ = try playhead.render(frames: 10, at: Fixture.sample(.max - 10))
        #expect(playhead.position == .max)
    }

    @Test
    func residencyNeedsContiguousCurrentHeadFrames() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(headFrames: 128))
        try playhead.insert(Fixture.block(0))
        #expect(!playhead.isHeadResident)
        try playhead.insert(Fixture.block(64, 63))
        #expect(!playhead.isHeadResident)  // 127 contiguous frames
        try playhead.insert(Fixture.block(127, 1))
        #expect(playhead.isHeadResident)  // exactly 128
    }

    @Test
    func residencyIgnoresFramesBeyondAGap() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(headFrames: 128))
        try playhead.insert(Fixture.block(0))
        try playhead.insert(Fixture.block(65))
        try playhead.insert(Fixture.block(129))
        #expect(!playhead.isHeadResident)  // 192 resident frames, but only 64 contiguous from the playhead
        var late = try Fixture.playhead(Fixture.smallPlan(headFrames: 128))
        try late.insert(Fixture.block(1))
        try late.insert(Fixture.block(65))
        #expect(!late.isHeadResident)  // 128 contiguous frames, but not starting at the playhead
    }

    @Test
    func residencyCountsFromThePlayheadNotTheBlockStart() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(headFrames: 128))
        for start in [0, 64, 128] { try playhead.insert(Fixture.block(Int64(start))) }
        #expect(playhead.isHeadResident)
        _ = try playhead.render(frames: 65, at: Fixture.sample(0))
        #expect(!playhead.isHeadResident)  // 127 frames left from position 65
        try playhead.insert(Fixture.block(192, 1))
        #expect(playhead.isHeadResident)
    }

    @Test
    func exampleSevenHeadIsResidentAfterTwelveBlocks() throws {
        var playhead = try Fixture.playhead(Fixture.examplePlan())
        for index in 0..<11 { try playhead.insert(Fixture.block(Int64(index * 4096), 4096)) }
        #expect(!playhead.isHeadResident)  // 45056 < 48000
        try playhead.insert(Fixture.block(11 * 4096, 4096))
        #expect(playhead.isHeadResident)  // 49152 ≥ 48000
    }

    @Test
    func locateMakesTheHeadNonResidentUntilRefilled() throws {
        // Example 03 seq 16: a locate moves the prefetch head; readiness must be re-prepared.
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        for start in [0, 64, 128] { try playhead.insert(Fixture.block(Int64(start))) }
        #expect(playhead.isHeadResident)
        #expect(try playhead.locate(to: 64) == 3)
        #expect(playhead.position == 64 && playhead.readGeneration == 2 && !playhead.isHeadResident)
        #expect(playhead.blocks.isEmpty && playhead.discardedStaleBlocks == 3)
        // Blocks from the old read never come back, even for the frames under the new position.
        #expect(try playhead.insert(Fixture.block(64, read: 1)) == .discardedStale)
        #expect(!playhead.isHeadResident)
        try playhead.insert(Fixture.block(64, read: 2))
        try playhead.insert(Fixture.block(128, read: 2))
        #expect(playhead.isHeadResident)
        #expect(Fixture.refusal { try playhead.locate(to: -1) } == .negativeFrame(-1))
        #expect(playhead.position == 64 && playhead.readGeneration == 2 && playhead.blocks.count == 2)
    }

    @Test
    func readGenerationChangeDiscardsAndIsNeverServed() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(0))
        try playhead.insert(Fixture.block(64))
        #expect(try playhead.advanceReadGeneration() == 2)
        #expect(playhead.readGeneration == 2 && playhead.position == 0 && !playhead.isHeadResident)
        #expect(playhead.discardedStaleBlocks == 2)
        let render = try playhead.render(frames: 128, at: Fixture.sample(0))
        #expect(render.segments == [.silence(sourceFrame: 0, frames: 128)])
    }

    @Test
    func sourceGenerationChangeDiscardsAndIsNeverServed() throws {
        // Example 05 seqs 6 and 10: source lost (1 → 2) and reacquired (2 → 3).
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        for start in [0, 64] { try playhead.insert(Fixture.block(Int64(start))) }
        #expect(try playhead.adoptSourceGeneration(2) == 2)
        #expect(!playhead.isHeadResident && playhead.blocks.isEmpty)
        #expect(try playhead.adoptSourceGeneration(3) == 0)
        #expect(try playhead.insert(Fixture.block(0, source: 2)) == .discardedStale)
        #expect(playhead.discardedStaleBlocks == 3)
        let render = try playhead.render(frames: 64, at: Fixture.sample(0))
        #expect(render.segments == [.silence(sourceFrame: 0, frames: 64)])
        try playhead.insert(Fixture.block(64, source: 3))
        try playhead.insert(Fixture.block(128, source: 3))
        #expect(playhead.isHeadResident)
    }

    @Test
    func sourceGenerationMustIncrease() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), source: 4)
        try playhead.insert(Fixture.block(0, source: 4))
        #expect(Fixture.refusal { try playhead.adoptSourceGeneration(4) }
            == .generationNotNewer(current: 4, proposed: 4))
        #expect(Fixture.refusal { try playhead.adoptSourceGeneration(3) }
            == .generationNotNewer(current: 4, proposed: 3))
        #expect(playhead.sourceGeneration == 4 && playhead.blocks.count == 1)
        #expect(try playhead.adoptSourceGeneration(5) == 1)
    }

    @Test
    func readGenerationOverflowIsRefusedUnchanged() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), read: .max - 1)
        try playhead.insert(Fixture.block(0, read: .max - 1))
        #expect(try playhead.advanceReadGeneration() == 1)
        try playhead.insert(Fixture.block(0, read: .max))
        #expect(Fixture.refusal { try playhead.advanceReadGeneration() } == .generationOverflow)
        #expect(Fixture.refusal { try playhead.locate(to: 500) } == .generationOverflow)
        #expect(playhead.readGeneration == .max && playhead.position == 0 && playhead.blocks.count == 1)
    }
}
