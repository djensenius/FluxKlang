//
//  WiringCandidateClassifier.swift
//  FluxKlang
//
//  Derives a connection class by running the graph contract's own
//  `validationErrors()` on the graph with the candidate edge applied. Only
//  errors the candidate introduces count: the errors of the unchanged graph are
//  subtracted (as a multiset), so a pre-existing, unrelated error never changes
//  the class. No compatibility rule is restated here.
//

/// Classifies port pairs through contract validation. See `WiringCandidate.classify`.
enum WiringCandidateClassifier {
    /// Stem of the temporary edge ID the candidate is validated under; a numeric
    /// suffix is added until it names no edge of the graph.
    static let probeStem: StaticString = "wpv.probe"

    /// The class of `from` → `to`. The bare wire is classified first, so a
    /// supplied conversion or feedback never masks direction, duplicate or signal
    /// classes; only valid, needsConversion and feedbackOnly are re-checked with them.
    static func connection(
        from: PortAddress, to: PortAddress, in graph: GraphDocument,
        conversion: EdgeConversion?, feedback: EdgeFeedback?
    ) throws(WiringPreviewRefusal) -> WiringConnection {
        let baseline = try checkedErrors(graph)
        try refuseUncheckableEndpoints([from.node, to.node], baseline: baseline)
        let probe = try probeID(avoiding: graph.edges)
        let bareEdge = GraphEdge(id: probe, from: from, to: to)
        let bare: WiringConnection
        do throws(WiringPreviewRefusal) {
            bare = try findings(of: bareEdge, in: graph, baseline: baseline).connection
        } catch .bounds(let limit) {
            // An existing wire adds no edge, so `existing` outranks the edge bound.
            guard let existing = try existingAtBound(bareEdge, in: graph) else { throw .bounds(limit) }
            return existing
        }
        guard conversion != nil || feedback != nil, bare.acceptsEdgeAttributes else { return bare }
        let explicit = GraphEdge(id: probe, from: from, to: to, conversion: conversion, feedback: feedback)
        return try findings(of: explicit, in: graph, baseline: baseline).connection
    }

    /// A deterministic edge ID unused by `edges`.
    static func probeID(avoiding edges: [GraphEdge]) throws(WiringPreviewRefusal) -> EdgeID {
        let used = Set(edges.map(\.id))
        var probe = EdgeID(validated: probeStem)
        var suffix = 0
        while used.contains(probe) {
            suffix += 1
            do { probe = try EdgeID("\(probeStem).\(suffix)") } catch { throw .probeUnavailable(suffix: suffix) }
        }
        return probe
    }

    /// The errors of `after` that are not in `before`, counting repeats, in `after` order.
    static func introduced(
        _ after: [GraphValidationError], over before: [GraphValidationError]
    ) -> [GraphValidationError] {
        var remaining: [GraphValidationError: Int] = [:]
        for error in before { remaining[error, default: 0] += 1 }
        return after.filter { error in
            guard let count = remaining[error], count > 0 else { return true }
            remaining[error] = count - 1
            return false
        }
    }

    /// Validation errors, refusing the graph when the contract stops before checking wires.
    private static func checkedErrors(_ graph: GraphDocument) throws(WiringPreviewRefusal) -> [GraphValidationError] {
        try checked(graph.validationErrors())
    }

    /// `errors` (a graph's validation errors), refused when the contract stopped before checking wires.
    static func checked(_ errors: [GraphValidationError]) throws(WiringPreviewRefusal) -> [GraphValidationError] {
        for error in errors {
            switch error {
            case .bounds(let limit): throw .bounds(limit)
            case .invalidRequiredFeatures, .requiredFeaturesCollision: throw .uncheckableGraph(error)
            default: continue
            }
        }
        return errors
    }

    /// The preview never vouches for an endpoint whose ports the contract already
    /// reports as broken (unconfirmed channel count, gain/mute shape error, or a repeated port ID).
    private static func refuseUncheckableEndpoints(
        _ endpoints: [NodeID], baseline: [GraphValidationError]
    ) throws(WiringPreviewRefusal) {
        for error in baseline {
            if let node = uncheckableNode(error), endpoints.contains(node) { throw .endpointUncheckable(node: node) }
        }
    }

    /// The node whose ports `error` reports as broken, making it an uncheckable endpoint; `nil` for other errors.
    static func uncheckableNode(_ error: GraphValidationError) -> NodeID? {
        switch error {
        case .invalidChannelCount(let node, _), .invalidGainShape(let node), .invalidMuteShape(let node),
             .duplicatePort(let node, _):
            node
        default:
            nil
        }
    }

