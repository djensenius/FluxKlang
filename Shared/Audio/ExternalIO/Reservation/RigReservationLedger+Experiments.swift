//
//  RigReservationLedger+Experiments.swift
// swiftlint:disable identifier_name
//  FluxKlang
//
//  Starting and stopping the single active experiment, restoration reports and release.
//

extension RigReservationLedger {
    /// Refusals, in order: time backwards, unknown reservation, phase not `booked`/`restored`, outside the window,
    /// baseline missing, first missing required approval, duplicate experiment id (any reservation), too many
    /// experiments, another reservation's experiment active (the lowest id by bytes), then only from `booked` ONE
    /// `port.acquire` call (busy or unavailable). A refusal before the lock makes zero port calls. From `restored`
    /// the lock is already held and the port is not called.
    func startingExperiment<Port: RigLockPort>(
        reservation id: RigToken,
        plan: RigExperimentPlan,
        at: RigInstant,
        port: inout Port
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try applying(to: id, at: at) { (reservation: inout RigReservation) throws(RigReservationRefusal) in
            try reservation.requireStartable(kind: plan.kind, at: at)
            guard !hasExperiment(plan.id) else { throw .duplicateExperiment(experiment: plan.id) }
            try reservation.requireExperimentCapacity()
            if let active = reservations.first(where: { $0.phase.hasActiveExperiment }) {
                throw .experimentAlreadyActive(reservation: active.id)
            }
            if reservation.needsLockForStart {
                try Self.acquireLock(reservation.lockRequest, port: &port)
            }
            reservation.beginExperiment(plan, at: at)
        }
    }

    /// Refusals, in order: time backwards, unknown reservation, phase other than `running`. A stop is allowed at any
    /// `at >= lastInstant`, also after the window ended, and never releases the lock.
    func stoppingExperiment(
        reservation id: RigToken,
        reason: RigStopReason,
        at: RigInstant
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try applying(to: id, at: at) { (reservation: inout RigReservation) throws(RigReservationRefusal) in
            try reservation.stopExperiment(reason: reason, at: at)
        }
    }

    /// Refusals, in order: time backwards, unknown reservation, phase other than `restoring`/`unresolved`.
    /// A mismatch with the recorded baseline succeeds and leaves the reservation `unresolved`.
    func reportingRestoration(
        reservation id: RigToken,
        observed: RigBaseline,
        at: RigInstant
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try applying(to: id, at: at) { (reservation: inout RigReservation) throws(RigReservationRefusal) in
            try reservation.reportRestoration(observed: observed)
        }
    }

    /// Refusals, in order: time backwards, unknown reservation, already released, restoration not verified
    /// (`running`/`restoring`/`unresolved`), then from `restored` ONE `port.release` call (not held, unavailable).
    /// A `booked` reservation releases without any port call (it cancels the booking).
    func releasing<Port: RigLockPort>(
        reservation id: RigToken,
        at: RigInstant,
        port: inout Port
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try applying(to: id, at: at) { (reservation: inout RigReservation) throws(RigReservationRefusal) in
            if try reservation.releaseNeedsLock() {
                try Self.releaseLock(reservation.lockRequest, port: &port)
            }
            reservation.markReleased()
        }
    }

    private func hasExperiment(_ id: RigToken) -> Bool {
        reservations.contains { $0.experiments.contains { $0.id == id } }
    }

    private static func acquireLock<Port: RigLockPort>(
        _ request: RigLockRequest,
        port: inout Port
    ) throws(RigReservationRefusal) {
        switch port.acquire(request) {
        case .acquired:
            return
        case .busy:
            throw .lockBusy(rig: request.rig)
        case .unavailable:
            throw .lockUnavailable(rig: request.rig)
        }
    }

    private static func releaseLock<Port: RigLockPort>(
        _ request: RigLockRequest,
        port: inout Port
    ) throws(RigReservationRefusal) {
        switch port.release(request) {
        case .released:
            return
        case .notHeld:
            throw .lockNotHeld(rig: request.rig)
        case .unavailable:
            throw .lockUnavailable(rig: request.rig)
        }
    }
}
// swiftlint:enable identifier_name
