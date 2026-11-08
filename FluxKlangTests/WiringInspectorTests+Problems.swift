//
//  WiringInspectorTests+Problems.swift
//  FluxKlangTests
//
//  The contract diagnostics of a selected node or edge (#101 WIN1): the table of all 30 validation errors (code,
//  scope, detail, stable ID and sentence), which errors concern which subject, their order and de-duplication, and
//  the words of the sentences and labels.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

extension WiringInspectorTests {
    /// One validation error and what the inspector says about it. `stableID` and `sentence` are empty for the six
    /// errors that are never listed (graph-level and uncheckable ones).
    fileprivate struct ClassifierRow {
        let error: GraphValidationError
        let code: String
        let scope: WiringInspectorScope
        let detail: String
        let stableID: String
        let sentence: String
    }

    fileprivate static func nodeRow(
        _ error: GraphValidationError, _ code: String, detail: String = "", words: String,
        scope: WiringInspectorScope? = nil
    ) -> ClassifierRow {
        let spoken = detail.isEmpty ? words : "\(words) \(detail)"
        return ClassifierRow(
            error: error, code: code, scope: scope ?? .node(nodeID("nod.a")), detail: detail,
            stableID: "\(code)|nod.a|\(detail)", sentence: "Node Reverb: \(spoken)."
        )
    }

    fileprivate static func edgeRow(
        _ error: GraphValidationError, _ code: String, detail: String = "", words: String
    ) -> ClassifierRow {
        let spoken = detail.isEmpty ? words : "\(words) \(detail)"
        return ClassifierRow(
            error: error, code: code, scope: .edge(edgeID("edg.a")), detail: detail,
            stableID: "\(code)|edg.a|\(detail)", sentence: "Wire edg.a: \(spoken)."
        )
    }

    fileprivate static func unlistedRow(
        _ error: GraphValidationError, _ code: String, _ scope: WiringInspectorScope, detail: String = ""
    ) -> ClassifierRow {
        ClassifierRow(error: error, code: code, scope: scope, detail: detail, stableID: "", sentence: "")
    }

    fileprivate static func classifierRows() -> [ClassifierRow] {
        let node = nodeID("nod.a")
        let other = nodeID("nod.b")
        let edge = edgeID("edg.a")
        let port = portID("prt.a")
        let capability: CapabilityID = Fixture.id("cap.a")
        let address = PortAddress(node: node, port: port)
        return [
            unlistedRow(.bounds(.exceeded(path: "$.nodes", maximum: 4_096)), "bounds", .uncheckable),
            unlistedRow(.reviewRequired, "reviewRequired", .graph),
            unlistedRow(.invalidRequiredFeatures(["x"]), "invalidRequiredFeatures", .uncheckable),
            unlistedRow(.requiredFeaturesCollision, "requiredFeaturesCollision", .uncheckable),
            nodeRow(.invalidMuteState(node), "invalidMuteState", words: "invalid mute state"),
            nodeRow(.invalidMuteShape(node), "invalidMuteShape", words: "invalid mute shape"),
            nodeRow(.invalidGainState(node), "invalidGainState", words: "invalid gain state"),
            nodeRow(.invalidGainValue(node), "invalidGainValue", words: "invalid gain value"),
            nodeRow(.invalidGainShape(node), "invalidGainShape", words: "invalid gain shape"),
            nodeRow(.invalidPosition(node), "invalidPosition", words: "invalid position"),
            nodeRow(.duplicateNode(node), "duplicateNode", words: "duplicate node"),
            nodeRow(.duplicatePort(node, port), "duplicatePort", detail: "prt.a", words: "duplicate port"),
            edgeRow(.duplicateEdge(edge), "duplicateEdge", words: "duplicate edge"),
            edgeRow(.duplicateWire(edge), "duplicateWire", words: "duplicate wire"),
            unlistedRow(.duplicateCapability(capability), "duplicateCapability", .graph, detail: "cap.a"),
            nodeRow(.undefinedCapability(node: node, capability), "undefinedCapability",
                    detail: "cap.a", words: "undefined capability"),
            nodeRow(.unsupportedRequiredCapability(node: node, capability), "unsupportedRequiredCapability",
                    detail: "cap.a", words: "unsupported required capability"),
            nodeRow(.conflictingCapabilityLevel(node: node, capability), "conflictingCapabilityLevel",
                    detail: "cap.a", words: "conflicting capability level"),
            nodeRow(.nonRoutableNodeHasPorts(node), "nonRoutableNodeHasPorts", words: "non routable node has ports"),
            nodeRow(.missingReference(node: node, field: "role"), "missingReference",
                    detail: "role", words: "missing reference"),
            nodeRow(.invalidChannelCount(node, port), "invalidChannelCount", detail: "prt.a",
                    words: "invalid channel count"),
            edgeRow(.missingNode(edge: edge, node), "missingNode", detail: "nod.a", words: "missing node"),
            edgeRow(.missingPort(edge: edge, address), "missingPort", detail: "nod.a/prt.a", words: "missing port"),
            edgeRow(.wrongDirection(edge: edge), "wrongDirection", words: "wrong direction"),
            edgeRow(.signalMismatch(edge: edge, from: .audio, to: .control), "signalMismatch",
                    detail: "audio to control", words: "signal mismatch"),
            edgeRow(.channelMismatch(edge: edge, from: 2, to: 3), "channelMismatch", detail: "2 to 3",
                    words: "channel mismatch"),
            edgeRow(.invalidConversion(edge: edge), "invalidConversion", words: "invalid conversion"),
            edgeRow(.invalidFeedback(edge: edge), "invalidFeedback", words: "invalid feedback"),
            nodeRow(.cycleWithoutFeedback([node, other]), "cycleWithoutFeedback", words: "cycle without feedback",
                    scope: .nodes([node, other])),
            unlistedRow(.unknownFields(path: "$.nodes[0]"), "unknownFields", .graph, detail: "$.nodes[0]")
        ]
    }

