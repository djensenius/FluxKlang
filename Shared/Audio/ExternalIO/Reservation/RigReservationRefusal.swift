//
//  RigReservationRefusal.swift
//  FluxKlang
//
//  The single typed refusal of the rig reservation ledger.
//

/// The ledger operation a phase refusal refers to.
enum RigOperation: String, CaseIterable, Sendable {
    case approve
    case recordBaseline
    case startExperiment
    case stopExperiment
    case reportRestoration
    case release
}

/// Why a rig reservation operation was refused. A refusal produces no new ledger value, so nothing changes.
///
/// Payloads are validated tokens (at most 64 bytes), enum cases and integer counts only: never owner free text,
/// file paths, payloads or a `String(describing:)` of an error.
enum RigReservationRefusal: Error, Hashable, Sendable {
    case invalidToken(field: RigTokenField, fault: RigTokenFault)
    case invalidInstant(seconds: Int)
    case windowEmpty(start: Int, end: Int)
    case windowTooLong(seconds: Int)
    case invalidSampleRate(Int)
    case invalidBufferFrames(Int)
    case duplicateStopCondition(RigStopCondition)
    case stopConditionMissing(RigStopCondition)
    case timeWentBackwards(last: Int, got: Int)
    case windowAlreadyEnded(end: Int, now: Int)
    case windowExpired(reservation: RigToken)
    case duplicateReservation(RigToken)
    case conflictingReservation(existing: RigToken, rig: RigToken)
    case ledgerFull(count: Int)
    case unknownReservation(RigToken)
    case invalidPhase(reservation: RigToken, phase: RigReservationPhase, operation: RigOperation)
    case duplicateApproval(reservation: RigToken, kind: RigApprovalKind)
    case baselineAlreadyRecorded(reservation: RigToken)
    case baselineMissing(reservation: RigToken)
    case outsideWindow(reservation: RigToken)
    case approvalMissing(reservation: RigToken, kind: RigApprovalKind)
    case duplicateExperiment(experiment: RigToken)
    case tooManyExperiments(reservation: RigToken, count: Int)
    case experimentAlreadyActive(reservation: RigToken)
    case lockBusy(rig: RigToken)
    case lockUnavailable(rig: RigToken)
    case lockNotHeld(rig: RigToken)
    case restorationNotVerified(reservation: RigToken, phase: RigReservationPhase)
    case noActiveExperiment
}
