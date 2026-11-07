import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Leasing, release, exhaustion, lease ownership and the scoped-read guard of the media block pool.
extension MediaBlockPoolTests {
    @Test
    func leasingEveryBlockThenOneMoreRefusesWithExactCounts() throws {
        let pool = try Self.makePool(blockCount: 4)
        var leases: [MediaBlockLease] = []
        for expected in 1...4 {
            try leases.append(pool.lease())
            #expect(pool.statistics.leasedCount == expected)
            #expect(pool.statistics.freeCount == 4 - expected)
        }
        #expect(pool.statistics.highWaterLeased == 4)
        let full = Self.snapshot(pool)
        // N+1: the pool never grows, blocks or allocates; it refuses, every time, and changes nothing.
        let exhausted = MediaBlockPoolRefusal.poolExhausted(leased: 4, retired: 0)
        #expect(Self.refusal { try pool.lease() } == exhausted)
        #expect(Self.refusal { try pool.lease() } == exhausted)
        #expect(Self.snapshot(pool) == full)
        // Releasing one block makes exactly that block leasable again.
        try pool.release(leases[2])
        let again = try pool.lease()
        #expect(again.slot == 2)
        #expect(pool.statistics.leasedCount == 4)
        #expect(Self.refusal { try pool.lease() } == exhausted)
    }

    @Test
    func leaseOrderIsLowestSlotFirstThenMostRecentlyReleasedFirst() throws {
        let pool = try Self.makePool(blockCount: 4)
        let leases = try Self.leaseAll(pool, count: 4)
        #expect(leases.map(\.slot) == [0, 1, 2, 3])
        #expect(pool.freeSlotsInLeaseOrder().isEmpty)
        try pool.release(leases[1])
        try pool.release(leases[3])
        try pool.release(leases[0])
        #expect(pool.freeSlotsInLeaseOrder() == [0, 3, 1])
        let next = try Self.leaseAll(pool, count: 3)
        #expect(next.map(\.slot) == [0, 3, 1])
        #expect(pool.freeSlotsInLeaseOrder().isEmpty)
    }

    @Test
    func highWaterMarkTracksTheLeasePeakAndNeverFalls() throws {
        let pool = try Self.makePool(blockCount: 4)
        #expect(pool.statistics.highWaterLeased == 0)
        let leases = try Self.leaseAll(pool, count: 3)
        #expect(pool.statistics.highWaterLeased == 3)
        for lease in leases {
            try pool.release(lease)
        }
        #expect(pool.statistics.leasedCount == 0)
        #expect(pool.statistics.retiredCount == 0)
        #expect(pool.statistics.highWaterLeased == 3)
        let one = try pool.lease()
        #expect(pool.statistics.highWaterLeased == 3)
        try pool.release(one)
        _ = try Self.leaseAll(pool, count: 4)
        #expect(pool.statistics.highWaterLeased == 4)
        #expect(pool.statistics.leasedCount == 4)
        #expect(pool.statistics.freeCount == 0)
    }

    @Test
    func doubleReleaseIsRefusedAndLeavesThePoolUnchanged() throws {
        let pool = try Self.makePool(blockCount: 4)
        let keep = try pool.lease()
        let doomed = try pool.lease()
        #expect(doomed.slot == 1)
        #expect(try pool.release(doomed) == .returned)
        let before = Self.snapshot(pool)
        #expect(Self.refusal { try pool.release(doomed) } == .leaseAlreadyReleased(slot: 1))
        #expect(Self.refusal { try pool.release(doomed) } == .leaseAlreadyReleased(slot: 1))
        #expect(Self.snapshot(pool) == before)
        // The live lease and the freed block are untouched: slot 1 is still the next block.
        #expect(try pool.usedFrames(of: keep) == 0)
        #expect(try pool.lease().slot == 1)
    }

    @Test
    func staleLeaseIsRefusedOnceItsSlotIsLeasedAgain() throws {
        let pool = try Self.makePool(blockCount: 2)
        let old = try pool.lease()
        try pool.release(old)
        let fresh = try pool.lease()
        #expect(fresh.slot == 0 && fresh.generation == 1)
        #expect(old != fresh)
        let before = Self.snapshot(pool)
        let stale = MediaBlockPoolRefusal.staleLease(slot: 0, leaseGeneration: 0, currentGeneration: 1)
        #expect(Self.refusal { try pool.release(old) } == stale)
        #expect(Self.refusal { try pool.usedFrames(of: old) } == stale)
        #expect(Self.refusal { try pool.copyOut(of: old) } == stale)
        #expect(Self.refusal { try pool.withSamples(of: old) { $0.count } } == stale)
        #expect(Self.refusal { try Self.fill(pool, [1, 2], frames: 1, lease: old) } == stale)
        #expect(Self.snapshot(pool) == before)
        // The newer lease is unaffected and still works.
        try Self.fill(pool, [1, 2], frames: 1, lease: fresh)
        #expect(try pool.copyOut(of: fresh) == [1, 2])
        #expect(try pool.release(fresh) == .returned)
    }

