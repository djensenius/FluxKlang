//
//  RigReservationLedger.swift
// swiftlint:disable identifier_name
//  FluxKlang
//
//  A pure ledger of rig reservations: booking, approvals, baselines and queries.
//

/// A deterministic ledger of rig reservations and experiments (#68), as an immutable value.
///
/// This is a MODEL: it does not exclude other processes. The machine-wide lock is the coordinator-owned flock
/// harness behind `RigLockPort`. Every operation is a non-mutating function that returns a new ledger or throws one
/// typed `RigReservationRefusal`; a refusal produces no ledger value, so the receiver cannot have changed. Only the
/// injected lock port is `inout`. Every operation takes the caller's time as a `RigInstant`; times must not go
/// backwards. The ledger is not serialized.
struct RigReservationLedger: Hashable, Sendable {
    /// The ledger with no reservations.
    static let empty = RigReservationLedger(reservations: [], lastInstant: nil)

    /// Every reservation, released ones included, sorted by id UTF-8 bytes.
    private(set) var reservations: [RigReservation]
    /// The `at` of the last accepted operation; nil for a ledger that has accepted none.
    private(set) var lastInstant: RigInstant?

    private init(reservations: [RigReservation], lastInstant: RigInstant?) {
        self.reservations = reservations
        self.lastInstant = lastInstant
    }

    /// The reservation with this id, if any.
    func reservation(_ id: RigToken) -> RigReservation? {
        reservations.first { $0.id == id }
    }

    /// The identifiers of the single active experiment, for stamping every physical measurement.
    func measurementStamp() throws(RigReservationRefusal) -> RigMeasurementStamp {
        guard let active = reservations.first(where: { $0.phase.hasActiveExperiment }),
              let record = active.activeExperiment else {
            throw .noActiveExperiment
        }
        return RigMeasurementStamp(
            reservation: active.id,
            experiment: record.id,
            rig: active.rig,
            owner: active.owner,
            kind: record.kind
        )
    }

    // MARK: Shared prelude

    /// P1: time never goes backwards; an equal instant is accepted.
    func requireNotBackwards(_ at: RigInstant) throws(RigReservationRefusal) {
        if let last = lastInstant, at < last {
            throw .timeWentBackwards(last: last.seconds, got: at.seconds)
        }
    }

    /// Runs P1 and P2 (unknown reservation), then `change` on a copy of the reservation, and returns the new ledger
    /// with `lastInstant` set to `at`. The transition cannot change the id or the sort order.
    func applying(
        to id: RigToken,
        at: RigInstant,
        _ change: (_ reservation: inout RigReservation) throws(RigReservationRefusal) -> Void
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try requireNotBackwards(at)
        guard let index = reservations.firstIndex(where: { $0.id == id }) else {
            throw .unknownReservation(id)
        }
        var copy = self
        try change(&copy.reservations[index])
        copy.lastInstant = at
        return copy
    }

    // MARK: Booking

    /// Refusals, in order: time backwards; window already ended (`end <= at`); duplicate id (released included);
    /// same-rig overlap with a non-released reservation (the lowest conflicting id by bytes); ledger full.
    func booking(
        _ request: RigBookingRequest,
        at: RigInstant
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try requireNotBackwards(at)
        guard at < request.window.end else {
            throw .windowAlreadyEnded(end: request.window.end.seconds, now: at.seconds)
        }
        guard reservation(request.id) == nil else { throw .duplicateReservation(request.id) }
        if let existing = reservations.first(where: { conflicts($0, with: request) }) {
            throw .conflictingReservation(existing: existing.id, rig: request.rig)
        }
        guard reservations.count < RigReservationLimits.maximumReservations else {
            throw .ledgerFull(count: reservations.count)
        }
        var copy = self
        let slot = reservations.firstIndex { request.id < $0.id } ?? reservations.count
        copy.reservations.insert(RigReservation(booking: request), at: slot)
        copy.lastInstant = at
        return copy
    }

    private func conflicts(_ existing: RigReservation, with request: RigBookingRequest) -> Bool {
        existing.phase != .released && existing.rig == request.rig && existing.window.overlaps(request.window)
    }

    // MARK: Approvals and baseline

    /// Refusals, in order: time backwards, unknown reservation, released phase, window expired (`at >= end`),
    /// duplicate approval of the kind. May be granted before the window starts and while running.
    func approving(
        reservation id: RigToken,
        kind: RigApprovalKind,
        approver: RigToken,
        at: RigInstant
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try applying(to: id, at: at) { (reservation: inout RigReservation) throws(RigReservationRefusal) in
            try reservation.approve(kind: kind, approver: approver, at: at)
        }
    }

    /// Refusals, in order: time backwards, unknown reservation, phase other than `booked`, window expired,
    /// baseline already recorded. A baseline may be recorded before the window starts and is immutable afterwards.
    func recordingBaseline(
        reservation id: RigToken,
        baseline: RigBaseline,
        at: RigInstant
    ) throws(RigReservationRefusal) -> RigReservationLedger {
        try applying(to: id, at: at) { (reservation: inout RigReservation) throws(RigReservationRefusal) in
            try reservation.recordBaseline(baseline, at: at)
        }
    }
}
// swiftlint:enable identifier_name
