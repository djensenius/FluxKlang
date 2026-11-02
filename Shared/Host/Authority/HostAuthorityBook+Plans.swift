//
//  HostAuthorityBook+Plans.swift
//  FluxKlang
//
//  Queue followed by outbox is one FIFO. Every outbox binding owns a ledger
//  entry, so the ledger capacity also bounds this storage.
//

extension HostAuthorityBook {
    func phase(of binding: PlanBinding) -> EnginePlanPhase? {
        for record in plans.snapshot().records where record.instance == binding.instance {
            for entry in record.entries where entry.attempt == binding.attempt {
                if case .bound(let actual, let phase) = entry.state, actual == binding { return phase }
            }
        }
        return nil
    }

    /// Only call on a real transition into retiring, after all fallible work.
    /// The future H5d whole-recovery batch is the only separate discard path.
    mutating func scheduleRetirement(_ binding: PlanBinding) {
        if retirementOutbox.isEmpty, case .success = queue.enqueue([.discard(binding)]) { return }
        retirementOutbox.append(binding)
    }

    /// Called after EACH dequeue, including a stale commit's loop continue.
    mutating func refillRetirements() {
        while let first = retirementOutbox.first, case .success = queue.enqueue([.discard(first)]) {
            retirementOutbox.removeFirst()
        }
    }

    mutating func retired(_ binding: PlanBinding) -> Result<Void, HostAuthorityRefusal> {
        guard !retirementOutbox.contains(binding), !queue.pending.contains(.discard(binding)) else {
            return .failure(.retirementQueued)
        }
        do { try plans.acknowledgeRetired(binding) } catch { return .failure(.plans(error)) }
        return .success(())
    }
}
