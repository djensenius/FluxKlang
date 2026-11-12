import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Exact accounting of the media block pool: block counts that always add up, the high-water mark, and counters
/// that saturate instead of wrapping.
extension MediaBlockPoolTests {
    @Test
    func statisticsCountersFollowLeaseReleaseAndRetirement() throws {
        // Four blocks, each retired at its second release (generation limit 1).
        let pool = try Self.makePool(blockCount: 4, maximumGeneration: 1)
        #expect(Self.blockCounts(pool) == [0, 4, 0, 0, 4])
        let leaseA = try pool.lease()
        #expect(Self.blockCounts(pool) == [1, 3, 0, 1, 3])
        let leaseB = try pool.lease()
        #expect(Self.blockCounts(pool) == [2, 2, 0, 2, 2])
        #expect(try pool.release(leaseA) == .returned)
        #expect(Self.blockCounts(pool) == [1, 3, 0, 2, 3])
        // The released block comes straight back, one generation on.
        let leaseC = try pool.lease()
        #expect(leaseC.slot == leaseA.slot && leaseC.generation == 1)
        #expect(Self.blockCounts(pool) == [2, 2, 0, 2, 2])
        // Its generation is at the limit now, so releasing it retires it: leased down, retired up, free unchanged.
        #expect(try pool.release(leaseC) == .retired)
        #expect(Self.blockCounts(pool) == [1, 2, 1, 2, 2])
        #expect(try pool.release(leaseB) == .returned)
        #expect(Self.blockCounts(pool) == [0, 3, 1, 2, 3])
        // One block was retired, so only three of the four can ever be leased at once: the pool is exhausted then.
        let rest = try Self.leaseAll(pool, count: 3)
        #expect(rest.map(\.slot) == [1, 2, 3])
        #expect(Self.blockCounts(pool) == [3, 0, 1, 3, 0])
        #expect(Self.refusal { try pool.lease() } == .poolExhausted(leased: 3, retired: 1))
        #expect(Self.blockCounts(pool) == [3, 0, 1, 3, 0])
        #expect(pool.statistics.leasesRefusedExhausted == 1 && pool.statistics.leasesRefusedBusy == 0)
        #expect(pool.statistics.blockCount == 4)
    }

    @Test
    func leaseRefusalCountersAreZeroInAFreshPoolAndSaturateAtUInt64Max() {
        let fresh = MediaBlockPoolStatistics(blockCount: 7)
        #expect(fresh.leasesRefusedExhausted == 0 && fresh.leasesRefusedBusy == 0)
        let top = UInt64.max
        var stats = MediaBlockPoolStatistics(
            blockCount: 2, leasesRefusedExhausted: top - 1, leasesRefusedBusy: top - 1
        )
        // Exactly up to the maximum is exact, and each counter moves alone.
        stats.recordLeaseRefusedExhausted()
        #expect(stats.leasesRefusedExhausted == top && stats.leasesRefusedBusy == top - 1)
        stats.recordLeaseRefusedBusy()
        #expect(stats.leasesRefusedExhausted == top && stats.leasesRefusedBusy == top)
        // One past it saturates instead of wrapping to zero.
        stats.recordLeaseRefusedExhausted()
        stats.recordLeaseRefusedBusy()
        #expect(stats.leasesRefusedExhausted == top && stats.leasesRefusedBusy == top)
        #expect(stats.leasedCount == 0 && stats.retiredCount == 0 && stats.copiesRefused == 0)
    }

    @Test
    func statisticsDifferWhenOnlyOneLeaseRefusalCounterDiffers() {
        let base = MediaBlockPoolStatistics(blockCount: 3)
        #expect(base == MediaBlockPoolStatistics(blockCount: 3, leasesRefusedExhausted: 0, leasesRefusedBusy: 0))
        #expect(base != MediaBlockPoolStatistics(blockCount: 3, leasesRefusedExhausted: 1))
        #expect(base != MediaBlockPoolStatistics(blockCount: 3, leasesRefusedBusy: 1))
        #expect(
            MediaBlockPoolStatistics(blockCount: 3, leasesRefusedExhausted: 1)
                != MediaBlockPoolStatistics(blockCount: 3, leasesRefusedBusy: 1)
        )
    }

    @Test
    func copyCountersSaturateAtUInt64MaxInsteadOfWrapping() {
        let top = UInt64.max
        var stats = MediaBlockPoolStatistics(
            blockCount: 2,
            framesCopied: top - 5,
            copiesCompleted: top - 1,
            copiesRefused: top - 1
        )
        // Exactly up to the maximum is exact.
        stats.recordCopy(frames: 3)
        stats.recordRefusedCopy()
        #expect(stats.framesCopied == top - 2)
        #expect(stats.copiesCompleted == top)
        #expect(stats.copiesRefused == top)
        // One past it saturates: the counters stay at the maximum instead of wrapping to zero.
        stats.recordCopy(frames: 3)
        stats.recordRefusedCopy()
        #expect(stats.framesCopied == top)
        #expect(stats.copiesCompleted == top)
        #expect(stats.copiesRefused == top)
        // A huge frame count saturates the same way, and nothing else changes.
        stats.recordCopy(frames: Int.max)
        #expect(stats.framesCopied == top && stats.copiesCompleted == top)
        #expect(stats.blockCount == 2 && stats.leasedCount == 0 && stats.retiredCount == 0)
    }

    @Test
    func freshStatisticsAreEmptyAndFreeCountIsDerived() {
        let stats = MediaBlockPoolStatistics(blockCount: 7)
        #expect(stats.blockCount == 7 && stats.freeCount == 7)
        #expect(stats.leasedCount == 0 && stats.retiredCount == 0 && stats.highWaterLeased == 0)
        #expect(stats.framesCopied == 0 && stats.copiesCompleted == 0 && stats.copiesRefused == 0)
        var changed = stats
        changed.recordLease()
        changed.recordLease()
        #expect(changed.freeCount == 5 && changed.leasedCount == 2 && changed.highWaterLeased == 2)
        // A retired block leaves the free count too: 7 - 1 leased - 1 retired.
        changed.recordRelease(retired: true)
        #expect(changed.freeCount == 5 && changed.leasedCount == 1 && changed.retiredCount == 1)
        changed.recordRelease(retired: false)
        #expect(changed.freeCount == 6 && changed.leasedCount == 0 && changed.highWaterLeased == 2)
        #expect(stats != changed)
        #expect(stats == MediaBlockPoolStatistics(blockCount: 7))
    }

    /// `[leased, free, retired, high-water, length of the free list]`, so every count is compared at once.
    private static func blockCounts(_ pool: MediaBlockPool) -> [Int] {
        let stats = pool.statistics
        return [
            stats.leasedCount,
            stats.freeCount,
            stats.retiredCount,
            stats.highWaterLeased,
            pool.freeSlotsInLeaseOrder().count
        ]
    }
}
