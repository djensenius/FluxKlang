import Foundation
import Observation

/// Planned controller replacement and outer-root detach share one FIFO, not authority.
@MainActor
@Observable
final class HostWingLifecycle {
    enum Success: Equatable, Sendable {
        case connected(UUID)
        case demo
        case disconnected
        case acceptanceFailure
    }

    enum Failure: Equatable, Sendable {
        case initialRelease(HostAuthorityRefusal)
        case cancelled
        case connection(String)
        case superseded
        case publishedIdentityChanged(cleanupRefusal: HostAuthorityRefusal?)

        var message: String {
            switch self {
            case .initialRelease:
                "The previous connection was stopped. No replacement was started because host release was refused."
            case .cancelled:
                "Connection change cancelled."
            case .connection(let reason):
                reason
            case .superseded:
                "The replacement controller changed before publication and was stopped."
            case .publishedIdentityChanged(let refusal):
                "A replacement connection was published, then stopped after its identity changed."
                    + (refusal == nil ? "" : " Host-session cleanup was refused.")
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case success(Success)
        case failure(Failure)

        var succeeded: Bool {
            if case .success = self { return true }
            return false
        }

        var failureMessage: String? {
            guard case .failure(let failure) = self else { return nil }
            return failure.message
        }
    }

    struct Operation {
        let stopOld: @MainActor () async -> Void
        let start: @MainActor () async -> Candidate
    }

    struct Candidate {
        let outcome: Outcome
        /// Live success must check both controller identity and exact connected session.
        let isCurrent: @MainActor () -> Bool
        let stop: @MainActor () async -> Void
        let finish: @MainActor () async -> Void
    }

    struct Completion {
        fileprivate let task: Task<Void, Never>

        func wait() async { await task.value }
    }

    @MainActor
    private final class Turn {
        var ready = false
        var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            if !ready { await withCheckedContinuation { waiter = $0 } }
        }

        func grant() {
            ready = true
            waiter?.resume()
            waiter = nil
        }
    }

    let owner: HostAuthorityOwner?
    private(set) var isBusy = false
    /// Historical presentation only; never used for admission or current connection state.
    private(set) var lastReplacementOutcome: Outcome?
    @ObservationIgnored private var reserved = false
    @ObservationIgnored private var waiting: [Turn] = []

    init(owner: HostAuthorityOwner? = nil) {
        self.owner = owner
    }

    /// Called immediately after controller assignment. Never discard the caller's
    /// retained candidate: it still supplies cleanup when this skips transport start.
    static func startUnlessCancelled(_ start: @MainActor () async -> Outcome) async -> Outcome {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        return await start()
    }

    func replace(makeOperation: @MainActor () -> Operation) async -> Outcome {
        let turn = reserve()
        await turn.wait()
        let outcome: Outcome
        if Task.isCancelled {
            outcome = .failure(.cancelled)
        } else {
            outcome = await perform(makeOperation())
        }
        lastReplacementOutcome = outcome
        handoff()
        return outcome
    }

    /// Submission is synchronous, including reservation before any Observation callback.
    /// The task retains this sequencer until the actual owner call has completed.
    @discardableResult
    func detach(_ window: WindowID) -> Completion {
        let turn = reserve()
        return Completion(task: Task {
            await turn.wait()
            await owner?.windowClosed(window)
            handoff()
        })
    }

    private func reserve() -> Turn {
        let turn = Turn()
        if reserved {
            waiting.append(turn)
        } else {
            reserved = true
            turn.grant()
            isBusy = true
        }
        return turn
    }

    private func handoff() {
        if waiting.isEmpty { isBusy = false }
        // Reset/report observers may synchronously submit more work. Never use a
        // pre-notification queue snapshot or expose an unreserved notification.
        if waiting.isEmpty {
            reserved = false
        } else {
            if !isBusy { isBusy = true }
            waiting.removeFirst().grant()
        }
    }

    private func perform(_ operation: Operation) async -> Outcome {
        let released = await owner?.disconnected()
        await operation.stopOld()
        if case .failure(let refusal)? = released {
            return .failure(.initialRelease(refusal))
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let candidate = await operation.start()
        guard !Task.isCancelled else {
            await candidate.stop()
            return .failure(.cancelled)
        }
        let current = candidate.isCurrent()
        guard !Task.isCancelled else {
            await candidate.stop()
            return .failure(.cancelled)
        }
        guard current else {
            await candidate.stop()
            return .failure(.superseded)
        }
        // This cancellation/identity check is the commit boundary. Later
        // cancellation alone must not undo a successful publication.
        if case .success(.connected(let session)) = candidate.outcome, let owner {
            await owner.connected(session: session)
            guard candidate.isCurrent() else {
                await candidate.stop()
                let cleanup = await owner.disconnected()
                if case .failure(let refusal) = cleanup {
                    return .failure(.publishedIdentityChanged(cleanupRefusal: refusal))
                }
                return .failure(.publishedIdentityChanged(cleanupRefusal: nil))
            }
        }
        if candidate.outcome.succeeded { await candidate.finish() }
        return candidate.outcome
    }
}