    // MARK: - Classifier and sentences

    @Test func wiringInspectorClassifiesAll30ValidationErrorsByCodeScopeAndDetail() {
        let rows = Self.classifierRows()
        #expect(rows.count == 30)
        #expect(Set(rows.map(\.code)).count == 30)
        for row in rows {
            let parts = WiringInspectorProblem.classify(row.error)
            #expect(parts.code == row.code, "\(row.code)")
            #expect(parts.scope == row.scope, "\(row.code)")
            #expect(parts.detail == row.detail, "\(row.code)")
        }
    }

    @Test func wiringInspectorGivesTheStableIDAndSentenceOfThe24ListedErrorsWhenTheirOwnerIsSelected() throws {
        var listed = 0
        for row in Self.classifierRows() {
            let selection: (subject: WiringInspectorSubject, owned: Bool)
            switch row.scope {
            case .node(let id): selection = (.node(id), true)
            case .nodes(let ids): selection = (.node(try #require(ids.first)), true)
            case .edge(let id): selection = (.edge(id), true)
            case .graph, .uncheckable: selection = (.node(Self.nodeID("nod.a")), false)
            }
            let found = WiringInspectorProblem.problems(
                [row.error], subject: selection.subject, attached: [], title: "Reverb"
            )
            guard selection.owned else {
                #expect(found.isEmpty, "\(row.code)")
                continue
            }
            listed += 1
            #expect(found.count == 1, "\(row.code)")
            let problem = try #require(found.first, "\(row.code)")
            #expect(problem.code == row.code)
            #expect(problem.stableID == row.stableID)
            #expect(problem.sentence == row.sentence)
        }
        #expect(listed == 24)
    }

    @Test func wiringInspectorUsesTheLabelOfTheSelectedNodeInNodeSentencesAndTheEdgeIDInWireSentences() throws {
        let twins = [Fixture.audio("in", .input, 2), Fixture.audio("in", .input, 2)]
        var node = Fixture.node("nod.dup", ports: twins, at: 9)
        node.label = "Reverb"
        let wire = Self.wire("edg.keys-dup", from: ("nod.keys", "out"), to: ("nod.ghost", "in"))
        let edits: [GraphEdit] = [.connect(wire)]
        let graph = Fixture.with([], nodes: [node])
        let own = try Self.inspect(Self.node("nod.dup"), on: graph)
        #expect(own.problems.map(\.sentence) == ["Node Reverb: duplicate port in."])
        let keys = try Self.inspect(Self.node("nod.keys"), edits, on: graph)
        #expect(keys.problems.map(\.sentence) == ["Wire edg.keys-dup: missing node nod.ghost."])
        let edge = try Self.inspect(Self.edge("edg.keys-dup"), edits, on: graph)
        #expect(edge.problems.map(\.sentence) == ["Wire edg.keys-dup: missing node nod.ghost."])
    }

    // MARK: - Which errors concern the selection

    @Test func wiringInspectorListsForANodeItsOwnErrorsItsAttachedEdgesErrorsAndTheCyclesNamingIt() {
        let node = Self.nodeID("nod.a")
        let errors: [GraphValidationError] = [
            .duplicateNode(node), .invalidPosition(Self.nodeID("nod.b")),
            .wrongDirection(edge: Self.edgeID("edg.in")), .invalidConversion(edge: Self.edgeID("edg.out")),
            .cycleWithoutFeedback([Self.nodeID("nod.b"), node]), .cycleWithoutFeedback([Self.nodeID("nod.b")])
        ]
        let found = WiringInspectorProblem.problems(
            errors, subject: .node(node), attached: [Self.edgeID("edg.in")], title: "A"
        )
        let expected = [
            "cycleWithoutFeedback|nod.a|", "duplicateNode|nod.a|", "wrongDirection|edg.in|"
        ]
        #expect(found.map(\.stableID) == expected)
    }

    @Test func wiringInspectorListsForAnEdgeOnlyTheErrorsOfItsOwnEdgeAndNotTheNodesOrCyclesAroundIt() {
        let edge = Self.edgeID("edg.a")
        let errors: [GraphValidationError] = [
            .wrongDirection(edge: edge), .invalidConversion(edge: Self.edgeID("edg.b")),
            .duplicateNode(Self.nodeID("nod.a")), .cycleWithoutFeedback([Self.nodeID("nod.a")])
        ]
        let found = WiringInspectorProblem.problems(errors, subject: .edge(edge), attached: [edge], title: "edg.a")
        #expect(found.map(\.stableID) == ["wrongDirection|edg.a|"])
    }

    @Test func wiringInspectorListsNoGraphLevelOrUncheckableErrorForANodeOrAnEdge() throws {
        let errors: [GraphValidationError] = [
            .reviewRequired, .duplicateCapability(Fixture.id("cap.a")), .unknownFields(path: "$"),
            .requiredFeaturesCollision, .invalidRequiredFeatures([]),
            .bounds(.exceeded(path: "$.nodes", maximum: 4_096))
        ]
        let node = Self.nodeID("nod.a")
        #expect(WiringInspectorProblem.problems(errors, subject: .node(node), attached: [], title: "A").isEmpty)
        let edge = Self.edgeID("edg.a")
        #expect(WiringInspectorProblem.problems(errors, subject: .edge(edge), attached: [], title: "A").isEmpty)
        var review = Fixture.graph
        review.requiresReview = true
        #expect(review.validationErrors() == [.reviewRequired])
        let keysOnReview = try Self.inspect(Self.node("nod.keys"), on: review)
        let wireOnReview = try Self.inspect(Self.edge("edg.keys-verb"), on: review)
        #expect(keysOnReview.problems.isEmpty)
        #expect(wireOnReview.problems.isEmpty)
    }

    @Test func wiringInspectorListsATwoNodeCycleOnBothNodesAndOnNeitherEdge() throws {
        let again = Self.wire("edg.delay-verb", from: ("nod.delay", "out"), to: ("nod.verb", "in"))
        let edits: [GraphEdit] = [.disconnect(Self.edgeID("edg.delay-verb-fb")), .connect(again)]
        let verb = try Self.inspect(Self.node("nod.verb"), edits)
        #expect(verb.problems.map(\.stableID) == ["cycleWithoutFeedback|nod.verb|"])
        #expect(verb.problems.map(\.sentence) == ["Node nod.verb: cycle without feedback."])
        let delay = try Self.inspect(Self.node("nod.delay"), edits)
        #expect(delay.problems.map(\.stableID) == ["cycleWithoutFeedback|nod.delay|"])
        let keys = try Self.inspect(Self.node("nod.keys"), edits)
        #expect(keys.problems.isEmpty)
        for name in ["edg.verb-delay", "edg.delay-verb"] {
            let wireInspector = try Self.inspect(Self.edge(name), edits)
            #expect(wireInspector.problems.isEmpty, "\(name)")
        }
    }

    @Test func wiringInspectorListsAnEndpointNodesErrorOnTheNodeAndNotOnAnEdgeThatTouchesIt() throws {
        let ports = [Fixture.audio("x", .output, 2), Fixture.audio("x", .input, 2)]
        let node = Fixture.node("nod.dup", ports: ports, at: 9)
        let wire = Self.wire("edg.dup-mains", from: ("nod.dup", "x"), to: ("nod.mains", "in"))
        let graph = Fixture.with([wire], nodes: [node])
        #expect(graph.validationErrors() == [.duplicatePort(Self.nodeID("nod.dup"), Self.portID("x"))])
        let owner = try Self.inspect(Self.node("nod.dup"), on: graph)
        #expect(owner.problems.map(\.stableID) == ["duplicatePort|nod.dup|x"])
        let mains = try Self.inspect(Self.node("nod.mains"), on: graph)
        #expect(mains.problems.isEmpty)
        let touching = try Self.inspect(Self.edge("edg.dup-mains"), on: graph)
        #expect(touching.problems.isEmpty)
    }

    // MARK: - Order and de-duplication

    @Test func wiringInspectorOrdersProblemsAscendingByStableIDWhateverTheOrderOfTheErrors() {
        let node = Self.nodeID("nod.a")
        let errors: [GraphValidationError] = [
            .missingNode(edge: Self.edgeID("edg.2"), Self.nodeID("nod.x")),
            .duplicatePort(node, Self.portID("prt.a")),
            .missingReference(node: node, field: "\u{212B}"), .missingReference(node: node, field: "\u{E0}"),
            .missingNode(edge: Self.edgeID("edg.1"), Self.nodeID("nod.x"))
        ]
        let attached = [Self.edgeID("edg.1"), Self.edgeID("edg.2")]
        let found = WiringInspectorProblem.problems(errors, subject: .node(node), attached: attached, title: "A")
        let expected = [
            "duplicatePort|nod.a|prt.a", "missingNode|edg.1|nod.x", "missingNode|edg.2|nod.x",
            "missingReference|nod.a|\u{E0}", "missingReference|nod.a|\u{212B}"
        ]
        #expect(found.map(\.stableID) == expected)
    }

    @Test func wiringInspectorKeepsTwoProblemsOfOneEdgeThatDifferOnlyInTheirDetail() throws {
        let wire = Self.wire("edg.ghosts", from: ("nod.ghost2", "out"), to: ("nod.ghost1", "in"))
        let inspector = try Self.inspect(Self.edge("edg.ghosts"), [.connect(wire)])
        let expected = ["missingNode|edg.ghosts|nod.ghost1", "missingNode|edg.ghosts|nod.ghost2"]
        #expect(inspector.problems.map(\.stableID) == expected)
        #expect(inspector.label == "nod.ghost2 (missing) to nod.ghost1 (missing), draft, not active. 2 problems.")
    }

    @Test func wiringInspectorCollapsesTheRepeatedMissingNodeOfASelfLoopOnAMissingNodeToOneProblem() throws {
        let loop = Self.wire("edg.ghost-loop", from: ("nod.ghost", "out"), to: ("nod.ghost", "in"))
        let inspector = try Self.inspect(Self.edge("edg.ghost-loop"), [.connect(loop)])
        #expect(inspector.problems.map(\.stableID) == ["missingNode|edg.ghost-loop|nod.ghost"])
        #expect(inspector.label == "nod.ghost (missing) to nod.ghost (missing), draft, not active. 1 problem.")
    }

    // MARK: - Words and labels

    @Test func wiringInspectorWritesACountInTheSingularOnlyAtExactlyOneWithoutGrouping() {
        #expect(WiringInspectorLabel.count(0, "input") == "0 inputs")
        #expect(WiringInspectorLabel.count(1, "input") == "1 input")
        #expect(WiringInspectorLabel.count(2, "input") == "2 inputs")
        #expect(WiringInspectorLabel.count(12, "connection") == "12 connections")
        #expect(WiringInspectorLabel.count(1_000_000, "output") == "1000000 outputs")
    }

    @Test func wiringInspectorSummarisesZeroOneTwoAndTwelveProblems() {
        #expect(WiringInspectorLabel.problemSummary(0) == "No problems.")
        #expect(WiringInspectorLabel.problemSummary(1) == "1 problem.")
        #expect(WiringInspectorLabel.problemSummary(2) == "2 problems.")
        #expect(WiringInspectorLabel.problemSummary(12) == "12 problems.")
    }

    @Test func wiringInspectorSplitsACodeIntoLowerCaseWordsAtEachAsciiCapitalAndLeavesOtherScalarsAlone() {
        #expect(WiringInspectorLabel.words("missingNode") == "missing node")
        #expect(WiringInspectorLabel.words("cycleWithoutFeedback") == "cycle without feedback")
        #expect(WiringInspectorLabel.words("ABc") == " a bc")
        #expect(WiringInspectorLabel.words("x1Y") == "x1 y")
        #expect(WiringInspectorLabel.words("zZ") == "z z")
        #expect(WiringInspectorLabel.words("\u{E9}V\u{C9}") == "\u{E9} v\u{C9}")
        #expect(WiringInspectorLabel.words("").isEmpty)
    }

    @Test func wiringInspectorLeavesOutTheSpaceAndDetailOfASentenceWhenTheDetailIsEmpty() {
        #expect(WiringInspectorLabel.sentence(prefix: "Wire e", code: "fooBar", detail: "") == "Wire e: foo bar.")
        let spoken = WiringInspectorLabel.sentence(prefix: "Wire e", code: "fooBar", detail: "d x")
        #expect(spoken == "Wire e: foo bar d x.")
        #expect(WiringInspectorLabel.markerWords(.active) == "active")
        #expect(WiringInspectorLabel.markerWords(.draft) == "draft, not active")
    }
}
