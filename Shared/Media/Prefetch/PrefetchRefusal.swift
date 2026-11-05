//
//  PrefetchRefusal.swift
//  FluxKlang
//
//  Typed refusals of the prefetch pool plan and playhead ledger (#109 PF1,
//  media-contract.md §8.2). A refused operation leaves the plan, block or
//  playhead unchanged. A gap between resident blocks is not a refusal: it is
//  an underrun at render time. A stale block is not a refusal either: it is
//  discarded and counted.
//

/// Why a prefetch plan, block, insert, render, locate or generation change is refused.
enum PrefetchRefusal: Error, Equatable, Sendable {
    /// `blockFrames` must lie in `PrefetchPlan.blockFramesRange` (schema: 64…65536).
    case blockFramesOutOfRange(Int)
    /// `blockCount` must lie in `PrefetchPlan.blockCountRange` (schema: 2…1024).
    case blockCountOutOfRange(Int)
    /// `headFrames` must be positive (schema `$defs/positive`).
    case headFramesNotPositive(Int)
    /// `blockFrames × blockCount` must be at least `headFrames`.
    case headExceedsPool(headFrames: Int, poolFrames: Int)
    /// A block holds `1…PrefetchPlan.blockFramesRange.upperBound` frames.
    case blockLengthOutOfRange(frames: Int)
    /// The block holds more frames than the plan's `blockFrames`.
    case blockTooLong(frames: Int, blockFrames: Int)
    /// Source frame positions are never negative.
    case negativeFrame(Int64)
    /// `startFrame + frames` does not fit in `Int64`.
    case frameOverflow(startFrame: Int64, frames: Int)
    /// A render covers `1…maximum` frames, where `maximum` is the plan's pool frames.
    case renderLengthOutOfRange(frames: Int, maximum: Int)
    /// The block is stamped with a generation newer than the playhead's; nothing can have produced it.
    case generationAhead(source: UInt64, read: UInt64)
    /// Source generations are schema `$defs/generation` values (minimum 1); 0 is never a source generation.
    case sourceGenerationNotPositive
    /// A new source generation must be greater than the current one.
    case generationNotNewer(current: UInt64, proposed: UInt64)
    /// The read generation is already `UInt64.max`.
    case generationOverflow
    /// The block's frames intersect a resident current block.
    case overlappingBlock(startFrame: Int64, frames: Int)
    /// Every pool block is resident; the pool never grows.
    case poolFull(blockCount: Int)
}
