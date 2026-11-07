//
//  MediaBlockPoolStatistics.swift
//  FluxKlang
//
//  Exact accounting for the preallocated media block pool (#109 IO1,
//  media-contract.md §8.2): block counts that always add up, a high-water
//  mark, and counters that make the one explicit capture copy observable.
//

/// Exact accounting for a `MediaBlockPool`.
///
/// Block counts are exact and always satisfy `leasedCount + freeCount + retiredCount == blockCount`. The copy
/// counters are monotonic and saturate at `UInt64.max` instead of wrapping. Only the pool changes these values:
/// the properties are `private(set)` and the `record...` mutators are driven by pool operations.
struct MediaBlockPoolStatistics: Equatable, Sendable {
    /// Every block the pool owns; fixed when the pool is created.
    let blockCount: Int
    /// Blocks currently leased.
    private(set) var leasedCount = 0
    /// Blocks permanently withdrawn because their slot generation reached the pool's maximum.
    private(set) var retiredCount = 0
    /// The most blocks ever leased at once; it never decreases.
    private(set) var highWaterLeased = 0
    /// Frames stored by completed copies.
    private(set) var framesCopied: UInt64 = 0
    /// Copies that completed.
    private(set) var copiesCompleted: UInt64 = 0
    /// Copies refused for their shape (channels, frames or source length) on an otherwise valid lease.
    private(set) var copiesRefused: UInt64 = 0

    /// Blocks neither leased nor retired: the blocks the next leases can take.
    var freeCount: Int { blockCount - leasedCount - retiredCount }

    /// The counters of a pool of `blockCount` blocks that has done nothing. The copy counters may be preset; the
    /// pool itself always starts them at zero, and tests use the presets to reach saturation.
    init(blockCount: Int, framesCopied: UInt64 = 0, copiesCompleted: UInt64 = 0, copiesRefused: UInt64 = 0) {
        self.blockCount = blockCount
        self.framesCopied = framesCopied
        self.copiesCompleted = copiesCompleted
        self.copiesRefused = copiesRefused
    }

    /// A block was leased.
    mutating func recordLease() {
        leasedCount += 1
        highWaterLeased = max(highWaterLeased, leasedCount)
    }

    /// A leased block was released; `retired` is true when it was withdrawn instead of returned to the free list.
    mutating func recordRelease(retired: Bool) {
        leasedCount -= 1
        if retired {
            retiredCount += 1
        }
    }

    /// A copy of `frames` frames completed.
    mutating func recordCopy(frames: Int) {
        framesCopied = Self.saturatingSum(framesCopied, UInt64(clamping: frames))
        copiesCompleted = Self.saturatingSum(copiesCompleted, 1)
    }

    /// A copy was refused for its shape on an otherwise valid lease.
    mutating func recordRefusedCopy() {
        copiesRefused = Self.saturatingSum(copiesRefused, 1)
    }

    private static func saturatingSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
