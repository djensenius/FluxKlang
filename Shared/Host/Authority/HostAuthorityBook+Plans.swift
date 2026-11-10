//
//  HostAuthorityBook+Plans.swift
//  FluxKlang
//
//  Queue followed by outbox is one FIFO. Every outbox binding owns a ledger
//  entry, so the ledger capacity also bounds this storage.
//

extension HostAuthorityBook {
    func phase(of binding: PlanBinding) -> EnginePlanPhase? {
        plans.phase(of: binding)
    }

    /// Only call on a real transition into retiring, after all fallible work.
    /// The future H5d whole-recovery batch is the only separate discard path.
    mutating func scheduleRetirement(_ binding: PlanBinding) {
        let queued: Bool
        if retirementOutbox.isEmpty, case .success = queue.enqueue([.discard(binding)]) {
            queued = true
        } else {
            queued = false
        }
        if !queued { retirementOutbox.append(binding) }
    }

    /// Called after EACH dequeue, including a stale commit's loop continue.
    mutating func refillRetirements() {
        while let first = retirementOutbox.first, case .success = queue.enqueue([.discard(first)]) {
            retirementOutbox.removeFirst()
        }
    }

    mutating func retired(_ binding: PlanBinding) -> Result<Void, HostAuthorityRefusal> {
        let restoreDependsOnBinding = restoring?.discardAfterRestore.contains(binding) == true
        let deferred = deferredRestoreDiscards.values.contains { $0.contains(binding) }
        guard !retirementOutbox.contains(binding), !queue.pending.contains(.discard(binding)),
              !restoreDependsOnBinding, !deferred else {
            return .failure(.retirementQueued)
        }
        do { try plans.acknowledgeRetired(binding) } catch { return .failure(.plans(error)) }
        return .success(())
    }
}
