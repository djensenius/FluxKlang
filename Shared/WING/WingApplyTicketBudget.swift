//
//  WingApplyTicketBudget.swift
//  FluxKlang
//
//  The most direct-send tickets one grant-gated Studio apply may mint (#62 AU7b).
//

import Synchronization

/// A cap on the tickets one `WingController.applyAndVerify(minting:)` may admit.
/// One budget per apply. It is a cap on attempts, not extra authority: every
/// ticket is still individually admitted, fenced, single-use and bound to exactly
/// one chunk's targets. A refused or failed mint still counts, since the attempt
/// may have spent a ticket.
final class WingApplyTicketBudget: Sendable {
    private let remaining: Mutex<Int>

    init(limit: Int) {
        remaining = Mutex(max(0, limit))
    }

    /// Takes one ticket; false once none are left. Never goes below zero.
    func take() -> Bool {
        remaining.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
    }

    /// Tickets for an apply of `safetyCount` safety and `remainingCount` other
    /// settings, with `c(x)` the chunks of `x` addresses: the safety send `c(S)`,
    /// its retry at most `c(S)` (a safety set that does not verify stops the apply),
    /// the remaining send `c(R)`, and the final retry, which pends at most `S + R`
    /// addresses, at most `c(S + R)`.
    static func limit(safetyCount: Int, remainingCount: Int) -> Int {
        func chunks(_ count: Int) -> Int {
            let size = HostAuthority.directSendBatchLimit
            return (max(0, count) + size - 1) / size
        }
        return 2 * chunks(safetyCount) + chunks(remainingCount) + chunks(safetyCount + remainingCount)
    }
}
