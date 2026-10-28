import Foundation

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
