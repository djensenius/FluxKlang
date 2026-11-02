import Testing
@testable import FluxKlang

/// Real prepare effects from the supported transaction API, not forged identities.
func ledgerAttempts(_ count: Int = 1) throws -> [PrepareAttemptID] {
    let host = HostID(validated: "host.ledger")
    let epoch = HostEpoch(host: host, generation: .initial)
    let permission = PermissionFingerprint(rawValue: "permissions.ledger")
    let graph = GraphDocument(id: GraphID(validated: "graph.ledger"))
    let request = ActivationRequest(
        draft: DraftID(validated: "draft.ledger"), graph: graph.id, baseRevision: .initial,
        hostEpoch: epoch, permission: permission, digest: ActivationDigest(rawValue: "ledger"), origin: .human
    )
    let capabilities = try DeviceCapabilityDocument(
        revision: .initial, host: host, hostEpoch: .initial, devices: [], routes: []
    )
    let live = ActivationLiveContext(
        activation: ActivationContext(hostEpoch: epoch, activeRevision: .initial,
                                      permission: permission, capabilities: capabilities),
        engine: .initial
    )
    var transaction = ActivationTransaction(
        project: ProjectID(validated: "prj.ledger"), running: RunningGraph(revision: .initial, prepared: nil)
    )
    return try (0..<count).map { _ in
        let effects = try transaction.begin(request, candidate: graph, in: live).get()
        guard case .prepare(_, let attempt) = try #require(effects.first) else {
            throw LedgerTestError.missingPrepare
        }
        _ = try transaction.prepared(.failure(.cancelled), attempt: attempt).get()
        return attempt
    }
}

private enum LedgerTestError: Error { case missingPrepare }

func ledgerRefusal<Value>(
    _ expected: EnginePlanLedgerRefusal, in ledger: EnginePlanLedger, _ operation: () throws -> Value
) {
    let before = ledger.snapshot()
    do {
        _ = try operation()
        Issue.record("Expected ledger refusal \(expected)")
    } catch {
        #expect(error as? EnginePlanLedgerRefusal == expected)
    }
    #expect(ledger.snapshot() == before)
}

func ledgerBinding(
    _ ledger: EnginePlanLedger, attempt: PrepareAttemptID,
    prepared: PreparedActivationID = PreparedActivationID(validated: "prep.ledger")
) throws -> PlanBinding {
    try ledger.dispatch(instance: ledger.currentInstance, attempt: attempt)
    let completion = try ledger.complete(instance: ledger.currentInstance, attempt: attempt, result: .success(prepared))
    guard case .held(let binding) = completion else { throw LedgerTestError.missingPrepare }
    return binding
}

struct EnginePlanLedgerTests {
    @Test(arguments: [0, -1, Int.min])
    func invalidCapacity(capacity: Int) {
        #expect(throws: EnginePlanLedgerRefusal.invalidCapacity) { try EnginePlanLedger(capacity: capacity) }
    }

    @Test func hugeCapacityIsLazyAndAliasesShareCanonicalState() throws {
        let ledger = try EnginePlanLedger(capacity: Int.max)
        let alias = ledger
        let before = ledger.snapshot()
        let attempt = try #require(ledgerAttempts().first)
        #expect(alias === ledger)
        #expect(before.records.count == 1 && before.records[0].entries.isEmpty)
        try alias.dispatch(instance: alias.currentInstance, attempt: attempt)
        #expect(ledger.count == 1)
        #expect(ledger.snapshot() == alias.snapshot())
        #expect(before.records[0].entries.isEmpty)
        #expect(Set([before, ledger.snapshot()]).count == 2)
    }

    @Test func everyLivePhaseConsumesCapacityAndDuplicateDispatchPreservesState() throws {
        let ledger = try EnginePlanLedger(capacity: 4)
        let attempts = try ledgerAttempts(5)
        let instance = ledger.currentInstance
        try ledger.dispatch(instance: instance, attempt: attempts[0])
        _ = try ledgerBinding(ledger, attempt: attempts[1])
        let committed = try ledgerBinding(ledger, attempt: attempts[2])
        try ledger.committed(committed, outcome: .succeeded)
        let retiring = try ledgerBinding(ledger, attempt: attempts[3])
        try ledger.release(retiring)
        for attempt in attempts.prefix(4) {
            ledgerRefusal(.duplicateAttempt, in: ledger) { try ledger.dispatch(instance: instance, attempt: attempt) }
        }
        ledgerRefusal(.capacityReached, in: ledger) {
            try ledger.dispatch(instance: instance, attempt: attempts[4])
        }
        ledgerRefusal(.unknownAttempt, in: ledger) { try ledger.reclaim(instance: instance, attempt: attempts[4]) }
        #expect(ledger.count == 4)
        try ledger.acknowledgeRetired(retiring)
        try ledger.dispatch(instance: instance, attempt: attempts[4])
        #expect(ledger.count == 4)
    }

