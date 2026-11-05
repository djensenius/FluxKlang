import Foundation

enum BindingTag: ContractIDTag {}
typealias BindingID = ContractID<BindingTag>

/// Neutral, opaque identity of one physical or virtual control; carries no protocol details.
enum ControlSourceTag: ContractIDTag {}
typealias ControlSourceID = ContractID<ControlSourceTag>

/// One control bound to one parameter. `step`, `lower` and `upper` are all in the binding's
/// `unit` (a `decibels` binding with `step` 0.5 moves half a decibel per detent). `step` is the
/// relative increment (required for relative profiles, absent for absolute ones); `lower`/`upper`
/// optionally narrow the parameter's range for this binding. `pickup` is the takeover mode of an
/// absolute control (required for absolute profiles, absent for relative ones, which never wait).
struct ControlBindingFields: ControlFields {
    static let knownKeys: Set<String> = [
        "id", "source", "target", "unit", "profile", "step", "lower", "upper", "pickup"
    ]
    let id: BindingID
    let source: ControlSourceID
    let target: ParameterID
    let unit: ParameterUnit
    let profile: EncoderProfile
    var step: Double?
    var lower: Double?
    var upper: Double?
    var pickup: PickupMode?

    func validate() throws {
        try profile.validate()
        guard [step, lower, upper].allSatisfy({ $0?.isFinite ?? true }) else {
            throw ControlValidationError.invalid("Binding step and range must be finite")
        }
        guard profile.isRelative == (step != nil), step.map({ $0 > 0 }) ?? true else {
            throw ControlValidationError.invalid("Relative bindings require a positive step; absolute bindings none")
        }
        guard profile.isRelative == (pickup == nil) else {
            throw ControlValidationError.invalid("Absolute bindings require a pickup mode; relative bindings none")
        }
        if let lower, let upper, lower > upper {
            throw ControlValidationError.invalid("Binding range lower bound exceeds upper bound")
        }
    }
}
typealias ControlBinding = ControlRecord<ControlBindingFields>

enum ControlBindingRefusal: Error, Hashable, Sendable {
    case descriptorMismatch(expected: ParameterID, found: ParameterID)
    /// Only `.live` parameters may be bound; every other class (structural, hazardous, safety,
    /// proposal) is refused. An explicit hazardous include for Learn (#88) is deferred to a
    /// separate, permissioned path and is never granted here.
    case unboundableClass(ControlClass)
    case unitMismatch(expected: ParameterUnit, found: ParameterUnit)
    case nonFinite
    case invalidStep(Double)
    case emptyRange(lower: Double, upper: Double)
    /// The range's width `upper - lower` overflows, so positions cannot be mapped without NaN.
    case unrepresentableRange(lower: Double, upper: Double)
    /// The curve law is not yet defined (`.faderTaper`); descriptors will carry the taper or a curve table.
    case undefinedCurve(ParameterCurve)
    case inputMismatch
    case inputOutOfRange(Double)
    case invalidValue(ParameterValueError)
    /// The controller is stale or missing; its pickup state is `.unavailable`.
    case pickupUnavailable
    /// The target is not in the host's current catalog (for example it was removed).
    case targetMissing(ParameterID)
    /// The host reports no current value for the target; none is ever assumed or cached.
    case valueUnavailable(ParameterID)
}
