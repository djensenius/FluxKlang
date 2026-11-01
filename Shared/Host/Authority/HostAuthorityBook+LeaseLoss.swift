//
//  HostAuthorityBook+LeaseLoss.swift
//  FluxKlang
//
//  Involuntary loss of the engine lease (#62 H5d-1): table T1 on the holder and
//  the fail-closed output lane. Voluntary `release` and `transfer` stay in
//  `HostAuthorityBook.swift` (refused while a commit is in flight, lazy withhold,
//  no T1). Restoring the running graph and unmuting are H5d-2's.
//
//  R1, two output paths: H5c's mutes travel in the FIFO (`requestMute`:
//  `abandonCommit` queues one, `withholdCommit` delivers one in a withheld
//  commit's place), and this lane (`pendingOutput`) is delivered by
//  `nextEngineCommand()` before the FIFO, taking no queue slot. Every mute on
//  either path sets `outputsMuted`; only H5d-2's acknowledged restore clears it.
//  A new mute path must do the same, or the engine-global mute state drifts.
//

extension HostAuthorityBook {
    /// The holder's lease was lost involuntarily (the engine or the system took it).
    /// Checks, in order: a lease is held (`.lease(.notHeld)`); `token` is its current
    /// token (`.lease(.staleToken)`). Never refused for a delivered commit
    /// (`inFlight`, unlike `release` and `transfer`) or a full queue (the lane needs
    /// no slot). The holder's state moves on a copy by table T1
    /// (`applyingLeaseLoss`); the lease is removed by `removeLease` (one context
    /// bump, staged); then the holder's state, its `inFlight` record and its
    /// authorizing window change together, and the lane owes a mute. The running
    /// graph is kept, nothing is discarded or installed, and other projects are
    /// unchanged. Returns the project that held the lease.
    mutating func leaseLost(_ token: EngineLeaseToken) -> Result<ProjectID, HostAuthorityRefusal> {
        guard let held = registry.snapshot else { return .failure(.lease(.notHeld)) }
        guard held.token == token else { return .failure(.lease(.staleToken)) }
        let holder = held.project
        let lost = projects[holder].map(Self.applyingLeaseLoss)
        if case .failure(let refusal) = removeLease(expected: token) { return .failure(refusal) }
        projects[holder] = lost
        inFlight[holder] = nil
        authorizedWindows[holder] = nil
        failClosedMute()
        return .success(holder)
    }

    /// Owes the engine a mute in the lane. Named apart from `requestMute`, the FIFO path.
    mutating func failClosedMute() {
        pendingOutput = true
        outputsMuted = true
    }

    /// The lane: the owed output command, if any, which it clears.
    mutating func takeOutput() -> EngineCommand? {
        guard let output = pendingOutput else { return nil }
        pendingOutput = nil
        return .setOutputsMuted(output)
    }

    /// Table T1 on the holder's state, every phase failing closed into `.recovering`:
    /// - `idle`, `preparing`, `awaitingReview`, `acknowledged`, `prepareFailed`,
    ///   `recovering`: the phase is kept. An outstanding prepare is still routed;
    ///   a reviewed plan stays live and can be cancelled; the context bump stales it.
    /// - `committing` (queued or delivered), `commitFailed`, `partial`: the commit is
    ///   abandoned as `.leaseLost` on the transaction itself (the book's
    ///   `abandonCommit` reserves that reason). Its recovery step is only the mute,
    ///   which the lane delivers; a still-queued `.commit` is then dropped by the
    ///   delivery guard. Should the transaction refuse (a contract break), its phase
    ///   is kept and the lifecycle still fails closed.
    private static func applyingLeaseLoss(_ state: HostProjectState) -> HostProjectState {
        var lost = state
        switch state.transaction.phase {
        case .committing, .commitFailed, .partial:
            if let attempt = state.transaction.lastAttempt {
                _ = lost.transaction.abandonCommit(attempt, reason: .leaseLost)
            }
        case .idle, .preparing, .awaitingReview, .acknowledged, .prepareFailed, .recovering: break
        }
        lost.enterRecovery()
        return lost
    }
}
