import Foundation
import Observation

/// Revokes reviewed final-send permissions on material incoming evidence changes.
/// Identical GET replies and optimistic SET cache updates are not changes. Initial
/// observations of unrelated addresses cannot invalidate an already reviewed target.
@MainActor
@Observable
final class WingAssistantActionEvidence {
    private(set) var revision = 0
    private var resetRevision = 0
    @ObservationIgnored private var lastValues: [String: WingValue] = [:]
    @ObservationIgnored private var addressRevisions: [String: AddressRevision] = [:]

    @Observable
    fileprivate final class AddressRevision {
        var value = 0
    }

    /// Observe metadata and remaining baselines, not completed members' expected SET echoes.
    /// Per-address counters still revoke on ABA, even when the final value matches again.
    func observeChanges(at addresses: [String]) {
        _ = resetRevision
        for address in addresses {
            let counter = addressRevisions[address] ?? AddressRevision()
            addressRevisions[address] = counter
            _ = counter.value
        }
    }

    func record(_ address: String, value: WingValue) {
        guard WingLiveObservations.addresses.contains(address)
            || ((address.hasPrefix("/ch/") || address.hasPrefix("/main/"))
                && ["/name", "/fdr", "/mute"].contains(where: { address.hasSuffix($0) })) else { return }
        if let previous = lastValues[address], previous != value {
            revision += 1
            addressRevisions[address]?.value += 1
        }
        lastValues[address] = value
    }

    func reset() {
        lastValues = [:]
        addressRevisions = [:]
        resetRevision += 1
        revision += 1
    }
}
