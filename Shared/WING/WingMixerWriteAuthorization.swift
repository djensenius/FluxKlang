import Foundation

/// Watch only the incoming baseline used by each queued relative SET.
@MainActor
final class WingMixerBaselineAuthorizations {
    private struct Baseline {
        let address: String
        let value: WingValue
        let authorization: WingMixerWriteAuthorization
    }

    private var pending: [UUID: Baseline] = [:]

    func register(address: String, value: WingValue?, authorization: WingMixerWriteAuthorization) -> UUID? {
        guard let value else { return nil }
        let id = UUID()
        pending[id] = Baseline(address: address, value: value, authorization: authorization)
        return id
    }

    func remove(_ id: UUID?) {
        if let id { pending.removeValue(forKey: id) }
    }

    func record(_ address: String, value: WingValue) {
        for baseline in pending.values where baseline.address == address && baseline.value != value {
            baseline.authorization.invalidate()
        }
    }
}

/// One-shot permission for a single mixer SET. Revocation and the physical send
/// share a lock: a queued actor hop cannot outlive cancellation, observed target
/// invalidation, or the monotonic freshness deadline. The body must not suspend.
final class WingMixerWriteAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var valid = true

    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }

    func consume(_ send: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard valid, !Task.isCancelled, ContinuousClock.now < deadline else {
            valid = false
            throw WingTransportError.notAuthorized
        }
        valid = false
        try send()
    }
}
