//
//  ControlLocalDispatchRefusal.swift
//  FluxKlang
//
//  Typed refusals of the local control dispatcher (#88, LCD1). A refusal is a value: `admit` and `settle`
//  return it in their results and neither function throws.
//

/// Why one call was refused as a whole (the first four cases) or why one binding was refused (the last three).
/// Deliberately not `Codable`: nothing persists a refusal.
enum ControlLocalDispatchRefusal: Error, Hashable, Sendable {
    /// A Learn session is listening or awaiting review; the call proposes nothing. Carries that phase.
    case learnActive(LearnPhaseKind)
    /// The update carries no control input a source id can be derived from.
    case intake(ControlIntakeRefusal)
    /// More bindings than `ControlLocalDispatch.maximumBindings`; carries the supplied count.
    case tooManyBindings(Int)
    /// A binding id appears more than once; carries the smallest such id (by UTF-8 bytes).
    case duplicateBinding(BindingID)

    /// A matched binding has no entry in the pickup table.
    case pickupStateMissing(BindingID)
    /// The update does not fit this binding's encoder profile, for example its width or its range.
    case bindingIntake(BindingID, ControlIntakeRefusal)
    /// The binding itself refused: its pickup state, the host truth for its target, or its mapping.
    case binding(BindingID, ControlBindingRefusal)
}
