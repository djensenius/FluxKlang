//
//  WiringSelectionTests+Reconcile.swift
//  FluxKlangTests
//
//  The selection of the wiring focus order (#101 WSL1): selecting, the six keyboard steps, labels and
//  announcements, what a selection falls back to after a draft edit, and a scan of the three production files.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WiringSelectionTests {
    static func nodeStop(_ raw: String) -> WiringSelectionTarget { .node(nodeID(raw)) }
    static func portStop(_ node: String, _ port: String) -> WiringSelectionTarget {
        .port(node: nodeID(node), port: portID(port))
    }
    static func edgeStop(_ raw: String) -> WiringSelectionTarget { .edge(edgeID(raw)) }

    static let worldPorts: [[String]] = [["n1", "p1"], ["n1", "p2"], ["n2", "p1"], ["n4", "p1"]]

    /// Nodes n1 (ports p1, p2), n2 (p1), n3 (none), n4 (p1) and edges e1, e2, e3, without the named nodes, ports
    /// ("n2.p1") and edges, plus the extra plain nodes. Its order is n1 n2 n3 n4 | n1.p1 n1.p2 n2.p1 n4.p1 | e1 e2 e3.
    static func world(dropping dropped: Set<String> = [], adding extra: [String] = []) -> GraphDocument {
        var nodes: [GraphNode] = []
        for name in ["n1", "n2", "n3", "n4"] where !dropped.contains(name) {
            let ports = worldPorts.filter { $0[0] == name && !dropped.contains($0[0] + "." + $0[1]) }
            nodes.append(node(name, ports: ports.map { port($0[1]) }))
        }
        nodes += extra.map { node($0) }
        let link = address("n1", "p1")
        let edges = ["e1", "e2", "e3"].filter { !dropped.contains($0) }.map { edge($0, from: link, to: link) }
        return graph(nodes: nodes, edges: edges)
    }

    static func select(_ target: WiringSelectionTarget, in order: WiringSelectionOrder) -> WiringSelection {
        WiringSelection.selecting(target, in: order)
    }

    // MARK: Selecting

    @Test func selectingATargetInTheOrderSelectsItAndSelectingAbsentOnesSelectsNothing() throws {
        let order = try Self.order(of: Self.world())
        let present = Self.nodeStop("n2")
        let selected = Self.select(present, in: order)
        #expect(selected.current == present)
        let absentNode = Self.select(Self.nodeStop("zz"), in: order)
        let absentPort = Self.select(Self.portStop("n3", "p1"), in: order)
        #expect(absentNode == WiringSelection.none)
        #expect(absentPort == WiringSelection.none)
        let nothing = WiringSelection.none
        #expect(nothing.current == nil)
    }

    @Test func eachTargetNamesItsSectionAndAPortSharesTheInspectorSubjectOfItsNode() {
        let node = Self.nodeStop("n2")
        let port = Self.portStop("n2", "p1")
        let edge = Self.edgeStop("e1")
        #expect(node.section == .nodes)
        #expect(port.section == .ports)
        #expect(edge.section == .edges)
        #expect(node.inspectorSubject == .node(Self.nodeID("n2")))
        #expect(port.inspectorSubject == .node(Self.nodeID("n2")))
        #expect(edge.inspectorSubject == .edge(Self.edgeID("e1")))
        #expect(node != port)
    }

    // MARK: Steps

    @Test func nextAndPreviousMoveOneStopAcrossSectionsAndDoNotWrapAtEitherEnd() throws {
        let order = try Self.order(of: Self.world())
        let middle = Self.select(Self.nodeStop("n2"), in: order)
        let afterMiddle = Self.select(Self.nodeStop("n3"), in: order)
        let beforeMiddle = Self.select(Self.nodeStop("n1"), in: order)
        #expect(middle.moving(.next, in: order) == .moved(afterMiddle))
        #expect(middle.moving(.previous, in: order) == .moved(beforeMiddle))
        let lastNode = Self.select(Self.nodeStop("n4"), in: order)
        let firstPort = Self.select(Self.portStop("n1", "p1"), in: order)
        #expect(lastNode.moving(.next, in: order) == .moved(firstPort))
        let end = Self.select(Self.edgeStop("e3"), in: order)
        let start = Self.select(Self.nodeStop("n1"), in: order)
        #expect(end.moving(.next, in: order) == .unchanged(end))
        #expect(start.moving(.previous, in: order) == .unchanged(start))
    }

    @Test func firstAndLastSelectTheEndStopsAndAreUnchangedOnThem() throws {
        let order = try Self.order(of: Self.world())
        let start = Self.select(Self.nodeStop("n1"), in: order)
        let end = Self.select(Self.edgeStop("e3"), in: order)
        let middle = Self.select(Self.portStop("n2", "p1"), in: order)
        #expect(middle.moving(.first, in: order) == .moved(start))
        #expect(middle.moving(.last, in: order) == .moved(end))
        #expect(start.moving(.first, in: order) == .unchanged(start))
        #expect(end.moving(.last, in: order) == .unchanged(end))
    }

    @Test func withoutASelectionNextAndFirstSelectStopZeroAndPreviousAndLastSelectTheLastStop() throws {
        let order = try Self.order(of: Self.world())
        let start = Self.select(Self.nodeStop("n1"), in: order)
        let end = Self.select(Self.edgeStop("e3"), in: order)
        let nothing = WiringSelection.none
        #expect(nothing.moving(.next, in: order) == .moved(start))
        #expect(nothing.moving(.first, in: order) == .moved(start))
        #expect(nothing.moving(.previous, in: order) == .moved(end))
        #expect(nothing.moving(.last, in: order) == .moved(end))
    }

    @Test func nextSectionSelectsTheFirstStopOfTheFollowingNonEmptySectionAndIsUnchangedInTheLast() throws {
        let order = try Self.order(of: Self.world())
        let firstPort = Self.select(Self.portStop("n1", "p1"), in: order)
        let firstEdge = Self.select(Self.edgeStop("e1"), in: order)
        let node = Self.select(Self.nodeStop("n3"), in: order)
        let port = Self.select(Self.portStop("n2", "p1"), in: order)
        let edge = Self.select(Self.edgeStop("e2"), in: order)
        #expect(node.moving(.nextSection, in: order) == .moved(firstPort))
        #expect(port.moving(.nextSection, in: order) == .moved(firstEdge))
        #expect(edge.moving(.nextSection, in: order) == .unchanged(edge))
        let flat = try Self.order(of: Self.graph(nodes: [Self.node("a")], edges: Self.world().edges))
        let lone = Self.select(Self.nodeStop("a"), in: flat)
        let flatEdge = Self.select(Self.edgeStop("e1"), in: flat)
        #expect(lone.moving(.nextSection, in: flat) == .moved(flatEdge))
    }

    @Test func previousSectionSelectsTheFirstStopOfThePrecedingNonEmptySectionNotOfTheCurrentOne() throws {
        let order = try Self.order(of: Self.world())
        let firstNode = Self.select(Self.nodeStop("n1"), in: order)
        let firstPort = Self.select(Self.portStop("n1", "p1"), in: order)
        let edge = Self.select(Self.edgeStop("e3"), in: order)
        let port = Self.select(Self.portStop("n4", "p1"), in: order)
        let node = Self.select(Self.nodeStop("n3"), in: order)
        #expect(edge.moving(.previousSection, in: order) == .moved(firstPort))
        #expect(port.moving(.previousSection, in: order) == .moved(firstNode))
        #expect(node.moving(.previousSection, in: order) == .unchanged(node))
        let flat = try Self.order(of: Self.graph(nodes: [Self.node("a")], edges: Self.world().edges))
        let flatEdge = Self.select(Self.edgeStop("e2"), in: flat)
        let lone = Self.select(Self.nodeStop("a"), in: flat)
        #expect(flatEdge.moving(.previousSection, in: flat) == .moved(lone))
    }

    @Test func withoutASelectionSectionStepsSelectTheFirstStopOfTheFirstOrLastNonEmptySection() throws {
        let order = try Self.order(of: Self.world())
        let nothing = WiringSelection.none
        let firstNode = Self.select(Self.nodeStop("n1"), in: order)
        let firstEdge = Self.select(Self.edgeStop("e1"), in: order)
        #expect(nothing.moving(.nextSection, in: order) == .moved(firstNode))
        #expect(nothing.moving(.previousSection, in: order) == .moved(firstEdge))
        let bare = try Self.order(of: Self.graph(nodes: Self.world().nodes))
        let firstPort = Self.select(Self.portStop("n1", "p1"), in: bare)
        #expect(nothing.moving(.previousSection, in: bare) == .moved(firstPort))
    }

    @Test func aSelectionTheOrderLacksMovesAsNoSelectionDoes() throws {
        let order = try Self.order(of: Self.world())
        let elsewhere = try Self.order(of: Self.graph(nodes: [Self.node("zz")]))
        let stale = Self.select(Self.nodeStop("zz"), in: elsewhere)
        #expect(stale.current == Self.nodeStop("zz"))
        let start = Self.select(Self.nodeStop("n1"), in: order)
        let end = Self.select(Self.edgeStop("e3"), in: order)
        #expect(stale.moving(.next, in: order) == .moved(start))
        #expect(stale.moving(.previous, in: order) == .moved(end))
        #expect(stale.moving(.nextSection, in: order) == .moved(start))
    }

    @Test func allSixStepsOnAnEmptyOrderAnswerUnchangedWithNoSelectionEvenForAStaleSelection() throws {
        let empty = try Self.order(of: Self.graph(nodes: []))
        let elsewhere = try Self.order(of: Self.graph(nodes: [Self.node("zz")]))
        let stale = Self.select(Self.nodeStop("zz"), in: elsewhere)
        let steps: [WiringSelectionStep] = [.next, .previous, .first, .last, .nextSection, .previousSection]
        let expected = WiringSelectionMove.unchanged(WiringSelection.none)
        for step in steps {
            #expect(WiringSelection.none.moving(step, in: empty) == expected)
            #expect(stale.moving(step, in: empty) == expected)
        }
    }

    @Test func onAOneStopOrderAllSixStepsFromTheSelectedStopAreUnchanged() throws {
        let order = try Self.order(of: Self.graph(nodes: [Self.node("solo")]))
        let selected = Self.select(Self.nodeStop("solo"), in: order)
        let steps: [WiringSelectionStep] = [.next, .previous, .first, .last, .nextSection, .previousSection]
        for step in steps {
            #expect(selected.moving(step, in: order) == .unchanged(selected))
        }
        #expect(WiringSelection.none.moving(.first, in: order) == .moved(selected))
    }

    // MARK: Labels

    @Test func aNodeIsLabelledByItsLabelOrByItsIdWhenTheLabelHasNoBytes() {
        let graph = Self.fixture
        #expect(WiringSelectionOrder.label(of: Self.nodeStop("a"), in: graph) == "Alpha")
        #expect(WiringSelectionOrder.label(of: Self.nodeStop("c"), in: graph) == "c")
    }

    @Test func aPortLabelNamesItsNodeItsIdItsDirectionAndItsSignal() {
        let graph = Self.fixture
        let input = WiringSelectionOrder.label(of: Self.portStop("a", "x"), in: graph)
        let output = WiringSelectionOrder.label(of: Self.portStop("a", "w"), in: graph)
        #expect(input == "Alpha, x, input, midi")
        #expect(output == "Alpha, w, output, audio")
    }

    @Test func anEdgeLabelIsTheWordWireAndItsId() {
        #expect(WiringSelectionOrder.label(of: Self.edgeStop("e1"), in: Self.fixture) == "wire e1")
    }

    @Test func aLabelIsNilForATargetTheGraphLacks() {
        let graph = Self.fixture
        #expect(WiringSelectionOrder.label(of: Self.nodeStop("zz"), in: graph) == nil)
        #expect(WiringSelectionOrder.label(of: Self.portStop("a", "zz"), in: graph) == nil)
        #expect(WiringSelectionOrder.label(of: Self.portStop("zz", "x"), in: graph) == nil)
        #expect(WiringSelectionOrder.label(of: Self.edgeStop("e9"), in: graph) == nil)
    }

    @Test func anAnnouncementIsTheLabelThenTheOneBasedPositionOfTheCount() throws {
        let graph = Self.fixture
        let order = try Self.order(of: graph)
        let node = Self.select(Self.nodeStop("a"), in: order)
        let port = Self.select(Self.portStop("a", "x"), in: order)
        let edge = Self.select(Self.edgeStop("e2"), in: order)
        #expect(node.announcement(in: order, graph: graph) == "Alpha, 1 of 10")
        #expect(port.announcement(in: order, graph: graph) == "Alpha, x, input, midi, 5 of 10")
        #expect(edge.announcement(in: order, graph: graph) == "wire e2, 10 of 10")
        let solo = Self.graph(nodes: [Self.node("solo")])
        let soloOrder = try Self.order(of: solo)
        let only = Self.select(Self.nodeStop("solo"), in: soloOrder)
        #expect(only.announcement(in: soloOrder, graph: solo) == "solo, 1 of 1")
    }

    @Test func anAnnouncementIsNilWithoutASelectionOrForAStopTheOrderOrTheGraphLacks() throws {
        let graph = Self.fixture
        let order = try Self.order(of: graph)
        #expect(WiringSelection.none.announcement(in: order, graph: graph) == nil)
        let elsewhere = try Self.order(of: Self.graph(nodes: [Self.node("zz")]))
        let stale = Self.select(Self.nodeStop("zz"), in: elsewhere)
        #expect(stale.announcement(in: order, graph: graph) == nil)
        let selected = Self.select(Self.nodeStop("a"), in: order)
        let emptied = Self.graph(nodes: [])
        #expect(selected.announcement(in: order, graph: emptied) == nil)
        #expect(selected.announcement(in: elsewhere, graph: graph) == nil)
    }

    // MARK: Reconcile

    static func change(
        _ target: WiringSelectionTarget, from old: GraphDocument = world(), to new: GraphDocument
    ) throws -> WiringSelectionChange {
        let before = try order(of: old)
        let after = try order(of: new)
        return select(target, in: before).reconciled(from: before, to: after)
    }

    static func expectation(_ stop: WiringSelectionTarget?, _ outcome: WiringSelectionOutcome) throws
        -> WiringSelectionChange {
        let order = try order(of: world())
        let selection = stop.map { select($0, in: order) } ?? WiringSelection.none
        return WiringSelectionChange(selection: selection, outcome: outcome)
    }

    @Test func aTargetThatSurvivesAnUnrelatedEditIsKept() throws {
        let result = try Self.change(Self.nodeStop("n2"), to: Self.world(dropping: ["e3"]))
        let expected = try Self.expectation(Self.nodeStop("n2"), .unchanged)
        #expect(result == expected)
    }

    @Test func aRenamedAndMovedNodeKeepsItsTarget() throws {
        var edited = Self.world()
        edited.nodes[1].label = "Renamed"
        edited.nodes[1].position = GraphPoint(x: 5, y: 7)
        let result = try Self.change(Self.nodeStop("n2"), to: edited)
        let expected = try Self.expectation(Self.nodeStop("n2"), .unchanged)
        #expect(result == expected)
    }

    @Test func aRemovedNodeFallsToTheFollowingNodeEvenWhenItsPortsAndEdgesVanishToo() throws {
        let result = try Self.change(Self.nodeStop("n2"), to: Self.world(dropping: ["n2", "e1"]))
        #expect(result.outcome == .fellBackToFollowing)
        #expect(result.selection.current == Self.nodeStop("n3"))
    }

    @Test func aFallbackSkipsStopsAddedByTheNewOrder() throws {
        let result = try Self.change(Self.nodeStop("n2"), to: Self.world(dropping: ["n2"], adding: ["n0", "n2a"]))
        #expect(result.outcome == .fellBackToFollowing)
        #expect(result.selection.current == Self.nodeStop("n3"))
    }

    @Test func aRemovedLastNodeFallsToThePrecedingNodeAndNotToAPort() throws {
        let result = try Self.change(Self.nodeStop("n4"), to: Self.world(dropping: ["n4", "n4.p1"]))
        #expect(result.outcome == .fellBackToPreceding)
        #expect(result.selection.current == Self.nodeStop("n3"))
    }

    @Test func aRemovedPortFallsToAFollowingPortOfAnotherNodeThenToAPrecedingOne() throws {
        let following = try Self.change(Self.portStop("n2", "p1"), to: Self.world(dropping: ["n2.p1"]))
        #expect(following.outcome == .fellBackToFollowing)
        #expect(following.selection.current == Self.portStop("n4", "p1"))
        let preceding = try Self.change(Self.portStop("n4", "p1"), to: Self.world(dropping: ["n4", "n4.p1"]))
        #expect(preceding.outcome == .fellBackToPreceding)
        #expect(preceding.selection.current == Self.portStop("n2", "p1"))
        let nearest = try Self.change(Self.portStop("n4", "p1"), to: Self.world(dropping: ["n2", "n4"]))
        #expect(nearest.outcome == .fellBackToPreceding)
        #expect(nearest.selection.current == Self.portStop("n1", "p2"))
    }

    @Test func aRemovedEdgeFallsToTheFollowingEdgeThenToThePrecedingOne() throws {
        let following = try Self.change(Self.edgeStop("e2"), to: Self.world(dropping: ["e2"]))
        #expect(following.outcome == .fellBackToFollowing)
        #expect(following.selection.current == Self.edgeStop("e3"))
        let preceding = try Self.change(Self.edgeStop("e2"), to: Self.world(dropping: ["e2", "e3"]))
        #expect(preceding.outcome == .fellBackToPreceding)
        #expect(preceding.selection.current == Self.edgeStop("e1"))
    }

    @Test func aSectionWithNoSurvivorFallsToTheFirstStopOfTheNewOrder() throws {
        let edges = try Self.change(Self.edgeStop("e3"), to: Self.world(dropping: ["e1", "e2", "e3"]))
        #expect(edges.outcome == .fellBackToFirst)
        #expect(edges.selection.current == Self.nodeStop("n1"))
        let allPorts: Set<String> = ["n1.p1", "n1.p2", "n2.p1", "n4.p1"]
        let ports = try Self.change(Self.portStop("n2", "p1"), to: Self.world(dropping: allPorts))
        #expect(ports.outcome == .fellBackToFirst)
        #expect(ports.selection.current == Self.nodeStop("n1"))
    }

    @Test func anEmptyNewOrderClearsTheSelection() throws {
        let empty = Self.graph(nodes: [])
        let result = try Self.change(Self.edgeStop("e2"), to: empty)
        let expected = try Self.expectation(nil, .cleared)
        #expect(result == expected)
        let node = try Self.change(Self.nodeStop("n1"), to: empty)
        #expect(node == expected)
    }

    @Test func aTargetInNeitherOrderIsClearedAndNotMovedToTheFirstStop() throws {
        let before = try Self.order(of: Self.world())
        let after = try Self.order(of: Self.world(dropping: ["e3"]))
        let elsewhere = try Self.order(of: Self.graph(nodes: [Self.node("zz")]))
        let stale = Self.select(Self.nodeStop("zz"), in: elsewhere)
        let result = stale.reconciled(from: before, to: after)
        let expected = WiringSelectionChange(selection: WiringSelection.none, outcome: .cleared)
        #expect(result == expected)
    }

    @Test func noSelectionStaysNoSelectionAcrossAnyEdit() throws {
        let before = try Self.order(of: Self.world())
        let after = try Self.order(of: Self.world(dropping: ["n1"]))
        let empty = try Self.order(of: Self.graph(nodes: []))
        let expected = WiringSelectionChange(selection: WiringSelection.none, outcome: .unchanged)
        #expect(WiringSelection.none.reconciled(from: before, to: after) == expected)
        #expect(WiringSelection.none.reconciled(from: before, to: empty) == expected)
    }

    // MARK: Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = [
            "../Shared/Wiring/Selection",
            "../../Sources/FluxKlang/Shared/Wiring/Selection"
        ]
        let marker = "WiringSelectionOrder.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the production files must not contain, even in a comment. Each is joined from pieces, so that no single
    /// literal in this list spells it.
    private static func forbiddenTexts() -> [String] {
        [
            ["Dou", "ble"].joined(), ["Flo", "at"].joined(), ["Da", "te("].joined(), ["Cl", "ock"].joined(),
            ["Ta", "sk"].joined(), ["import", " SwiftUI"].joined(), ["Dispatch", "Queue"].joined(),
            ["defa", "ult:"].joined(), ["try", "!"].joined(), ["mutat", "ing"].joined(),
            ["static", " var"].joined(), [".conta", "ins("].joined(), [".first", "Index"].joined(),
            ["first", "(where"].joined(), [".fil", "ter"].joined(), [".sor", "ted()"].joined(),
            [".so", "rt()"].joined(), ["remove", "First"].joined(), ["fatal", "Error"].joined(),
            ["arc4", "random"].joined()
        ]
    }

    /// Patterns that name a hand-written operator, an array insertion, a stored label, or a comparison of IDs by
    /// `String <`.
    private static func forbiddenPatterns() -> [String] {
        [
            #"insert\([^)]*at:"#, #"static func\s*[=<>!&|+*/-]"#, #"\b(let|var) label\b"#,
            #"(?:\.id|rawValue|first|second)\s<\s"#
        ]
    }

    private static func count(of pattern: String, in text: String) -> Int {
        text.components(separatedBy: pattern).count - 1
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the selection sources are not next to the tests"))
    func theThreeProductionFilesNameNoListedTextAndSortWithSortedByCalls() throws {
        let directory = try #require(Self.sourceDirectory(), "the selection sources are not next to the tests")
        let names = ["WiringSelection.swift", "WiringSelectionOrder.swift", "WiringSelectionRefusal.swift"]
        var hits: [String] = []
        var combined = ""
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            combined += text
            for word in Self.forbiddenTexts() where text.contains(word) {
                hits.append("\(name): \(word)")
            }
            for pattern in Self.forbiddenPatterns() where text.range(of: pattern, options: .regularExpression) != nil {
                hits.append("\(name): \(pattern)")
            }
        }
        #expect(hits.isEmpty)
        let sortCalls = Self.count(of: "sorted(", in: combined)
        let comparatorSorts = Self.count(of: "sorted(by:", in: combined)
        #expect(sortCalls == comparatorSorts)
        #expect(comparatorSorts == 3)
        #expect(Self.count(of: "lexicographicallyPrecedes", in: combined) == 1)
    }
}
