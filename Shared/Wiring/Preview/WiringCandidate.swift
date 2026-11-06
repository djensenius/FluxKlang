//
//  WiringCandidate.swift
//  FluxKlang
//
//  A port pair together with the connection class `wiring.md` ("Connection
//  validation") gives it. The class is derived only from the graph contract's
//  own validation (see `WiringCandidateClassifier`); nothing is converted or
//  treated as feedback unless the caller supplied it.
//

/// Why a destination is listed but cannot be chosen.
enum WiringDisabledReason: Hashable, Sendable {
    /// The ports carry different signals (contract `signalMismatch`).
    case signalMismatch(from: PortSignal, to: PortSignal)
}

/// The connection class of a port pair, in the fixed precedence order
/// notRoutable → notOffered → existing → disabled → needsConversion →
/// feedbackOnly → valid.
enum WiringConnection: Hashable, Sendable {
    /// Connecting adds no validation error.
    case valid
    /// Audio widths differ; the caller must choose an explicit conversion. None is chosen here.
    case needsConversion(sourceChannels: Int, destinationChannels: Int)
    /// Listed but not selectable.
    case disabled(WiringDisabledReason)
    /// Wrong direction: not offered as a destination at all.
    case notOffered
    /// The wire would close a cycle; it needs an explicit `EdgeFeedback` (at least
    /// one block of delay and a ceiling) from the caller. `cycle` lists the nodes
    /// the wire newly puts on (or between) unfed cycles, sorted, as the contract's
    /// `cycleWithoutFeedback` reports them; nodes already looping are left out. When
    /// both endpoints already loop, it is just those two endpoints. It is therefore a
    /// subset of the cycle (only the newly or locally implicated nodes), and a UI may
    /// show only part of the loop.
    case feedbackOnly(cycle: [NodeID])
    /// The same wire already exists; the UI moves focus to this edge.
    case existing(EdgeID)
    /// An endpoint is on this observed shortcut node, which is never routable.
    case notRoutable(NodeID)

    /// The classes whose outcome can still change with a caller-supplied conversion or feedback.
    var acceptsEdgeAttributes: Bool {
        switch self {
        case .valid, .needsConversion, .feedbackOnly: true
        case .disabled, .notOffered, .existing, .notRoutable: false
        }
    }
}

/// A classified port pair. Built only by `classify` (or, bare, by `WiringCandidateBatch`, which
/// gives the same class), so the class always matches the graph and attributes it was computed from.
struct WiringCandidate: Hashable, Sendable {
    private(set) var from: PortAddress
    private(set) var to: PortAddress
    /// Exactly the conversion the caller supplied; never a default.
    private(set) var conversion: EdgeConversion?
    /// Exactly the feedback the caller supplied; never inferred.
    private(set) var feedback: EdgeFeedback?
    private(set) var connection: WiringConnection

    fileprivate init(
        from: PortAddress, to: PortAddress, conversion: EdgeConversion?, feedback: EdgeFeedback?,
        connection: WiringConnection
    ) {
        self.from = from
        self.to = to
        self.conversion = conversion
        self.feedback = feedback
        self.connection = connection
    }

    /// Classifies the wire `from` → `to` in `graph`, optionally with an explicit
    /// conversion and/or feedback. Unknown endpoints are refused, not classified.
    static func classify(
        from: PortAddress, to: PortAddress, in graph: GraphDocument,
        conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil
    ) throws(WiringPreviewRefusal) -> WiringCandidate {
        let connection = try WiringCandidateClassifier.connection(
            from: from, to: to, in: graph, conversion: conversion, feedback: feedback
        )
        return WiringCandidate(
            from: from, to: to, conversion: conversion, feedback: feedback, connection: connection
        )
    }
}

/// Bare candidates of one source port in one graph, classified against one shared
/// `WiringCandidateContext`: the graph is validated once per batch instead of once per pair.
/// Every candidate (or refusal) equals what `WiringCandidate.classify(from:to:in:)` gives for the
/// same pair; source- and graph-level refusals are thrown once, by `init`.
struct WiringCandidateBatch {
    private var context: WiringCandidateContext

    /// `validate` computes the graph's validation errors; it is called exactly once (a test seam).
    init(
        from source: PortAddress, in graph: GraphDocument,
        validate: (GraphDocument) -> [GraphValidationError] = { $0.validationErrors() }
    ) throws(WiringPreviewRefusal) {
        context = try WiringCandidateContext(source: source, in: graph, validate: validate)
    }

    /// The bare candidate source → `destination`, or the refusal of that pair alone.
    mutating func classify(to destination: PortAddress) throws(WiringPreviewRefusal) -> WiringCandidate {
        let connection = try context.connection(to: destination)
        return WiringCandidate(
            from: context.source, to: destination, conversion: nil, feedback: nil, connection: connection
        )
    }
}
