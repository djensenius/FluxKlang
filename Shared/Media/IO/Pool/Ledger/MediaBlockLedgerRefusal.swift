//
//  MediaBlockLedgerRefusal.swift
//  FluxKlang
//
//  Typed refusals of the resident block ledger (#109 BLG1). A refused call leaves the ledger unchanged.
//

/// Why a ledger could not be built, or a claim or release was refused.
///
/// Refusal orders (a later check runs only when every earlier one passed):
/// - `make`: block count, then the first role limit outside `0...blockCount` in role order (playback, recorder,
///   tuner), then the sum of the limits.
/// - `claim`: slot range, then occupancy, then the role budget.
/// - `release`: slot range, then an empty slot, then a lease mismatch, then the wrong role.
enum MediaBlockLedgerRefusal: Error, Equatable, Sendable {
    /// `make`: the block count is outside `PrefetchPlan.blockCountRange`.
    case blockCountOutOfRange(Int)
    /// `make`: a role limit is outside `0...blockCount`.
    case roleLimitOutOfRange(MediaTapRole, limit: Int, blockCount: Int)
    /// `make`: the three limits add up to more than the block count.
    case budgetExceedsPool(total: Int, blockCount: Int)
    /// The lease's slot is outside `0..<blockCount`.
    case slotOutOfRange(slot: Int, blockCount: Int)
    /// `claim`: this exact lease is already held, by `holder` (the asking role may be any role).
    case alreadyHeld(slot: Int, holder: MediaTapRole)
    /// `claim`: the slot is held under a different lease value (another generation or another pool's lease).
    case slotHeldByOtherLease(slot: Int, heldGeneration: UInt32, offeredGeneration: UInt32)
    /// `claim`: the role already holds its whole limit.
    case roleBudgetExhausted(MediaTapRole, limit: Int)
    /// `release`: nothing is held on the slot.
    case notHeld(slot: Int)
    /// `release`: the slot is held under a different lease value (another generation or another pool's lease).
    case leaseMismatch(slot: Int, heldGeneration: UInt32, offeredGeneration: UInt32)
    /// `release`: the block is held by another role.
    case heldByOtherRole(slot: Int, heldBy: MediaTapRole, offered: MediaTapRole)
}
