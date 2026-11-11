import Foundation
import Observation

/// One app-owned, unsaved software-routing draft. No engine or persistence owner.
/// The app passes its retained owner to openOrCreate for every explicit New Project.
@MainActor
@Observable
final class PerformanceProjectSession {
    enum EditRefusal: Error, Hashable, Sendable {
        /// The toggle owns this complete edge record, not just its ID.
        case reservedStereoRouteReplacement(EdgeID)
    }

    /// Published together, only after folding, composition and project validation succeed.
    struct Snapshot: Hashable, Sendable {
        let history: DraftHistory
        let candidate: GraphDocument
        let diff: WiringReviewDiff
    }

    let project: ProjectDocument
    let base: GraphDocument
    private(set) var snapshot: Snapshot
    private(set) var navigation = WorkspaceNavigationState()
    private let stereoNodes: [GraphNode]
    private let stereoEdge: GraphEdge

    /// Explicit New/Open only. Reconcile navigation without replacing an existing document.
    static func openOrCreate(
        existing: PerformanceProjectSession?, window: WindowID, widthClass: WorkspaceWidthClass = .regular
    ) throws -> PerformanceProjectSession {
        guard let existing else {
            return try PerformanceProjectSession(window: window, widthClass: widthClass)
        }
        if existing.navigation.windowProjects[window] == existing.project.id {
            try existing.setWidthClass(widthClass, window: window)
        } else {
            try existing.openWindow(window, widthClass: widthClass)
        }
        return existing
    }

    /// New Project is the only creation path. UUIDs are document identities, not engine authority.
    init(window: WindowID, widthClass: WorkspaceWidthClass = .regular, historyDepth: Int = 100) throws {
        let sourceRole = ProjectRole(
            id: RoleID(validated: "role.source"), label: "Source", direction: .input, signal: .audio, channels: 2
        )
        let outputRole = ProjectRole(
            id: RoleID(validated: "role.output"), label: "Output", direction: .output, signal: .audio, channels: 2
        )
        let port = PortID(validated: "audio")
        let source = GraphNode(
            id: NodeID(validated: "node.source"), kind: .roleInput, label: "Source", role: sourceRole.id,
            ports: [GraphPort(id: port, direction: .output, signal: .audio, channels: 2)]
        )
        let destination = GraphNode(
            id: NodeID(validated: "node.output"), kind: .roleOutput, label: "Output", role: outputRole.id,
            ports: [GraphPort(id: port, direction: .input, signal: .audio, channels: 2)]
        )
        let edge = GraphEdge(
            id: EdgeID(validated: "edge.direct"),
            from: PortAddress(node: source.id, port: port), to: PortAddress(node: destination.id, port: port)
        )
        let base = GraphDocument(id: GraphID(uuid: UUID()))
        let project = ProjectDocument(
            id: ProjectID(uuid: UUID()), name: "Untitled Project",
            graphs: [ProjectGraphReference(graph: base.id, revision: base.revision)],
            roles: [sourceRole, outputRole],
            patches: [ProjectPatch(id: PatchID(uuid: UUID()), label: "Stereo Routing", graph: base.id)]
        )
        try project.validatePreparationContext(selectedGraph: base)
        var history = try DraftHistory.make(draft: DraftID(uuid: UUID()), base: base, depth: historyDepth)
        try history.apply([.addNode(source), .addNode(destination), .connect(edge)], on: base)
        let snapshot = try Self.checked(history, project: project, base: base, stereoEdge: edge)
        self.project = project
        self.base = base
        self.snapshot = snapshot
        stereoNodes = [source, destination]
        stereoEdge = edge
        try openWindow(window, widthClass: widthClass)
    }

    var stereoConnectionEnabled: Bool {
        snapshot.candidate.edges.contains(stereoEdge)
    }

    /// Re-enabling after undoing creation restores the two role nodes as one gesture.
    func setStereoConnectionEnabled(_ enabled: Bool) throws {
        guard enabled != stereoConnectionEnabled else { return }
        if enabled {
            let present = Set(snapshot.candidate.nodes.map(\.id))
            let missing = stereoNodes.filter { !present.contains($0.id) }.map(GraphEdit.addNode)
            try apply(missing + [.connect(stereoEdge)])
        } else {
            try apply([.disconnect(stereoEdge.id)])
        }
    }

    /// A failed gesture leaves the entire previous snapshot, including redo, intact.
    func apply(_ gesture: [GraphEdit]) throws {
        var history = snapshot.history
        guard try history.apply(gesture, on: base) == .recorded else { return }
        snapshot = try Self.checked(history, project: project, base: base, stereoEdge: stereoEdge)
    }

    func undo() throws {
        var history = snapshot.history
        try history.undo(on: base)
        snapshot = try Self.checked(history, project: project, base: base, stereoEdge: stereoEdge)
    }

    func redo() throws {
        var history = snapshot.history
        try history.redo(on: base)
        snapshot = try Self.checked(history, project: project, base: base, stereoEdge: stereoEdge)
    }

    /// Direct duplicate opens refuse; openOrCreate reconciles membership for explicit New/Open.
    func openWindow(_ window: WindowID, widthClass: WorkspaceWidthClass = .regular) throws {
        var staged = navigation
        try staged.apply(.openWindow(window, project: project.id))
        try staged.apply(.setWidthClass(widthClass, window: window))
        if staged.lastAppliedRevision(for: project.id) == nil {
            // Observe the unchanged document base, never a draft as an acknowledged revision.
            try staged.apply(.revisionApplied(base.revision, project: project.id, present: []))
        }
        navigation = staged
    }

    func setWidthClass(_ widthClass: WorkspaceWidthClass, window: WindowID) throws {
        var staged = navigation
        try staged.apply(.setWidthClass(widthClass, window: window))
        navigation = staged
    }

    /// Root/window lifetime only: destination disappearance must not call this.
    /// Closing the last window discards navigation observation, not the unsaved documents.
    func closeWindow(_ window: WindowID) throws {
        var staged = navigation
        try staged.apply(.closeWindow(window))
        navigation = staged
    }

    private static func checked(
        _ history: DraftHistory, project: ProjectDocument, base: GraphDocument, stereoEdge: GraphEdge
    ) throws -> Snapshot {
        let candidate = try WiringDraftComposer.draftGraph(active: base, draft: history.draft)
        try project.validatePreparationContext(selectedGraph: candidate)
        // Check the final candidate, not intermediate gesture operations. Other edges/nodes
        // remain editable; this reserved record may only be absent or exactly canonical.
        if let reserved = candidate.edges.first(where: { $0.id == stereoEdge.id }), reserved != stereoEdge {
            throw EditRefusal.reservedStereoRouteReplacement(stereoEdge.id)
        }
        let diff = try WiringReviewDiff.make(active: base, draft: history.draft)
        return Snapshot(history: history, candidate: candidate, diff: diff)
    }
}
