//
//  RigExperiment.swift
// swiftlint:disable identifier_name
//  FluxKlang
//
//  Experiment kinds, plans and the records a reservation keeps of started and stopped experiments.
//

/// The kind of physical experiment. Case order is the order of the table in `requiredApprovals`.
enum RigExperimentKind: String, CaseIterable, Sendable {
    case analogLoopback
    case digitalCalibration
    case avEnginePilot
    case directIOPilot
    case rustPilot
    case midiOscExercise
    case clockExercise
    case soak
    case wingProcedure

    /// The approvals that must all be on the reservation before this kind may start, in approval case order.
    var requiredApprovals: [RigApprovalKind] {
        switch self {
        case .analogLoopback, .avEnginePilot, .directIOPilot, .rustPilot:
            return [.audibility, .mappings, .restoration]
        case .digitalCalibration, .midiOscExercise:
            return [.mappings, .restoration]
        case .clockExercise:
            return [.clockChange, .configChange, .restoration]
        case .soak:
            return [.audibility, .mappings, .clockChange, .restoration]
        case .wingProcedure:
            return [.mappings, .configChange, .restoration]
        }
    }
}

/// An experiment to run: an id, a kind and the complete list of stop conditions (stored in case order).
struct RigExperimentPlan: Hashable, Sendable {
    let id: RigToken
    let kind: RigExperimentKind
    private(set) var stopConditions: [RigStopCondition]

    /// Refusals, in order: the first duplicate in INPUT order is `.duplicateStopCondition`; then the first condition
    /// missing in CASE order is `.stopConditionMissing`. A plan must list all seven conditions exactly once.
    init(
        id: RigToken,
        kind: RigExperimentKind,
        stopConditions: [RigStopCondition]
    ) throws(RigReservationRefusal) {
        var seen: [RigStopCondition] = []
        for condition in stopConditions {
            if seen.contains(condition) {
                throw .duplicateStopCondition(condition)
            }
            seen.append(condition)
        }
        if let missing = RigStopCondition.allCases.first(where: { !seen.contains($0) }) {
            throw .stopConditionMissing(missing)
        }
        self.id = id
        self.kind = kind
        self.stopConditions = RigStopCondition.allCases
    }
}

/// When and why an experiment stopped.
struct RigStopRecord: Hashable, Sendable {
    let reason: RigStopReason
    let at: RigInstant
}

/// One experiment a reservation started; `stop` is nil while it is still running.
struct RigExperimentRecord: Hashable, Sendable {
    let id: RigToken
    let kind: RigExperimentKind
    let startedAt: RigInstant
    private(set) var stop: RigStopRecord?

    init(id: RigToken, kind: RigExperimentKind, startedAt: RigInstant) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.stop = nil
    }

    func stopped(reason: RigStopReason, at: RigInstant) -> RigExperimentRecord {
        var copy = self
        copy.stop = RigStopRecord(reason: reason, at: at)
        return copy
    }
}
// swiftlint:enable identifier_name
