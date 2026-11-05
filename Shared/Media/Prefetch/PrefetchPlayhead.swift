//
//  PrefetchPlayhead.swift
//  FluxKlang
//
//  The playhead ledger of one audio source voice (#109 PF1, media-contract.md
//  §8.2). It owns at most `plan.blockCount` resident blocks, all stamped with
//  the current source and read generations. A render serves only resident
//  current frames; each gap is output as silence for exactly the missing
//  frames, the position advances past them to stay aligned, and the gap is
//  recorded as a `RuntimeDiscontinuity` of kind `.underrun` with its frame
//  count (example 05). A locate, a read-generation change or a new source
//  generation discards every resident block, so the head stays non-resident
//  until refilled. This is a pure model, not the SPSC/RT ring (#64).
//

/// The result of one render: the segments in source order and one underrun per gap.
struct PrefetchRender: Sendable {
    let segments: [PrefetchSegment]
    let underruns: [RuntimeDiscontinuity]
}

/// A validated playhead over a fixed pool. Build it with `make`.
struct PrefetchPlayhead: Sendable {
    let plan: PrefetchPlan
    /// The playback stream ordinal stamped on recorded underruns.
    let stream: UInt32
    /// The next source frame to render.
    private(set) var position: Int64
    private(set) var sourceGeneration: UInt64
    private(set) var readGeneration: UInt64
    /// Resident current blocks, sorted by `startFrame`, never overlapping, never more than `plan.blockCount`.
    private(set) var blocks: [PrefetchBlock]
    /// Stale blocks discarded at insert or by a generation change; none was ever served.
    private(set) var discardedStaleBlocks: Int
    /// Total silence frames output for underruns.
    private(set) var underrunFrames: Int64

    private init(validatedPlan plan: PrefetchPlan, stream: UInt32, position: Int64, sourceGeneration: UInt64,
                 readGeneration: UInt64) {
        self.plan = plan
        self.stream = stream
        self.position = position
        self.sourceGeneration = sourceGeneration
        self.readGeneration = readGeneration
        var blocks: [PrefetchBlock] = []
        blocks.reserveCapacity(plan.blockCount)
        self.blocks = blocks
        discardedStaleBlocks = 0
        underrunFrames = 0
    }

    static func make(plan: PrefetchPlan, stream: UInt32, position: Int64 = 0, sourceGeneration: UInt64,
                     readGeneration: UInt64) throws(PrefetchRefusal) -> PrefetchPlayhead {
        guard position >= 0 else { throw .negativeFrame(position) }
        guard sourceGeneration >= 1 else { throw .sourceGenerationNotPositive }
        return PrefetchPlayhead(validatedPlan: plan, stream: stream, position: position,
                                sourceGeneration: sourceGeneration, readGeneration: readGeneration)
    }

    /// True only when contiguous current frames starting at `position` cover at least `plan.headFrames`.
    var isHeadResident: Bool {
        var cursor = position
        for block in blocks where block.endFrame > cursor {
            guard block.startFrame <= cursor else { break }
            cursor = block.endFrame
        }
        return cursor - position >= Int64(plan.headFrames)
    }

    /// Adds a filled block. Stale or passed blocks are discarded; a too-long, future, overlapping or
    /// pool-full insert is refused and nothing changes.
    @discardableResult
    mutating func insert(_ block: PrefetchBlock) throws(PrefetchRefusal) -> PrefetchInsertOutcome {
        guard block.frames <= plan.blockFrames else {
            throw .blockTooLong(frames: block.frames, blockFrames: plan.blockFrames)
        }
        if block.sourceGeneration < sourceGeneration || block.readGeneration < readGeneration {
            discardedStaleBlocks += 1
            return .discardedStale
        }
        guard block.sourceGeneration == sourceGeneration, block.readGeneration == readGeneration else {
            throw .generationAhead(source: block.sourceGeneration, read: block.readGeneration)
        }
        guard block.endFrame > position else { return .discardedPassed }
        let index = blocks.firstIndex { $0.startFrame >= block.startFrame } ?? blocks.endIndex
        let overlapsPrevious = index > blocks.startIndex && blocks[index - 1].endFrame > block.startFrame
        let overlapsNext = index < blocks.endIndex && blocks[index].startFrame < block.endFrame
        guard !overlapsPrevious, !overlapsNext else {
            throw .overlappingBlock(startFrame: block.startFrame, frames: block.frames)
        }
        guard blocks.count < plan.blockCount else { throw .poolFull(blockCount: plan.blockCount) }
        blocks.insert(block, at: index)
        return .resident
    }

