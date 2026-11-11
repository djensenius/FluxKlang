import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@MainActor
@Suite(.productionAccessAudit)
struct PerformanceProjectSessionTests {
    @Test func creationUsesCanonicalStereoShapeAndPinnedPatchContext() throws {
        let window = WindowID(uuid: UUID())
        let session = try PerformanceProjectSession(window: window)
        let canonical = AudioRoutingTestFixtures.documents()
        #expect(session.project.roles == canonical.project.roles)
        #expect(session.snapshot.candidate.nodes == canonical.graph.nodes)
        #expect(session.snapshot.candidate.edges == canonical.graph.edges)
        #expect(session.base.nodes.isEmpty && session.base.edges.isEmpty)
        try #require(session.project.graphs.count == 1)
        try #require(session.project.patches.count == 1)
        let reference = try #require(session.project.graphs.first)
        let patch = try #require(session.project.patches.first)
        #expect(reference.graph == session.base.id)
        #expect(reference.revision == session.base.revision)
        #expect(patch.graph == reference.graph)
        #expect(session.snapshot.candidate.id == reference.graph)
        #expect(session.snapshot.candidate.revision == reference.revision)
        #expect(session.snapshot.history.draft.graph == reference.graph)
        #expect(session.snapshot.history.draft.baseRevision == reference.revision)
        #expect(session.navigation.windowProjects == [window: session.project.id])
        try session.project.validatePreparationContext(selectedGraph: session.base)
        try session.project.validatePreparationContext(selectedGraph: session.snapshot.candidate)
        var wrongRevision = session.snapshot.candidate
        wrongRevision.revision = try wrongRevision.revision.next()
        #expect(throws: PreparationProjectRefusal.selected(
            .graphNotSupplied(wrongRevision.id, revision: wrongRevision.revision)
        )) {
            try session.project.validatePreparationContext(selectedGraph: wrongRevision)
        }
    }

    @Test func connectionEditsUndoAndRedoPreserveDocumentsAndIdentity() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let project = session.project
        let base = session.base
        let initial = session.snapshot
        try session.setStereoConnectionEnabled(false)
        let disconnected = session.snapshot
        #expect(disconnected.candidate.edges.isEmpty)
        #expect(disconnected.candidate.nodes == initial.candidate.nodes)
        #expect(disconnected.history.undoCount == initial.history.undoCount + 1)
        try session.undo()
        #expect(session.snapshot.candidate == initial.candidate)
        #expect(session.snapshot.diff == initial.diff)
        #expect(session.snapshot.history.draft == initial.history.draft)
        try session.redo()
        #expect(session.snapshot.candidate == disconnected.candidate)
        #expect(session.snapshot.diff == disconnected.diff)
        try session.setStereoConnectionEnabled(true)
        #expect(session.snapshot.candidate == initial.candidate)
        #expect(session.snapshot.history.draft == initial.history.draft)
        #expect(session.project == project && session.base == base)
        #expect(session.navigation.lastAppliedRevision(for: project.id) == base.revision)
    }

    @Test func validationFailurePreservesSnapshotRedoAndDocuments() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        try session.setStereoConnectionEnabled(false)
        try session.undo()
        let before = session.snapshot
        let project = session.project
        let base = session.base
        let navigation = session.navigation
        var invalid = try #require(before.candidate.nodes.first { $0.kind == .roleInput })
        let outputRole = try #require(project.roles.first { $0.direction == .output })
        invalid.id = NodeID(validated: "node.invalid")
        invalid.role = outputRole.id
        #expect(throws: PreparationProjectRefusal.selected(
            .roleMismatch(base.id, node: invalid.id, outputRole.id)
        )) {
            try session.apply([.addNode(invalid)])
        }
        #expect(session.snapshot == before)
        #expect(session.project == project && session.base == base)
        #expect(session.navigation == navigation)
        try session.redo()
        #expect(session.snapshot.candidate.edges.isEmpty)
    }

    @Test func failedMultiEditGestureDoesNotPublishItsValidPrefix() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let edge = try #require(session.snapshot.candidate.edges.first)
        let before = session.snapshot
        let missing = NodeID(validated: "node.absent")
        #expect(throws: DraftHistoryRefusal.edit(index: 1, .missingNode(missing))) {
            try session.apply([.disconnect(edge.id), .removeNode(missing)])
        }
        #expect(session.snapshot == before)
    }

    @Test func noOpKeepsRedoAndNewEditClearsIt() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        try session.setStereoConnectionEnabled(false)
        try session.undo()
        let before = session.snapshot
        try session.setStereoConnectionEnabled(true)
        try session.apply([])
        #expect(session.snapshot == before)
        let source = try #require(session.snapshot.candidate.nodes.first)
        try session.apply([.moveNode(source.id, to: GraphPoint(x: 12, y: 34))])
        #expect(session.snapshot.history.redoCount == 0)
        let edited = session.snapshot
        #expect(throws: DraftHistoryRefusal.nothingToRedo) { try session.redo() }
        #expect(session.snapshot == edited)
    }

    @Test func boundedHistoryDropsOldestStepsWithoutChangingBase() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()), historyDepth: 2)
        let base = session.base
        for enabled in [false, true, false, true, false, true] {
            try session.setStereoConnectionEnabled(enabled)
            #expect(session.snapshot.history.undoCount <= 2)
        }
        try session.undo()
        #expect(!session.stereoConnectionEnabled)
        try session.undo()
        #expect(session.stereoConnectionEnabled)
        let before = session.snapshot
        #expect(throws: DraftHistoryRefusal.nothingToUndo) { try session.undo() }
        #expect(session.snapshot == before)
        #expect(session.base == base)
        try session.redo()
        try session.redo()
        #expect(session.stereoConnectionEnabled)
    }

    @Test(arguments: [0, 1_001])
    func invalidHistoryDepthRefusesCreation(_ depth: Int) throws {
        #expect(throws: DraftHistoryRefusal.depthOutOfRange(depth)) {
            _ = try PerformanceProjectSession(window: WindowID(uuid: UUID()), historyDepth: depth)
        }
    }

    @Test func typedWindowLifetimeRetainsUnsavedDraftAcrossLastCloseAndReopen() throws {
        let first = WindowID(uuid: UUID())
        let second = WindowID(uuid: UUID())
        let session = try PerformanceProjectSession(window: first)
        try session.setStereoConnectionEnabled(false)
        let before = session.snapshot
        let project = session.project
        let navigation = session.navigation
        #expect(throws: WorkspaceNavigationError.duplicateWindow(first)) {
            try session.openWindow(first, widthClass: .compact)
        }
        #expect(session.navigation == navigation)
        try session.openWindow(second, widthClass: .compact)
        try session.setWidthClass(.compact, window: first)
        let firstState = try #require(session.navigation.windows[first])
        let secondState = try #require(session.navigation.windows[second])
        #expect(firstState.widthClass == .compact && secondState.widthClass == .compact)
        #expect(session.navigation.windowProjects == [first: project.id, second: project.id])
        try session.closeWindow(first)
        #expect(session.navigation.lastAppliedRevision(for: project.id) == session.base.revision)
        try session.closeWindow(second)
        #expect(session.navigation.windows.isEmpty)
        #expect(session.navigation.lastAppliedRevision(for: project.id) == nil)
        #expect(session.project == project && session.snapshot == before)
        let closed = session.navigation
        #expect(throws: WorkspaceNavigationError.unknownWindow(first)) {
            try session.setWidthClass(.regular, window: first)
        }
        #expect(throws: WorkspaceNavigationError.unknownWindow(first)) { try session.closeWindow(first) }
        #expect(session.navigation == closed)
        try session.openWindow(first)
        #expect(session.navigation.windowProjects[first] == project.id)
        #expect(session.navigation.lastAppliedRevision(for: project.id) == session.base.revision)
        #expect(session.snapshot == before)
        try session.undo()
        #expect(session.stereoConnectionEnabled)
    }

    @Test func windowLimitRefusalPreservesNavigationAndDraft() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        for _ in 1..<WorkspaceNavigationState.maxWindows {
            try session.openWindow(WindowID(uuid: UUID()))
        }
        let navigation = session.navigation
        let snapshot = session.snapshot
        #expect(throws: WorkspaceNavigationError.windowLimitExceeded(maximum: WorkspaceNavigationState.maxWindows)) {
            try session.openWindow(WindowID(uuid: UUID()))
        }
        #expect(session.navigation == navigation && session.snapshot == snapshot)
        #expect(throws: WorkspaceNavigationError.windowLimitExceeded(maximum: WorkspaceNavigationState.maxWindows)) {
            _ = try PerformanceProjectSession.openOrCreate(existing: session, window: WindowID(uuid: UUID()))
        }
        #expect(session.navigation == navigation && session.snapshot == snapshot)
        let openWindow = try #require(navigation.windows.keys.first)
        let retained = try PerformanceProjectSession.openOrCreate(existing: session, window: openWindow)
        #expect(retained === session)
        #expect(session.snapshot == snapshot)
    }

    @Test(arguments: [false, true])
    func validReservedRouteRerouteRefusesWithoutLosingRedo(_ rerouteSource: Bool) throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        try session.setStereoConnectionEnabled(false)
        try session.undo()
        let edge = try #require(session.snapshot.candidate.edges.first)
        var endpoint = try #require(session.snapshot.candidate.nodes.first {
            $0.id == (rerouteSource ? edge.from.node : edge.to.node)
        })
        endpoint.id = NodeID(validated: "node.alternate")
        var replacement = edge
        if rerouteSource {
            replacement.from.node = endpoint.id
        } else {
            replacement.to.node = endpoint.id
        }
        try expectReservedRouteRefusal(
            [.addNode(endpoint), .disconnect(edge.id), .connect(replacement)], session: session, edge: edge.id
        )
        try session.redo()
        #expect(session.snapshot.candidate.edges.isEmpty)
    }

    enum RouteMetadataLocation: CaseIterable, Sendable {
        case edgeExtensions, edgeUnknown, sourceExtensions, sourceUnknown, destinationExtensions, destinationUnknown
    }

    @Test(arguments: RouteMetadataLocation.allCases)
    func reservedRouteMetadataRefusesWithoutLosingRedo(_ location: RouteMetadataLocation) throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        try session.setStereoConnectionEnabled(false)
        try session.undo()
        let original = try #require(session.snapshot.candidate.edges.first)
        var replacement = original
        let metadata: [String: JSONValue] = ["reviewNote": .string("must not be silently discarded")]
        switch location {
        case .edgeExtensions: replacement.extensions = metadata
        case .edgeUnknown: replacement.unknownFields = metadata
        case .sourceExtensions: replacement.from.extensions = metadata
        case .sourceUnknown: replacement.from.unknownFields = metadata
        case .destinationExtensions: replacement.to.extensions = metadata
        case .destinationUnknown: replacement.to.unknownFields = metadata
        }
        try expectReservedRouteRefusal(
            [.disconnect(original.id), .connect(replacement)], session: session, edge: original.id
        )
        try session.redo()
        #expect(session.snapshot.candidate.edges.isEmpty)
        try session.setStereoConnectionEnabled(true)
        #expect(session.snapshot.candidate.edges == [original])
    }

    @Test func finalCanonicalRouteAndUnrelatedMetadataRemainEditable() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let original = try #require(session.snapshot.candidate.edges.first)
        var transient = original
        transient.extensions = ["temporary": .string("folded away")]
        var destination = try #require(session.snapshot.candidate.nodes.first { $0.id == original.to.node })
        destination.id = NodeID(validated: "node.extra")
        destination.label = "Additional output"
        var extra = original
        extra.id = EdgeID(validated: "edge.extra")
        extra.to.node = destination.id
        extra.extensions = ["note": .string("retained")]
        extra.unknownFields = ["future": .string("also retained")]
        try session.apply([
            .disconnect(original.id), .connect(transient),
            .disconnect(original.id), .connect(original),
            .addNode(destination), .connect(extra)
        ])
        let withExtra = session.snapshot
        #expect(withExtra.candidate.edges == [original, extra])
        #expect(withExtra.diff.changes.contains(.addedEdge(extra)))
        #expect(withExtra.diff.changes.contains(.addedNode(destination)))
        try session.setStereoConnectionEnabled(false)
        #expect(session.snapshot.candidate.edges == [extra])
        try session.setStereoConnectionEnabled(true)
        #expect(Set(session.snapshot.candidate.edges) == Set([original, extra]))
        try session.undo()
        try session.undo()
        #expect(session.snapshot.candidate == withExtra.candidate)
        #expect(session.snapshot.diff == withExtra.diff)
    }

    @Test func repeatedNewReconcilesWidthAndRetainsOwnerDocumentsAndRedo() throws {
        let window = WindowID(uuid: UUID())
        let session = try PerformanceProjectSession.openOrCreate(existing: nil, window: window)
        let canonical = AudioRoutingTestFixtures.documents()
        #expect(session.snapshot.candidate.nodes == canonical.graph.nodes)
        #expect(session.snapshot.candidate.edges == canonical.graph.edges)
        try session.project.validatePreparationContext(selectedGraph: session.snapshot.candidate)
        try session.setStereoConnectionEnabled(false)
        try session.undo()
        let before = session.snapshot
        let project = session.project
        let base = session.base
        try #require(before.history.redoCount == 1)
        for width in [WorkspaceWidthClass.compact, .regular, .compact] {
            let retained = try PerformanceProjectSession.openOrCreate(
                existing: session, window: window, widthClass: width
            )
            #expect(retained === session)
            #expect(retained.project == project && retained.base == base)
            #expect(retained.snapshot == before)
            #expect(retained.navigation.windowProjects == [window: project.id])
            let state = try #require(retained.navigation.windows[window])
            #expect(state.widthClass == width)
        }
        try session.redo()
        #expect(session.snapshot.candidate.edges.isEmpty)
    }

    @Test func newFromAnotherWindowAndAfterLastCloseRetainsOwnerAndRedo() throws {
        let first = WindowID(uuid: UUID())
        let second = WindowID(uuid: UUID())
        let session = try PerformanceProjectSession.openOrCreate(existing: nil, window: first)
        try session.setStereoConnectionEnabled(false)
        try session.undo()
        let before = session.snapshot
        let project = session.project
        let base = session.base
        let retained = try PerformanceProjectSession.openOrCreate(
            existing: session, window: second, widthClass: .compact
        )
        #expect(retained === session)
        #expect(retained.project == project && retained.base == base && retained.snapshot == before)
        #expect(retained.navigation.windowProjects == [first: project.id, second: project.id])
        let secondState = try #require(retained.navigation.windows[second])
        #expect(secondState.widthClass == .compact)
        try session.closeWindow(first)
        try session.closeWindow(second)
        #expect(session.navigation.lastAppliedRevision(for: project.id) == nil)
        let reopened = try PerformanceProjectSession.openOrCreate(existing: session, window: first)
        #expect(reopened === session)
        #expect(reopened.project == project && reopened.base == base && reopened.snapshot == before)
        #expect(reopened.navigation.windowProjects == [first: project.id])
        #expect(reopened.navigation.lastAppliedRevision(for: project.id) == base.revision)
        try reopened.redo()
        #expect(reopened.snapshot.candidate.edges.isEmpty)
    }

    /// Establish that the replacement is a valid contract edit, then assert the narrower session refusal.
    private func expectReservedRouteRefusal(
        _ gesture: [GraphEdit], session: PerformanceProjectSession, edge: EdgeID
    ) throws {
        let before = session.snapshot
        let project = session.project
        let base = session.base
        let navigation = session.navigation
        try #require(before.history.redoCount == 1)
        var history = before.history
        try history.apply(gesture, on: base)
        let candidate = try WiringDraftComposer.draftGraph(active: base, draft: history.draft)
        try project.validatePreparationContext(selectedGraph: candidate)
        #expect(candidate != before.candidate)
        #expect(throws: PerformanceProjectSession.EditRefusal.reservedStereoRouteReplacement(edge)) {
            try session.apply(gesture)
        }
        #expect(session.snapshot == before)
        #expect(session.project == project && session.base == base)
        #expect(session.navigation == navigation)
    }
}
