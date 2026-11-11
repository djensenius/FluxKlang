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
}
