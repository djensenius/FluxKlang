import Testing
@testable import FluxKlang

extension EnginePlanLedgerTests {
    struct Instances {
        @Test func emptyButUnquiescedPriorPreventsThirdInstance() throws {
            let ledger = try EnginePlanLedger(capacity: 1)
            let first = ledger.currentInstance
            ledgerRefusal(.currentInstance, in: ledger) { try ledger.acknowledgeQuiescent(first) }
            let second = try ledger.supersede()
            #expect(first != second)
            let records = ledger.snapshot().records
            #expect(records.map(\.instance) == [first, second])
            #expect(records[0].superseded && !records[0].quiescent && records[0].entries.isEmpty)
            ledgerRefusal(.priorInstanceRetained, in: ledger) { try ledger.supersede() }
            ledgerRefusal(.currentInstance, in: ledger) { try ledger.acknowledgeQuiescent(second) }
            try ledger.acknowledgeQuiescent(first)
            #expect(ledger.snapshot().records.map(\.instance) == [second])
            ledgerRefusal(.unknownInstance, in: ledger) { try ledger.acknowledgeQuiescent(first) }
            let third = try ledger.supersede()
            #expect(Set([first, second, third]).count == 3)
            #expect(ledger.snapshot().records.map(\.instance) == [second, third])
        }

