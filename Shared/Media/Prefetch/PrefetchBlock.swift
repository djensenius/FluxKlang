//
//  PrefetchBlock.swift
//  FluxKlang
//
//  One filled pool block (#109 PF1, media-contract.md §8.2): a contiguous run
//  of source frames stamped with the source generation (file identity) and the
//  read generation (the locate or re-read that produced it). The model carries
//  frame ranges, not samples.
//

/// A validated block of source frames `[startFrame, endFrame)`. Build it with `make`.
struct PrefetchBlock: Hashable, Sendable {
    var startFrame: Int64 { storedStartFrame }
    var frames: Int { storedFrames }
    /// One past the last source frame; `make` guarantees it fits in `Int64`.
    var endFrame: Int64 { storedStartFrame + Int64(storedFrames) }
    var sourceGeneration: UInt64 { storedSourceGeneration }
    var readGeneration: UInt64 { storedReadGeneration }

    private let storedStartFrame: Int64
    private let storedFrames: Int
    private let storedSourceGeneration: UInt64
    private let storedReadGeneration: UInt64

    private init(validatedStartFrame startFrame: Int64, frames: Int, sourceGeneration: UInt64,
                 readGeneration: UInt64) {
        storedStartFrame = startFrame
        storedFrames = frames
        storedSourceGeneration = sourceGeneration
        storedReadGeneration = readGeneration
    }

    static func make(startFrame: Int64, frames: Int, sourceGeneration: UInt64,
                     readGeneration: UInt64) throws(PrefetchRefusal) -> PrefetchBlock {
        guard (1...PrefetchPlan.blockFramesRange.upperBound).contains(frames) else {
            throw .blockLengthOutOfRange(frames: frames)
        }
        guard startFrame >= 0 else { throw .negativeFrame(startFrame) }
        guard !startFrame.addingReportingOverflow(Int64(frames)).overflow else {
            throw .frameOverflow(startFrame: startFrame, frames: frames)
        }
        guard sourceGeneration >= 1 else { throw .sourceGenerationNotPositive }
        return PrefetchBlock(validatedStartFrame: startFrame, frames: frames, sourceGeneration: sourceGeneration,
                             readGeneration: readGeneration)
    }
}

/// What `PrefetchPlayhead.insert` did with a block that was not refused.
enum PrefetchInsertOutcome: Equatable, Sendable {
    /// The block now occupies a pool slot.
    case resident
    /// The block carries an older source or read generation; it was dropped and counted, never served.
    case discardedStale
    /// Every frame of the block is behind the playhead; it was dropped without taking a slot.
    case discardedPassed
}

/// One contiguous run of a render, in source frames.
enum PrefetchSegment: Equatable, Sendable {
    /// Frames served from resident current blocks.
    case served(sourceFrame: Int64, frames: Int)
    /// Missing frames output as silence; the source frames are skipped to stay aligned.
    case silence(sourceFrame: Int64, frames: Int)
}