    @Test(arguments: [false, true])
    func terminalFailureRemovesOnlyPendingWithoutInventingBinding(reclaim: Bool) throws {
        let ledger = try EnginePlanLedger(capacity: 2)
        let attempts = try ledgerAttempts(2)
        let held = try ledgerBinding(ledger, attempt: attempts[0])
        let instance = ledger.currentInstance
        try ledger.dispatch(instance: instance, attempt: attempts[1])
        if reclaim { try ledger.reclaim(instance: instance, attempt: attempts[1]) }
        #expect(ledger.count == 2)
        #expect(ledger.pendingRetirements().isEmpty)
        let reply = try ledger.complete(instance: instance, attempt: attempts[1], result: .failure(.cancelled))
        #expect(reply == .failed(instance: instance, attempt: attempts[1], reason: .cancelled))
        #expect(ledger.snapshot().records[0].entries == [.init(attempt: attempts[0], state: .bound(held, .held))])
        ledgerRefusal(.unknownAttempt, in: ledger) {
            try ledger.complete(instance: instance, attempt: attempts[1], result: .success(held.prepared))
        }
        ledgerRefusal(.unknownAttempt, in: ledger) { try ledger.reclaim(instance: instance, attempt: attempts[1]) }
    }

    @Test func pendingReclaimCompletesDirectlyToRetiringAndCannotBeCompletedTwice() throws {
        let ledger = try EnginePlanLedger(capacity: 1)
        let attempt = try #require(ledgerAttempts().first)
        let instance = ledger.currentInstance
        let prepared = PreparedActivationID(validated: "prep.late")
        try ledger.dispatch(instance: instance, attempt: attempt)
        try ledger.reclaim(instance: instance, attempt: attempt)
        let marked = ledger.snapshot()
        try ledger.reclaim(instance: instance, attempt: attempt)
        #expect(ledger.snapshot() == marked)
        #expect(marked.records[0].entries[0].state == .pending(reclaim: true))
        let reply = try ledger.complete(instance: instance, attempt: attempt, result: .success(prepared))
        guard case .retiring(let binding) = reply else {
            Issue.record("Reclaimed completion must retire")
            return
        }
        #expect(binding.instance == instance && binding.attempt == attempt && binding.prepared == prepared)
        #expect(ledger.pendingRetirements() == [binding] && ledger.count == 1)
        ledgerRefusal(.notPending, in: ledger) {
            try ledger.complete(instance: instance, attempt: attempt, result: .failure(.engineRefused))
        }
        ledgerRefusal(.notPending, in: ledger) {
            try ledger.complete(instance: instance, attempt: attempt, result: .success(prepared))
        }
    }

    @Test func heldReclaimAndAuthorizedReleaseAreStableUntilTrueAcknowledgement() throws {
        let ledger = try EnginePlanLedger(capacity: 2)
        let attempts = try ledgerAttempts(2)
        let first = try ledgerBinding(ledger, attempt: attempts[0])
        let second = try ledgerBinding(ledger, attempt: attempts[1])
        ledgerRefusal(.notRetiring, in: ledger) { try ledger.acknowledgeRetired(first) }
        try ledger.reclaim(instance: first.instance, attempt: first.attempt)
        try ledger.release(second)
        let beforeHandoff = ledger.snapshot()
        let intents = ledger.pendingRetirements()
        #expect(intents == [first, second])
        // Simulate a failed handoff: no acknowledgement, then retry.
        #expect(ledger.pendingRetirements() == intents && ledger.snapshot() == beforeHandoff)
        try ledger.reclaim(instance: first.instance, attempt: first.attempt)
        try ledger.release(first)
        try ledger.release(second)
        #expect(ledger.snapshot() == beforeHandoff && ledger.count == 2)
        ledgerRefusal(.notHeld, in: ledger) { try ledger.committed(first, outcome: .succeeded) }
        try ledger.acknowledgeRetired(first)
        #expect(ledger.pendingRetirements() == [second] && ledger.count == 1)
        ledgerRefusal(.unknownAttempt, in: ledger) { try ledger.acknowledgeRetired(first) }
        try ledger.acknowledgeRetired(second)
        #expect(ledger.count == 0)
    }

