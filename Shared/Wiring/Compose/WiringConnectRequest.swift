//
//  WiringConnectRequest.swift
//  FluxKlang
//
//  What the caller asks to connect. The conversion and feedback are exactly
//  what the caller chose; the composer never supplies a default for either.
//

/// One connect a caller asks `WiringDraftComposer` to add to a draft.
struct WiringConnectRequest: Hashable, Sendable {
    /// The ID the new edge gets; it must be unused in the draft's graph and its edits.
    var edge: EdgeID
    var from: PortAddress
    var to: PortAddress
    /// The caller's explicit conversion, required exactly when the pair needs one.
    var conversion: EdgeConversion?
    /// The caller's explicit feedback, required exactly when the wire closes a cycle.
    var feedback: EdgeFeedback?

    init(
        edge: EdgeID, from: PortAddress, to: PortAddress,
        conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil
    ) {
        self.edge = edge
        self.from = from
        self.to = to
        self.conversion = conversion
        self.feedback = feedback
    }
}
