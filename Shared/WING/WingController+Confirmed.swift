import Foundation

extension WingController {
    func confirmedSnapshot(now: Date = Date()) -> WingConfirmedSnapshot {
        let status: WingConfirmedSnapshot.Status
        if isDemo {
            status = .demo
        } else if !connection.isConnected || sessionID == nil {
            status = .disconnected
        } else if liveObservations.receivedAt.isEmpty {
            status = .refreshing
        } else if liveObservations.receivedAt.values.contains(where: {
            (0...WingConfirmedSnapshot.maximumAge).contains(now.timeIntervalSince($0))
        }) {
            status = .observed
        } else {
            status = .stale
        }
        return WingConfirmedSnapshot(
            status: status, sessionID: sessionID, capturedAt: now,
            values: liveObservations.values.merging(confirmedValues, uniquingKeysWith: { _, fresh in fresh }),
            receivedAt: liveObservations.receivedAt.merging(
                confirmedReceivedAt, uniquingKeysWith: { _, fresh in fresh }))
    }

    /// Address replies have no OSC transaction ID. This is a bounded,
    /// incoming-only read requiring new replies, not a transactional hardware lock.
    func readFreshConfirmed(
        _ addresses: [String], session: UUID,
        timeout: Duration = .milliseconds(750)
    ) async -> [String: WingValue]? {
        guard !Task.isCancelled, !isDemo, connection.isConnected, sessionID == session else { return nil }
        let addresses = Array(Set(addresses)).sorted()
        guard !addresses.isEmpty else { return [:] }
        let requestedAt = Date()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // Keep shared Listen/Temporary Move confirmations intact. Only replies
        // received after requestedAt can satisfy this independent read.
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

    func refreshLiveReferences(_ references: [AssistantLiveReference]) async -> Bool {
        guard !references.isEmpty else { return true }
        guard let session = sessionID, references.allSatisfy({ $0.sessionID == session }) else { return false }
        let addresses = references.flatMap { reference -> [String] in
            if reference.kind == .localInput { return [WingAddress.inputName(reference.index)] }
            var addresses = [
                WingAddress.name(.channel, reference.index), WingAddress.channelSourceGroup(reference.index),
                WingAddress.channelSourceIndex(reference.index)
            ]
            if reference.sourceGroup == WingSourceGroup.local.rawValue, let index = reference.sourceIndex {
                addresses.append(WingAddress.inputName(index))
            }
            return addresses
        }
        return await readFreshConfirmed(addresses, session: session) != nil
    }

    nonisolated static func isValidMixerValue(_ node: WingNodeRef, value: WingValue, muted: Bool) -> Bool {
        guard node.kind == .channel || node.kind == .main,
              (1...node.kind.count).contains(node.index) else { return false }
        if muted { return value.intValue.map { $0 == 0 || $0 == 1 } ?? false }
        return value.floatValue.map { $0.isFinite && (0...1).contains($0) } ?? false
    }
}
