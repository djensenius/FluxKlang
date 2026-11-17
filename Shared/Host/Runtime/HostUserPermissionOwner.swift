import Observation

/// Permission gestures only, not an authority or a lifecycle owner. Production
/// permission producers use `shared`; canonical APIs remain available internally.
@MainActor @Observable
final class HostUserPermissionOwner {
    static let shared = HostUserPermissionOwner(owner: .shared)

    enum Gesture: Sendable { case grant, revoke }
    enum Outcome: Equatable, Sendable { case granted, revoked, revisionExhausted }
    enum Presence: Equatable, Sendable { case present, absent }

    /// Historical completion information, never an authorization input.
    struct Report: Equatable, Sendable {
        let outcome: Outcome
        let lastChecked: Presence
    }

    struct Completion: Sendable {
        fileprivate let task: Task<Report, Never>
        var value: Report { get async { await task.value } }
    }

    enum Submission {
        case accepted(Completion)
        case busy
    }

    private let owner: HostAuthorityOwner
    @ObservationIgnored private var admissionReserved = false
    private(set) var isBusy = false
    private(set) var report: Report?

    /// Tests inject an isolated real owner. Construction performs no permission action/read.
    init(owner: HostAuthorityOwner) {
        self.owner = owner
    }

    @discardableResult
    func submit(_ gesture: Gesture) -> Submission {
        guard !admissionReserved else { return .busy }
        // Observation's synchronous willSet callbacks can resubmit before isBusy changes.
        admissionReserved = true
        isBusy = true
        let task = Task {
            let outcome: Outcome
            switch gesture {
            case .grant:
                switch await owner.grant(.host) {
                case .success: outcome = .granted
                case .failure(.revisionExhausted): outcome = .revisionExhausted
                }
            case .revoke:
                await owner.revoke()
                outcome = .revoked
            }
            // Discard the fingerprint. Even this observation may be superseded on resume.
            let presence: Presence = await owner.authority.snapshot().live.permission == nil ? .absent : .present
            let completed = Report(outcome: outcome, lastChecked: presence)
            report = completed
            isBusy = false
            admissionReserved = false
            return completed
        }
        // The task retains this facade until publication AND the snapshot/report finish.
        return .accepted(Completion(task: task))
    }
}
