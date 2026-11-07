//
//  RigReservation.swift
// swiftlint:disable identifier_name
//  FluxKlang
//
//  One reservation of the rig: its identity, window, approvals, baseline, phase and experiment records.
//

/// A request to reserve a rig for a window.
struct RigBookingRequest: Hashable, Sendable {
    let id: RigToken
    let rig: RigToken
    let owner: RigToken
    let window: RigWindow
}

/// Where a reservation is in the exclusive rig protocol.
enum RigReservationPhase: String, CaseIterable, Sendable {
    /// No lock held, no experiment yet.
    case booked
    /// Lock held, one active experiment.
    case running
    /// Experiment stopped, restoration unverified, lock held.
    case restoring
    /// Restoration mismatch reported, lock held, operator resolution needed.
    case unresolved
    /// Restoration verified, lock held, idle.
    case restored
    /// Terminal; the lock is released or was never taken.
    case released

    /// True for `running`, `restoring` and `unresolved`: the phases that own the single active experiment.
    var hasActiveExperiment: Bool {
        switch self {
        case .running, .restoring, .unresolved:
            return true
        case .booked, .restored, .released:
            return false
        }
    }
}

/// The identifiers recorded with every physical measurement of the single active experiment.
struct RigMeasurementStamp: Hashable, Sendable {
    let reservation: RigToken
    let experiment: RigToken
    let rig: RigToken
    let owner: RigToken
    let kind: RigExperimentKind
}

/// One reservation. Its only starting state is `init(booking:)` (phase `booked`); every later state is reached through
/// the transition methods below, each of which checks its own phase rule. The ledger adds the ledger-wide rules.
struct RigReservation: Hashable, Sendable {
    let id: RigToken
    let rig: RigToken
    let owner: RigToken
    let window: RigWindow
    private(set) var approvals: [RigApproval]
    private(set) var baseline: RigBaseline?
    private(set) var phase: RigReservationPhase
    /// Experiment records in start order; at most `maximumExperimentsPerReservation`.
    private(set) var experiments: [RigExperimentRecord]
    /// How many baseline fields the last restoration report disagreed on; 0 unless `unresolved`.
    private(set) var unresolvedFieldCount: Int

    init(booking request: RigBookingRequest) {
        id = request.id
        rig = request.rig
        owner = request.owner
        window = request.window
        approvals = []
        baseline = nil
        phase = .booked
        experiments = []
        unresolvedFieldCount = 0
    }

    func approval(of kind: RigApprovalKind) -> RigApproval? {
        approvals.first { $0.kind == kind }
    }

    /// The reservation's lock request: its rig, held by its id.
    var lockRequest: RigLockRequest {
        RigLockRequest(rig: rig, holder: id)
    }

    private func phaseRefusal(_ operation: RigOperation) -> RigReservationRefusal {
        .invalidPhase(reservation: id, phase: phase, operation: operation)
    }

    // MARK: Approvals and baseline

    /// Refusals, in order: released phase, `at >= window.end`, a second approval of the same kind.
    mutating func approve(kind: RigApprovalKind, approver: RigToken, at: RigInstant) throws(RigReservationRefusal) {
        guard phase != .released else { throw phaseRefusal(.approve) }
        guard at < window.end else { throw .windowExpired(reservation: id) }
        guard approval(of: kind) == nil else { throw .duplicateApproval(reservation: id, kind: kind) }
        approvals.append(RigApproval(kind: kind, approver: approver, at: at))
        approvals.sort { $0.kind.sortIndex < $1.kind.sortIndex }
    }

    /// Refusals, in order: phase other than `booked`, `at >= window.end`, a baseline already recorded.
    mutating func recordBaseline(_ value: RigBaseline, at: RigInstant) throws(RigReservationRefusal) {
        guard phase == .booked else { throw phaseRefusal(.recordBaseline) }
        guard at < window.end else { throw .windowExpired(reservation: id) }
        guard baseline == nil else { throw .baselineAlreadyRecorded(reservation: id) }
        baseline = value
    }

    // MARK: Experiments

    /// The reservation-local start checks, in order: phase `booked` or `restored`, `at` inside the window, a baseline,
    /// every approval the plan's kind requires.
    func requireStartable(kind: RigExperimentKind, at: RigInstant) throws(RigReservationRefusal) {
        guard phase == .booked || phase == .restored else { throw phaseRefusal(.startExperiment) }
        guard window.contains(at) else { throw .outsideWindow(reservation: id) }
        guard baseline != nil else { throw .baselineMissing(reservation: id) }
        if let missing = kind.requiredApprovals.first(where: { approval(of: $0) == nil }) {
            throw .approvalMissing(reservation: id, kind: missing)
        }
    }

    /// Refuses when the reservation already holds the maximum number of experiment records.
    func requireExperimentCapacity() throws(RigReservationRefusal) {
        guard experiments.count < RigReservationLimits.maximumExperimentsPerReservation else {
            throw .tooManyExperiments(reservation: id, count: experiments.count)
        }
    }

    /// Whether the next start must take the lock: only from `booked`; `restored` already holds it.
    var needsLockForStart: Bool { phase == .booked }

    /// Appends the experiment record and enters `running`. Call only after every start check passed.
    mutating func beginExperiment(_ plan: RigExperimentPlan, at: RigInstant) {
        experiments.append(RigExperimentRecord(id: plan.id, kind: plan.kind, startedAt: at))
        phase = .running
        unresolvedFieldCount = 0
    }

    /// Records the stop of the running experiment and enters `restoring`; the lock stays held.
    mutating func stopExperiment(reason: RigStopReason, at: RigInstant) throws(RigReservationRefusal) {
        guard phase == .running else { throw phaseRefusal(.stopExperiment) }
        guard let last = experiments.popLast() else { throw .noActiveExperiment }
        experiments.append(last.stopped(reason: reason, at: at))
        phase = .restoring
    }

    /// Compares `observed` with the recorded baseline: equal gives `restored`, otherwise `unresolved` with the
    /// differing field count (a successful report, not a refusal).
    mutating func reportRestoration(observed: RigBaseline) throws(RigReservationRefusal) {
        guard phase == .restoring || phase == .unresolved else { throw phaseRefusal(.reportRestoration) }
        guard let recorded = baseline else { throw .baselineMissing(reservation: id) }
        let differing = observed.differingFieldCount(from: recorded)
        unresolvedFieldCount = differing
        phase = differing == 0 ? .restored : .unresolved
    }

    // MARK: Release

    /// Whether releasing needs the lock released through the port. Refusals, in order: already `released`; an
    /// active phase (`restorationNotVerified`). `booked` never took the lock (false); `restored` holds it (true).
    func releaseNeedsLock() throws(RigReservationRefusal) -> Bool {
        switch phase {
        case .released:
            throw phaseRefusal(.release)
        case .running, .restoring, .unresolved:
            throw .restorationNotVerified(reservation: id, phase: phase)
        case .booked:
            return false
        case .restored:
            return true
        }
    }

    /// Enters the terminal `released` phase. Call only after `releaseNeedsLock` and any port call succeeded.
    mutating func markReleased() {
        phase = .released
    }

    /// The record of the experiment that is running, restoring or unresolved, if any.
    var activeExperiment: RigExperimentRecord? {
        phase.hasActiveExperiment ? experiments.last : nil
    }
}

extension RigApprovalKind {
    /// Position in case order, used to keep approvals sorted without relying on sort stability.
    fileprivate var sortIndex: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}
// swiftlint:enable identifier_name