    /// Renders `frames` frames whose first frame plays at `sample`. Serves resident frames, outputs
    /// silence for each gap, advances `position` by `frames` and frees fully consumed blocks.
    ///
    /// `frames` must lie in `1...plan.poolFrames`: a longer render can never be fully resident, so it is refused
    /// with `.renderLengthOutOfRange`. Callers split a longer host buffer into chunks of at most `plan.poolFrames`.
    ///
    /// This is the model, not the real-time path: it allocates the `segments` and `underruns` arrays on every
    /// call. A real-time port must write into preallocated output instead (#64).
    mutating func render(frames: Int, at sample: RuntimeSampleStamp) throws(PrefetchRefusal) -> PrefetchRender {
        guard (1...plan.poolFrames).contains(frames) else {
            throw .renderLengthOutOfRange(frames: frames, maximum: plan.poolFrames)
        }
        let length = Int64(frames)
        let (end, positionOverflow) = position.addingReportingOverflow(length)
        guard !positionOverflow else { throw .frameOverflow(startFrame: position, frames: frames) }
        guard !sample.frame.addingReportingOverflow(length).overflow else {
            throw .frameOverflow(startFrame: sample.frame, frames: frames)
        }
        var segments: [PrefetchSegment] = []
        var underruns: [RuntimeDiscontinuity] = []
        var cursor = position
        func gap(to next: Int64) {
            guard next > cursor else { return }
            let missing = next - cursor
            segments.append(.silence(sourceFrame: cursor, frames: Int(missing)))
            let frame = sample.frame + (cursor - position)
            underruns.append(RuntimeDiscontinuity(
                kind: .underrun, sample: RuntimeSampleStamp(clock: sample.clock, generation: sample.generation,
                                                            frame: frame),
                frames: UInt32(missing), stream: stream, host: nil
            ))
            cursor = next
        }
        for block in blocks where block.endFrame > cursor && block.startFrame < end {
            gap(to: block.startFrame)
            let served = min(block.endFrame, end) - cursor
            segments.append(.served(sourceFrame: cursor, frames: Int(served)))
            cursor += served
        }
        gap(to: end)
        blocks.removeAll { $0.endFrame <= end }
        underrunFrames += underruns.reduce(0) { $0 + Int64($1.frames ?? 0) }
        position = end
        return PrefetchRender(segments: segments, underruns: underruns)
    }

    /// Moves the playhead. A locate is a new read: every resident block becomes stale and is discarded.
    @discardableResult
    mutating func locate(to frame: Int64) throws(PrefetchRefusal) -> Int {
        guard frame >= 0 else { throw .negativeFrame(frame) }
        let discarded = try advanceReadGeneration()
        position = frame
        return discarded
    }

    /// Starts a new read at the same position; every resident block is discarded. Returns how many.
    @discardableResult
    mutating func advanceReadGeneration() throws(PrefetchRefusal) -> Int {
        guard readGeneration < UInt64.max else { throw .generationOverflow }
        readGeneration += 1
        return discardStaleBlocks()
    }

    /// Adopts a newer source generation (source lost or reacquired); every resident block is discarded.
    @discardableResult
    mutating func adoptSourceGeneration(_ generation: UInt64) throws(PrefetchRefusal) -> Int {
        guard generation > sourceGeneration else {
            throw .generationNotNewer(current: sourceGeneration, proposed: generation)
        }
        sourceGeneration = generation
        return discardStaleBlocks()
    }

    private mutating func discardStaleBlocks() -> Int {
        let count = blocks.count
        blocks.removeAll(keepingCapacity: true)
        discardedStaleBlocks += count
        return count
    }
}
