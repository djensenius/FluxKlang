import Synchronization

/// Off-callback only. One waiter, no queue. The task owns this state, never the delivery owner while idle.
final class MIDIConsumerWake: Sendable {
    private struct State {
        var active = false
        var finished = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    var isWaiting: Bool { state.withLock { $0.waiter != nil } }

    func setActive(_ active: Bool) {
        let waiter = state.withLock { state in
            state.active = active
            guard active else { return Optional<CheckedContinuation<Void, Never>>.none }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func finish() {
        let waiter = state.withLock { state in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state in
                    if state.active || state.finished { return true }
                    precondition(state.waiter == nil)
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            self.finish()
        }
    }
}

/// One reusable main-actor driver per input, made before connecting. Only active delivery sleeps at 2 ms.
@MainActor
final class MIDICallbackDelivery {
    private let wake = MIDIConsumerWake()
    private var consumer: Task<Void, Never>?
    private var session: MIDICallbackIngress?
    private var handler: (@MainActor (MIDIPacketBatch) -> Void)?
    private var reconcile: (@MainActor () -> Void)?
    private var pending: MIDIIngressDescriptor?

    /// Manual turns exercise the exact consumer without clocks or native I/O.
    init(automaticallyDrive: Bool = true) {
        if automaticallyDrive {
            consumer = Task { @MainActor [weak self, wake] in
                while !Task.isCancelled {
                    await wake.wait()
                    guard !Task.isCancelled, self != nil else { return }
                    self?.tick()
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                }
            }
        }
    }

    deinit {
        wake.finish()
        consumer?.cancel()
        session?.close()
    }

    var isIdleWaiting: Bool { wake.isWaiting }

    func start(
        _ session: MIDICallbackIngress,
        reconcile: @escaping @MainActor () -> Void,
        handler: @escaping @MainActor (MIDIPacketBatch) -> Void
    ) {
        stop()
        self.session = session
        self.reconcile = reconcile
        self.handler = handler
        wake.setActive(true)
    }

    func stop() {
        session?.close()
        session = nil
        handler = nil
        reconcile = nil
        pending = nil
        wake.setActive(false)
    }

    /// At most 64 batches / 65,536 bytes; a popped descriptor may be held without acknowledging its payload.
    func tick() {
        guard let session else { return }
        if session.takeSourcesChanged() { reconcile?() }
        guard self.session === session else { return }
        var bytes = 0
        for _ in 0..<64 {
            if pending == nil { pending = session.storage.descriptors.tryPop() }
            guard let descriptor = pending else { return }
            guard descriptor.byteCount <= MIDICallbackIngress.maximumBytes - bytes else { return }
            pending = nil
            let batch = session.storage.copyAndAcknowledge(descriptor)
            bytes += descriptor.byteCount
            handler?(batch)
            guard self.session === session else { return }
        }
    }
}
