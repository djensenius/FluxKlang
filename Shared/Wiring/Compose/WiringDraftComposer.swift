//
//  WiringDraftComposer.swift
//  FluxKlang
//
//  Composes exactly one `GraphEdit.connect` onto a draft. The draft's graph is
//  `active.applying(draft.edits)`; the pair is classified there and composed
//  only with the conversion and feedback the caller supplied, each of which
//  must be needed. A stale draft is reported, never rebased, and the active
//  graph is only read: the result is a new `DraftEdits` value.
//

/// Builds connects into drafts and lists a draft's destinations. Pure and deterministic.
enum WiringDraftComposer {
    /// `active.applying(draft.edits)`, checked by `WiringDraftGraph` exactly as the review diff checks
    /// it: graph ID, then base revision (`.preview(.draftBaseMismatch)`), then repeated node or edge
    /// IDs in the active graph, then bounds and applicability.
    static func draftGraph(active: GraphDocument, draft: DraftEdits) throws(WiringComposeRefusal) -> GraphDocument {
        do { return try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
    }

    /// Every destination of `source` in the draft's graph, grouped by connection class.
    static func destinations(
        from source: PortAddress, active: GraphDocument, draft: DraftEdits
    ) throws(WiringComposeRefusal) -> WiringDestinationList {
        let graph = try draftGraph(active: active, draft: draft)
        do { return try WiringDestinationList.make(from: source, in: graph) } catch { throw .preview(error) }
    }

    /// `draft` with one more edit, `.connect` of `request`, appended after its existing edits.
    /// Refused, with nothing changed, unless the pair classifies as valid in the draft's graph
    /// once exactly the supplied conversion and feedback are applied, every supplied attribute is
    /// needed, and the whole edit list passes `GraphEdit.validateBatch` and applies to `active`.
    static func compose(
        _ request: WiringConnectRequest, into draft: DraftEdits, active: GraphDocument
    ) throws(WiringComposeRefusal) -> DraftEdits {
        let graph = try draftGraph(active: active, draft: draft)
        try resolve(request, in: graph)
        let edge = GraphEdge(
            id: request.edge, from: request.from, to: request.to,
            conversion: request.conversion, feedback: request.feedback
        )
        let edits = draft.edits + [.connect(edge)]
        do {
            try GraphEdit.validateBatch(edits)
        } catch {
            if case .bounds(let limit) = error { throw .preview(.bounds(limit)) }
            throw .batchInvalid(error)
        }
        do {
            _ = try active.applying(edits)
        } catch {
            if case .bounds(let limit) = error { throw .preview(.bounds(limit)) }
            throw .connectDoesNotApply(error)
        }
        var composed = draft
        composed.edits = edits
        return composed
    }

    /// Classifies the bare pair, then adds each supplied attribute only when the current
    /// class asks for it, until the pair is valid. Each attribute is applied at most once, so
    /// at most three classifications run. A supplied attribute never asked for is refused.
    private static func resolve(_ request: WiringConnectRequest, in graph: GraphDocument) throws(WiringComposeRefusal) {
        var conversion: EdgeConversion?
        var feedback: EdgeFeedback?
        while true {
            let connection: WiringConnection
            do {
                connection = try WiringCandidate.classify(
                    from: request.from, to: request.to, in: graph, conversion: conversion, feedback: feedback
                ).connection
            } catch { throw .preview(error) }
            if let refusal = structuralRefusal(connection) { throw refusal }
            switch connection {
            case .needsConversion(let source, let destination):
                guard conversion == nil, let supplied = request.conversion else {
                    throw .conversionRequired(sourceChannels: source, destinationChannels: destination)
                }
                conversion = supplied
            case .feedbackOnly(let cycle):
                guard feedback == nil, let supplied = request.feedback else { throw .feedbackRequired(cycle: cycle) }
                feedback = supplied
            default:
                // `.valid`: the structural classes were refused above.
                if let supplied = request.conversion, conversion == nil { throw .conversionNotNeeded(supplied) }
                if let supplied = request.feedback, feedback == nil { throw .feedbackNotNeeded(supplied) }
                return
            }
        }
    }

    /// The distinct refusal of a class no conversion or feedback can change; `nil` for the others.
    private static func structuralRefusal(_ connection: WiringConnection) -> WiringComposeRefusal? {
        switch connection {
        case .existing(let edge): .existing(edge)
        case .disabled(let reason): .disabled(reason)
        case .notOffered: .notOffered
        case .notRoutable(let node): .notRoutable(node)
        case .valid, .needsConversion, .feedbackOnly: nil
        }
    }
}
