//
//  ResourcePressurePolicy.swift
//  FluxKlang
//
//  What to do with a piece of work while the resource ledger is under pressure (#78,
//  slice PLG6). Pressure DEFERS scans and state work and REJECTS new reservations; it
//  never cuts a held note, because no decision here releases anything: the only way a
//  reservation leaves a ledger is `ResourceLedger.release(owner:)`. The policy is a pure
//  function of numbers the caller passes in: no clock, no scan, no plugin load.
//

/// Caller-supplied percentages of scratch use. A plain value anyone can build, so it is
/// validated again at every `evaluate`: valid only when `1 <= defer <= reject <= 100`.
struct PressureThresholds: Hashable, Sendable {
    static let maximumPercent = 100

    let deferAtPercent: Int
    let rejectAtPercent: Int

    init(defer deferAtPercent: Int, reject rejectAtPercent: Int) {
        self.deferAtPercent = deferAtPercent
        self.rejectAtPercent = rejectAtPercent
    }

    var isValid: Bool {
        deferAtPercent >= 1 && deferAtPercent <= rejectAtPercent && rejectAtPercent <= Self.maximumPercent
    }
}

enum WorkRequest: Equatable, Sendable {
    /// Work on the render path. It is never deferred and never rejected for pressure.
    case realTimeCritical
    case scan
    case stateWork
    /// A new reservation the caller wants to make. The decision is about the ledger's current
    /// pressure only; whether this reservation fits is `ResourceLedger.reserve`'s typed refusal.
    case newReservation(ResourceReservation)
}

/// Why a request was rejected: the ledger is at or above the reject threshold, or the request
/// itself is invalid (a hand-built value the policy refuses to interpret).
enum PressureRejection: Equatable, Sendable {
    case overPressure(percent: Int)
    case invalidThresholds(PressureThresholds)
    case invalidLedger(usedScratchBytes: Int, totalScratchBytes: Int)
    case invalidHeldNotes(Int)
}

enum PressureDecision: Equatable, Sendable {
    case proceed
    /// Postpone the work and ask again later; `percent` is the pressure that caused it.
    case `defer`(percent: Int)
    case reject(PressureRejection)

    /// Whether acting on this decision frees a reservation. None does. The switch has no
    /// `default`, so a new case cannot compile until it is classified here; classified `true`,
    /// the no-release grid test fails for any input that returns it. That test cannot see what
    /// acting on a future decision does, only what this property says about it.
    var releasesReservation: Bool {
        switch self {
        case .proceed, .defer, .reject: false
        }
    }
}

/// Decides proceed, defer or reject from the ledger's scratch pressure.
///
/// Pressure is `used * 100 / total` in integer arithmetic over SCRATCH bytes only (instance
/// exhaustion is `reserve`'s refusal, not pressure). Decision table, `d` and `r` being the
/// defer and reject thresholds:
///
/// | request | below d | d up to r - 1 | r and above |
/// | --- | --- | --- | --- |
/// | real-time-critical | proceed | proceed | proceed |
/// | scan, state work | proceed | defer | defer |
/// | new reservation | proceed | proceed | reject |
struct ResourcePressurePolicy: Equatable, Sendable {
    let thresholds: PressureThresholds

    func evaluate(ledger: ResourceLedger, request: WorkRequest, heldNotes: Int) -> PressureDecision {
        evaluate(
            usedScratchBytes: ledger.reservedScratchBytes, totalScratchBytes: ledger.totalScratchBytes,
            request: request, heldNotes: heldNotes
        )
    }

    /// The numbers behind `evaluate(ledger:...)`, so a total or a use no ledger can hold is
    /// still checked. Order: the thresholds, then the ledger numbers, then the held-note count;
    /// each is checked before ANY request kind is looked at, so an invalid request is rejected
    /// even when it is real-time-critical. `heldNotes` never changes a valid decision.
    func evaluate(
        usedScratchBytes: Int, totalScratchBytes: Int, request: WorkRequest, heldNotes: Int
    ) -> PressureDecision {
        if let rejection = invalidRequest(used: usedScratchBytes, total: totalScratchBytes, heldNotes: heldNotes) {
            return .reject(rejection)
        }
        let percent = usedScratchBytes * PressureThresholds.maximumPercent / totalScratchBytes
        switch request {
        case .realTimeCritical:
            return .proceed
        case .scan, .stateWork:
            return percent >= thresholds.deferAtPercent ? .defer(percent: percent) : .proceed
        case .newReservation:
            return percent >= thresholds.rejectAtPercent ? .reject(.overPressure(percent: percent)) : .proceed
        }
    }

    /// The total is limited to the scratch maximum before it is multiplied, so `used * 100` is at
    /// most 1_677_721_600 and cannot overflow.
    private func invalidRequest(used: Int, total: Int, heldNotes: Int) -> PressureRejection? {
        guard thresholds.isValid else { return .invalidThresholds(thresholds) }
        guard (1...ResourceLimits.maximumScratchBytes).contains(total), (0...total).contains(used) else {
            return .invalidLedger(usedScratchBytes: used, totalScratchBytes: total)
        }
        guard heldNotes >= 0 else { return .invalidHeldNotes(heldNotes) }
        return nil
    }
}
