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

/// A single-use permission for one direct send, minted only by
/// `HostAuthorityBook.authorizeDirectSend` from a ticket that has just redeemed.
/// Reference model, mirroring `WingMixerWriteAuthorization`: `consume` runs the
/// send under the grant's lock, and `revoke` takes the same lock, so a send is
/// either finished before revocation returns or never starts.
final class DirectWriteAuthorization: Sendable {
    private enum State {
        case armed
        case consumed
        case revoked(DirectWriteRefusal)
    }

    /// The redeemed ticket whose fence the authority keeps checking.
    let ticket: DirectWriteTicket
    private let state = Mutex(State.armed)

    /// Book only (`authorizeDirectSend`).
    fileprivate init(_ ticket: DirectWriteTicket) {
        self.ticket = ticket
    }

    /// True until consumed or revoked; diagnostics and pruning only.
    var isArmed: Bool {
        state.withLock { state in
            if case .armed = state { return true }
            return false
        }
    }

    /// Runs `send` once, under the grant's lock. Throws the revocation's
    /// `DirectWriteRefusal` if revoked, `.notOutstanding` if already consumed, or
    /// `send`'s own error unchanged (untyped `throws`, so both can propagate). The
    /// grant is consumed before `send` runs, so it is spent even if `send` throws.
    /// `send` cannot suspend; it must not touch this grant or wait on the
    /// authority, which may be blocked in `revoke` on this lock.
    func consume(_ send: () throws -> Void) throws {
        try state.withLock { state in
            switch state {
            case .revoked(let refusal): throw refusal
            case .consumed: throw DirectWriteRefusal.notOutstanding
            case .armed:
                state = .consumed
                try send()
            }
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
    /// grant for its send. Order: the redeem refusal, unchanged, minting nothing;
    /// grants no longer armed are pruned; at `HostAuthority.directSendCapacity`
    /// armed grants, `tooManyOutstanding` (fails closed: the ticket is already
    /// spent and the write must be admitted again). Never changes the snapshot.
    mutating func authorizeDirectSend(
        _ ticket: DirectWriteTicket
    ) -> Result<DirectWriteAuthorization, DirectWriteRefusal> {
        if case .failure(let refusal) = redeemDirect(ticket) { return .failure(refusal) }
        // `isArmed` takes each grant's lock, so a pruned grant's send has finished.
        sendGrants.removeAll { !$0.isArmed }
        guard sendGrants.count < HostAuthority.directSendCapacity else { return .failure(.tooManyOutstanding) }
        let grant = DirectWriteAuthorization(ticket)
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