        @Test func supersedeRetainsAllPhasesAndCountsOldAndNewEntries() throws {
            let ledger = try EnginePlanLedger(capacity: 5)
            let attempts = try ledgerAttempts(6)
            let first = ledger.currentInstance
            try ledger.dispatch(instance: first, attempt: attempts[0])
            let held = try ledgerBinding(ledger, attempt: attempts[1])
            let committed = try ledgerBinding(ledger, attempt: attempts[2])
            try ledger.committed(committed, outcome: .succeeded)
            let retiring = try ledgerBinding(ledger, attempt: attempts[3])
            try ledger.release(retiring)
            let resident = try #require(ledger.attestCommitted(committed))
            let second = try ledger.supersede()
            #expect(ledger.count == 4 && ledger.attestCommitted(committed) == nil)
            #expect(resident.binding == committed) // Immutable observation, not perpetual freshness.
            #expect(ledger.snapshot().records[0].entries.map(\.state) == [
                .pending(reclaim: true), .bound(held, .retiring),
                .bound(committed, .retiring), .bound(retiring, .retiring)
            ])
            #expect(ledger.pendingRetirements() == [held, committed, retiring])
            try ledger.dispatch(instance: second, attempt: attempts[4])
            ledgerRefusal(.capacityReached, in: ledger) {
                try ledger.dispatch(instance: second, attempt: attempts[5])
            }
            ledgerRefusal(.notCurrentInstance, in: ledger) {
                try ledger.dispatch(instance: first, attempt: attempts[5])
            }
            ledgerRefusal(.priorInstanceRetained, in: ledger) { try ledger.supersede() }
            ledgerRefusal(.pendingPreparations, in: ledger) { try ledger.acknowledgeQuiescent(first) }
            try ledger.acknowledgeRetired(held)
            #expect(ledger.count == 4)
            try ledger.dispatch(instance: second, attempt: attempts[5])
            #expect(ledger.count == 5 && ledger.snapshot().records.count == 2)
        }

        @Test func oldCompletionUsesExactInstanceEvenWhenAttemptAndRawIDMatchCurrent() throws {
            let ledger = try EnginePlanLedger(capacity: 2)
            let attempt = try #require(ledgerAttempts().first)
            let first = ledger.currentInstance
            let prepared = PreparedActivationID(validated: "prep.recycled")
            try ledger.dispatch(instance: first, attempt: attempt)
            let second = try ledger.supersede()
            // Same attempt in another instance is a distinct explicit key. G2
            // must still enforce lifetime at-most-once dispatch for each key.
            let current = try ledgerBinding(ledger, attempt: attempt, prepared: prepared)
            try ledger.committed(current, outcome: .succeeded)
            let currentRecord = ledger.snapshot().records[1]
            let reply = try ledger.complete(instance: first, attempt: attempt, result: .success(prepared))
            guard case .retiring(let old) = reply else {
                Issue.record("Old completion must retire")
                return
            }
            #expect(old.instance == first && current.instance == second && old != current)
            #expect(old.attempt == current.attempt && old.prepared == current.prepared)
            #expect(ledger.snapshot().records[1] == currentRecord)
            #expect(ledger.pendingRetirements() == [old])
            #expect(ledger.attestCommitted(current)?.binding == current)
            try ledger.acknowledgeQuiescent(first)
            #expect(ledger.snapshot().records.count == 2)
            ledgerRefusal(.priorInstanceRetained, in: ledger) { try ledger.supersede() }
            try ledger.acknowledgeRetired(old)
            #expect(ledger.snapshot().records == [currentRecord])
            ledgerRefusal(.unknownInstance, in: ledger) {
                try ledger.complete(instance: first, attempt: attempt, result: .failure(.cancelled))
            }
            #expect(ledger.attestCommitted(current)?.binding == current)
        }

        @Test(arguments: [false, true])
        func priorReleaseRequiresBothQuiescenceAndLastRetirement(quiescenceFirst: Bool) throws {
            let ledger = try EnginePlanLedger(capacity: 2)
            let attempts = try ledgerAttempts(2)
            let first = try ledgerBinding(ledger, attempt: attempts[0])
            let last = try ledgerBinding(ledger, attempt: attempts[1])
            let current = try ledger.supersede()
            if quiescenceFirst {
                try ledger.acknowledgeQuiescent(first.instance)
                let quiesced = ledger.snapshot()
                try ledger.acknowledgeQuiescent(first.instance)
                #expect(ledger.snapshot() == quiesced)
            }
            try ledger.acknowledgeRetired(first)
            #expect(ledger.snapshot().records.count == 2 && ledger.count == 1)
            ledgerRefusal(.priorInstanceRetained, in: ledger) { try ledger.supersede() }
            try ledger.acknowledgeRetired(last)
            if !quiescenceFirst {
                #expect(ledger.count == 0 && ledger.snapshot().records.count == 2)
                ledgerRefusal(.priorInstanceRetained, in: ledger) { try ledger.supersede() }
                try ledger.acknowledgeQuiescent(first.instance)
            }
            #expect(ledger.snapshot().records.map(\.instance) == [current])
            let next = try ledger.supersede()
            #expect(next != current)
        }

        @Test func pendingOldFailureNeedsNoInventedRetirementButStillNeedsQuiescence() throws {
            let ledger = try EnginePlanLedger(capacity: 1)
            let attempt = try #require(ledgerAttempts().first)
            let first = ledger.currentInstance
            try ledger.dispatch(instance: first, attempt: attempt)
            let second = try ledger.supersede()
            ledgerRefusal(.pendingPreparations, in: ledger) { try ledger.acknowledgeQuiescent(first) }
            let reply = try ledger.complete(instance: first, attempt: attempt, result: .failure(.engineRefused))
            #expect(reply == .failed(instance: first, attempt: attempt, reason: .engineRefused))
            #expect(ledger.count == 0 && ledger.pendingRetirements().isEmpty)
            #expect(ledger.snapshot().records.count == 2)
            ledgerRefusal(.priorInstanceRetained, in: ledger) { try ledger.supersede() }
            try ledger.acknowledgeQuiescent(first)
            #expect(ledger.snapshot().records.map(\.instance) == [second])
        }

        @Test func wrongKnownInstanceCannotCompleteOrReclaimAnotherInstancesAttempt() throws {
            let ledger = try EnginePlanLedger(capacity: 2)
            let attempts = try ledgerAttempts(2)
            let first = ledger.currentInstance
            try ledger.dispatch(instance: first, attempt: attempts[0])
            let second = try ledger.supersede()
            try ledger.dispatch(instance: second, attempt: attempts[1])
            for (instance, attempt) in [(first, attempts[1]), (second, attempts[0])] {
                ledgerRefusal(.unknownAttempt, in: ledger) {
                    try ledger.complete(instance: instance, attempt: attempt, result: .failure(.cancelled))
                }
                ledgerRefusal(.unknownAttempt, in: ledger) { try ledger.reclaim(instance: instance, attempt: attempt) }
            }
        }
    }
}
