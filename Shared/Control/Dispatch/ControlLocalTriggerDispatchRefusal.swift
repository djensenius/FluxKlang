//
//  ControlLocalTriggerDispatchRefusal.swift
//  FluxKlang
//
//  Typed refusals of the local trigger dispatcher (#87, LTD1). A refusal is a value: `dispatch` returns it in its
//  result and does not throw.
//

/// Why one call was refused as a whole (the first four cases) or why one trigger binding was refused (the last two).
/// Deliberately not `Codable`: nothing persists a refusal.
enum ControlLocalTriggerRefusal: Error, Hashable, Sendable {
    /// A Learn session is listening or awaiting review; nothing is dispatched. Carries that phase.
    case learnActive(LearnPhaseKind)
    /// The update carries no control input a source id can be derived from (a note, sustain, program, a system
    /// message and the other refusals of `MIDIControlIntake.key`).
    case intake(ControlIntakeRefusal)
    /// More bindings than `ControlLocalTriggerDispatch.maximumBindings`; carries the supplied count.
    case tooManyBindings(Int)
    /// A binding id appears more than once; carries the smallest such id (by UTF-8 bytes).
    case duplicateBinding(BindingID)

    /// The update does not fit this binding's encoder profile, for example its width or its range.
    case bindingIntake(BindingID, ControlIntakeRefusal)
    /// The detector refused this binding: unknown id, source mismatch, stale source, target or sequence refusals.
    case detector(BindingID, ControlTriggerRefusal)
}
