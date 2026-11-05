import Foundation

// Phase payloads, proposals and commits are built only in this file (fileprivate initializers),
// so callers cannot forge a session state that skipped `start`, `hear` or `confirm` checks.

/// What a session learns into: the target as described at start, the new binding's ID and the
/// eligibility policy, which is re-applied at confirmation.
struct LearnTarget: Hashable, Sendable {
    let descriptor: ParameterDescriptor
    let binding: BindingID
    let policy: LearnEligibilityPolicy

    fileprivate init(descriptor: ParameterDescriptor, binding: BindingID, policy: LearnEligibilityPolicy) {
        self.descriptor = descriptor
        self.binding = binding
        self.policy = policy
    }
}

struct LearnListening: Hashable, Sendable {
    let target: LearnTarget
    let startTick: UInt64
    let timeoutTicks: UInt64

    fileprivate init(target: LearnTarget, startTick: UInt64, timeoutTicks: UInt64) {
        self.target = target
        self.startTick = startTick
        self.timeoutTicks = timeoutTicks
    }
}

/// A heard control proposed for review: a validated candidate binding and every conflict.
struct LearnProposal: Hashable, Sendable {
    let device: DeviceID
    let binding: ControlBinding
    let conflicts: [LearnConflict]

    fileprivate init(device: DeviceID, binding: ControlBinding, conflicts: [LearnConflict]) {
        self.device = device
        self.binding = binding
        self.conflicts = conflicts
    }
}

/// Review has no timeout; it ends only by explicit confirm or cancel.
struct LearnReview: Hashable, Sendable {
    let target: LearnTarget
    let proposal: LearnProposal

    fileprivate init(target: LearnTarget, proposal: LearnProposal) {
        self.target = target
        self.proposal = proposal
    }
}

struct LearnBlocked: Hashable, Sendable {
    let target: ParameterID
    let reason: LearnBlockReason

    fileprivate init(target: ParameterID, reason: LearnBlockReason) {
        self.target = target
        self.reason = reason
    }
}

/// A confirmed Learn: the new binding and the sorted IDs the caller must remove. Learn itself
/// mutates no binding store.
struct LearnCommit: Hashable, Sendable {
    let binding: ControlBinding
    let removing: [BindingID]

    fileprivate init(binding: ControlBinding, removing: [BindingID]) {
        self.binding = binding
        self.removing = removing
    }
}

enum LearnCancellation: Hashable, Sendable {
    case user
    case timedOut
}

enum LearnPhase: Hashable, Sendable {
    case idle
    case listening(LearnListening)
    case awaitingReview(LearnReview)
    case committed(LearnCommit)
    case cancelled(LearnCancellation)
    case blocked(LearnBlocked)

    var kind: LearnPhaseKind {
        switch self {
        case .idle: .idle
        case .listening: .listening
        case .awaitingReview: .awaitingReview
        case .committed: .committed
        case .cancelled: .cancelled
        case .blocked: .blocked
        }
    }

    /// Listening and reviewing sessions are active; every other phase may start a new session.
    var isActive: Bool {
        switch self {
        case .listening, .awaitingReview: true
        case .idle, .committed, .cancelled, .blocked: false
        }
    }
}

/// A pure Learn state machine: idle → listening → awaitingReview → committed | cancelled, or
/// blocked at start. One value runs one session at a time. Time is caller-supplied monotonic
/// ticks; listening times out once `timeoutTicks` have elapsed. A thrown refusal never changes
/// the session, and cancelling leaves no binding behind.
struct LearnSession: Hashable, Sendable {
    static let maximumTimeoutTicks: UInt64 = 3_600_000
    static let maximumPresentDevices = 256

    private(set) var phase: LearnPhase = .idle
    private(set) var lastTick: UInt64 = 0

    /// An idle session.
    public init() {}

    /// Starts listening on `descriptor`, or reports `blocked` when the target is ineligible.
    @discardableResult
    mutating func start(_ descriptor: ParameterDescriptor, binding id: BindingID,
                        policy: LearnEligibilityPolicy, timeoutTicks: UInt64,
                        now: UInt64) throws(LearnRefusal) -> LearnPhase {
        guard !phase.isActive else { throw .sessionInProgress(phase.kind) }
        guard (1...Self.maximumTimeoutTicks).contains(timeoutTicks) else { throw .invalidTimeout(timeoutTicks) }
        try requireMonotonic(now)
        lastTick = now
        if let reason = policy.blockReason(for: descriptor) {
            phase = .blocked(LearnBlocked(target: descriptor.id, reason: reason))
        } else {
            let target = LearnTarget(descriptor: descriptor, binding: id, policy: policy)
            phase = .listening(LearnListening(target: target, startTick: now, timeoutTicks: timeoutTicks))
        }
        return phase
    }

