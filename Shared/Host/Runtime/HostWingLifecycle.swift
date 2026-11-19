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
        /// The WING state re-read for a published `.connected(session)` (#62 AU8d); true only when it
        /// succeeded on that session. The default never verifies, so an unwired candidate stays recovering.
        var reread: @MainActor (UUID) async -> Bool = { _ in false }
    }

    struct Completion {
        fileprivate let fence: Task<Void, Never>
        fileprivate let task: Task<Void, Never>

        /// Joins only the early fence of the window's in-flight applies, not the detach itself.
        func fenced() async { await fence.value }

        func wait() async {
            await fence.value
            await task.value
        }
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
    /// Count of submitted detaches across all windows, never reset: the generation a detach fences and
    /// closes with and an `open` reopens with. A scalar, so it holds no per-window state.
    @ObservationIgnored private var detachSubmissions: UInt64 = 0
    /// The latest published connect's state re-read. It holds no FIFO turn; the next replacement cancels it.
    /// Readable only so tests can await it.
    @ObservationIgnored private(set) var reread: Task<Void, Never>?

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
    /// The fence is a task started at submission (a MainActor job, then one owner hop); it also closes
    /// `window` until `open`. The detach itself waits for its FIFO turn, then for its fence.
    @discardableResult
    func detach(_ window: WindowID) -> Completion {
        let owner = owner
        detachSubmissions += 1
        let generation = detachSubmissions
        let fence = Task { if let owner { await owner.fenceApplies(for: window, generation: generation) } }
        let turn = reserve()
        return Completion(fence: fence, task: Task {
            await turn.wait()
            await fence.value
            await owner?.windowClosed(window, generation: generation)
            handoff()
        })
    }

    /// Reopens `window` on its own FIFO turn, so a detach queued before it closes it first. A detach
    /// submitted after it wins: whether its fence lands before or after this turn's owner hop, the owner
    /// keeps `window` closed against this open's older submission generation. No fence.
    @discardableResult
    func open(_ window: WindowID) -> Completion {
        let owner = owner
        let submitted = detachSubmissions
        let turn = reserve()
        return Completion(fence: Task {}, task: Task {
            await turn.wait()
            // Awaited before handoff: a later detach's close may prune only after this open has landed.
            await owner?.windowOpened(window, generation: submitted)
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
        reread?.cancel()
        reread = nil
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
        if case .success(.connected(let session)) = candidate.outcome, let owner {
            startReread(candidate, session: session, owner: owner)
        }
        return candidate.outcome
    }

    /// Verifies the published `session` without holding the turn: the owner hears only a re-read that
    /// succeeded, was not cancelled, and whose candidate is still current on `session` (#62 AU8d).
    private func startReread(_ candidate: Candidate, session: UUID, owner: HostAuthorityOwner) {
        reread = Task {
            guard await candidate.reread(session), !Task.isCancelled else { return }
            guard candidate.isCurrent() else { return }
            await owner.verifiedReconnect(session: session)
        }
    }
}

/// Studio Apply's route to the WING (#62 AU8c-2; host-authority-sources.md decisions 2, 5, 6 and 8).
/// Only Demo Mode keeps the ungated apply, and it never touches the owner. A real session applies only
/// through the gated overload, on the session `beginApply` returned for the applying root window, with
/// one production minter per apply. A refusal before the first mint sends nothing, and a refused mint
/// never falls back to the ungated path.
@MainActor
enum StudioApplyRoute {
    /// Why a real-session apply stopped before its first mint; nothing was sent.
    enum Refusal: Error, Equatable, Sendable {
        /// No host authority owner: only previews and tests build an `AppModel` without one.
        case noOwner
        case noWindow
        /// No Host role was granted in this launch (decision 2).
        case notGranted
        case apply(HostAuthorityOwner.ApplyRefusal)
        /// The owner's session is not the controller's.
        case sessionMismatch

        var details: String {
            switch self {
            case .noOwner: "Host authority is unavailable. Nothing was sent."
            case .noWindow: "Apply needs an open window. Nothing was sent."
            case .notGranted: "Grant Host role before applying to WING. Nothing was sent."
            case .apply(.noSession): "WING is not connected. Nothing was sent."
            case .apply(.otherWindowRenders): "Another window renders to WING; apply there. Nothing was sent."
            case .apply(.windowClosed): "This window is not open. Nothing was sent."
            case .apply(.authority): "The host refused this apply. Nothing was sent."
            case .sessionMismatch: "The WING session changed. Nothing was sent."
            }
        }

        /// Nothing was confirmed: the gated apply's failed verdict for its `expected` settings.
        func verdict(_ expected: [WingSetting]) -> WingApplyVerification {
            WingApplyVerification(state: .failed, settings: expected, confirmedCount: 0, details: details)
        }
    }

    static func apply(_ settings: [WingSetting], safetySettings: [WingSetting], on wing: WingController,
                      owner: HostAuthorityOwner?, window: WindowID?) async -> WingApplyVerification {
        guard !wing.isDemo else { return await wing.applyAndVerify(settings, safetySettings: safetySettings) }
        let expected = { wing.directApplyPlan(settings, safetySettings: safetySettings).expected }
        guard let owner else { return Refusal.noOwner.verdict(expected()) }
        guard let window else { return Refusal.noWindow.verdict(expected()) }
        // A read-only check, so an ungranted tap claims no rendering for its window.
        guard await owner.permission != nil else { return Refusal.notGranted.verdict(expected()) }
        let session: UUID
        switch await owner.beginApply(window: window) {
        case .success(let begun): session = begun
        case .failure(let refusal): return Refusal.apply(refusal).verdict(expected())
        }
        guard wing.sessionID == session else { return Refusal.sessionMismatch.verdict(expected()) }
        let minter = WingApplyGrantMinter(
            authority: owner.authority, project: owner.studio, window: window,
            budget: wing.directApplyBudget(settings, safetySettings: safetySettings), provider: owner.provider
        )
        return await wing.applyAndVerify(settings, safetySettings: safetySettings, session: session, minting: minter)
    }
}
