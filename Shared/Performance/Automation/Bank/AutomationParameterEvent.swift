//
//  AutomationParameterEvent.swift
//  FluxKlang
//
//  One automation ramp event tagged with the parameter it is for (#108, slice AUB1).
//

/// An `AutomationRampEvent` and the `ParameterID` it addresses. A plain value: the bank returns it and nothing sends
/// it anywhere yet; an audio-unit adapter that dispatches by parameter is outstanding.
struct AutomationParameterEvent: Hashable, Sendable {
    let parameter: ParameterID
    let event: AutomationRampEvent
}
