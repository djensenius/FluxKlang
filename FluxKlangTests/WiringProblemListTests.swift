//
//  WiringProblemListTests.swift
//  FluxKlangTests
//
//  The graph-wide wiring problem list (#101 WGP1): one entry per distinct problem with its fixed sentence and the
//  node or edge to focus, sorted once by key bytes, capped at 64 with a count of the rest, made from errors, a
//  graph or a draft. The list is a pure value: nothing here reads a view or a key.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct WiringProblemListTests {
    @Test func wiringProblemListOfNoErrorsAndOfAValidGraphIsEmpty() {
        let lists = [WiringProblemList.make(errors: []), WiringProblemList.make(graph: ProblemFixtures.validGraph())]
        for list in lists {
            let line = list.omittedLine
            #expect(list.entries.isEmpty)
            #expect(list.isEmpty)
            #expect(list.distinctCount == 0)
            #expect(list.omittedCount == 0)
            #expect(line == nil)
            #expect(list.summary == "No problems.")
        }
    }

    @Test func wiringProblemListOfOneEdgeErrorHasTheFixedKeySentenceTargetAndSummary() throws {
        let edge = ProblemFixtures.edge("e1")
        let list = WiringProblemList.make(errors: [.wrongDirection(edge: edge)])
        try #require(list.entries.count == 1)
        let entry = list.entries[0]
        let target = entry.target
        let expected: WiringSelectionTarget? = .edge(edge)
        let line = list.omittedLine
        #expect(entry.code == "wrongDirection")
        #expect(entry.stableKey == "wrongDirection\0edge:e1\0")
        #expect(entry.sentence == "Wire e1: wrong direction.")
        #expect(target == expected)
        #expect(!list.isEmpty)
        #expect(list.distinctCount == 1)
        #expect(list.omittedCount == 0)
        #expect(line == nil)
        #expect(list.summary == "1 problem.")
    }

    @Test func wiringProblemListTargetsTheNodeTheEdgeOrNothingForEveryErrorCase() throws {
        let rows = ProblemFixtures.targetRows()
        try #require(rows.count == 30)
        for row in rows {
            let list = WiringProblemList.make(errors: [row.error])
            try #require(list.entries.count == 1)
            let target = list.entries[0].target
            let expected = row.target
            #expect(target == expected, "\(row.error)")
        }
    }

    @Test func wiringProblemListTargetsTheLeastNodeBytesOfACycle() throws {
        let nodeA = ProblemFixtures.node("a")
        let nodeB = ProblemFixtures.node("b")
        let nodeC = ProblemFixtures.node("c")
        let shorter = ProblemFixtures.node("n1")
        let longer = ProblemFixtures.node("n10")
        let list = WiringProblemList.make(errors: [.cycleWithoutFeedback([nodeB, nodeA, nodeC])])
        try #require(list.entries.count == 1)
        let sentence = list.entries[0].sentence
        #expect(sentence == "Cycle b a c: cycle without feedback.")
        let least = try ProblemFixtures.cycleTarget([nodeB, nodeA, nodeC])
        let single = try ProblemFixtures.cycleTarget([nodeB])
        let prefixed = try ProblemFixtures.cycleTarget([longer, shorter])
        let empty = try ProblemFixtures.cycleTarget([])
        let expectedLeast: WiringSelectionTarget? = .node(nodeA)
        let expectedSingle: WiringSelectionTarget? = .node(nodeB)
        let expectedPrefixed: WiringSelectionTarget? = .node(shorter)
        #expect(least == expectedLeast)
        #expect(single == expectedSingle)
        #expect(prefixed == expectedPrefixed)
        #expect(empty == nil)
    }

    @Test func wiringProblemListSortsByKeyBytesWhateverTheInputOrder() {
        let missing = GraphValidationError.missingNode(edge: ProblemFixtures.edge("e0"), ProblemFixtures.node("ghost"))
        let feedback = GraphValidationError.invalidFeedback(edge: ProblemFixtures.edge("e9"))
        let tenth = GraphValidationError.duplicateEdge(ProblemFixtures.edge("e10"))
        let second = GraphValidationError.duplicateEdge(ProblemFixtures.edge("e2"))
        let first = GraphValidationError.duplicateEdge(ProblemFixtures.edge("e1"))
        let scrambled = [missing, feedback, second, tenth, first]
        let inputs: [[GraphValidationError]] = [
            scrambled, Array(scrambled.reversed()), [tenth, missing, first, feedback, second]
        ]
        let expected = [
            "duplicateEdge\0edge:e1\0", "duplicateEdge\0edge:e10\0", "duplicateEdge\0edge:e2\0",
            "invalidFeedback\0edge:e9\0", "missingNode\0edge:e0\0ghost"
        ]
        for input in inputs {
            let keys = WiringProblemList.make(errors: input).entries.map(\.stableKey)
            #expect(keys == expected)
        }
    }

    @Test func wiringProblemListCapsAtSixtyFourAndSaysHowManyAreNotShown() throws {
        #expect(WiringProblemList.maximumEntries == 64)
        try ProblemFixtures.expectCap(63, shown: 63, omitted: 0, line: nil, last: "e00062")
        try ProblemFixtures.expectCap(64, shown: 64, omitted: 0, line: nil, last: "e00063")
        try ProblemFixtures.expectCap(65, shown: 64, omitted: 1, line: "1 problem not shown.", last: "e00063")
        try ProblemFixtures.expectCap(70, shown: 64, omitted: 6, line: "6 problems not shown.", last: "e00063")
    }

    @Test func wiringProblemListOfFiftyThousandDistinctErrorsRepeatedKeepsOnePerProblem() throws {
        let backward = ProblemFixtures.wrongDirections(50_000, descending: true)
        let forward = ProblemFixtures.wrongDirections(50_000, descending: false)
        let errors = backward + forward
        let list = WiringProblemList.make(errors: errors)
        try #require(list.entries.count == 64)
        let firstKey = list.entries[0].stableKey
        let lastKey = list.entries[63].stableKey
        let line = list.omittedLine
        #expect(list.distinctCount == 50_000)
        #expect(list.omittedCount == 49_936)
        #expect(line == "49936 problems not shown.")
        #expect(firstKey == "wrongDirection\0edge:e00000\0")
        #expect(lastKey == "wrongDirection\0edge:e00063\0")
        #expect(list.summary == "50000 problems.")
    }

    @Test func wiringProblemListKeepsOneEntryPerDistinctKeyNotPerError() {
        let node = ProblemFixtures.node("n1")
        let edge = ProblemFixtures.edge("e1")
        let port = ProblemFixtures.port("p1")
        let other = ProblemFixtures.port("p2")
        let nodes = [node, ProblemFixtures.node("n2")]
        let wider = [node, ProblemFixtures.node("n3")]
        let triple = [GraphValidationError.duplicateNode(node), .duplicateNode(node), .duplicateNode(node)]
        let codes = [GraphValidationError.duplicateWire(edge), .duplicateEdge(edge)]
        let ports = [GraphValidationError.duplicatePort(node, port), .duplicatePort(node, other)]
        let cycles = [
            GraphValidationError.cycleWithoutFeedback(nodes), .cycleWithoutFeedback(wider),
            .cycleWithoutFeedback(nodes)
        ]
        ProblemFixtures.expectKeys(triple, ["duplicateNode\0node:n1\0"])
        ProblemFixtures.expectKeys(codes, ["duplicateEdge\0edge:e1\0", "duplicateWire\0edge:e1\0"])
        ProblemFixtures.expectKeys(ports, ["duplicatePort\0node:n1\0p1", "duplicatePort\0node:n1\0p2"])
        ProblemFixtures.expectKeys(
            cycles, ["cycleWithoutFeedback\0nodes:n1,n2\0", "cycleWithoutFeedback\0nodes:n1,n3\0"]
        )
    }

    @Test func wiringProblemListKeepsDetailsThatDifferOnlyInNormalisationApartInByteOrder() {
        let composed = GraphValidationError.unknownFields(path: "$.\u{E9}")
        let decomposed = GraphValidationError.unknownFields(path: "$.e\u{301}")
        let expected = [
            Array("unknownFields\0graph\0$.e\u{301}".utf8), Array("unknownFields\0graph\0$.\u{E9}".utf8)
        ]
        for input in [[composed, decomposed], [decomposed, composed]] {
            let list = WiringProblemList.make(errors: input)
            let keys = list.entries.map { Array($0.stableKey.utf8) }
            #expect(keys == expected)
            #expect(list.distinctCount == 2)
        }
    }

    @Test func wiringProblemListOfRealGraphsListsEachDefectWhereItIs() throws {
        let danglingList = WiringProblemList.make(graph: ProblemFixtures.danglingGraph())
        try #require(danglingList.entries.count == 1)
        let missing = danglingList.entries[0]
        let missingTarget = missing.target
        let expectedEdge: WiringSelectionTarget? = .edge(ProblemFixtures.edge("e0"))
        #expect(missing.sentence == "Wire e0: missing node ghost.")
        #expect(missingTarget == expectedEdge)

        let cycleList = WiringProblemList.make(graph: ProblemFixtures.cycleGraph())
        try #require(cycleList.entries.count == 1)
        let loop = cycleList.entries[0]
        let loopTarget = loop.target
        let nodeOne = ProblemFixtures.node("n1")
        let expectedNode: WiringSelectionTarget? = .node(nodeOne)
        #expect(loop.sentence == "Cycle n1 n2: cycle without feedback.")
        #expect(loopTarget == expectedNode)

        let both = WiringProblemList.make(graph: ProblemFixtures.defectGraph())
        let codes = both.entries.map(\.code)
        let targets = both.entries.map(\.target)
        let expectedCodes = ["cycleWithoutFeedback", "duplicateNode", "missingNode", "reviewRequired"]
        let expectedTargets: [WiringSelectionTarget?] = [
            .node(nodeOne), .node(nodeOne), .edge(ProblemFixtures.edge("e3")), nil
        ]
        #expect(codes == expectedCodes)
        #expect(targets == expectedTargets)
        #expect(both.distinctCount == 4)
    }

    @Test func wiringProblemListOfAnUncheckableGraphListsItAsAGraphProblem() throws {
        var badFeatures = ProblemFixtures.validGraph()
        badFeatures.requiredFeatures = ["bogus"]
        var collision = ProblemFixtures.validGraph()
        collision.unknownFields["requiredFeatures"] = .bool(true)
        try ProblemFixtures.expectOneGraphProblem(
            badFeatures, code: "invalidRequiredFeatures", sentence: "Graph: invalid required features."
        )
        try ProblemFixtures.expectOneGraphProblem(
            collision, code: "requiredFeaturesCollision", sentence: "Graph: required features collision."
        )
        try ProblemFixtures.expectOneGraphProblem(
            ProblemFixtures.overLimitGraph(), code: "bounds", sentence: "Graph: bounds."
        )
    }

    @Test func wiringProblemListEntriesAreTheImpactProblemsOfTheClassifiedErrors() throws {
        for row in ProblemFixtures.targetRows() {
            let list = WiringProblemList.make(errors: [row.error])
            try #require(list.entries.count == 1)
            let problem = list.entries[0].problem
            let expected = WiringImpactProblems.problem(WiringInspectorProblem.classify(row.error))
            #expect(problem == expected, "\(row.error)")
        }
    }

    @Test func wiringProblemListOfADraftListsTheDraftGraphAndCarriesEachRefusalVerbatim() throws {
        var active = ProblemFixtures.danglingGraph()
        active.unknownFields["extra"] = .bool(true)
        let dangling = ProblemFixtures.wire("e5", from: "ghost", to: "n1")
        let draft = ProblemFixtures.draft([.disconnect(ProblemFixtures.edge("e0")), .connect(dangling)], on: active)
        let keys = try WiringProblemList.make(active: active, draft: draft).entries.map(\.stableKey)
        #expect(keys == ["missingNode\0edge:e5\0ghost"])

        var invalid = ProblemFixtures.danglingGraph()
        invalid.requiresReview = true
        let three = try ContractRevision(3)
        let seven = try ContractRevision(7)
        invalid.revision = three
        var foreign = ProblemFixtures.draft([], on: invalid)
        foreign.graph = GraphID(validated: "gph.other")
        var stale = ProblemFixtures.draft([], on: invalid)
        stale.baseRevision = seven
        let wrongGraph = ProblemFixtures.refusal(active: invalid, draft: foreign)
        let wrongBase = ProblemFixtures.refusal(active: invalid, draft: stale)
        let graphMismatch = WiringPreviewRefusal.draftGraphMismatch(draft: foreign.graph, active: invalid.id)
        let baseMismatch = WiringPreviewRefusal.draftBaseMismatch(draft: seven, active: three)
        let expectedGraph: WiringProblemListRefusal? = .preview(graphMismatch)
        let expectedBase: WiringProblemListRefusal? = .preview(baseMismatch)
        #expect(wrongGraph == expectedGraph)
        #expect(wrongBase == expectedBase)

        let doubled = ProblemFixtures.defectGraph()
        let ambiguous = ProblemFixtures.refusal(active: doubled, draft: ProblemFixtures.draft([], on: doubled))
        let expectedAmbiguous: WiringProblemListRefusal? = .preview(.ambiguousNode(ProblemFixtures.node("n1")))
        #expect(ambiguous == expectedAmbiguous)
    }

    @Test func wiringProblemListOfADraftRefusesAnOverLimitGraphAsBounds() {
        let huge = ProblemFixtures.overLimitGraph()
        let refused = ProblemFixtures.refusal(active: huge, draft: ProblemFixtures.draft([], on: huge))
        let expected: WiringProblemListRefusal? = .preview(.bounds(.exceeded(path: "$.nodes", maximum: 4_096)))
        #expect(refused == expected)
    }

    @Test func wiringProblemListOfAGraphIsPureAndEqualsTheListOfItsErrors() {
        var graph = ProblemFixtures.defectGraph()
        graph.unknownFields["extra"] = .bool(true)
        let first = WiringProblemList.make(graph: graph)
        let second = WiringProblemList.make(graph: graph)
        let fromErrors = WiringProblemList.make(errors: graph.validationErrors())
        let again = WiringProblemList.make(errors: graph.validationErrors())
        let codes = first.entries.map(\.code)
        #expect(first == second)
        #expect(first == fromErrors)
        #expect(fromErrors == again)
        #expect(!codes.contains("unknownFields"))
    }

    @Test func wiringProblemListNeverTargetsAPort() throws {
        var ports = 0
        for row in ProblemFixtures.targetRows() {
            let list = WiringProblemList.make(errors: [row.error])
            try #require(list.entries.count == 1)
            switch list.entries[0].target {
            case .port: ports += 1
            case .node, .edge, nil: break
            }
        }
        #expect(ports == 0)
    }

    @Test(.enabled(if: !ProblemFixtures.problemSources().isEmpty))
    func wiringProblemListSourcesNameNoBannedTokenAndAllThreeAreRead() throws {
        let texts = ProblemFixtures.problemSources()
        try #require(texts.count == 3)
        let worker = "Ta" + "sk"
        let timer = "Cl" + "ock"
        let fallback = "defa" + "ult:"
        let everywhere = [worker, timer, fallback]
        let banned: [String] = [
            "Date(", "Double", "Float", "Codable", "try!", "static var", "mutating", ".contains(", ".filter(",
            ".sorted(", ".min(", ".max(", ".firstIndex", ".first(where", "removeFirst", ".rawValue <", ".hasPrefix",
            "Set<String>"
        ]
        for text in texts {
            let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let code = lines.joined(separator: "\n")
            for token in everywhere { #expect(!text.contains(token), "\(token)") }
            for token in banned { #expect(!code.contains(token), "\(token)") }
        }
    }
}

private enum ProblemFixtures {
    typealias Row = (error: GraphValidationError, target: WiringSelectionTarget?)

    static let graphID = GraphID(validated: "gph.problems")
    static let draftID = DraftID(validated: "dft.problems")
    static let files = ["WiringProblemList.swift", "WiringProblemList+Text.swift", "WiringProblemListRefusal.swift"]

    static func id<Tag: ContractIDTag>(_ raw: String) -> ContractID<Tag> {
        guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("Invalid fixture ID \(raw)") }
        return id
    }

    static func node(_ raw: String) -> NodeID { id(raw) }
    static func port(_ raw: String) -> PortID { id(raw) }
    static func edge(_ raw: String) -> EdgeID { id(raw) }
    static func capability(_ raw: String) -> CapabilityID { id(raw) }

    /// A plugin with a MIDI input `in` and a MIDI output `out`, so a wire between two of them is valid.
    static func midiNode(_ raw: String) -> GraphNode {
        let input = GraphPort(id: port("in"), direction: .input, signal: .midi)
        let output = GraphPort(id: port("out"), direction: .output, signal: .midi)
        return GraphNode(id: node(raw), kind: .plugin, label: raw, ports: [input, output])
    }

    /// An edge from the `out` port of `source` to the `in` port of `sink`.
    static func wire(_ raw: String, from source: String, to sink: String) -> GraphEdge {
        let start = PortAddress(node: node(source), port: port("out"))
        let end = PortAddress(node: node(sink), port: port("in"))
        return GraphEdge(id: edge(raw), from: start, to: end)
    }

    static func graph(_ nodes: [GraphNode], _ edges: [GraphEdge]) -> GraphDocument {
        GraphDocument(id: graphID, nodes: nodes, edges: edges)
    }

    /// No problem: n1 sends to n2.
    static func validGraph() -> GraphDocument {
        graph([midiNode("n1"), midiNode("n2")], [wire("e1", from: "n1", to: "n2")])
    }

    /// One problem: edge e0 leaves the missing node ghost.
    static func danglingGraph() -> GraphDocument {
        graph([midiNode("n1")], [wire("e0", from: "ghost", to: "n1")])
    }

    /// One problem: n1 and n2 send to each other with no feedback edge.
    static func cycleGraph() -> GraphDocument {
        graph([midiNode("n2"), midiNode("n1")], [wire("e1", from: "n1", to: "n2"), wire("e2", from: "n2", to: "n1")])
    }

    /// Four problems that validation emits in an order other than key order: review required, a repeated n1, the
    /// dangling e3 and the cycle of n1 and n2.
    static func defectGraph() -> GraphDocument {
        var document = graph(
            [midiNode("n2"), midiNode("n1"), midiNode("n1")],
            [wire("e1", from: "n1", to: "n2"), wire("e2", from: "n2", to: "n1"), wire("e3", from: "ghost", to: "n1")]
        )
        document.requiresReview = true
        return document
    }

    /// One node more than `ProjectGraphLimits.nodes`, so validation stops at the bounds.
    static func overLimitGraph() -> GraphDocument {
        let nodes = (0...ProjectGraphLimits.nodes).map {
            GraphNode(id: node("n" + String($0)), kind: .plugin, label: "n", ports: [])
        }
        return graph(nodes, [])
    }

    static func draft(_ edits: [GraphEdit], on document: GraphDocument) -> DraftEdits {
        DraftEdits(id: draftID, graph: document.id, baseRevision: document.revision, edits: edits)
    }

    static func refusal(active: GraphDocument, draft: DraftEdits) -> WiringProblemListRefusal? {
        do throws(WiringProblemListRefusal) {
            _ = try WiringProblemList.make(active: active, draft: draft)
            return nil
        } catch {
            return error
        }
    }

    /// `count` distinct wrong-direction errors with zero-padded edge IDs, so byte order and number order agree.
    static func wrongDirections(_ count: Int, descending: Bool) -> [GraphValidationError] {
        let numbers = Array(0..<count)
        let ordered = descending ? Array(numbers.reversed()) : numbers
        return ordered.map { .wrongDirection(edge: edge(String(format: "e%05ld", $0))) }
    }

    /// Every error case with the focus it must give, typed by hand: a node, an edge, or nothing.
    static func targetRows() -> [Row] {
        let nodeOne = node("n1")
        let nodeTwo = node("n2")
        let edgeOne = edge("e1")
        let portOne = port("p1")
        let level = capability("cap.x")
        let address = PortAddress(node: nodeTwo, port: portOne)
        var rows: [Row] = []
        rows.append((.bounds(.exceeded(path: "$.nodes", maximum: 4_096)), nil))
        rows.append((.reviewRequired, nil))
        rows.append((.invalidRequiredFeatures(["bogus"]), nil))
        rows.append((.requiredFeaturesCollision, nil))
        rows.append((.invalidMuteState(nodeOne), .node(nodeOne)))
        rows.append((.invalidMuteShape(nodeOne), .node(nodeOne)))
        rows.append((.invalidGainState(nodeOne), .node(nodeOne)))
        rows.append((.invalidGainValue(nodeOne), .node(nodeOne)))
        rows.append((.invalidGainShape(nodeOne), .node(nodeOne)))
        rows.append((.invalidPosition(nodeOne), .node(nodeOne)))
        rows.append((.duplicateNode(nodeOne), .node(nodeOne)))
        rows.append((.duplicatePort(nodeOne, portOne), .node(nodeOne)))
        rows.append((.duplicateEdge(edgeOne), .edge(edgeOne)))
        rows.append((.duplicateWire(edgeOne), .edge(edgeOne)))
        rows.append((.duplicateCapability(level), nil))
        rows.append((.undefinedCapability(node: nodeOne, level), .node(nodeOne)))
        rows.append((.unsupportedRequiredCapability(node: nodeOne, level), .node(nodeOne)))
        rows.append((.conflictingCapabilityLevel(node: nodeOne, level), .node(nodeOne)))
        rows.append((.nonRoutableNodeHasPorts(nodeOne), .node(nodeOne)))
        rows.append((.missingReference(node: nodeOne, field: "role"), .node(nodeOne)))
        rows.append((.invalidChannelCount(nodeOne, portOne), .node(nodeOne)))
        rows.append((.missingNode(edge: edgeOne, nodeTwo), .edge(edgeOne)))
        rows.append((.missingPort(edge: edgeOne, address), .edge(edgeOne)))
        rows.append((.wrongDirection(edge: edgeOne), .edge(edgeOne)))
        rows.append((.signalMismatch(edge: edgeOne, from: .audio, to: .midi), .edge(edgeOne)))
        rows.append((.channelMismatch(edge: edgeOne, from: 1, to: 2), .edge(edgeOne)))
        rows.append((.invalidConversion(edge: edgeOne), .edge(edgeOne)))
        rows.append((.invalidFeedback(edge: edgeOne), .edge(edgeOne)))
        rows.append((.cycleWithoutFeedback([nodeTwo, nodeOne]), .node(nodeOne)))
        rows.append((.unknownFields(path: "$"), nil))
        return rows
    }

    static func cycleTarget(_ ids: [NodeID]) throws -> WiringSelectionTarget? {
        let list = WiringProblemList.make(errors: [.cycleWithoutFeedback(ids)])
        try #require(list.entries.count == 1)
        return list.entries[0].target
    }

    static func expectKeys(_ errors: [GraphValidationError], _ expected: [String]) {
        let list = WiringProblemList.make(errors: errors)
        let keys = list.entries.map(\.stableKey)
        #expect(keys == expected)
        #expect(list.distinctCount == expected.count)
    }

    static func expectOneGraphProblem(_ document: GraphDocument, code: String, sentence: String) throws {
        let list = WiringProblemList.make(graph: document)
        try #require(list.entries.count == 1)
        let entry = list.entries[0]
        let target = entry.target
        #expect(entry.code == code)
        #expect(entry.sentence == sentence)
        #expect(target == nil)
        #expect(list.distinctCount == 1)
    }

    static func expectCap(_ count: Int, shown: Int, omitted: Int, line: String?, last: String) throws {
        let list = WiringProblemList.make(errors: wrongDirections(count, descending: true))
        try #require(list.entries.count == shown)
        let firstKey = list.entries[0].stableKey
        let lastKey = list.entries[shown - 1].stableKey
        let note = list.omittedLine
        let expectedLast = "wrongDirection\0edge:" + last + "\0"
        let expectedSummary = "\(count) problems."
        #expect(list.distinctCount == count)
        #expect(list.omittedCount == omitted)
        #expect(note == line)
        #expect(firstKey == "wrongDirection\0edge:e00000\0")
        #expect(lastKey == expectedLast)
        #expect(list.summary == expectedSummary)
    }

    /// The production files of the list, read from the checkout or from the package mirror; empty when absent.
    static func problemSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Wiring/Problems/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = files.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == files.count { return texts }
        }
        return []
    }
}
