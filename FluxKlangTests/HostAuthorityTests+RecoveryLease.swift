import Testing
@testable import FluxKlang

// Recovery under a lost or changed engine lease; the bench helpers are in `+Recovery.swift`.
private let projectA = ProjectID(validated: "prj.a")
private let projectB = ProjectID(validated: "prj.b")
private let windowB = WindowID(validated: "win.b1")
private let planID = PreparedActivationID(validated: "prep.next")
private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]
private let partial = CommitReportDraft(prepared: planID, outcome: .partial, applied: [nodes[0]],
                                        unapplied: [nodes[1], nodes[2]])
private let failed = CommitReportDraft(prepared: planID, outcome: .failed, applied: [], unapplied: Set(nodes))

private func restore(_ revision: ContractRevision) -> ActivationRecoveryStep {
    ActivationRecoveryStep(cause: .commitFailed, decisions: [.restorePrevious(revision)], effects: [.discard(planID)])
}

private func mutedRecovery(_ cause: RecoveryEvent) -> ActivationRecoveryStep {
    ActivationRecoveryStep(cause: cause, decisions: [.recover(muteOutputs: true)], effects: [])
}

extension HostAuthorityTests.Recovery {
    /// How the lease differs, at a partial resolve, from the one the commit was issued under.
    enum PartialLeaseChange: CaseIterable, Sendable { case released, reacquired, transferred }

    @Test(arguments: PartialLeaseChange.allCases)
    func partialResolveWithoutCommitLeaseFailsClosed(change: PartialLeaseChange) throws {
        var host = try TransactionBench()
        let attempt = try host.committedAttempt()
        _ = try host.transaction.acknowledged(partial).get()
        let token = try #require(host.registry.snapshot).token
        switch change {
        case .released: _ = try host.registry.release(expected: token)
        case .reacquired:
            _ = try host.registry.release(expected: token)
            try host.acquire(projectA)
        case .transferred: _ = try host.registry.transfer(to: projectB, window: windowB, expected: token)
        }
        let before = host.transaction
        let running = before.running
        // No install and no discard of the running plan: muted recovery over the old running graph.
        #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get()
            == mutedRecovery(.leaseLost))
        host.expectSettled(.recovering(planID), running: running, since: before)
        if let held = host.registry.snapshot, held.project != projectA {
            _ = try host.registry.release(expected: held.token)
        }
        if host.registry.snapshot == nil { try host.acquire(projectA) }  // Any token of this project restores.
        #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get()
            == restore(.initial))
        host.expectSettled(.idle, running: running, since: before)
    }

    @Test(arguments: [false, true])
    func leaseLossExitsFailedOrPartialCommitIntoRecovery(partially: Bool) throws {
        var host = try TransactionBench()
        let attempt = try host.committedAttempt()
        _ = try host.transaction.acknowledged(partially ? partial : failed).get()
        let phase = host.transaction.phase
        for reason in [CommitAbandonment.outcomeUnknown, .revisionOverflow] {
            #expect(host.refusal { $0.abandonCommit(attempt, reason: reason) } == .unexpectedPhase(phase))
        }
        let foreign = try TransactionBench.foreignAttempt()
        #expect(host.refusal { $0.abandonCommit(foreign, reason: .leaseLost) } == .staleReport)
        let before = host.transaction
        #expect(try host.transaction.abandonCommit(attempt, reason: .leaseLost).get() == mutedRecovery(.leaseLost))
        host.expectSettled(.recovering(planID), running: before.running, since: before)
        try host.expectRestoreNeedsLease(attempt)
        #expect(try host.transaction.resolveRecovery(attempt, lease: host.registry.snapshot).get()
            == restore(.initial))
        host.expectSettled(.idle, running: before.running, since: before)
    }

    @Test func leaseLossOutranksRevisionOverflowAtPartialResolve() throws {
        let last = try ContractRevision(ContractRevision.maximumValue)
        var host = try TransactionBench(revision: last)
        let attempt = try host.committedAttempt(base: last)
        _ = try host.transaction.acknowledged(partial).get()
        _ = try host.registry.release(expected: try #require(host.registry.snapshot).token)
        #expect(try host.transaction.resolveRecovery(attempt, lease: nil).get() == mutedRecovery(.leaseLost))
        #expect(host.transaction.phase == .recovering(planID))
    }
}
