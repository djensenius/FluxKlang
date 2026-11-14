//
//  WiringComposeTests.swift
//  FluxKlangTests
//
//  The connect composer (#101 WP2): one `GraphEdit.connect` appended to a
//  draft, classified in the draft's graph, with only the conversion and
//  feedback the caller supplied; typed refusals for every other outcome,
//  stale drafts reported (never rebased) and the active graph never written.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

enum WiringComposeFixture {
    static let draftID = DraftID(validated: "dft.compose")
    static let comp = Fixture.stereo("nod.comp", at: 10)
    static let downmix = EdgeConversion(map: [[0, 1]], label: "Both sides to mono")

    static func draft(_ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph) -> DraftEdits {
        DraftEdits(id: draftID, graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func request(
        _ edge: String, _ from: (String, String), _ to: (String, String),
        conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil
    ) -> WiringConnectRequest {
        WiringConnectRequest(
            edge: Fixture.id(edge), from: Fixture.address(from.0, from.1), to: Fixture.address(to.0, to.1),
            conversion: conversion, feedback: feedback
        )
    }

    static func compose(
        _ request: WiringConnectRequest, into draft: DraftEdits = draft(), active: GraphDocument = Fixture.graph
    ) throws(WiringComposeRefusal) -> DraftEdits {
        try WiringDraftComposer.compose(request, into: draft, active: active)
    }

    /// The fixture plus a mono node fed (down-mixed) by verb: mono → verb needs a conversion and closes a cycle.
    static var monoLoop: GraphDocument {
        Fixture.with(
            [Fixture.edge("edg.verb-mono", Fixture.address("nod.verb", "out"), Fixture.address("nod.mono", "in"),
                          conversion: downmix)],
            nodes: [Fixture.node("nod.mono", ports: [Fixture.audio("in", .input, 1), Fixture.audio("out", .output, 1)],
                                 at: 12)]
        )
    }

    static func revision(_ value: Int) -> ContractRevision {
        guard let revision = try? ContractRevision(value) else { preconditionFailure("Invalid revision \(value)") }
        return revision
    }
}

private typealias Compose = WiringComposeFixture

@Suite("Wiring connect composer", .productionAccessAudit)
struct WiringComposeTests {
    static let verbEchoCycle = [NodeID(validated: "nod.echo"), NodeID(validated: "nod.verb")]

    /// The last edit of `draft` must be a connect; returns its edge.
    static func lastEdge(_ draft: DraftEdits) -> GraphEdge? {
        guard case .connect(let edge) = draft.edits.last else { return nil }
        return edge
    }

    @Test func validPairAppendsExactlyOneConnect() throws {
        let request = Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        let draft = Compose.draft()
        let composed = try Compose.compose(request, into: draft)
        let expected = Fixture.edge("edg.keys-mains", request.from, request.to)
        #expect(composed.edits == [.connect(expected)])
        #expect(composed.id == draft.id && composed.graph == draft.graph && composed.baseRevision == draft.baseRevision)
        #expect(try Fixture.graph.applying(composed.edits).validationErrors().isEmpty)
    }

    @Test func appendingPreservesEarlierEditsAndUsesTheDraftGraph() throws {
        let earlier: [GraphEdit] = [
            .addNode(Compose.comp),
            .connect(Fixture.edge("edg.keys-comp", Fixture.address("nod.keys", "out"),
                                  Fixture.address("nod.comp", "in"))),
            .moveNode(Fixture.id("nod.mains"), to: GraphPoint(x: 9, y: 9))
        ]
        let draft = Compose.draft(earlier)
        // nod.comp exists only in the draft's graph.
        let composed = try Compose.compose(
            Compose.request("edg.comp-mains", ("nod.comp", "out"), ("nod.mains", "in")), into: draft
        )
        #expect(Array(composed.edits.prefix(earlier.count)) == earlier)
        #expect(composed.edits.count == earlier.count + 1)
        #expect(Self.lastEdge(composed)?.id == Fixture.id("edg.comp-mains"))
        let review = try WiringReviewDiff.make(active: Fixture.graph, draft: composed)
        #expect(review.changes.contains(.addedEdge(try #require(Self.lastEdge(composed)))))
    }

    @Test func activeGraphAndInputDraftAreNeverWritten() throws {
        let active = Fixture.graph
        let draft = Compose.draft([.disconnect(Fixture.id("edg.echo-verb"))])
        let composed = try WiringDraftComposer.compose(
            Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in")), into: draft, active: active
        )
        #expect(composed.edits.count == 2)
        #expect(active == Fixture.graph)
        #expect(draft == Compose.draft([.disconnect(Fixture.id("edg.echo-verb"))]))
        #expect(throws: WiringComposeRefusal.notOffered) {
            try WiringDraftComposer.compose(
                Compose.request("edg.x", ("nod.mains", "in"), ("nod.verb", "in")), into: draft, active: active
            )
        }
        #expect(active == Fixture.graph)
    }

    @Test func conversionIsRequiredAndUsedOnlyWhenSupplied() throws {
        let bare = Compose.request("edg.mic-mains", ("nod.mic", "out"), ("nod.mains", "in"))
        #expect(throws: WiringComposeRefusal.conversionRequired(sourceChannels: 1, destinationChannels: 2)) {
            try Compose.compose(bare)
        }
        // Feedback is no substitute for a conversion.
        #expect(throws: WiringComposeRefusal.conversionRequired(sourceChannels: 1, destinationChannels: 2)) {
            try Compose.compose(Compose.request("edg.mic-mains", ("nod.mic", "out"), ("nod.mains", "in"),
                                                feedback: Fixture.feedback))
        }
        let chosen = Compose.request("edg.mic-mains", ("nod.mic", "out"), ("nod.mains", "in"),
                                     conversion: Fixture.upmix)
        let edge = try #require(Self.lastEdge(try Compose.compose(chosen)))
        #expect(edge.conversion == Fixture.upmix)
        #expect(edge.feedback == nil)
    }

    @Test func feedbackIsRequiredAndUsedOnlyWhenSupplied() throws {
        #expect(throws: WiringComposeRefusal.feedbackRequired(cycle: Self.verbEchoCycle)) {
            try Compose.compose(Compose.request("edg.verb-echo", ("nod.verb", "out"), ("nod.echo", "in")))
        }
        #expect(throws: WiringComposeRefusal.feedbackRequired(cycle: Self.verbEchoCycle)) {
            try Compose.compose(Compose.request("edg.verb-echo", ("nod.verb", "out"), ("nod.echo", "in"),
                                                conversion: EdgeConversion(map: [[0], [1]])))
        }
        let chosen = Compose.request("edg.verb-echo", ("nod.verb", "out"), ("nod.echo", "in"),
                                     feedback: Fixture.feedback)
        let composed = try Compose.compose(chosen)
        let edge = try #require(Self.lastEdge(composed))
        #expect(edge.feedback == Fixture.feedback)
        #expect(edge.conversion == nil)
        #expect(try Fixture.graph.applying(composed.edits).validationErrors().isEmpty)
    }

    @Test func conversionAndFeedbackTogetherWhenBothAreNeeded() throws {
        let graph = Compose.monoLoop
        #expect(graph.validationErrors().isEmpty)
        let draft = Compose.draft(on: graph)
        let cycle = [NodeID(validated: "nod.mono"), NodeID(validated: "nod.verb")]
        func compose(
            _ conversion: EdgeConversion?, _ feedback: EdgeFeedback?
        ) throws(WiringComposeRefusal) -> DraftEdits {
            try Compose.compose(Compose.request("edg.mono-verb", ("nod.mono", "out"), ("nod.verb", "in"),
                                                conversion: conversion, feedback: feedback),
                                into: draft, active: graph)
        }
        #expect(throws: WiringComposeRefusal.conversionRequired(sourceChannels: 1, destinationChannels: 2)) {
            try compose(nil, nil)
        }
        #expect(throws: WiringComposeRefusal.conversionRequired(sourceChannels: 1, destinationChannels: 2)) {
            try compose(nil, Fixture.feedback)
        }
        #expect(throws: WiringComposeRefusal.feedbackRequired(cycle: cycle)) { try compose(Fixture.upmix, nil) }
        let composed = try compose(Fixture.upmix, Fixture.feedback)
        let edge = try #require(Self.lastEdge(composed))
        #expect(edge.conversion == Fixture.upmix && edge.feedback == Fixture.feedback)
        #expect(try graph.applying(composed.edits).validationErrors().isEmpty)
    }

    @Test func suppliedAttributesThePairDoesNotNeedAreRefused() {
        let identity = EdgeConversion(map: [[0], [1]])
        #expect(throws: WiringComposeRefusal.conversionNotNeeded(identity)) {
            try Compose.compose(Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"),
                                                conversion: identity))
        }
        #expect(throws: WiringComposeRefusal.feedbackNotNeeded(Fixture.feedback)) {
            try Compose.compose(Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"),
                                                feedback: Fixture.feedback))
        }
        #expect(throws: WiringComposeRefusal.feedbackNotNeeded(Fixture.feedback)) {
            try Compose.compose(Compose.request("edg.mic-mains", ("nod.mic", "out"), ("nod.mains", "in"),
                                                conversion: Fixture.upmix, feedback: Fixture.feedback))
        }
        #expect(throws: WiringComposeRefusal.conversionNotNeeded(identity)) {
            try Compose.compose(Compose.request("edg.verb-echo", ("nod.verb", "out"), ("nod.echo", "in"),
                                                conversion: identity, feedback: Fixture.feedback))
        }
        #expect(throws: WiringComposeRefusal.conversionNotNeeded(identity)) {
            try Compose.compose(Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"),
                                                conversion: identity, feedback: Fixture.feedback))
        }
    }

    @Test func structuralClassesHaveDistinctRefusalsEvenWithAttributes() {
        let rows: [(pair: ((String, String), (String, String)), refusal: WiringComposeRefusal)] = [
            ((("nod.keys", "out"), ("nod.verb", "in")), .existing(Fixture.id("edg.keys-verb"))),
            ((("nod.keys", "out"), ("nod.verb", "mod")), .disabled(.signalMismatch(from: .audio, to: .control))),
            ((("nod.mains", "in"), ("nod.verb", "in")), .notOffered),
            ((("nod.ch7", "out"), ("nod.verb", "in")), .notRoutable(Fixture.id("nod.ch7")))
        ]
        for ((from, to), refusal) in rows {
            #expect(throws: refusal, "\(from) → \(to)") { try Compose.compose(Compose.request("edg.x", from, to)) }
            #expect(throws: refusal, "\(from) → \(to) with attributes") {
                try Compose.compose(Compose.request("edg.x", from, to, conversion: Fixture.upmix,
                                                    feedback: Fixture.feedback))
            }
        }
    }

    @Test func invalidSuppliedAttributesAndUnknownEndpointsAreRefused() {
        let wrongWidth = EdgeConversion(map: [[0]])
        #expect(throws: WiringComposeRefusal.preview(.invalidConversion(wrongWidth))) {
            try Compose.compose(Compose.request("edg.mic-mains", ("nod.mic", "out"), ("nod.mains", "in"),
                                                conversion: wrongWidth))
        }
        let uncapped = EdgeFeedback(gainCeilingDb: 3)
        #expect(throws: WiringComposeRefusal.preview(.invalidFeedback(uncapped))) {
            try Compose.compose(Compose.request("edg.verb-echo", ("nod.verb", "out"), ("nod.echo", "in"),
                                                feedback: uncapped))
        }
        #expect(throws: WiringComposeRefusal.preview(.unknownNode(Fixture.id("nod.ghost")))) {
            try Compose.compose(Compose.request("edg.x", ("nod.ghost", "out"), ("nod.mains", "in")))
        }
        #expect(throws: WiringComposeRefusal.preview(.unknownPort(Fixture.address("nod.keys", "aux")))) {
            try Compose.compose(Compose.request("edg.x", ("nod.keys", "aux"), ("nod.mains", "in")))
        }
    }

    @Test func staleDraftIsReportedWithBothRevisionsAndNeverRebased() throws {
        var active = Fixture.graph
        active.revision = Compose.revision(43)
        var older = Fixture.graph
        older.revision = Compose.revision(42)
        let draft = Compose.draft(on: older)
        let report = try #require(WiringStaleDraft.check(draft, active: active))
        #expect(report.description == "Based on rev 42; active is 43")
        #expect(report.draft == Compose.draftID)
        #expect(report.baseRevision == Compose.revision(42) && report.activeRevision == Compose.revision(43))
        #expect(report.refusal == .draftBaseMismatch(draft: Compose.revision(42), active: Compose.revision(43)))
        #expect(WiringStaleDraft.check(draft, active: older) == nil)
        // One refusal shape for the same stale draft: compose, destinations and the review diff agree.
        let request = Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        #expect(throws: WiringComposeRefusal.preview(report.refusal)) {
            try WiringDraftComposer.compose(request, into: draft, active: active)
        }
        #expect(throws: WiringComposeRefusal.preview(report.refusal)) {
            try WiringDraftComposer.destinations(from: request.from, active: active, draft: draft)
        }
        #expect(throws: report.refusal) { try WiringReviewDiff.make(active: active, draft: draft) }
        // A draft based on a later revision than the active one is stale too.
        var behind = active
        behind.revision = Compose.revision(41)
        let ahead = try #require(WiringStaleDraft.check(draft, active: behind))
        #expect(ahead.description == "Based on rev 42; active is 41")
        #expect(throws: WiringComposeRefusal.preview(ahead.refusal)) {
            try WiringDraftComposer.compose(request, into: draft, active: behind)
        }
        #expect(draft.baseRevision == Compose.revision(42))
    }

    @Test func foreignAndStaleDraftReportsGraphMismatch() {
        var active = Fixture.graph
        active.revision = Compose.revision(43)
        var foreign = Compose.draft()
        foreign.graph = Fixture.id("gph.other")
        // Another graph's revisions are not comparable: no stale report, a graph mismatch everywhere.
        #expect(WiringStaleDraft.check(foreign, active: active) == nil)
        let mismatch = WiringPreviewRefusal.draftGraphMismatch(draft: Fixture.id("gph.other"), active: Fixture.graphID)
        let request = Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        #expect(throws: WiringComposeRefusal.preview(mismatch)) {
            try WiringDraftComposer.compose(request, into: foreign, active: active)
        }
        #expect(throws: WiringComposeRefusal.preview(mismatch)) {
            try WiringDraftComposer.destinations(from: request.from, active: active, draft: foreign)
        }
        #expect(throws: mismatch) { try WiringReviewDiff.make(active: active, draft: foreign) }
    }

    @Test func repeatedActiveNodeIDIsRefusedUpFront() {
        // A later node repeats nod.mains: the composer refuses the graph as the review diff does.
        let active = Fixture.with([], nodes: [Fixture.stereo("nod.mains", at: 20)])
        let draft = Compose.draft(on: active)
        let request = Compose.request("edg.keys-echo", ("nod.keys", "out"), ("nod.echo", "in"))
        let refusal = WiringPreviewRefusal.ambiguousNode(Fixture.id("nod.mains"))
        #expect(throws: WiringComposeRefusal.preview(refusal)) {
            try Compose.compose(request, into: draft, active: active)
        }
        #expect(throws: WiringComposeRefusal.preview(refusal)) {
            try WiringDraftComposer.destinations(from: request.from, active: active, draft: draft)
        }
        #expect(throws: refusal) { try WiringReviewDiff.make(active: active, draft: draft) }
    }

    @Test func foreignGraphAndDraftsThatDoNotApplyAreRefused() {
        var foreign = Compose.draft()
        foreign.graph = Fixture.id("gph.other")
        let request = Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        #expect(throws: WiringComposeRefusal.preview(.draftGraphMismatch(draft: Fixture.id("gph.other"),
                                                                           active: Fixture.graphID))) {
            try Compose.compose(request, into: foreign)
        }
        let broken = Compose.draft([.disconnect(Fixture.id("edg.missing"))])
        #expect(throws: WiringComposeRefusal.preview(.draftDoesNotApply(.missingEdge(Fixture.id("edg.missing"))))) {
            try Compose.compose(request, into: broken)
        }
    }

    @Test func batchValidationFailureCarriesTheUnderlyingError() {
        let reused = Fixture.edge("edg.new", Fixture.address("nod.keys", "out"), Fixture.address("nod.mains", "in"))
        let draft = Compose.draft([.connect(reused)])
        #expect(throws: WiringComposeRefusal.batchInvalid(.contradictoryEdge(Fixture.id("edg.new")))) {
            try Compose.compose(Compose.request("edg.new", ("nod.echo", "out"), ("nod.mains", "in")), into: draft)
        }
        let disconnected = Compose.draft([.disconnect(Fixture.id("edg.echo-verb"))])
        #expect(throws: WiringComposeRefusal.batchInvalid(.contradictoryEdge(Fixture.id("edg.echo-verb")))) {
            try Compose.compose(Compose.request("edg.echo-verb", ("nod.keys", "out"), ("nod.delay", "in")),
                                into: disconnected)
        }
    }

    @Test func takenEdgeIDDoesNotApply() {
        #expect(throws: WiringComposeRefusal.connectDoesNotApply(.edgeExists(Fixture.id("edg.keys-verb")))) {
            try Compose.compose(Compose.request("edg.keys-verb", ("nod.keys", "out"), ("nod.mains", "in")))
        }
    }

    @Test func editBoundIsCheckedOnTheDraftAndOnTheComposedBatch() throws {
        let limit = ProjectGraphLimitError.exceeded(path: "$.edits", maximum: ProjectGraphLimits.edits)
        let request = Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        let overfull = Compose.draft((0...ProjectGraphLimits.edits).map { .disconnect(Fixture.id("edg.gone.\($0)")) })
        #expect(throws: WiringComposeRefusal.preview(.bounds(limit))) { try Compose.compose(request, into: overfull) }
        // Each padding node is added and then moved, so N edits stay within the node bound.
        let pads = (0..<ProjectGraphLimits.edits / 2).map { Fixture.node("nod.pad.\($0)", ports: []) }
        let adds: [GraphEdit] = pads.map { .addNode($0) } + pads.map { .moveNode($0.id, to: nil) }
        // N − 1 earlier edits plus the connect is exactly N: accepted.
        let composed = try Compose.compose(request, into: Compose.draft(Array(adds.dropLast())))
        #expect(composed.edits.count == ProjectGraphLimits.edits)
        // N earlier edits plus the connect is N + 1: every bound is the one bounds refusal.
        #expect(throws: WiringComposeRefusal.preview(.bounds(limit))) {
            try Compose.compose(request, into: Compose.draft(adds))
        }
    }

    @Test func connectAtTheEdgeBoundIsRefusedWithBounds() {
        // Dangling padding fills the graph to exactly the edge bound; the graph itself is within bounds.
        let padding = (Fixture.graph.edges.count..<ProjectGraphLimits.edges).map { index in
            Fixture.edge("edg.pad.\(index)", Fixture.address("nod.gone", "out"), Fixture.address("nod.gone", "in"))
        }
        let full = Fixture.with(padding)
        #expect(full.edges.count == ProjectGraphLimits.edges)
        let limit = ProjectGraphLimitError.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges)
        let request = Compose.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        #expect(throws: WiringComposeRefusal.preview(.bounds(limit))) {
            try Compose.compose(request, into: Compose.draft(on: full), active: full)
        }
        #expect(throws: WiringComposeRefusal.preview(.bounds(limit))) {
            try WiringDraftComposer.destinations(from: request.from, active: full, draft: Compose.draft(on: full))
        }
    }

    @Test func classesComeFromTheDraftGraphNotTheActiveGraph() throws {
        // Existing in the active graph, but the draft disconnects it.
        let freed = Compose.draft([.disconnect(Fixture.id("edg.keys-verb"))])
        let composed = try Compose.compose(Compose.request("edg.keys-verb-2", ("nod.keys", "out"), ("nod.verb", "in")),
                                           into: freed)
        #expect(composed.edits.count == 2)
        // Valid in the active graph, but the draft already wires it.
        let wired = Fixture.edge("edg.keys-mains", Fixture.address("nod.keys", "out"),
                                 Fixture.address("nod.mains", "in"))
        #expect(throws: WiringComposeRefusal.existing(Fixture.id("edg.keys-mains"))) {
            try Compose.compose(Compose.request("edg.keys-mains-2", ("nod.keys", "out"), ("nod.mains", "in")),
                                into: Compose.draft([.connect(wired)]))
        }
    }
}
