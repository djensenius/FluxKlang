//
//  MediaBlockLedger.swift
//  FluxKlang
//
//  Which consumer role holds which leased pool block (#109 BLG1). Pure value: it leases and releases nothing in the
//  pool, validates no lease, runs no worker and reads no time.
//

/// One role's hold on one leased block.
private struct MediaBlockLedgerEntry: Equatable, Sendable {
    let lease: MediaBlockLease
    let role: MediaTapRole
}

private extension MediaTapRole {
    /// The position of the role in the ledger's three-element tables.
    var ledgerIndex: Int { Int(rawValue) }
}

/// Records which `MediaTapRole` holds which leased block of ONE `MediaBlockPool`, so that one block has one
/// ledger-visible holder.
///
/// It is the block-level counterpart of `MediaTapClaims` (one consumer per role per tap). Storage is one entry per
/// pool slot, so every list it returns is in ascending slot order. There is no transfer and no eviction: a block
/// changes holder by `release` and then `claim`.
///
/// Caller contract, none of it checked here:
/// - `blockCount` is the pool's own `plan.blockCount`, and only leases of that pool are offered. The pool exposes no
///   identity token, so a lease of another pool that lands on a free slot is accepted; one that lands on a held slot
///   is refused as `.slotHeldByOtherLease`.
/// - Claim after a successful `pool.lease()`. Release here before `pool.release(_:)`; if the pool refuses, the block
///   is free in the ledger and may be claimed again with the same lease.
/// - A limit is a ceiling on ledger-visible claims. Limits add up to at most `blockCount`, but the ledger cannot
///   reserve pool blocks: leasing is role-blind.
struct MediaBlockLedger: Equatable, Sendable {
    /// The largest ledger, read from `PrefetchPlan.blockCountRange`.
    static let maximumBlocks = PrefetchPlan.blockCountRange.upperBound

    /// The number of pool blocks this ledger serves.
    let blockCount: Int
    private let limits: [Int]
    private var counts: [Int]
    private var entries: [MediaBlockLedgerEntry?]

    private init(blockCount: Int, limits: [Int]) {
        self.blockCount = blockCount
        self.limits = limits
        counts = [0, 0, 0]
        entries = Array(repeating: nil, count: blockCount)
    }

    /// Builds an empty ledger. A limit of 0 disables its role. Refusals follow the order in
    /// `MediaBlockLedgerRefusal`. Nothing is allocated for a refused request.
    static func make(
        blockCount: Int,
        playbackLimit: Int,
        recorderLimit: Int,
        tunerLimit: Int
    ) throws(MediaBlockLedgerRefusal) -> MediaBlockLedger {
        guard PrefetchPlan.blockCountRange.contains(blockCount) else { throw .blockCountOutOfRange(blockCount) }
        let requested = [playbackLimit, recorderLimit, tunerLimit]
        for (role, limit) in zip(MediaTapRole.allCases, requested) {
            guard (0...blockCount).contains(limit) else {
                throw .roleLimitOutOfRange(role, limit: limit, blockCount: blockCount)
            }
        }
        let total = playbackLimit + recorderLimit + tunerLimit
        guard total <= blockCount else { throw .budgetExceedsPool(total: total, blockCount: blockCount) }
        return MediaBlockLedger(blockCount: blockCount, limits: requested)
    }

    // MARK: - Queries

    /// The most blocks `role` may hold.
    func limit(for role: MediaTapRole) -> Int {
        limits[role.ledgerIndex]
    }

    /// How many blocks `role` holds now.
    func heldCount(by role: MediaTapRole) -> Int {
        counts[role.ledgerIndex]
    }

    /// How many blocks every role holds together.
    var totalHeld: Int {
        counts.reduce(0, +)
    }

