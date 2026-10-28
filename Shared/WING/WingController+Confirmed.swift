import Foundation

extension WingController {
    func confirmedSnapshot(now: Date = Date()) -> WingConfirmedSnapshot {
        let status: WingConfirmedSnapshot.Status
        if isDemo {
            status = .demo
        } else if !connection.isConnected || sessionID == nil {
            status = .disconnected
        } else if confirmedReceivedAt.isEmpty {
            status = .refreshing
        } else if confirmedReceivedAt.values.contains(where: {
            (0...WingConfirmedSnapshot.maximumAge).contains(now.timeIntervalSince($0))
        }) {
            status = .observed
        } else {
            status = .stale
        }
        return WingConfirmedSnapshot(
            status: status, sessionID: sessionID, capturedAt: now,
            values: confirmedValues, receivedAt: confirmedReceivedAt)
    }

    /// Address replies have no OSC transaction ID. This is a bounded,
    /// incoming-only read after invalidation, not a transactional hardware lock.
    func readFreshConfirmed(
        _ addresses: [String], session: UUID,
        timeout: Duration = .milliseconds(750)
    ) async -> [String: WingValue]? {
        guard !Task.isCancelled, !isDemo, connection.isConnected, sessionID == session else { return nil }
        let addresses = Array(Set(addresses)).sorted()
        guard !addresses.isEmpty else { return [:] }
        let requestedAt = Date()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        invalidateConfirmedValues(addresses)
        // Queries run separately so even a delayed transport send cannot extend
        // the read deadline. Cancellation stops further GETs, never replays SETs.
        let queryTask = Task { [weak self] in
            for address in addresses {
                guard let self, !Task.isCancelled, self.sessionID == session,
                      self.connection.isConnected, ContinuousClock.now < deadline else { return }
                await self.refresh(address)
            }
        }
        defer { queryTask.cancel() }
        while !Task.isCancelled, connection.isConnected, sessionID == session {
            guard ContinuousClock.now < deadline else { return nil }
            if addresses.allSatisfy({ (confirmedReceivedAt[$0] ?? .distantPast) >= requestedAt }) {
                return Dictionary(
                    uniqueKeysWithValues: addresses.compactMap { address in
                        confirmedValues[address].map { (address, $0) }
                    })
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        }
        return nil
    }

    static func isValidMixerValue(_ node: WingNodeRef, value: WingValue, muted: Bool) -> Bool {
        guard node.kind == .channel || node.kind == .main,
              (1...node.kind.count).contains(node.index) else { return false }
        if muted { return value.intValue.map { $0 == 0 || $0 == 1 } ?? false }
        return value.floatValue.map { $0.isFinite && (0...1).contains($0) } ?? false
    }
}
