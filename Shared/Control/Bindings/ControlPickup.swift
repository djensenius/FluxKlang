import Foundation

/// How an absolute control takes over a parameter whose value moved without it.
/// Relative bindings carry no mode: a relative turn always starts from host truth.
enum PickupMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Writes nothing until the control reaches or crosses the parameter's position.
    case `catch`
    /// Every input applies immediately, even when it makes the value jump.
    case jump
}

/// Runtime-only takeover state of one binding, kept per `BindingID` by its caller. It is never
/// persisted and never part of the parameter value; the pickup target is always host truth.
enum PickupState: Hashable, Sendable {
    /// Inputs apply. `hardware` is the last seen normalized position, kept so a host-side change
    /// knows which side of the new value the control is on.
    case engaged(hardware: Double?)
    /// Inputs are held. `hardware` is the last seen normalized position, `nil` until one arrives.
    case waiting(hardware: Double?)
    /// The controller is stale or missing; inputs are refused.
    case unavailable
}

/// Why a catch binding held an input.
enum PickupHoldReason: Hashable, Sendable {
    /// The control has not reached or crossed the parameter's position.
    case notCaught
    /// Host truth lies below the binding's writable range; catching at its end would jump.
    case targetBelowRange
    /// Host truth lies above the binding's writable range (for example above a lowered ceiling).
    case targetAboveRange
}

/// What one input does under pickup. `held` never carries a write; its positions are normalized
/// over the binding's writable range, the target clamped into it for display.
enum PickupDecision: Hashable, Sendable {
    case apply(CommandOperation)
    case held(hardware: Double, target: Double, reason: PickupHoldReason)
    case unchanged
}

struct PickupResolution: Hashable, Sendable {
    let decision: PickupDecision
    let state: PickupState
}
