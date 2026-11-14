import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared builders for the prefetch suites.
enum PrefetchFixture {
    /// Examples 03, 05 and 07: 16 × 4096-frame blocks for a 48000-frame head.
    static func examplePlan() throws -> PrefetchPlan {
        try PrefetchPlan.make(blockFrames: 4096, blockCount: 16, headFrames: 48_000)
    }

    /// 4 × 64-frame blocks for a 128-frame head.
    static func smallPlan(blockCount: Int = 4, headFrames: Int = 128) throws -> PrefetchPlan {
        try PrefetchPlan.make(blockFrames: 64, blockCount: blockCount, headFrames: headFrames)
    }

    static func block(_ start: Int64, _ frames: Int = 64, source: UInt64 = 1, read: UInt64 = 1) throws
        -> PrefetchBlock {
        try PrefetchBlock.make(startFrame: start, frames: frames, sourceGeneration: source, readGeneration: read)
    }

    static func playhead(_ plan: PrefetchPlan, position: Int64 = 0, source: UInt64 = 1,
                         read: UInt64 = 1) throws -> PrefetchPlayhead {
        try PrefetchPlayhead.make(plan: plan, stream: 7, position: position, sourceGeneration: source,
                                  readGeneration: read)
    }

    static func sample(_ frame: Int64) -> RuntimeSampleStamp {
        RuntimeSampleStamp(clock: 3, generation: 1, frame: frame)
    }

    static func refusal(_ body: () throws -> some Any) -> PrefetchRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? PrefetchRefusal
        }
    }

    static func starts(_ playhead: PrefetchPlayhead) -> [Int64] {
        playhead.blocks.map(\.startFrame)
    }
}

@Suite("Prefetch plan", .productionAccessAudit)
struct PrefetchPlanTests {
    typealias Fixture = PrefetchFixture

    @Test
    func examplePlanIsAccepted() throws {
        // Examples 03, 05, 07: 4096 × 16 = 65536 ≥ 48000. A check of blockFrames alone (4096) would refuse it.
        let plan = try Fixture.examplePlan()
        #expect(plan.blockFrames == 4096 && plan.blockCount == 16 && plan.headFrames == 48_000)
        #expect(plan.poolFrames == 65_536)
    }