    /// At the edge bound the probe cannot be added, but a wire that already exists
    /// still is `existing`. The probe is validated in place of the last edge and,
    /// if that was the only repeat, of the first, so the contract still names the
    /// first repeated edge. `nil` when neither finds a duplicate wire.
    private static func existingAtBound(
        _ edge: GraphEdge, in graph: GraphDocument
    ) throws(WiringPreviewRefusal) -> WiringConnection? {
        guard graph.edges.count > 1 else { return nil }
        for dropped in [graph.edges.count - 1, 0] {
            var reduced = graph
            reduced.edges.remove(at: dropped)
            let found = try findings(of: edge, in: reduced, baseline: try checkedErrors(reduced))
            if found.duplicate != nil { return found.connection }
        }
        return nil
    }

    /// The candidate goes first, so a duplicate wire is reported against the
    /// existing edge it repeats rather than against the candidate.
    private static func findings(
        of edge: GraphEdge, in graph: GraphDocument, baseline: [GraphValidationError]
    ) throws(WiringPreviewRefusal) -> Findings {
        var candidate = graph
        candidate.edges.insert(edge, at: 0)
        var findings = Findings(probe: edge, baseline: baseline)
        for error in introduced(try checkedErrors(candidate), over: baseline) {
            try findings.record(error, in: graph)
        }
        return findings
    }
}

/// What the introduced errors say about the candidate, resolved by precedence.
private struct Findings {
    let probe: GraphEdge
    /// Nodes the unchanged graph already reports on or between unfed cycles.
    let looping: Set<NodeID>
    var unroutable: NodeID?
    var wrongDirection = false
    var duplicate: EdgeID?
    var signals: (from: PortSignal, to: PortSignal)?
    var channels: (from: Int, to: Int)?
    var cycle: [NodeID]?

    init(probe: GraphEdge, baseline: [GraphValidationError]) {
        self.probe = probe
        var looping: Set<NodeID> = []
        for case .cycleWithoutFeedback(let nodes) in baseline { looping.formUnion(nodes) }
        self.looping = looping
    }

    var connection: WiringConnection {
        if let unroutable { return .notRoutable(unroutable) }
        if wrongDirection { return .notOffered }
        if let duplicate { return .existing(duplicate) }
        if let signals { return .disabled(.signalMismatch(from: signals.from, to: signals.to)) }
        if let channels { return .needsConversion(sourceChannels: channels.from, destinationChannels: channels.to) }
        if let cycle { return .feedbackOnly(cycle: cycle) }
        // The contract reports one aggregate list of looping nodes, so a wire among nodes that
        // already loop adds no error. Without feedback it is conservatively feedbackOnly (a bridge
        // between two separate loops is over-approximated, as the contract's own peeling does).
        if probe.feedback == nil, looping.contains(probe.from.node), looping.contains(probe.to.node) {
            return .feedbackOnly(cycle: Set([probe.from.node, probe.to.node]).sorted())
        }
        return .valid
    }

    /// Unknown endpoints and invalid supplied attributes are refused at once:
    /// they outrank every class.
    mutating func record(_ error: GraphValidationError, in graph: GraphDocument) throws(WiringPreviewRefusal) {
        switch error {
        case .missingNode(let edge, let node) where edge == probe.id:
            throw .unknownNode(node)
        case .missingPort(let edge, let address) where edge == probe.id:
            guard graph.node(address.node)?.kind.isRoutable == false else { throw .unknownPort(address) }
            unroutable = unroutable ?? address.node
        case .duplicateWire(let edge) where edge != probe.id:
            duplicate = duplicate ?? edge
        case .cycleWithoutFeedback(let nodes):
            cycle = nodes.filter { !looping.contains($0) }
        default:
            try recordWire(error)
        }
    }

    private mutating func recordWire(_ error: GraphValidationError) throws(WiringPreviewRefusal) {
        switch error {
        case .wrongDirection(let edge) where edge == probe.id:
            wrongDirection = true
        case .signalMismatch(let edge, let from, let to) where edge == probe.id:
            signals = (from, to)
        case .channelMismatch(let edge, let from, let to) where edge == probe.id:
            channels = (from, to)
        case .invalidConversion(let edge) where edge == probe.id:
            guard let conversion = probe.conversion else { throw .unexpectedValidation(error) }
            throw .invalidConversion(conversion)
        case .invalidFeedback(let edge) where edge == probe.id:
            guard let feedback = probe.feedback else { throw .unexpectedValidation(error) }
            throw .invalidFeedback(feedback)
        default:
            throw .unexpectedValidation(error)
        }
    }
}
