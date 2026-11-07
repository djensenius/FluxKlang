//
//  MediaBlockPoolRefusal.swift
//  FluxKlang
//
//  Typed refusals of the preallocated media block pool (#109 IO1,
//  media-contract.md §8.2). A bounded pool never allocates, truncates, blocks
//  or silently drops to make an operation succeed: it refuses, visibly. A
//  refused operation leaves the pool unchanged, with one documented exception:
//  a copy refused for its shape on a valid lease adds exactly one to the
//  `copiesRefused` counter and changes nothing else.
//

/// Why a media block pool could not be built, or an operation on it was refused.
enum MediaBlockPoolRefusal: Error, Equatable, Sendable {
    /// `make`: the channel count is outside `MediaBlockPool.channelCountRange` (`1...16`).
    case channelCountOutOfRange(Int)
    /// `make`: the per-slot generation limit is outside `0...UInt32.max`.
    case maximumGenerationOutOfRange(Int)
    /// `make`: `poolFrames x channelCount` samples exceed `MediaBlockPool.maximumSampleCapacity`.
    /// `samples` is `Int.max` when the product itself overflows.
    case capacityExceedsCap(samples: Int, maximum: Int)
    /// `lease`: every block is leased or retired, and the pool never grows.
    case poolExhausted(leased: Int, retired: Int)
    /// The lease was issued by a different pool, or by a pool that no longer exists.
    case foreignLease
    /// The lease's block is not leased: the lease was already released, or its block was retired when it was.
    case leaseAlreadyReleased(slot: Int)
    /// The lease's block was released and leased again, so the lease generation differs from the block's.
    case staleLease(slot: Int, leaseGeneration: UInt32, currentGeneration: UInt32)
    /// `copyIn`: `frames` is outside `0...blockFrames`.
    case framesOutOfRange(frames: Int, blockFrames: Int)
    /// `copyIn`: the copy's channel count differs from the pool's channel count.
    case channelCountMismatch(expected: Int, found: Int)
    /// `copyIn`: the source view does not hold exactly `frames x channels` samples.
    case sourceLengthMismatch(expected: Int, found: Int)
    /// `lease`, `release` or `copyIn` was called while a `withSamples` body was running; the viewed block must
    /// not move.
    case accessInProgress
}
