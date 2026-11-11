import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Calls the same session methods `PerformanceWiringListView` calls.
@MainActor
@Suite(.productionAccessAudit)
struct PerformanceWiringEditorTests {
    @Test func destinationsListStarterOutputAsExistingThenValidAfterRemoval() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let edge = session.stereoEdge
        let connected = try session.destinations(from: edge.from)
        #expect(connected.groups.map(\.connectionClass) == [.existing])
        let existing = try #require(connected.group(.existing)?.candidates.first)
        #expect(existing.to == edge.to && existing.connection == .existing(edge.id))
        let undoCount = session.snapshot.history.undoCount
        try session.removeConnection(edge.id)
        #expect(!session.stereoConnectionEnabled)
        #expect(session.snapshot.candidate.edges.isEmpty)
        #expect(session.snapshot.history.undoCount == undoCount + 1)
        let removed = try session.destinations(from: edge.from)
        let valid = try #require(removed.group(.valid)?.candidates.first)
        #expect(valid.to == edge.to && valid.connection == .valid)
        #expect(removed.group(.existing) == nil)
    }

    @Test func connectingStarterPairAfterRemovalReusesCanonicalEdgeAndToggle() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let initial = session.snapshot
        let edge = session.stereoEdge
        try session.removeConnection(edge.id)
        let request = WiringConnectRequest(edge: EdgeID(uuid: UUID()), from: edge.from, to: edge.to)
        #expect(session.isStarterPair(request))
        let removedUndoCount = session.snapshot.history.undoCount
        try session.connect(request)
        #expect(session.snapshot.history.undoCount == removedUndoCount + 1)
        #expect(session.snapshot.history.redoCount == 0)
        #expect(session.snapshot.candidate.edges == [edge])
        #expect(session.stereoConnectionEnabled)
        #expect(session.snapshot.history.draft == initial.history.draft)
        #expect(session.snapshot.diff == initial.diff)
        try session.setStereoConnectionEnabled(false)
        #expect(session.snapshot.candidate.edges.isEmpty)
        try session.setStereoConnectionEnabled(true)
        #expect(session.snapshot.candidate.edges == [edge])
        try session.undo()
        try session.undo()
        try session.undo()
        #expect(!session.stereoConnectionEnabled)
        try session.undo()
        #expect(session.snapshot.candidate == initial.candidate)
    }

    @Test func addedOutputNodeConnectsAndAppearsInReview() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let outputRole = try #require(session.project.roles.first { $0.direction == .output })
        let undoCount = session.snapshot.history.undoCount
        let label = PerformanceWiringText.nextLabel(for: outputRole, in: session.snapshot.candidate)
        #expect(label == "Output 2")
        let node = try session.addRoleNode(role: outputRole.id, id: NodeID(uuid: UUID()), label: label)
        #expect(node.kind == .roleOutput && node.role == outputRole.id && node.label == "Output 2")
        let expectedPort = GraphPort(id: PortID(validated: "audio"), direction: .input, signal: .audio, channels: 2)
        #expect(node.ports == [expectedPort])
        let port = try #require(node.ports.first)
        let destination = PortAddress(node: node.id, port: port.id)
        let list = try session.destinations(from: session.stereoEdge.from)
        #expect(list.group(.valid)?.candidates.map(\.to) == [destination])
        let request = WiringConnectRequest(edge: EdgeID(uuid: UUID()), from: session.stereoEdge.from, to: destination)
        #expect(!session.isStarterPair(request))
        try session.connect(request)
        let edge = GraphEdge(id: request.edge, from: request.from, to: request.to)
        #expect(session.snapshot.history.undoCount == undoCount + 2)
        #expect(session.snapshot.candidate.edges == [session.stereoEdge, edge])
        #expect(session.snapshot.diff.changes.contains(.addedNode(node)))
        #expect(session.snapshot.diff.changes.contains(.addedEdge(edge)))
        try session.project.validatePreparationContext(selectedGraph: session.snapshot.candidate)
        #expect(PerformanceWiringText.nextLabel(for: outputRole, in: session.snapshot.candidate) == "Output 3")
    }

    @Test func addedSourceNodeFeedsTheStarterOutput() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let sourceRole = try #require(session.project.roles.first { $0.direction == .input })
        let node = try session.addRoleNode(role: sourceRole.id, id: NodeID(uuid: UUID()), label: "Source 2")
        #expect(node.kind == .roleInput)
        #expect(node.ports.map(\.direction) == [.output])
        let port = try #require(node.ports.first)
        let source = PortAddress(node: node.id, port: port.id)
        let list = try session.destinations(from: source)
        #expect(list.group(.valid)?.candidates.map(\.to) == [session.stereoEdge.to])
        #expect(list.group(.notOffered)?.candidates.map(\.to) == [session.stereoEdge.from])
        // The picker hides the wrong-direction starter source and lists only the valid output.
        #expect(PerformanceWiringText.listedDestinations(list).map(\.to) == [session.stereoEdge.to])
        let request = WiringConnectRequest(edge: EdgeID(uuid: UUID()), from: source, to: session.stereoEdge.to)
        try session.connect(request)
        #expect(session.snapshot.candidate.edges.count == 2)
        #expect(session.stereoConnectionEnabled)
        let connected = PerformanceWiringText.listedDestinations(try session.destinations(from: source))
        #expect(connected.map(\.connection) == [.existing(request.edge)])
    }

    @Test func pickedSourceGoesStaleAfterUndoOfItsNode() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let sourceRole = try #require(session.project.roles.first { $0.direction == .input })
        let node = try session.addRoleNode(role: sourceRole.id, id: NodeID(uuid: UUID()), label: "Source 2")
        let port = try #require(node.ports.first)
        let source = PortAddress(node: node.id, port: port.id)
        #expect(session.liveSource(source) == source)
        #expect(session.liveSource(session.stereoEdge.from) == session.stereoEdge.from)
        #expect(session.liveSource(session.stereoEdge.to) == nil)
        #expect(session.liveSource(nil) == nil)
        try session.undo()
        #expect(session.liveSource(source) == nil)
        let refusal = try #require(throws: WiringComposeRefusal.self) { try session.destinations(from: source) }
        guard case .preview = refusal else {
            Issue.record("Expected a preview refusal, got \(refusal)")
            return
        }
        #expect(PerformanceWiringText.failure(refusal) == "The draft changed. Choose the source again")
    }

    @Test func removingNodeRemovesItsConnectionsInOneUndoStep() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let (node, edge) = try addConnectedOutput(session)
        let before = session.snapshot
        let plan = try session.nodeRemovalPlan(node.id)
        #expect(plan.node == node.id && plan.edgesToDisconnect == [edge.id])
        try session.removeNode(node.id, confirmed: plan)
        #expect(session.snapshot.history.undoCount == before.history.undoCount + 1)
        #expect(session.snapshot.candidate.node(node.id) == nil)
        #expect(session.snapshot.candidate.edges == [session.stereoEdge])
        #expect(!session.snapshot.diff.changes.contains(.addedNode(node)))
        try session.undo()
        #expect(session.snapshot.candidate == before.candidate)
        #expect(session.snapshot.diff == before.diff)
        #expect(session.snapshot.history.draft == before.history.draft)
        try session.redo()
        #expect(session.snapshot.candidate.node(node.id) == nil)

        let output = session.stereoEdge.to.node
        let starterPlan = try session.nodeRemovalPlan(output)
        #expect(starterPlan.edgesToDisconnect == [session.stereoEdge.id])
        try session.removeNode(output)
        #expect(!session.stereoConnectionEnabled)
        #expect(session.snapshot.candidate.edges.isEmpty)
    }

    @Test func refusalsLeaveTheWholeSnapshotIncludingRedoUnchanged() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let (node, edge) = try addConnectedOutput(session)
        try session.undo()
        try #require(session.snapshot.history.redoCount == 1)
        let unknownEdge = EdgeID(validated: "edge.unknown")
        try expectRefusal(WiringEditRefusal.unknownEdge(unknownEdge), session) {
            try session.removeConnection(unknownEdge)
        }
        let sourceRole = try #require(session.project.roles.first { $0.direction == .input })
        let sourceNode = session.stereoEdge.from.node
        try expectRefusal(WiringNodeRefusal.nodeAlreadyPresent(sourceNode), session) {
            try session.addRoleNode(role: sourceRole.id, id: sourceNode, label: "Source 2")
        }
        try expectRefusal(WiringNodeRefusal.nodeAlreadyPresent(node.id), session) {
            try session.addRoleNode(role: sourceRole.id, id: node.id, label: "Source 2")
        }
        let missingRole = RoleID(validated: "role.missing")
        try expectRefusal(PerformanceProjectSession.WiringRefusal.unknownRole(missingRole), session) {
            try session.addRoleNode(role: missingRole, id: NodeID(uuid: UUID()), label: "Missing")
        }
        try expectRefusal(WiringComposeRefusal.existing(session.stereoEdge.id), session) {
            try session.connect(WiringConnectRequest(
                edge: EdgeID(uuid: UUID()), from: session.stereoEdge.from, to: session.stereoEdge.to
            ))
        }
        // Wrong direction: an input port is never a connection's source.
        let second = NodeID(uuid: UUID())
        try expectRefusal(WiringComposeRefusal.notOffered, session) {
            try session.connect(WiringConnectRequest(
                edge: EdgeID(uuid: UUID()), from: session.stereoEdge.to, to: session.stereoEdge.from
            ))
        }
        var mismatched = try session.roleNode(role: sourceRole.id, id: second, label: "Source 2")
        mismatched.kind = .roleOutput
        try expectRefusal(
            PreparationProjectRefusal.selected(.roleMismatch(session.base.id, node: second, sourceRole.id)), session
        ) {
            try session.apply([.addNode(mismatched)])
        }
        let missing = NodeID(validated: "node.missing")
        try expectRefusal(WiringNodeRefusal.unknownNode(missing), session) {
            _ = try session.nodeRemovalPlan(missing)
        }
        try expectRefusal(WiringNodeRefusal.unknownNode(missing), session) { try session.removeNode(missing) }
        try session.redo()
        #expect(session.snapshot.candidate.edges == [session.stereoEdge, edge])
    }

    @Test func staleRemovalPlanAndReservedStarterIDAreRefused() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let (node, edge) = try addConnectedOutput(session)
        let stale = try session.nodeRemovalPlan(node.id)
        #expect(stale.edgesToDisconnect == [edge.id])
        try session.removeConnection(edge.id)
        try session.setStereoConnectionEnabled(false)
        try session.setStereoConnectionEnabled(true)
        try session.undo()
        try #require(session.snapshot.history.redoCount == 1)
        try expectRefusal(PerformanceProjectSession.WiringRefusal.staleRemovalPlan(node.id), session) {
            try session.removeNode(node.id, confirmed: stale)
        }
        // The toggle owns the starter edge ID: it never names another pair.
        let port = try #require(node.ports.first)
        let reserved = WiringConnectRequest(
            edge: session.stereoEdge.id, from: session.stereoEdge.from, to: PortAddress(node: node.id, port: port.id)
        )
        try expectRefusal(
            PerformanceProjectSession.EditRefusal.reservedStereoRouteReplacement(session.stereoEdge.id), session
        ) {
            try session.connect(reserved)
        }
        try session.removeNode(node.id, confirmed: session.nodeRemovalPlan(node.id))
        #expect(session.snapshot.candidate.node(node.id) == nil)
    }

    @Test func removingStarterSourceThenToggleOnRestoresCanonicalNodesBesideUserNodes() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let sourceRole = try #require(session.project.roles.first { $0.direction == .input })
        let canonical = session.snapshot.candidate.nodes
        let label = PerformanceWiringText.nextLabel(for: sourceRole, in: session.snapshot.candidate)
        #expect(label == "Source 2")
        let user = try session.addRoleNode(role: sourceRole.id, id: NodeID(uuid: UUID()), label: label)
        let sourceNode = session.stereoEdge.from.node
        try session.removeNode(sourceNode)
        #expect(session.snapshot.candidate.node(sourceNode) == nil)
        #expect(!session.stereoConnectionEnabled)
        let removed = session.snapshot
        try session.setStereoConnectionEnabled(true)
        #expect(session.stereoConnectionEnabled)
        #expect(session.snapshot.candidate.edges == [session.stereoEdge])
        for node in canonical + [user] {
            #expect(session.snapshot.candidate.node(node.id) == node)
        }
        #expect(session.snapshot.candidate.nodes.count == 3)
        try session.project.validatePreparationContext(selectedGraph: session.snapshot.candidate)
        try session.undo()
        #expect(session.snapshot.candidate == removed.candidate)
    }

    @Test func inspectorLabelsSayDraftNotActive() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let edge = try session.inspector(.edge(session.stereoEdge.id))
        #expect(edge.marker == .draft)
        #expect(edge.label == "Source to Output, draft, not active. No problems.")
        let source = try session.inspector(.node(session.stereoEdge.from.node))
        #expect(source.label == "Source, roleInput, draft, not active. 0 inputs, 1 output."
                + " 1 connection, 0 feedback. No problems.")
        let missing = NodeID(validated: "node.missing")
        #expect(throws: WiringInspectorRefusal.subjectAbsent(.node(missing))) {
            try session.inspector(.node(missing))
        }
        let labels = session.inspectorLabels()
        #expect(labels.count == 3)
        #expect(labels[.edge(session.stereoEdge.id)] == edge.label)
        #expect(labels[.node(session.stereoEdge.from.node)] == source.label)
    }

    @Test func undoRedoRoundTripOfEveryListEdit() throws {
        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let role = try #require(session.project.roles.first { $0.direction == .output })
        let node = try session.addRoleNode(role: role.id, id: NodeID(uuid: UUID()), label: "Output 2")
        let port = try #require(node.ports.first)
        let request = WiringConnectRequest(
            edge: EdgeID(uuid: UUID()), from: session.stereoEdge.from, to: PortAddress(node: node.id, port: port.id)
        )
        try session.undo()
        var snapshots = [session.snapshot]
        let steps: [() throws -> Void] = [
            { try session.addRoleNode(role: role.id, id: node.id, label: "Output 2") },
            { try session.connect(request) },
            { try session.removeConnection(session.stereoEdge.id) },
            { try session.removeConnection(request.edge) },
            { try session.removeNode(node.id) }
        ]
        for step in steps {
            try step()
            snapshots.append(session.snapshot)
        }
        #expect(session.snapshot.candidate.edges.isEmpty)
        #expect(session.snapshot.candidate.nodes.count == 2)
        for expected in snapshots.dropLast().reversed() {
            try session.undo()
            #expect(session.snapshot.candidate == expected.candidate)
            #expect(session.snapshot.diff == expected.diff)
            #expect(session.snapshot.history.draft == expected.history.draft)
        }
        for expected in snapshots.dropFirst() {
            try session.redo()
            #expect(session.snapshot.candidate == expected.candidate)
            #expect(session.snapshot.history.draft == expected.history.draft)
        }
    }

    @Test func textHelpersNameReasonsLabelsAndRemovals() throws {
        let reasons = WiringDestinationClass.allCases.map(PerformanceWiringText.reason)
        #expect(Set(reasons).count == WiringDestinationClass.allCases.count)
        #expect(PerformanceWiringText.reason(.existing) == "Already connected")
        #expect(PerformanceWiringText.reason(WiringDestinationClass.notOffered) == "Not offered: same direction")
        #expect(WiringDestinationClass.allCases.filter(PerformanceWiringText.isSelectable) == [.valid])
        #expect(PerformanceWiringText.reason(.disabled(.signalMismatch(from: .audio, to: .control)))
                == "Not available: audio cannot feed a control input")
        #expect(PerformanceWiringText.reason(.needsConversion(sourceChannels: 2, destinationChannels: 1))
                == "Not available here: 2 to 1 channels needs a conversion")
        let edgeID = EdgeID(validated: "edge.direct")
        #expect(PerformanceWiringText.failure(WiringComposeRefusal.existing(edgeID)) == "Already connected")
        #expect(PerformanceWiringText.failure(WiringComposeRefusal.notOffered) == "Not offered: same direction")
        #expect(PerformanceWiringText.failure(PerformanceProjectSession.WiringRefusal.staleRemovalPlan(
            NodeID(validated: "node.output")
        )) == "The node's connections changed. Review the removal again")
        #expect(PerformanceWiringText.failure(PerformanceProjectSession.EditRefusal.reservedStereoRouteReplacement(
            edgeID
        )) == "The starter connection's endpoints and metadata are fixed")
        #expect(WiringDestinationClass.allCases.filter(PerformanceWiringText.isListed)
                == [.valid, .needsConversion, .feedbackOnly, .existing, .disabled, .uncheckable])
        #expect(PerformanceWiringText.failure(WiringEditRefusal.unknownEdge(edgeID))
                == "That connection is no longer in the draft")
        #expect(PerformanceWiringText.failure(DraftHistoryRefusal.nothingToUndo)
                == String(describing: DraftHistoryRefusal.nothingToUndo))

        let session = try PerformanceProjectSession(window: WindowID(uuid: UUID()))
        let graph = session.snapshot.candidate
        #expect(PerformanceWiringText.portTitle(session.stereoEdge.from, in: graph)
                == "Source: audio output, 2 channels")
        #expect(PerformanceWiringText.connectionTitle(session.stereoEdge, in: graph) == "Source to Output")
        #expect(PerformanceWiringText.nodeTitle(NodeID(validated: "node.gone"), in: graph) == "node.gone")
        let (node, _) = try addConnectedOutput(session)
        let plan = try session.nodeRemovalPlan(node.id)
        let current = session.snapshot.candidate
        #expect(PerformanceWiringText.removalTitle(node.id, in: current) == "Remove Output 2 from the draft?")
        #expect(PerformanceWiringText.removalMessage(plan, in: current)
                == "Also removes 1 connection: Source to Output 2. Undo restores everything.")
        #expect(PerformanceWiringText.removalConfirm(plan) == "Remove Node and 1 Connection")
        var outputs = try #require(session.project.roles.first { $0.direction == .output })
        outputs.label = "Output"
        var crowded = current
        crowded.nodes.append(GraphNode(id: NodeID(validated: "node.three"), kind: .roleOutput, label: "Output 3"))
        #expect(PerformanceWiringText.nextLabel(for: outputs, in: crowded) == "Output 4")
        crowded.nodes.removeAll { $0.id == node.id }
        #expect(PerformanceWiringText.nextLabel(for: outputs, in: crowded) == "Output 2")
    }

    /// Adds "Output 2" and connects the starter source to it: two undo steps.
    private func addConnectedOutput(_ session: PerformanceProjectSession) throws -> (GraphNode, GraphEdge) {
        let role = try #require(session.project.roles.first { $0.direction == .output })
        let label = PerformanceWiringText.nextLabel(for: role, in: session.snapshot.candidate)
        let node = try session.addRoleNode(role: role.id, id: NodeID(uuid: UUID()), label: label)
        let port = try #require(node.ports.first)
        let request = WiringConnectRequest(
            edge: EdgeID(uuid: UUID()), from: session.stereoEdge.from, to: PortAddress(node: node.id, port: port.id)
        )
        try session.connect(request)
        let edge = try #require(session.snapshot.candidate.edges.first { $0.id == request.edge })
        return (node, edge)
    }

    /// The edit throws exactly `expected`, and documents, navigation and the snapshot (incl. redo) are unchanged.
    private func expectRefusal<Refusal: Error & Equatable>(
        _ expected: Refusal, _ session: PerformanceProjectSession, _ operation: () throws -> Void
    ) throws {
        let before = session.snapshot
        let project = session.project
        let base = session.base
        let navigation = session.navigation
        #expect(throws: expected) { try operation() }
        #expect(session.snapshot == before)
        #expect(session.snapshot.history.redoCount == before.history.redoCount)
        #expect(session.project == project && session.base == base && session.navigation == navigation)
    }
}
