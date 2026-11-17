//
//  DirectWriteAuthorization.swift
//  FluxKlang
//
//  Revocable, lock-fenced direct-send grants (#62 AU2). `redeemDirect` checks a
//  ticket's fence on the `HostAuthority` actor, but the physical send runs
//  elsewhere (e.g. `WingTransport`), after the actor turn has returned. A grant
//  closes that race: `HostAuthority.authorizeDirectSend` redeems the ticket and
//  returns a `DirectWriteAuthorization`; the send runs inside `consume`, under the
//  grant's lock, and the actor revokes the grant, under the same lock, in the
//  same actor turn that makes its fence stale (`HostAuthority.book`'s `didSet`).
//
//  Invariant: after any `HostAuthority` method that changes the fence returns,
//  no grant whose ticket would now be refused can start a send, and a send that
//  started earlier finished before that method returned. Revoked, consumed,
//  at-capacity and throwing sends all mean no further write.
//
//  Cost: three actor paths take grant locks, so each can wait for a running send:
//  revocation (every tracked grant whose fence is now stale), the pruning in
//  `authorizeDirectSend` and `outstandingDirectSendCount` (every tracked grant).
//  Also, the `didSet` re-checks the fence for every tracked grant (at most
//  `HostAuthority.directSendCapacity` armed, plus spent ones not yet pruned) on
//  every `book` mutation. Sends are short and cannot suspend (the body is not
//  `async`), so each wait is bounded by one send.
//

import Synchronization

/// What one entry of a direct-send grant may write (#62 AU4). Neutral: the
/// authority only compares keys; WING uses the OSC address.
struct DirectSendTarget: Hashable, Sendable {
    let key: String

    init(_ key: String) {
        self.key = key
    }
}

/// A permission for one send to each of a fixed set of targets, minted only by
/// `HostAuthorityBook.authorizeDirectSend` from a ticket that has just redeemed.
/// Reference model, mirroring `WingMixerWriteAuthorization`: `consume` runs one
/// entry's send under the grant's lock, and `revoke` takes the same lock, so a
/// send is either finished before revocation returns or never starts. The lock is
/// taken per entry, so revocation waits for at most one entry's send.
final class DirectWriteAuthorization: Sendable {
    private enum State {
        /// Never empty: the last entry's `consume` moves to `.consumed`.
        case armed(remaining: Set<DirectSendTarget>)
        case consumed
        case revoked(DirectWriteRefusal)
    }

    /// The redeemed ticket whose fence the authority keeps checking.
    let ticket: DirectWriteTicket
    private let state: Mutex<State>

    /// Book only (`authorizeDirectSend`), with validated, non-empty `targets`.
    fileprivate init(_ ticket: DirectWriteTicket, targets: Set<DirectSendTarget>) {
        self.ticket = ticket
        state = Mutex(.armed(remaining: targets))
    }

    /// True while any target remains and the grant is not revoked; diagnostics and pruning only.
    var isArmed: Bool {
        state.withLock { state in
            if case .armed(let remaining) = state { return !remaining.isEmpty }
            return false
        }
    }

    /// Runs `send` once for `target`, under the grant's lock. Throws the
    /// revocation's `DirectWriteRefusal` if revoked, `.notOutstanding` if every
    /// target is spent, `.notGranted` if `target` is not bound or already sent (and
    /// then revokes the rest: fail closed), or `send`'s own error unchanged
    /// (untyped `throws`, so both can propagate). `target` is spent before `send`
    /// runs, so it is spent even if `send` throws. `send` cannot suspend; it must
    /// not touch this grant or wait on the authority, which may be blocked in
    /// `revoke` on this lock.
    func consume(_ target: DirectSendTarget, _ send: () throws -> Void) throws {
        try state.withLock { state in
            switch state {
            case .revoked(let refusal): throw refusal
            case .consumed: throw DirectWriteRefusal.notOutstanding
            case .armed(var remaining):
                guard remaining.remove(target) != nil else {
                    state = .revoked(.notGranted)
                    throw DirectWriteRefusal.notGranted
                }
                state = remaining.isEmpty ? .consumed : .armed(remaining: remaining)
                try send()
            }
        }
    }

    /// Holder side: spends every remaining target without sending, for example when
    /// a batch stops early. Waits for a send in progress. Revoked grants are unchanged.
    func relinquish() {
        state.withLock { state in
            if case .armed = state { state = .consumed }
        }
    }

    /// Authority only. Revokes an armed grant with `reason`; a consumed or already
    /// revoked grant is unchanged. Waits for a send in progress, so that send is
    /// ordered before this returns.
    fileprivate func revoke(_ reason: DirectWriteRefusal) {
        state.withLock { state in
            if case .armed = state { state = .revoked(reason) }
        }
    }
}

extension HostAuthorityBook {
    /// Redeems `ticket` (always consuming it, as `redeemDirect` does) and mints a
    /// grant for one send to each of `targets`. Order: the redeem refusal,
    /// unchanged, minting nothing; `invalidBinding` for empty or duplicate
    /// `targets`, or more than `HostAuthority.directSendBatchLimit`; `outOfScope`
    /// unless `policy` admits every target under `ticket.scope`; grants no
    /// longer armed are pruned; at `HostAuthority.directSendCapacity` armed grants
    /// (a batch holds one), `tooManyOutstanding`. Every refusal fails closed: the
    /// ticket is already spent and the write must be admitted again. Never changes
    /// the snapshot.
    mutating func authorizeDirectSend(
        _ ticket: DirectWriteTicket, targets: [DirectSendTarget], policy: any DirectSendScopePolicy
    ) -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        if case .failure(let refusal) = redeemDirect(ticket) { return .failure(refusal) }
        let bound = Set(targets)
        guard !targets.isEmpty, targets.count <= HostAuthority.directSendBatchLimit,
              bound.count == targets.count else { return .failure(.invalidBinding) }
        guard targets.allSatisfy({ policy.admits($0, under: ticket.scope) }) else { return .failure(.outOfScope) }
        // `isArmed` takes each grant's lock, so a pruned grant's send has finished.
        sendGrants.removeAll { !$0.isArmed }
        guard sendGrants.count < HostAuthority.directSendCapacity else { return .failure(.tooManyOutstanding) }
        let grant = DirectWriteAuthorization(ticket, targets: bound)
        sendGrants.append(grant)
        return .success(grant)
    }

    /// Revokes every grant whose ticket the fence would now refuse, with that
    /// refusal. Called by `HostAuthority.book`'s `didSet` after every mutation, so
    /// before the actor method that staled the grant returns. Every tracked grant
    /// whose fence is stale is locked, including consumed ones, so a send still
    /// running is ordered before this returns. Non-mutating: grants are references.
    func revokeUnredeemableSendGrants() {
        for grant in sendGrants {
            if let refusal = directWriteRefusal(grant.ticket) { grant.revoke(refusal) }
        }
    }

    /// Armed grants; diagnostics and tests only.
    var outstandingDirectSendCount: Int { sendGrants.count { $0.isArmed } }
}
