//
//  SetupFlowSourceRefusal.swift
//  FluxKlang
//
//  Why the setup flow's facts could not be derived from the app's values.
//

enum SetupFlowSourceRefusal: Error, Equatable, Sendable {
    /// `SetupFlowFacts.make` refused the derived facts; carries its refusal unchanged.
    case facts(SetupFlowRefusal)
    /// A rig id that the flow's id type rejects; carries its raw text. Unreachable while both id types share one
    /// validator; kept so the conversion has no force unwrap.
    case rigIDRejected(String)
}
