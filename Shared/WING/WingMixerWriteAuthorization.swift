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
    private var consumed = false
    private let allowed: WingSetting?
    private let allowedNode: WingNodeRef?
    private let allowedMute: Bool?

    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
        allowed = nil
        allowedNode = nil
        allowedMute = nil
    }

    /// Reviewed actions bind the single-use token to exactly one address/value.
    init(deadline: ContinuousClock.Instant, node: WingNodeRef, value: WingValue, muted: Bool) {
        self.deadline = deadline
        allowedNode = node
        allowedMute = muted
        allowed = WingSetting(address: muted ? WingAddress.mute(node.kind, node.index)
                                           : WingAddress.fader(node.kind, node.index), value: value)
    }

    var wasConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return consumed
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }

    func consume(_ send: () throws -> Void) throws {
        try consume(node: nil, value: nil, muted: nil, send)
    }

    func consume(node: WingNodeRef?, value: WingValue?, muted: Bool?, _ send: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard valid, !Task.isCancelled, ContinuousClock.now < deadline,
              allowed == nil || (node == allowedNode && value == allowed?.value && muted == allowedMute) else {
            valid = false
            throw WingTransportError.notAuthorized
        }
        valid = false
        consumed = true
        try send()
    }
}