    /// Advances time; a listening session whose deadline has passed is cancelled as timed out.
    @discardableResult
    mutating func advance(to now: UInt64) throws(LearnRefusal) -> LearnPhase {
        try requireMonotonic(now)
        var expired = false
        if case .listening(let listening) = phase { expired = try Self.expired(listening, at: now) }
        lastTick = now
        if expired { phase = .cancelled(.timedOut) }
        return phase
    }

    /// Records the first eligible heard control as a proposal. The deadline is checked first: at
    /// or past it the session times out before any bound, presence or binding check. Otherwise
    /// controls from devices outside `present`, or whose default binding does not fit, are ignored.
    mutating func hear(_ heard: LearnHeardControl, present: Set<DeviceID>, existing: [ControlBinding],
                       now: UInt64) throws(LearnRefusal) -> LearnHearing {
        guard case .listening(let listening) = phase else { throw .notListening(phase.kind) }
        try requireMonotonic(now)
        guard try !Self.expired(listening, at: now) else {
            lastTick = now
            phase = .cancelled(.timedOut)
            return .timedOut
        }
        guard present.count <= Self.maximumPresentDevices else { throw .tooManyPresentDevices(present.count) }
        do { try heard.profile.validate() } catch { throw .invalidProfile(error) }
        let target = listening.target
        let conflicts = try LearnConflicts.find(source: heard.source, target: target.descriptor.id, in: existing)
        lastTick = now
        guard present.contains(heard.device) else { return .ignored(.deviceAbsent(heard.device)) }
        let binding: ControlBinding
        do {
            binding = try LearnDefaults.binding(target.binding, for: heard, on: target.descriptor)
        } catch {
            return .ignored(error)
        }
        let proposal = LearnProposal(device: heard.device, binding: binding, conflicts: conflicts)
        phase = .awaitingReview(LearnReview(target: target, proposal: proposal))
        return .recorded(proposal)
    }

    /// Confirms the reviewed proposal against current host truth. Conflicts are recomputed from
    /// `existing`; by default any conflict refuses, and `replace` must name exactly the conflicts.
    mutating func confirm(_ resolution: LearnConflictResolution = .refuse, descriptor: ParameterDescriptor,
                          existing: [ControlBinding]) throws(LearnRefusal) -> LearnCommit {
        guard case .awaitingReview(let review) = phase else { throw .notAwaitingReview(phase.kind) }
        let expected = review.target.descriptor.id
        guard descriptor.id == expected else { throw .targetMismatch(expected: expected, found: descriptor.id) }
        if let reason = review.target.policy.blockReason(for: descriptor) { throw .targetBlocked(reason) }
        let binding = review.proposal.binding
        do { _ = try binding.validate(against: descriptor) } catch { throw .invalidBinding(error) }
        let conflicts = try LearnConflicts.find(source: binding.source, target: binding.target, in: existing)
        let removing = try LearnConflicts.resolve(resolution, conflicts: conflicts)
        if !removing.contains(binding.id), existing.contains(where: { $0.id == binding.id }) {
            throw .bindingIDInUse(binding.id)
        }
        let commit = LearnCommit(binding: binding, removing: removing)
        phase = .committed(commit)
        return commit
    }

    /// Abandons a listening or reviewing session; no binding is produced.
    mutating func cancel() throws(LearnRefusal) {
        guard phase.isActive else { throw .noActiveSession(phase.kind) }
        phase = .cancelled(.user)
    }

    private func requireMonotonic(_ now: UInt64) throws(LearnRefusal) {
        guard now >= lastTick else { throw .tickRegressed(last: lastTick, now: now) }
    }

    /// Checked, so a broken `startTick > now` invariant refuses instead of trapping.
    private static func expired(_ listening: LearnListening, at now: UInt64) throws(LearnRefusal) -> Bool {
        let (elapsed, overflow) = now.subtractingReportingOverflow(listening.startTick)
        guard !overflow else { throw .tickBeforeStart(start: listening.startTick, now: now) }
        return elapsed >= listening.timeoutTicks
    }
}