    @Test
    func blockFramesSchemaEdges() {
        // media-contract-v1.schema.json lines 92: blockFrames minimum 64, maximum 65536.
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 63, blockCount: 2, headFrames: 1) }
            == .blockFramesOutOfRange(63))
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: 1) } == nil)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 65_536, blockCount: 2, headFrames: 1) } == nil)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 65_537, blockCount: 2, headFrames: 1) }
            == .blockFramesOutOfRange(65_537))
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 0, blockCount: 0, headFrames: 0) }
            == .blockFramesOutOfRange(0))
    }

    @Test
    func blockCountSchemaEdges() {
        // Schema line 93: blockCount minimum 2, maximum 1024.
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 1, headFrames: 1) }
            == .blockCountOutOfRange(1))
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: 1) } == nil)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 1024, headFrames: 1) } == nil)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 1025, headFrames: 1) }
            == .blockCountOutOfRange(1025))
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 0, headFrames: 0) }
            == .blockCountOutOfRange(0))
    }

    @Test
    func headFramesMustBePositive() throws {
        // Schema line 94: headFrames is `$defs/positive` (minimum 1).
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: 0) }
            == .headFramesNotPositive(0))
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: -1) }
            == .headFramesNotPositive(-1))
        #expect(try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: 1).headFrames == 1)
    }

    @Test
    func poolMustCoverTheHeadInclusively() throws {
        // §8.2: blockFrames × blockCount ≥ headFrames, so equality is accepted and one more frame is refused.
        #expect(try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: 128).poolFrames == 128)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 64, blockCount: 2, headFrames: 129) }
            == .headExceedsPool(headFrames: 129, poolFrames: 128))
        #expect(try PrefetchPlan.make(blockFrames: 4096, blockCount: 16, headFrames: 65_536).poolFrames == 65_536)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 4096, blockCount: 16, headFrames: 65_537) }
            == .headExceedsPool(headFrames: 65_537, poolFrames: 65_536))
        let largest = 65_536 * 1024
        #expect(try PrefetchPlan.make(blockFrames: 65_536, blockCount: 1024, headFrames: largest).poolFrames
            == largest)
        #expect(Fixture.refusal { try PrefetchPlan.make(blockFrames: 65_536, blockCount: 1024, headFrames: .max) }
            == .headExceedsPool(headFrames: .max, poolFrames: largest))
    }

    @Test
    func blockLengthAndFrameEdges() throws {
        #expect(Fixture.refusal { try Fixture.block(0, 0) } == .blockLengthOutOfRange(frames: 0))
        #expect(try Fixture.block(0, 1).frames == 1)
        #expect(try Fixture.block(0, 65_536).endFrame == 65_536)
        #expect(Fixture.refusal { try Fixture.block(0, 65_537) } == .blockLengthOutOfRange(frames: 65_537))
        #expect(Fixture.refusal { try Fixture.block(-1) } == .negativeFrame(-1))
        #expect(try Fixture.block(0).startFrame == 0)
        #expect(try Fixture.block(.max - 1, 1).endFrame == .max)
        #expect(Fixture.refusal { try Fixture.block(.max - 1, 2) } == .frameOverflow(startFrame: .max - 1, frames: 2))
    }

    @Test
    func blockCarriesBothGenerations() throws {
        let block = try Fixture.block(4096, 4096, source: 3, read: 9)
        #expect(block.sourceGeneration == 3 && block.readGeneration == 9)
        #expect(block.startFrame == 4096 && block.frames == 4096 && block.endFrame == 8192)
    }

    @Test
    func sourceGenerationZeroIsRefused() throws {
        // Schema line 24: `$defs/generation` minimum 1; source counters (`source/…`) hold such values (lines 26–31).
        #expect(Fixture.refusal { try Fixture.block(0, source: 0) } == .sourceGenerationNotPositive)
        #expect(try Fixture.block(0, source: 1).sourceGeneration == 1)
        let plan = try Fixture.smallPlan()
        #expect(Fixture.refusal { try Fixture.playhead(plan, source: 0) } == .sourceGenerationNotPositive)
        #expect(try Fixture.playhead(plan, source: 1).sourceGeneration == 1)
        // The schema has no read-generation field, so no minimum is invented for it.
        #expect(try Fixture.block(0, read: 0).readGeneration == 0)
        #expect(try Fixture.playhead(plan, read: 0).readGeneration == 0)
    }

    @Test
    func playheadStartsEmptyAtAValidPosition() throws {
        let plan = try Fixture.smallPlan()
        #expect(Fixture.refusal { try Fixture.playhead(plan, position: -1) } == .negativeFrame(-1))
        let playhead = try Fixture.playhead(plan, position: 0, source: 2, read: 5)
        #expect(playhead.position == 0 && playhead.blocks.isEmpty && !playhead.isHeadResident)
        #expect(playhead.sourceGeneration == 2 && playhead.readGeneration == 5 && playhead.stream == 7)
        #expect(playhead.discardedStaleBlocks == 0 && playhead.underrunFrames == 0)
    }

    @Test
    func blockLongerThanThePlanIsRefused() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        #expect(Fixture.refusal { try playhead.insert(Fixture.block(0, 65)) }
            == .blockTooLong(frames: 65, blockFrames: 64))
        #expect(playhead.blocks.isEmpty)
        #expect(try playhead.insert(Fixture.block(0, 64)) == .resident)
    }

    @Test
    func fullPoolIsRefusedAndNeverGrows() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(blockCount: 2))
        #expect(try playhead.insert(Fixture.block(0)) == .resident)
        #expect(try playhead.insert(Fixture.block(64)) == .resident)
        let before = Fixture.starts(playhead)
        #expect(Fixture.refusal { try playhead.insert(Fixture.block(128)) } == .poolFull(blockCount: 2))
        #expect(Fixture.starts(playhead) == before)
        // Rendering frees the consumed block, so its slot is reused; the count never exceeds blockCount.
        let render = try playhead.render(frames: 64, at: Fixture.sample(0))
        #expect(render.segments == [.served(sourceFrame: 0, frames: 64)] && render.underruns.isEmpty)
        #expect(try playhead.insert(Fixture.block(128)) == .resident)
        #expect(Fixture.starts(playhead) == [64, 128])
    }

    @Test
    func overlappingBlockIsRefusedUnchanged() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan())
        try playhead.insert(Fixture.block(64))
        try playhead.insert(Fixture.block(192))
        for (start, frames) in [(64, 64), (32, 64), (127, 1), (100, 10), (120, 64), (191, 2), (200, 8)] {
            #expect(Fixture.refusal { try playhead.insert(Fixture.block(Int64(start), frames)) }
                == .overlappingBlock(startFrame: Int64(start), frames: frames), "start \(start) frames \(frames)")
            #expect(Fixture.starts(playhead) == [64, 192])
        }
        // Touching edges are not overlaps.
        #expect(try playhead.insert(Fixture.block(0)) == .resident)
        #expect(try playhead.insert(Fixture.block(128)) == .resident)
        #expect(Fixture.starts(playhead) == [0, 64, 128, 192])
    }

    @Test
    func overlapIsCheckedBeforePoolFull() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(blockCount: 2))
        try playhead.insert(Fixture.block(0))
        try playhead.insert(Fixture.block(64))
        #expect(Fixture.refusal { try playhead.insert(Fixture.block(32)) }
            == .overlappingBlock(startFrame: 32, frames: 64))
    }

    @Test
    func staleBlockIsDiscardedAndCounted() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), source: 2, read: 2)
        #expect(try playhead.insert(Fixture.block(0, source: 1, read: 2)) == .discardedStale)
        #expect(try playhead.insert(Fixture.block(0, source: 2, read: 1)) == .discardedStale)
        #expect(try playhead.insert(Fixture.block(0, source: 1, read: 3)) == .discardedStale)
        #expect(playhead.blocks.isEmpty && playhead.discardedStaleBlocks == 3)
        // A stale block is never served: its frames render as silence.
        let render = try playhead.render(frames: 64, at: Fixture.sample(0))
        #expect(render.segments == [.silence(sourceFrame: 0, frames: 64)])
        #expect(try playhead.insert(Fixture.block(64, source: 2, read: 2)) == .resident)
    }

    @Test
    func staleBlockIsNotCheckedForOverlapOrCapacity() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(blockCount: 2), read: 2)
        try playhead.insert(Fixture.block(0, read: 2))
        try playhead.insert(Fixture.block(64, read: 2))
        #expect(try playhead.insert(Fixture.block(0, read: 1)) == .discardedStale)
        #expect(Fixture.starts(playhead) == [0, 64] && playhead.discardedStaleBlocks == 1)
    }

    @Test
    func blockFromTheFutureIsRefused() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), source: 2, read: 2)
        #expect(Fixture.refusal { try playhead.insert(Fixture.block(0, source: 3, read: 2)) }
            == .generationAhead(source: 3, read: 2))
        #expect(Fixture.refusal { try playhead.insert(Fixture.block(0, source: 2, read: 3)) }
            == .generationAhead(source: 2, read: 3))
        #expect(playhead.blocks.isEmpty && playhead.discardedStaleBlocks == 0)
    }

    @Test
    func blockBehindThePlayheadIsDiscarded() throws {
        var playhead = try Fixture.playhead(Fixture.smallPlan(), position: 128)
        #expect(try playhead.insert(Fixture.block(64)) == .discardedPassed)
        #expect(try playhead.insert(Fixture.block(65)) == .resident)
        #expect(Fixture.starts(playhead) == [65] && playhead.discardedStaleBlocks == 0)
    }
}