    /// The role holding exactly this lease, or nil when the slot is empty or holds a different lease.
    func holder(of lease: MediaBlockLease) -> MediaTapRole? {
        guard lease.slot >= 0, lease.slot < blockCount, let held = entries[lease.slot], held.lease == lease else {
            return nil
        }
        return held.role
    }

    /// Every held lease, ascending by slot.
    func heldLeases() -> [MediaBlockLease] {
        leases(heldBy: nil)
    }

    /// The leases `role` holds, ascending by slot.
    func heldLeases(by role: MediaTapRole) -> [MediaBlockLease] {
        leases(heldBy: role)
    }

    // MARK: - Changes

    /// Records `role` as the holder of `lease`. The second claim of one lease is refused even by its holder.
    mutating func claim(_ lease: MediaBlockLease, by role: MediaTapRole) throws(MediaBlockLedgerRefusal) {
        let slot = try checkedSlot(of: lease)
        try requireVacant(slot: slot, offered: lease)
        try requireBudget(for: role)
        entries[slot] = MediaBlockLedgerEntry(lease: lease, role: role)
        counts[role.ledgerIndex] += 1
    }

    /// Frees the slot of `lease`, which `role` must hold.
    mutating func release(_ lease: MediaBlockLease, by role: MediaTapRole) throws(MediaBlockLedgerRefusal) {
        let slot = try checkedSlot(of: lease)
        let held = try heldEntry(slot: slot, offered: lease, by: role)
        entries[slot] = nil
        counts[held.role.ledgerIndex] -= 1
    }

    /// Frees every block `role` holds and returns those leases, ascending by slot. The caller releases each one to
    /// the pool. Total: it never refuses, and an unheld role returns an empty list.
    mutating func releaseAll(heldBy role: MediaTapRole) -> [MediaBlockLease] {
        var released: [MediaBlockLease] = []
        released.reserveCapacity(heldCount(by: role))
        for slot in entries.indices {
            if let held = entries[slot], held.role == role {
                released.append(held.lease)
                entries[slot] = nil
            }
        }
        counts[role.ledgerIndex] = 0
        return released
    }

    // MARK: - Checks

    private func checkedSlot(of lease: MediaBlockLease) throws(MediaBlockLedgerRefusal) -> Int {
        guard lease.slot >= 0, lease.slot < blockCount else {
            throw .slotOutOfRange(slot: lease.slot, blockCount: blockCount)
        }
        return lease.slot
    }

    private func requireVacant(slot: Int, offered: MediaBlockLease) throws(MediaBlockLedgerRefusal) {
        guard let held = entries[slot] else { return }
        if held.lease == offered { throw .alreadyHeld(slot: slot, holder: held.role) }
        throw .slotHeldByOtherLease(
            slot: slot, heldGeneration: held.lease.generation, offeredGeneration: offered.generation
        )
    }

    private func requireBudget(for role: MediaTapRole) throws(MediaBlockLedgerRefusal) {
        guard counts[role.ledgerIndex] < limits[role.ledgerIndex] else {
            throw .roleBudgetExhausted(role, limit: limits[role.ledgerIndex])
        }
    }

    private func heldEntry(
        slot: Int, offered: MediaBlockLease, by role: MediaTapRole
    ) throws(MediaBlockLedgerRefusal) -> MediaBlockLedgerEntry {
        guard let held = entries[slot] else { throw .notHeld(slot: slot) }
        guard held.lease == offered else {
            throw .leaseMismatch(
                slot: slot, heldGeneration: held.lease.generation, offeredGeneration: offered.generation
            )
        }
        guard held.role == role else { throw .heldByOtherRole(slot: slot, heldBy: held.role, offered: role) }
        return held
    }

    private func leases(heldBy role: MediaTapRole?) -> [MediaBlockLease] {
        var result: [MediaBlockLease] = []
        result.reserveCapacity(role.map { heldCount(by: $0) } ?? totalHeld)
        for case let held? in entries where role == nil || held.role == role {
            result.append(held.lease)
        }
        return result
    }
}