    @Test(arguments: [ActivationCommitOutcome.succeeded, .partial, .failed])
    func commitOutcomeAccountsForOwnershipOnly(outcome: ActivationCommitOutcome) throws {
        let ledger = try EnginePlanLedger(capacity: 1)
        let binding = try ledgerBinding(ledger, attempt: #require(ledgerAttempts().first))
        #expect(ledger.attestCommitted(binding) == nil)
        let held = ledger.snapshot()
        try ledger.committed(binding, outcome: outcome)
        if outcome == .failed {
            #expect(ledger.snapshot() == held && ledger.attestCommitted(binding) == nil)
            try ledger.reclaim(instance: binding.instance, attempt: binding.attempt)
        } else {
            #expect(ledger.attestCommitted(binding)?.binding == binding)
            ledgerRefusal(.notReclaimable, in: ledger) {
                try ledger.reclaim(instance: binding.instance, attempt: binding.attempt)
            }
            ledgerRefusal(.notHeld, in: ledger) { try ledger.committed(binding, outcome: .failed) }
            ledgerRefusal(.notRetiring, in: ledger) { try ledger.acknowledgeRetired(binding) }
            try ledger.release(binding)
        }
        #expect(ledger.attestCommitted(binding) == nil)
        #expect(ledger.pendingRetirements() == [binding] && ledger.count == 1)
    }

    @Test func sameRawIDAcrossAttemptsNeverAliasesOwnership() throws {
        let ledger = try EnginePlanLedger(capacity: 2)
        let attempts = try ledgerAttempts(2)
        let first = try ledgerBinding(ledger, attempt: attempts[0])
        let second = try ledgerBinding(ledger, attempt: attempts[1])
        #expect(first !== second && first != second && first.prepared == second.prepared)
        #expect(Set([first, second]).count == 2)
        try ledger.committed(second, outcome: .partial)
        try ledger.reclaim(instance: first.instance, attempt: first.attempt)
        try ledger.acknowledgeRetired(first)
        #expect(ledger.attestCommitted(second)?.binding == second)
        #expect(ledger.snapshot().records[0].entries == [
            .init(attempt: second.attempt, state: .bound(second, .committed))
        ])
        ledgerRefusal(.unknownAttempt, in: ledger) { try ledger.release(first) }
    }

    @Test func defensiveOutOfContractProbeRejectsMismatchedBindingAfterAttemptReuse() throws {
        let ledger = try EnginePlanLedger(capacity: 1)
        let attempt = try #require(ledgerAttempts().first)
        let old = try ledgerBinding(ledger, attempt: attempt)
        try ledger.release(old)
        try ledger.acknowledgeRetired(old)
        // INTENTIONAL out-of-contract defensive probe: reusing this retired
        // attempt violates the lifetime at-most-once dispatch premise. This is
        // NOT supported retired-attempt replay and adds no replay guarantee.
        let replacement = try ledgerBinding(
            ledger, attempt: attempt, prepared: PreparedActivationID(validated: "prep.replacement")
        )
        #expect(replacement.instance == old.instance && replacement.attempt == old.attempt)
        #expect(replacement.prepared != old.prepared)
        ledgerRefusal(.bindingMismatch, in: ledger) { try ledger.release(old) }
        #expect(ledger.snapshot().records[0].entries == [
            .init(attempt: attempt, state: .bound(replacement, .held))
        ])
        #expect(ledger.count == 1 && ledger.pendingRetirements().isEmpty)
    }

    @Test func foreignBindingsAndInstancesCannotMutateOrAttest() throws {
        let ledger = try EnginePlanLedger(capacity: 2)
        let foreign = try EnginePlanLedger(capacity: 2)
        let attempt = try #require(ledgerAttempts().first)
        let own = try ledgerBinding(ledger, attempt: attempt)
        let other = try ledgerBinding(foreign, attempt: attempt)
        #expect(own != other && own.attempt == other.attempt && own.prepared == other.prepared)
        #expect(Set([own.instance, other.instance]).count == 2)
        ledgerRefusal(.unknownInstance, in: ledger) { try ledger.release(other) }
        ledgerRefusal(.unknownInstance, in: ledger) { try ledger.committed(other, outcome: .succeeded) }
        ledgerRefusal(.unknownInstance, in: ledger) { try ledger.acknowledgeRetired(other) }
        ledgerRefusal(.unknownInstance, in: ledger) { try ledger.acknowledgeQuiescent(other.instance) }
        ledgerRefusal(.unknownInstance, in: ledger) {
            try ledger.dispatch(instance: other.instance, attempt: attempt)
        }
        ledgerRefusal(.unknownInstance, in: ledger) {
            try ledger.reclaim(instance: other.instance, attempt: attempt)
        }
        ledgerRefusal(.unknownInstance, in: ledger) {
            try ledger.complete(instance: other.instance, attempt: attempt, result: .success(other.prepared))
        }
        try foreign.committed(other, outcome: .succeeded)
        #expect(foreign.attestCommitted(other) != nil && ledger.attestCommitted(other) == nil)
        #expect(ledger.count == 1 && ledger.attestCommitted(own) == nil)
    }
}
