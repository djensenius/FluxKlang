import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Slot generations of the media block pool: exact increments, exact retirement at the maximum, and no wrap-around.
/// The default limit is `UInt32.max`, which cannot be reached by leasing; these tests use the factory's
/// `maximumGeneration` parameter to reach the very same retirement path with a handful of leases.
extension MediaBlockPoolTests {
    @Test
    func releaseAdvancesTheSlotGenerationByExactlyOne() throws {
        let pool = try Self.makePool(blockCount: 2)
        var lease = try pool.lease()
        #expect(lease.slot == 0 && lease.generation == 0)
        for expected in 1...5 {
            #expect(try pool.release(lease) == .returned)
            lease = try pool.lease()
            // The block just released is the next one out, with a generation exactly one higher.
            #expect(lease.slot == 0)
            #expect(lease.generation == UInt32(expected))
        }
        // The other block's generation is its own.
        let other = try pool.lease()
        #expect(other.slot == 1 && other.generation == 0)
    }

    @Test
    func releaseReturnsTheBlockBelowTheMaximumGenerationAndRetiresItAtTheMaximum() throws {
        let pool = try Self.makePool(blockCount: 2, maximumGeneration: 2)
        let first = try pool.lease()
        #expect(first.slot == 0 && first.generation == 0)
        #expect(try pool.release(first) == .returned)
        let second = try pool.lease()
        #expect(second.slot == 0 && second.generation == 1)
        #expect(try pool.release(second) == .returned)
        #expect(pool.statistics.retiredCount == 0)
        // The third lease of the block is at the maximum generation: releasing it withdraws the block.
        let third = try pool.lease()
        #expect(third.slot == 0 && third.generation == 2)
        #expect(try pool.release(third) == .retired)
        #expect(pool.statistics.retiredCount == 1)
        #expect(pool.statistics.leasedCount == 0)
        #expect(pool.statistics.freeCount == 1)
        #expect(pool.freeSlotsInLeaseOrder() == [1])
    }

    @Test
    func aSlotOffersExactlyMaximumGenerationPlusOneLeases() throws {
        for limit in [0, 1, 5] {
            let pool = try Self.makePool(blockCount: 2, maximumGeneration: limit)
            var expected: [String] = []
            for slot in 0..<2 {
                for generation in 0...limit {
                    expected.append("\(slot):\(generation)")
                }
            }
            // Lease and release one block at a time: it is offered again until it retires, then the next block is.
            var offers: [String] = []
            for _ in 0..<(2 * (limit + 1)) {
                let lease = try pool.lease()
                offers.append("\(lease.slot):\(lease.generation)")
                try pool.release(lease)
            }
            #expect(offers == expected, "limit \(limit)")
            #expect(pool.statistics.retiredCount == 2)
            #expect(pool.statistics.leasedCount == 0 && pool.statistics.freeCount == 0)
            #expect(Self.refusal { try pool.lease() } == .poolExhausted(leased: 0, retired: 2))
        }
    }

    @Test
    func retiredBlockIsNeverLeasedAgainAndItsLeaseIsRefused() throws {
        let pool = try Self.makePool(blockCount: 3, maximumGeneration: 1)
        let first = try pool.lease()
        try pool.release(first)
        let second = try pool.lease()
        #expect(second.slot == 0 && second.generation == 1)
        #expect(try pool.release(second) == .retired)
        // Only the blocks that were never retired remain, in their original order.
        #expect(pool.freeSlotsInLeaseOrder() == [1, 2])
        // Both leases of the retired block are dead, and every operation refuses them.
        let dead = MediaBlockPoolRefusal.leaseAlreadyReleased(slot: 0)
        for lease in [first, second] {
            #expect(Self.refusal { try pool.release(lease) } == dead)
            #expect(Self.refusal { try pool.usedFrames(of: lease) } == dead)
            #expect(Self.refusal { try pool.copyOut(of: lease) } == dead)
            #expect(Self.refusal { try Self.fill(pool, [1, 2], frames: 1, lease: lease) } == dead)
        }
        // The retired block is never handed out again.
        let rest = try Self.leaseAll(pool, count: 2)
        #expect(rest.map(\.slot) == [1, 2])
        #expect(Self.refusal { try pool.lease() } == .poolExhausted(leased: 2, retired: 1))
        try pool.release(rest[1])
        try pool.release(rest[0])
        #expect(pool.freeSlotsInLeaseOrder() == [1, 2])
        #expect(pool.statistics.retiredCount == 1)
    }

    @Test
    func exhaustionCountsRetiredBlocksAndThePoolNeverGrows() throws {
        let pool = try Self.makePool(blockCount: 3, maximumGeneration: 0)
        let leases = try Self.leaseAll(pool, count: 3)
        #expect(leases.map(\.generation) == [0, 0, 0])
        for (index, lease) in leases.enumerated() {
            let exhausted = MediaBlockPoolRefusal.poolExhausted(leased: 3 - index, retired: index)
            #expect(Self.refusal { try pool.lease() } == exhausted)
            #expect(try pool.release(lease) == .retired)
        }
        #expect(Self.refusal { try pool.lease() } == .poolExhausted(leased: 0, retired: 3))
        #expect(pool.statistics.blockCount == 3)
        #expect(pool.statistics.retiredCount == 3 && pool.statistics.freeCount == 0)
        #expect(pool.freeSlotsInLeaseOrder().isEmpty)
    }

    @Test
    func maximumGenerationZeroOffersEachBlockExactlyOneLease() throws {
        let pool = try Self.makePool(blockCount: 4, maximumGeneration: 0)
        var slots: [Int] = []
        for _ in 0..<4 {
            let lease = try pool.lease()
            slots.append(lease.slot)
            #expect(lease.generation == 0)
            #expect(try pool.release(lease) == .retired)
        }
        #expect(slots == [0, 1, 2, 3])
        #expect(pool.statistics.retiredCount == 4 && pool.statistics.leasedCount == 0)
        #expect(pool.statistics.highWaterLeased == 1)
        #expect(Self.refusal { try pool.lease() } == .poolExhausted(leased: 0, retired: 4))
    }
}
