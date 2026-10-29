import Foundation
import Observation

/// Current-session last observations survive verification-cache invalidation so
/// stale metadata remains inspectable, but never becomes fresh evidence again.
@MainActor
@Observable
final class WingLiveObservations {
    private(set) var values: [String: WingValue] = [:]
    private(set) var receivedAt: [String: Date] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    deinit { refreshTask?.cancel() }

    func record(_ message: WingIncoming, value: WingValue) {
        guard Self.addresses.contains(message.address) else { return }
        values[message.address] = value
        receivedAt[message.address] = message.receivedAt
    }

    func reset() { values = [:]; receivedAt = [:] }
    func stop() { refreshTask?.cancel(); refreshTask = nil }

    func start(controller: WingController, interval: Duration = .seconds(15)) {
        stop()
        guard !controller.isDemo, let session = controller.sessionID,
              interval > .zero, interval < .seconds(30) else { return }
        refreshTask = Task { [weak controller] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let currentSession = controller?.sessionID, currentSession == session else { return }
                await controller?.refreshLiveObservationMetadata(session: session)
            }
        }
    }

    static let addresses: [String] = (1...24).map(WingAddress.inputName) + (1...40).flatMap {
        [WingAddress.name(.channel, $0), WingAddress.channelSourceGroup($0), WingAddress.channelSourceIndex($0)]
    }
}

extension WingController {
    /// Background metadata polling is GET-only and must never invalidate the
    /// shared confirmations used by Listen or Temporary Move verification.
    func refreshLiveObservationMetadata(session: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        for (offset, address) in WingLiveObservations.addresses.enumerated() {
            guard !Task.isCancelled, !isDemo, connection.isConnected, sessionID == session,
                  ContinuousClock.now < deadline else { return }
            await refresh(address)
            if (offset + 1).isMultiple(of: WingNetwork.bulkRefreshBatchSize) {
                do { try await Task.sleep(for: WingNetwork.bulkRefreshBatchDelay) } catch { return }
            }
        }
    }
}
