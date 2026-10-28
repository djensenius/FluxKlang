import Foundation
import Observation

/// Revokes reviewed final-send permissions on material incoming evidence changes.
/// Identical GET replies and optimistic SET cache updates are not changes. Initial
/// observations of unrelated addresses cannot invalidate an already reviewed target.
@MainActor
@Observable
final class WingAssistantActionEvidence {
    private(set) var revision = 0
    @ObservationIgnored private var lastValues: [String: WingValue] = [:]

    func record(_ address: String, value: WingValue) {
        guard WingLiveObservations.addresses.contains(address)
            || ((address.hasPrefix("/ch/") || address.hasPrefix("/main/"))
                && ["/name", "/fdr", "/mute"].contains(where: { address.hasSuffix($0) })) else { return }
        if let previous = lastValues[address], previous != value { revision += 1 }
        lastValues[address] = value
    }

    func reset() {
        lastValues = [:]
        revision += 1
    }
}
