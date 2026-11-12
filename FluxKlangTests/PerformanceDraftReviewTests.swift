import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@MainActor
@Suite(.productionAccessAudit)
struct PerformanceDraftReviewTests {
    @Test func initialReviewContainsEveryCanonicalNodeAndDirectEdge() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let canonical = AudioRoutingTestFixtures.documents()
        let expected = canonical.graph.nodes.sorted { $0.id < $1.id }.map(WiringReviewChange.addedNode)
            + canonical.graph.edges.map(WiringReviewChange.addedEdge)
        #expect(session.snapshot.diff.changes == expected)
        #expect(session.snapshot.diff.groups.map(\.kind) == [.addedNode, .addedEdge])
        #expect(session.snapshot.history.draft.edits ==
                canonical.graph.nodes.map(GraphEdit.addNode) + canonical.graph.edges.map(GraphEdit.connect))
        #expect(session.snapshot.history.undoCount == 1)
        #expect(try WiringDraftComposer.draftGraph(
            active: session.base, draft: session.snapshot.history.draft
        ) == session.snapshot.candidate)
    }

    @Test func connectionRemovalAndHistoryShowNetChangesAgainstEmptyBase() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let initial = session.snapshot.diff
        try session.setStereoConnectionEnabled(false)
        let nodesOnly = session.snapshot.diff
        #expect(nodesOnly.changes == initial.changes.filter { $0.kind == .addedNode })
        #expect(nodesOnly.groups.map(\.kind) == [.addedNode])
        try session.undo()
        #expect(session.snapshot.diff == initial)
        try session.undo()
        #expect(session.snapshot.diff.isEmpty)
        #expect(session.snapshot.history.draft.edits.isEmpty)
        #expect(session.snapshot.candidate == session.base)
        try session.redo()
        #expect(session.snapshot.diff == initial)
        try session.redo()
        #expect(session.snapshot.diff == nodesOnly)
    }

    @Test func enablingAfterUndoOfCreationRestoresWholeRouteAsOneGesture() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let initial = session.snapshot
        try session.undo()
        try session.setStereoConnectionEnabled(true)
        #expect(session.snapshot.candidate == initial.candidate)
        #expect(session.snapshot.diff == initial.diff)
        #expect(session.snapshot.history.draft == initial.history.draft)
        #expect(session.snapshot.history.undoCount == 1)
        #expect(session.snapshot.history.redoCount == 0)
        try session.undo()
        #expect(session.snapshot.diff.isEmpty)
    }

    @Test func movedDraftNodeAppearsOnceAtFinalPositionAndRemovalCascadesThroughReview() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let source = try #require(session.snapshot.candidate.nodes.first { $0.kind == .roleInput })
        let position = GraphPoint(x: 60, y: 120)
        try session.apply([.moveNode(source.id, to: position)])
        var moved = source
        moved.position = position
        let sourceRows = session.snapshot.diff.changes.filter { $0.sortID == source.id.rawValue }
        #expect(sourceRows == [.addedNode(moved)])
        let beforeRemoval = session.snapshot
        try session.apply([.removeNode(source.id)])
        let remaining = try #require(session.snapshot.candidate.nodes.first)
        #expect(session.snapshot.candidate.nodes.count == 1)
        #expect(session.snapshot.candidate.edges.isEmpty)
        #expect(session.snapshot.diff.changes == [.addedNode(remaining)])
        try session.undo()
        #expect(session.snapshot.candidate == beforeRemoval.candidate)
        #expect(session.snapshot.diff == beforeRemoval.diff)
        #expect(session.snapshot.history.draft == beforeRemoval.history.draft)
        try session.redo()
        #expect(session.snapshot.diff.changes == [.addedNode(remaining)])
    }

    // MARK: Connections list (#101)

    @Test func rigLessPresenceMarksRoleNodesUnmappedAndGuessesNothingElse() throws {
        let nodes = try NodeKind.allCases.map {
            GraphNode(id: try NodeID("node.\($0.rawValue)"), kind: $0, label: $0.rawValue)
        }
        let presence = PerformanceProjectSession.presenceWithoutRig(nodes)
        for node in nodes {
            let expected: WiringNodePresence? = node.kind.requiresRole ? .unmapped : nil
            #expect(presence[node.id] == expected, "\(node.kind)")
        }
        #expect(Set(presence.values) == [.unmapped])
        #expect(PerformanceProjectSession.presenceWithoutRig([]).isEmpty)
    }

    @Test func starterConnectionListsAsOneDraftRowUnderAnUnmappedOutput() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let list = try session.connectionList()
        let section = try #require(list.sections.first)
        #expect(list.sections.count == 1 && section.node == session.stereoEdge.to.node)
        #expect(section.heading == "Output (2ch) Unmapped" && section.presence == .unmapped)
        #expect(section.accessibilityLabel == "Output, 2 channels, Unmapped on this host, 1 connection.")
        #expect(section.emptyText == nil)
        let row = try #require(section.rows.first)
        #expect(section.rows.count == 1 && row.edge == session.stereoEdge.id)
        #expect(row.text == "Source → Output" && row.detailText == nil)
        #expect(row.badge == .draft && row.badge.text == "Draft" && !row.badge.isStruckThrough)
        #expect(row.accessibilityLabel == "Source to Output, audio, 2 channels, draft, not active.")
        let title = PerformanceWiringText.connectionTitle(session.stereoEdge, in: session.snapshot.candidate)
        #expect(PerformanceWiringText.removeLabel(row) == "Remove \(title) from draft")
    }

    @Test func addedOutputGetsItsOwnSectionSayingNoConnections() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let outputRole = try #require(session.project.roles.first { $0.direction == .output })
        let node = try session.addRoleNode(role: outputRole.id, id: NodeID(uuid: UUID()), label: "Output 2")
        let list = try session.connectionList()
        #expect(list.sections.map(\.title) == ["Output", "Output 2"])
        let added = try #require(list.section(for: node.id))
        #expect(added.heading == "Output 2 (2ch) Unmapped" && added.rows.isEmpty)
        #expect(added.emptyText == "No connections")
        #expect(added.accessibilityLabel == "Output 2, 2 channels, Unmapped on this host, no connections.")
    }

    @Test func listFollowsTheDraftWhenTheStarterConnectionOrItsOutputIsRemoved() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        try session.removeConnection(session.stereoEdge.id)
        let emptied = try session.connectionList()
        let section = try #require(emptied.sections.first)
        #expect(section.rows.isEmpty && section.emptyText == "No connections")
        try session.apply([.removeNode(session.stereoEdge.to.node)])
        #expect(try session.connectionList().sections.isEmpty)
    }

    @Test func aNodeWithoutARoleIsRefusedWithTheFallbackLineNotGuessed() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let port = GraphPort(id: PortID(validated: "audio"), direction: .input, signal: .audio, channels: 2)
        let plugin = GraphNode(id: NodeID(validated: "node.plugin"), kind: .plugin, label: "Plugin", ports: [port])
        try session.apply([.addNode(plugin)])
        let refusal = WiringConnectionListRefusal.presenceMissing(plugin.id)
        #expect(throws: refusal) { try session.connectionList() }
        let line = PerformanceWiringText.connectionsUnavailable(refusal)
        #expect(line == "Connections unavailable: \(PerformanceWiringText.failure(refusal))")
        #expect(line.hasPrefix("Connections unavailable: ") && line.contains("presenceMissing"))
    }

    @Test func removeIsOfferedOnlyOnRowsThatStayInTheDraft() {
        let removable = WiringConnectionBadge.allCases.filter(PerformanceWiringText.isRemovable)
        #expect(removable == [WiringConnectionBadge.none, .draft])
        #expect(!PerformanceWiringText.isRemovable(.willRemove))
    }
}
