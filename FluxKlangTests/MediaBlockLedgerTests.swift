import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The resident block ledger (#109 BLG1). Leases come only from a real `MediaBlockPool`; the pool is a lease source
/// and nothing here claims more about it than the lease order of a fresh pool (slots 0, 1, 2, ...).
@Suite("Media block ledger", .productionAccessAudit)
struct MediaBlockLedgerTests {
    private static func makePool(blocks: Int) throws -> MediaBlockPool {
        let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: blocks, headFrames: 64)
        return try MediaBlockPool.make(plan: plan, channelCount: 1)
    }

    private static func leaseAll(_ pool: MediaBlockPool, count: Int) throws -> [MediaBlockLease] {
        var leases: [MediaBlockLease] = []
        for _ in 0..<count {
            try leases.append(pool.lease())
        }
        return leases
    }

    private static func pick(_ leases: [MediaBlockLease], _ index: Int) throws -> MediaBlockLease {
        try #require(leases.indices.contains(index))
        return leases[index]
    }

    private static func makeLedger(
        blocks: Int = 4, playback: Int = 2, recorder: Int = 1, tuner: Int = 1
    ) throws -> MediaBlockLedger {
        try MediaBlockLedger.make(
            blockCount: blocks, playbackLimit: playback, recorderLimit: recorder, tunerLimit: tuner
        )
    }

    private static func claimRefusal(
        _ ledger: inout MediaBlockLedger, _ lease: MediaBlockLease, _ role: MediaTapRole
    ) -> MediaBlockLedgerRefusal? {
        do {
            try ledger.claim(lease, by: role)
            return nil
        } catch {
            return error
        }
    }

    private static func releaseRefusal(
        _ ledger: inout MediaBlockLedger, _ lease: MediaBlockLease, _ role: MediaTapRole
    ) -> MediaBlockLedgerRefusal? {
        do {
            try ledger.release(lease, by: role)
            return nil
        } catch {
            return error
        }
    }

    private static func makeRefusal(
        blocks: Int, _ playback: Int, _ recorder: Int, _ tuner: Int
    ) -> MediaBlockLedgerRefusal? {
        do {
            _ = try MediaBlockLedger.make(
                blockCount: blocks, playbackLimit: playback, recorderLimit: recorder, tunerLimit: tuner
            )
            return nil
        } catch {
            return error
        }
    }

    private static func slots(_ leases: [MediaBlockLease]) -> [Int] {
        leases.map(\.slot)
    }

    // MARK: - Holding

    @Test
    func mediaBlockLedgerClaimedLeaseIsHeldByItsRole() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 4), count: 1)
        let leaseZero = try Self.pick(leases, 0)
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseZero, by: .recorder)
        let holder = ledger.holder(of: leaseZero)
        #expect(holder == .recorder)
        #expect(ledger.heldCount(by: .recorder) == 1)
        #expect(ledger.heldCount(by: .playback) == 0)
        #expect(ledger.heldCount(by: .tuner) == 0)
        #expect(ledger.totalHeld == 1)
        #expect(ledger.blockCount == 4)
    }

    @Test
    func mediaBlockLedgerTwoRolesHoldTwoBlocksListedInSlotOrder() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 4), count: 2)
        let leaseZero = try Self.pick(leases, 0)
        let leaseOne = try Self.pick(leases, 1)
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseOne, by: .recorder)
        try ledger.claim(leaseZero, by: .playback)
        let all = ledger.heldLeases()
        let recorderOnly = ledger.heldLeases(by: .recorder)
        let tunerOnly = ledger.heldLeases(by: .tuner)
        #expect(all == [leaseZero, leaseOne])
        #expect(recorderOnly == [leaseOne])
        #expect(tunerOnly.isEmpty)
    }

    @Test
    func mediaBlockLedgerRefusesASecondRoleClaimingAHeldLease() throws {
        let leaseZero = try Self.pick(Self.leaseAll(Self.makePool(blocks: 4), count: 1), 0)
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseZero, by: .recorder)
        let before = ledger
        let refusal = Self.claimRefusal(&ledger, leaseZero, .tuner)
        #expect(refusal == .alreadyHeld(slot: 0, holder: .recorder))
        #expect(ledger == before)
        let holder = ledger.holder(of: leaseZero)
        #expect(holder == .recorder)
    }

    @Test
    func mediaBlockLedgerRefusesTheSameRoleClaimingTheSameLeaseTwice() throws {
        let leaseZero = try Self.pick(Self.leaseAll(Self.makePool(blocks: 4), count: 1), 0)
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseZero, by: .recorder)
        let before = ledger
        let refusal = Self.claimRefusal(&ledger, leaseZero, .recorder)
        #expect(refusal == .alreadyHeld(slot: 0, holder: .recorder))
        #expect(ledger == before)
        #expect(ledger.heldCount(by: .recorder) == 1)
    }

    @Test
    func mediaBlockLedgerReleaseByHolderFreesTheSlotForAnotherRole() throws {
        let leaseZero = try Self.pick(Self.leaseAll(Self.makePool(blocks: 4), count: 1), 0)
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseZero, by: .recorder)
        try ledger.release(leaseZero, by: .recorder)
        let emptied = ledger.holder(of: leaseZero)
        #expect(emptied == nil)
        #expect(ledger.heldCount(by: .recorder) == 0)
        #expect(ledger.totalHeld == 0)
        try ledger.claim(leaseZero, by: .tuner)
        let holder = ledger.holder(of: leaseZero)
        #expect(holder == .tuner)
        #expect(ledger.heldCount(by: .tuner) == 1)
        #expect(ledger.heldCount(by: .recorder) == 0)
    }

    @Test
    func mediaBlockLedgerRefusesReleaseByTheWrongRoleAndOfAnEmptySlot() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 4), count: 3)
        let leaseZero = try Self.pick(leases, 0)
        let leaseTwo = try Self.pick(leases, 2)
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseZero, by: .recorder)
        let before = ledger
        let wrongRole = Self.releaseRefusal(&ledger, leaseZero, .tuner)
        #expect(wrongRole == .heldByOtherRole(slot: 0, heldBy: .recorder, offered: .tuner))
        #expect(ledger == before)
        let empty = Self.releaseRefusal(&ledger, leaseTwo, .recorder)
        #expect(empty == .notHeld(slot: 2))
        #expect(ledger == before)
        let holder = ledger.holder(of: leaseZero)
        #expect(holder == .recorder)
    }

    @Test
    func mediaBlockLedgerRefusesAStaleGenerationUntilTheOldEntryIsReleased() throws {
        let pool = try Self.makePool(blocks: 4)
        let leaseZero = try pool.lease()
        var ledger = try Self.makeLedger()
        try ledger.claim(leaseZero, by: .playback)
        _ = try pool.release(leaseZero)
        let renewed = try pool.lease()
        #expect(renewed.slot == 0)
        #expect(renewed.generation == 1)
        let before = ledger
        let claim = Self.claimRefusal(&ledger, renewed, .playback)
        #expect(claim == .slotHeldByOtherLease(slot: 0, heldGeneration: 0, offeredGeneration: 1))
        let release = Self.releaseRefusal(&ledger, renewed, .playback)
        #expect(release == .leaseMismatch(slot: 0, heldGeneration: 0, offeredGeneration: 1))
        #expect(ledger == before)
        let stale = ledger.holder(of: renewed)
        #expect(stale == nil)
        try ledger.release(leaseZero, by: .playback)
        try ledger.claim(renewed, by: .playback)
        let holder = ledger.holder(of: renewed)
        #expect(holder == .playback)
    }

    /// A lease of a second pool is told apart by its identity only where the slot is held; on a free slot it is
    /// accepted, because the ledger cannot detect a foreign pool. This test claims nothing more.
    @Test
    func mediaBlockLedgerComparesPoolIdentityOnHeldSlotsButNotOnFreeSlots() throws {
        let own = try Self.leaseAll(Self.makePool(blocks: 4), count: 1)
        let foreign = try Self.leaseAll(Self.makePool(blocks: 4), count: 2)
        let ownZero = try Self.pick(own, 0)
        let foreignZero = try Self.pick(foreign, 0)
        let foreignOne = try Self.pick(foreign, 1)
        #expect(ownZero.generation == foreignZero.generation)
        var ledger = try Self.makeLedger()
        try ledger.claim(ownZero, by: .playback)
        let held = Self.claimRefusal(&ledger, foreignZero, .recorder)
        #expect(held == .slotHeldByOtherLease(slot: 0, heldGeneration: 0, offeredGeneration: 0))
        try ledger.claim(foreignOne, by: .recorder)
        let holder = ledger.holder(of: foreignOne)
        #expect(holder == .recorder)
    }

    // MARK: - Budgets

    @Test
    func mediaBlockLedgerRoleBudgetsCapClaimsPerRole() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 6), count: 6)
        var ledger = try Self.makeLedger(blocks: 6, playback: 3, recorder: 1, tuner: 2)
        #expect(ledger.limit(for: .playback) == 3)
        #expect(ledger.limit(for: .recorder) == 1)
        #expect(ledger.limit(for: .tuner) == 2)
        try ledger.claim(Self.pick(leases, 0), by: .recorder)
        let before = ledger
        let second = Self.claimRefusal(&ledger, try Self.pick(leases, 1), .recorder)
        #expect(second == .roleBudgetExhausted(.recorder, limit: 1))
        #expect(ledger == before)
        try ledger.claim(Self.pick(leases, 1), by: .playback)
        try ledger.claim(Self.pick(leases, 2), by: .playback)
        try ledger.claim(Self.pick(leases, 3), by: .playback)
        let fourth = Self.claimRefusal(&ledger, try Self.pick(leases, 4), .playback)
        #expect(fourth == .roleBudgetExhausted(.playback, limit: 3))
        // The ledger ceiling only: a full playback budget leaves the tuner's claims valid here.
        try ledger.claim(Self.pick(leases, 4), by: .tuner)
        #expect(ledger.heldCount(by: .playback) == 3)
        #expect(ledger.totalHeld == 5)
    }

    @Test
    func mediaBlockLedgerZeroLimitRefusesClaimsOfThatRole() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 4), count: 2)
        var ledger = try Self.makeLedger(blocks: 4, playback: 2, recorder: 2, tuner: 0)
        let tuner = Self.claimRefusal(&ledger, try Self.pick(leases, 0), .tuner)
        #expect(tuner == .roleBudgetExhausted(.tuner, limit: 0))
        #expect(ledger.totalHeld == 0)
        try ledger.claim(Self.pick(leases, 0), by: .playback)
        try ledger.claim(Self.pick(leases, 1), by: .recorder)
        #expect(ledger.totalHeld == 2)
    }

    // MARK: - Release all

    @Test
    func mediaBlockLedgerReleaseAllReturnsOneRolesLeasesInSlotOrder() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 8), count: 6)
        var ledger = try Self.makeLedger(blocks: 8, playback: 3, recorder: 3, tuner: 2)
        try ledger.claim(Self.pick(leases, 5), by: .recorder)
        try ledger.claim(Self.pick(leases, 1), by: .recorder)
        try ledger.claim(Self.pick(leases, 0), by: .playback)
        try ledger.claim(Self.pick(leases, 3), by: .recorder)
        try ledger.claim(Self.pick(leases, 2), by: .tuner)
        let beforeAll = ledger.heldLeases()
        #expect(Self.slots(beforeAll) == [0, 1, 2, 3, 5])
        let released = ledger.releaseAll(heldBy: .recorder)
        #expect(Self.slots(released) == [1, 3, 5])
        #expect(ledger.heldCount(by: .recorder) == 0)
        #expect(Self.slots(ledger.heldLeases()) == [0, 2])
        let playback = ledger.heldLeases(by: .playback)
        #expect(Self.slots(playback) == [0])
        #expect(ledger.heldCount(by: .playback) == 1)
        #expect(ledger.heldCount(by: .tuner) == 1)
        let again = ledger.releaseAll(heldBy: .recorder)
        #expect(again.isEmpty)
        #expect(ledger.totalHeld == 2)
    }

    // MARK: - Refusal order

    @Test
    func mediaBlockLedgerRefusalOrdersHoldWhenTwoDefectsAreCombined() throws {
        let pool = try Self.makePool(blocks: 10)
        let leases = try Self.leaseAll(pool, count: 10)
        var ledger = try Self.makeLedger(blocks: 4, playback: 1, recorder: 1, tuner: 2)
        try ledger.claim(Self.pick(leases, 0), by: .playback)
        try ledger.claim(Self.pick(leases, 1), by: .recorder)
        // Claim: the slot range comes before the budget (the playback budget is full).
        let beyond = Self.claimRefusal(&ledger, try Self.pick(leases, 9), .playback)
        #expect(beyond == .slotOutOfRange(slot: 9, blockCount: 4))
        let edge = Self.claimRefusal(&ledger, try Self.pick(leases, 4), .playback)
        #expect(edge == .slotOutOfRange(slot: 4, blockCount: 4))
        // Claim: occupancy comes before the budget (the recorder budget is full).
        let sameLease = Self.claimRefusal(&ledger, try Self.pick(leases, 0), .recorder)
        #expect(sameLease == .alreadyHeld(slot: 0, holder: .playback))
        _ = try pool.release(Self.pick(leases, 1))
        let renewed = try pool.lease()
        #expect(renewed.slot == 1)
        let otherLease = Self.claimRefusal(&ledger, renewed, .recorder)
        #expect(otherLease == .slotHeldByOtherLease(slot: 1, heldGeneration: 0, offeredGeneration: 1))
        // Release: the slot range, then the lease match before the role match.
        let outside = Self.releaseRefusal(&ledger, try Self.pick(leases, 9), .tuner)
        #expect(outside == .slotOutOfRange(slot: 9, blockCount: 4))
        let outsideHolder = ledger.holder(of: try Self.pick(leases, 9))
        #expect(outsideHolder == nil)
        let mismatch = Self.releaseRefusal(&ledger, renewed, .playback)
        #expect(mismatch == .leaseMismatch(slot: 1, heldGeneration: 0, offeredGeneration: 1))
        // Make: the block count, then the first bad limit in role order, then the sum.
        let blocks = Self.makeRefusal(blocks: 1, 9, 9, 9)
        #expect(blocks == .blockCountOutOfRange(1))
        let limit = Self.makeRefusal(blocks: 4, -1, 9, 0)
        #expect(limit == .roleLimitOutOfRange(.playback, limit: -1, blockCount: 4))
        let recorder = Self.makeRefusal(blocks: 4, 0, 9, -1)
        #expect(recorder == .roleLimitOutOfRange(.recorder, limit: 9, blockCount: 4))
        let sum = Self.makeRefusal(blocks: 4, 3, 3, 3)
        #expect(sum == .budgetExceedsPool(total: 9, blockCount: 4))
    }

    // MARK: - Limits

    @Test
    func mediaBlockLedgerBlockCountEdges() throws {
        let maximum = MediaBlockLedger.maximumBlocks
        #expect(maximum == 1_024)
        let largest = try Self.makeLedger(blocks: maximum, playback: 0, recorder: 0, tuner: 0)
        #expect(largest.blockCount == 1_024)
        let beyond = Self.makeRefusal(blocks: maximum + 1, 0, 0, 0)
        #expect(beyond == .blockCountOutOfRange(1_025))
        let smallest = try Self.makeLedger(blocks: 2, playback: 0, recorder: 0, tuner: 0)
        #expect(smallest.blockCount == 2)
        let one = Self.makeRefusal(blocks: 1, 0, 0, 0)
        #expect(one == .blockCountOutOfRange(1))
        let zero = Self.makeRefusal(blocks: 0, 0, 0, 0)
        #expect(zero == .blockCountOutOfRange(0))
        let negative = Self.makeRefusal(blocks: -1, 0, 0, 0)
        #expect(negative == .blockCountOutOfRange(-1))
    }

    @Test
    func mediaBlockLedgerRoleBudgetEdgesOnAMaximumLedger() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 1_024), count: 1_024)
        var ledger = try Self.makeLedger(blocks: 1_024, playback: 512, recorder: 256, tuner: 256)
        for index in 0..<512 {
            try ledger.claim(Self.pick(leases, index), by: .playback)
        }
        let beyond = Self.claimRefusal(&ledger, try Self.pick(leases, 512), .playback)
        #expect(beyond == .roleBudgetExhausted(.playback, limit: 512))
        for index in 512..<768 {
            try ledger.claim(Self.pick(leases, index), by: .recorder)
        }
        let extra = Self.claimRefusal(&ledger, try Self.pick(leases, 768), .recorder)
        #expect(extra == .roleBudgetExhausted(.recorder, limit: 256))
        #expect(ledger.totalHeld == 768)
        let released = ledger.releaseAll(heldBy: .playback)
        #expect(released.count == 512)
        let first = try #require(released.first)
        let last = try #require(released.last)
        #expect(first.slot == 0)
        #expect(last.slot == 511)
        #expect(ledger.totalHeld == 256)
    }

    @Test
    func mediaBlockLedgerLimitSumEdges() throws {
        let exact = try Self.makeLedger(blocks: 8, playback: 3, recorder: 3, tuner: 2)
        #expect(exact.totalHeld == 0)
        let under = try Self.makeLedger(blocks: 8, playback: 3, recorder: 3, tuner: 1)
        #expect(under.limit(for: .tuner) == 1)
        let over = Self.makeRefusal(blocks: 8, 3, 3, 3)
        #expect(over == .budgetExceedsPool(total: 9, blockCount: 8))
        let playbackAll = try Self.makeLedger(blocks: 8, playback: 8, recorder: 0, tuner: 0)
        #expect(playbackAll.limit(for: .playback) == 8)
        let tunerAll = try Self.makeLedger(blocks: 8, playback: 0, recorder: 0, tuner: 8)
        #expect(tunerAll.limit(for: .tuner) == 8)
        let single = Self.makeRefusal(blocks: 8, 0, 9, 0)
        #expect(single == .roleLimitOutOfRange(.recorder, limit: 9, blockCount: 8))
    }

    // MARK: - Unchanged and values

    @Test
    func mediaBlockLedgerRefusedCallsLeaveTheLedgerEqualToItsBefore() throws {
        let pool = try Self.makePool(blocks: 6)
        let leases = try Self.leaseAll(pool, count: 6)
        var ledger = try Self.makeLedger(blocks: 4, playback: 2, recorder: 1, tuner: 1)
        try ledger.claim(Self.pick(leases, 0), by: .playback)
        try ledger.claim(Self.pick(leases, 1), by: .recorder)
        let before = ledger
        let claims: [(MediaBlockLease, MediaTapRole)] = try [
            (Self.pick(leases, 0), .tuner), (Self.pick(leases, 1), .recorder), (Self.pick(leases, 5), .tuner),
            (Self.pick(leases, 2), .recorder)
        ]
        for (lease, role) in claims {
            let refusal = Self.claimRefusal(&ledger, lease, role)
            #expect(refusal != nil)
            #expect(ledger == before)
        }
        let releases: [(MediaBlockLease, MediaTapRole)] = try [
            (Self.pick(leases, 0), .recorder), (Self.pick(leases, 2), .playback), (Self.pick(leases, 5), .playback)
        ]
        for (lease, role) in releases {
            let refusal = Self.releaseRefusal(&ledger, lease, role)
            #expect(refusal != nil)
            #expect(ledger == before)
        }
    }

    @Test
    func mediaBlockLedgerCopiesAreIndependentValues() throws {
        let leases = try Self.leaseAll(Self.makePool(blocks: 4), count: 2)
        let leaseZero = try Self.pick(leases, 0)
        let leaseOne = try Self.pick(leases, 1)
        var original = try Self.makeLedger()
        try original.claim(leaseZero, by: .playback)
        var copy = original
        try copy.claim(leaseOne, by: .recorder)
        #expect(original.totalHeld == 1)
        #expect(copy.totalHeld == 2)
        try original.release(leaseZero, by: .playback)
        let kept = copy.holder(of: leaseZero)
        #expect(kept == .playback)
        let listed = copy.heldLeases()
        #expect(listed == [leaseZero, leaseOne])
        #expect(copy.heldLeases() == listed)
    }

    // MARK: - Round trip

    @Test
    func mediaBlockLedgerRoundTripLeavesPoolAndLedgerEmpty() throws {
        let pool = try Self.makePool(blocks: 4)
        let leases = try Self.leaseAll(pool, count: 4)
        var ledger = try Self.makeLedger(blocks: 4, playback: 2, recorder: 1, tuner: 1)
        try ledger.claim(Self.pick(leases, 0), by: .playback)
        try ledger.claim(Self.pick(leases, 1), by: .playback)
        try ledger.claim(Self.pick(leases, 2), by: .recorder)
        try ledger.claim(Self.pick(leases, 3), by: .tuner)
        #expect(pool.statistics.leasedCount == 4)
        let roles: [MediaTapRole] = [.playback, .recorder, .tuner]
        var returned: [Int] = []
        for role in roles {
            for lease in ledger.releaseAll(heldBy: role) {
                #expect(try pool.release(lease) == .returned)
                returned.append(lease.slot)
            }
        }
        #expect(returned == [0, 1, 2, 3])
        #expect(ledger.totalHeld == 0)
        #expect(pool.statistics.leasedCount == 0)
    }
}