    @Test
    func leaseFromAnotherLivePoolIsForeignForEveryOperation() throws {
        let home = try Self.makePool(blockCount: 3)
        let away = try Self.makePool(blockCount: 3)
        let homeLease = try home.lease()
        let foreign = try away.lease()
        // Same slot and generation as the home lease: only the pool identity can tell them apart.
        #expect(foreign.slot == homeLease.slot && foreign.generation == homeLease.generation)
        let homeBefore = Self.snapshot(home)
        let awayBefore = Self.snapshot(away)
        #expect(Self.refusal { try home.release(foreign) } == .foreignLease)
        #expect(Self.refusal { try home.usedFrames(of: foreign) } == .foreignLease)
        #expect(Self.refusal { try home.copyOut(of: foreign) } == .foreignLease)
        #expect(Self.refusal { try home.withSamples(of: foreign) { $0.count } } == .foreignLease)
        #expect(Self.refusal { try Self.fill(home, [1, 2], frames: 1, lease: foreign) } == .foreignLease)
        #expect(Self.snapshot(home) == homeBefore)
        #expect(Self.snapshot(away) == awayBefore)
        // Each lease still works with its own pool, and only with its own pool.
        try Self.fill(home, [3, 4], frames: 1, lease: homeLease)
        #expect(try home.copyOut(of: homeLease) == [3, 4])
        #expect(try away.usedFrames(of: foreign) == 0)
    }

    @Test
    func leaseFromADeallocatedPoolIsForeignToAFreshPoolOfTheSameShape() throws {
        let ghost = try Self.leaseFromDeadPool()
        // A fresh pool of the same shape may reuse the dead pool's memory; the old lease must still be foreign.
        let fresh = try Self.makePool(blockCount: 3)
        let live = try fresh.lease()
        #expect(ghost.slot == live.slot && ghost.generation == live.generation)
        let before = Self.snapshot(fresh)
        #expect(Self.refusal { try fresh.release(ghost) } == .foreignLease)
        #expect(Self.refusal { try fresh.usedFrames(of: ghost) } == .foreignLease)
        #expect(Self.snapshot(fresh) == before)
        #expect(try fresh.release(live) == .returned)
    }

    @Test
    func scopedReadRefusesLeaseReleaseAndCopyUntilItReturns() throws {
        let pool = try Self.makePool(blockCount: 3)
        let reading = try pool.lease()
        let other = try pool.lease()
        try Self.fill(pool, [1, 2, 3, 4], frames: 2, lease: reading)
        let before = Self.snapshot(pool)
        var refusals: [MediaBlockPoolRefusal?] = []
        let viewed = try pool.withSamples(of: reading) { (view: UnsafeBufferPointer<Float>) -> [Float] in
            refusals.append(Self.refusal { try pool.lease() })
            refusals.append(Self.refusal { try pool.release(other) })
            refusals.append(Self.refusal { try Self.fill(pool, [5, 6], frames: 1, lease: other) })
            refusals.append(Self.refusal { try pool.release(reading) })
            return Array(view)
        }
        #expect(viewed == [1, 2, 3, 4])
        #expect(refusals.count == 4)
        #expect(refusals.allSatisfy { $0 == .accessInProgress })
        #expect(Self.snapshot(pool) == before)
        // Reads may nest, and the guard stays up until the OUTERMOST read has returned.
        var afterNested: MediaBlockPoolRefusal?
        try pool.withSamples(of: reading) { (_: UnsafeBufferPointer<Float>) in
            _ = try? pool.withSamples(of: other) { $0.count }
            afterNested = Self.refusal { try pool.lease() }
        }
        #expect(afterNested == .accessInProgress)
        // Afterwards the pool works again, and the refused calls changed nothing.
        let next = try pool.lease()
        #expect(next.slot == 2)
        try pool.release(next)
        try Self.fill(pool, [5, 6], frames: 1, lease: other)
        #expect(try pool.copyOut(of: other) == [5, 6])
        #expect(try pool.release(other) == .returned)
        #expect(try pool.release(reading) == .returned)
    }

    @Test
    func leasesCompareAndHashByPoolSlotAndGeneration() throws {
        let poolA = try Self.makePool(blockCount: 3)
        let poolB = try Self.makePool(blockCount: 3)
        let leaseA0 = try poolA.lease()
        let leaseB0 = try poolB.lease()
        let copyA0 = leaseA0
        #expect(leaseA0 == copyA0 && leaseA0.hashValue == copyA0.hashValue)
        // Same slot and generation, different pool.
        #expect(leaseA0.slot == leaseB0.slot && leaseA0.generation == leaseB0.generation)
        #expect(leaseA0 != leaseB0)
        // Same pool, different slot.
        let leaseA1 = try poolA.lease()
        #expect(leaseA0 != leaseA1)
        // Same pool and slot, later generation.
        try poolA.release(leaseA1)
        let leaseA1Again = try poolA.lease()
        #expect(leaseA1Again.slot == leaseA1.slot && leaseA1Again.generation == leaseA1.generation + 1)
        #expect(leaseA1 != leaseA1Again)
        #expect(Set([leaseA0, leaseB0, leaseA1, leaseA1Again]).count == 4)
        #expect(Set([leaseA0, copyA0]).count == 1)
    }

    /// A lease whose pool is gone by the time the caller gets it back.
    private static func leaseFromDeadPool() throws -> MediaBlockLease {
        let dead = try makePool(blockCount: 3)
        return try dead.lease()
    }
}
