import Foundation

enum BindingTag: ContractIDTag {}
typealias BindingID = ContractID<BindingTag>

/// Neutral, opaque identity of one physical or virtual control; carries no protocol details.
enum ControlSourceTag: ContractIDTag {}
typealias ControlSourceID = ContractID<ControlSourceTag>

/// One control bound to one parameter. `step` is the relative increment in `unit`
/// (required for relative profiles, absent for absolute ones); `lower`/`upper`
/// optionally narrow the parameter's range for this binding.
struct ControlBindingFields: ControlFields {
    static let knownKeys: Set<String> = ["id", "source", "target", "unit", "profile", "step", "lower", "upper"]
    let id: BindingID
    let source: ControlSourceID
    let target: ParameterID
    let unit: ParameterUnit
    let profile: EncoderProfile
    var step: Double?
    var lower: Double?
    var upper: Double?

    func validate() throws {
        try profile.validate()
        guard [step, lower, upper].allSatisfy({ $0?.isFinite ?? true }) else {
            throw ControlValidationError.invalid("Binding step and range must be finite")
        }
        guard profile.isRelative == (step != nil), step.map({ $0 > 0 }) ?? true else {
            throw ControlValidationError.invalid("Relative bindings require a positive step; absolute bindings none")
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
    /// The curve law is not yet defined (`.faderTaper`); descriptors will carry the taper or a curve table.
    case undefinedCurve(ParameterCurve)
    case inputMismatch
    case inputOutOfRange(Double)
    case invalidValue(ParameterValueError)
}
