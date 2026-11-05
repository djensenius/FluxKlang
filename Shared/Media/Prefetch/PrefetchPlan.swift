//
//  PrefetchPlan.swift
//  FluxKlang
//
//  A checked prefetch pool plan (#109 PF1, media-contract.md §8.2): each audio
//  source voice owns `blockCount` preallocated blocks of `blockFrames` frames,
//  and `blockFrames × blockCount ≥ headFrames`. Bounds follow
//  media-contract-v1.schema.json `$defs/action.properties.prefetch` (lines 89–94):
//  blockFrames 64…65536, blockCount 2…1024, headFrames ≥ 1.
//

/// A validated prefetch pool plan. Build it with `make(blockFrames:blockCount:headFrames:)`.
struct PrefetchPlan: Hashable, Sendable {
    static let blockFramesRange = 64...65_536
    static let blockCountRange = 2...1024

    var blockFrames: Int { storedBlockFrames }
    var blockCount: Int { storedBlockCount }
    var headFrames: Int { storedHeadFrames }
    /// `blockFrames × blockCount`: every frame the pool can hold at once.
    var poolFrames: Int { storedPoolFrames }

    private let storedBlockFrames: Int
    private let storedBlockCount: Int
    private let storedHeadFrames: Int
    private let storedPoolFrames: Int

    private init(validatedBlockFrames blockFrames: Int, blockCount: Int, headFrames: Int, poolFrames: Int) {
        storedBlockFrames = blockFrames
        storedBlockCount = blockCount
        storedHeadFrames = headFrames
        storedPoolFrames = poolFrames
    }

    static func make(blockFrames: Int, blockCount: Int, headFrames: Int) throws(PrefetchRefusal) -> PrefetchPlan {
        guard blockFramesRange.contains(blockFrames) else { throw .blockFramesOutOfRange(blockFrames) }
        guard blockCountRange.contains(blockCount) else { throw .blockCountOutOfRange(blockCount) }
        guard headFrames >= 1 else { throw .headFramesNotPositive(headFrames) }
        // The bounds keep the product at most 2^26; the overflow check still refuses rather than traps.
        let (poolFrames, overflow) = blockFrames.multipliedReportingOverflow(by: blockCount)
        guard !overflow, poolFrames >= headFrames else {
            throw .headExceedsPool(headFrames: headFrames, poolFrames: overflow ? Int.max : poolFrames)
        }
        return PrefetchPlan(validatedBlockFrames: blockFrames, blockCount: blockCount, headFrames: headFrames,
                            poolFrames: poolFrames)
    }
}
