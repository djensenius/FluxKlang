//
//  PerformRecallModel.swift
//  FluxKlang
//
//  The values a perform recall cell reads and keeps: the target, the caller's facts and the phase (#102 RCL1).
//

enum PerformRecallVariationTag: ContractIDTag {}

/// A variation of a patch, named by this slice so that it depends on no patch-variation record; a wiring slice
/// converts by raw value.
typealias PerformRecallVariationID = ContractID<PerformRecallVariationTag>

/// What a recall cell recalls: a patch, and one of its variations or, with no variation, its baseline.
struct PerformRecallTarget: Equatable, Sendable {
    let patch: PatchID
    let variation: PerformRecallVariationID?
}

/// What the caller knows when an event arrives. The reducer trusts none of it beyond its type: each field is a total
/// type, so there is nothing to validate.
struct PerformRecallFacts: Equatable, Sendable {
    let epoch: HostEpoch
    let resyncing: Bool
    let permitted: Bool
    let targetExists: Bool
    /// Recall is `.structural` in the command set (CommandAdmission.swift:34); this cell refuses structural at the
    /// class check and does not map classes, so a caller that supplies `.live` to obtain a fire takes that decision
    /// itself (wiring slice).
    let controlClass: ControlClass
    let readiness: ReadinessState
}

/// Where one recall cell stands. A phase that holds an epoch is stale for press and confirm when that epoch
/// differs from the live one; cancel and settle never check staleness.
enum PerformRecallPhase: Equatable, Sendable {
    case idle
    /// A hazardous press is waiting for a confirm; "armed" is a derived display word, not a phase.
    case awaitingConfirm(HostEpoch)
    /// An intent went out and its outcome is not yet settled.
    case fired(HostEpoch)

    /// The epoch the phase was entered under; idle holds none.
    var heldEpoch: HostEpoch? {
        switch self {
        case .idle: nil
        case .awaitingConfirm(let epoch), .fired(let epoch): epoch
        }
    }
}
