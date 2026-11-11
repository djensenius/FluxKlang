import SwiftUI

/// The list wiring editor of the unsaved draft (#101): keyboard- and VoiceOver-reachable Buttons and Menus only.
/// Every edit goes through the session's composer-checked methods and the workspace's error line.
struct PerformanceWiringListView: View {
    let session: PerformanceProjectSession
    /// The workspace's error-line helper: runs one edit, shows any refusal, and returns whether it applied.
    let edit: (() throws -> Void) -> Bool
    @State private var pendingSource: PortAddress?
    @State private var pendingRemoval: WiringNodeRemovalPlan?
    /// Inspector labels, rebuilt only when the snapshot changes.
    @State private var labels: [WiringInspectorSubject: String] = [:]

    private var graph: GraphDocument { session.snapshot.candidate }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PerformanceWiringText.heading).font(.title2)
            Text(PerformanceWiringText.notice).foregroundStyle(.secondary)
            connections
            addConnection
            nodes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: session.snapshot, initial: true) {
            labels = session.inspectorLabels()
            // An undo can remove the picked source port; drop the stale pick.
            if session.liveSource(pendingSource) == nil { pendingSource = nil }
        }
        .confirmationDialog(
            pendingRemoval.map { PerformanceWiringText.removalTitle($0.node, in: graph) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { plan in
            Button(PerformanceWiringText.removalConfirm(plan), role: .destructive) {
                _ = edit { try session.removeNode(plan.node, confirmed: plan) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(PerformanceWiringText.removalMessage(plan, in: graph))
        }
    }

    // MARK: Connections

    @ViewBuilder private var connections: some View {
        Text(PerformanceWiringText.connectionsHeading).font(.headline)
        if graph.edges.isEmpty { Text(PerformanceWiringText.noConnections) }
        ForEach(destinationNodes, id: \.self) { node in
            Text(PerformanceWiringText.destinationHeading(node, in: graph)).font(.subheadline.bold())
            ForEach(graph.edges.filter { $0.to.node == node }, id: \.id) { edge in
                connectionRow(edge)
            }
        }
    }

    /// Destination nodes of the draft's connections, by raw ID bytes.
    private var destinationNodes: [NodeID] {
        Set(graph.edges.map(\.to.node)).sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }
    }

    private func connectionRow(_ edge: GraphEdge) -> some View {
        let title = PerformanceWiringText.connectionTitle(edge, in: graph)
        let ports = "\(PerformanceWiringText.portTitle(edge.from, in: graph)) → "
            + PerformanceWiringText.portTitle(edge.to, in: graph)
        let remove = { _ = edit { try session.removeConnection(edge.id) } }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(ports)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label(.edge(edge.id), fallback: title))
            .accessibilityHint(ports)
            .accessibilityAction(named: PerformanceWiringText.removeFromDraft, remove)
            Spacer()
            Button("Remove", action: remove)
                .accessibilityLabel("Remove \(title) from draft")
        }
    }

    // MARK: Add Connection

    @ViewBuilder private var addConnection: some View {
        if let source = session.liveSource(pendingSource) {
            destinationPicker(source)
        } else {
            Menu(PerformanceWiringText.addConnection) {
                ForEach(outputPorts, id: \.self) { address in
                    Button(PerformanceWiringText.portTitle(address, in: graph)) { pendingSource = address }
                }
            }
            .disabled(outputPorts.isEmpty)
            .fixedSize()
        }
    }

    private var outputPorts: [PortAddress] {
        graph.nodes.filter(\.kind.isRoutable).flatMap { node in
            node.ports.filter { $0.direction == .output }.map { PortAddress(node: node.id, port: $0.id) }
        }
    }

    @ViewBuilder
    private func destinationPicker(_ source: PortAddress) -> some View {
        Text("Connect \(PerformanceWiringText.portTitle(source, in: graph)) to:").font(.headline)
        switch destinations(source) {
        case .success(let list):
            ForEach(PerformanceWiringText.listedDestinations(list), id: \.to) { candidate in
                destinationRow(candidate, from: source)
            }
            ForEach(list.group(.uncheckable)?.uncheckable ?? [], id: \.to) { row in
                Text("\(PerformanceWiringText.portTitle(row.to, in: graph)) — "
                     + PerformanceWiringText.reason(.uncheckable))
                    .foregroundStyle(.secondary)
            }
        case .failure(let refusal):
            Text("Destinations unavailable: \(PerformanceWiringText.failure(refusal))")
        }
        Button("Cancel") { pendingSource = nil }
    }

    private func destinations(_ source: PortAddress) -> Result<WiringDestinationList, WiringComposeRefusal> {
        do { return .success(try session.destinations(from: source)) } catch { return .failure(error) }
    }

    private func destinationRow(_ candidate: WiringCandidate, from source: PortAddress) -> some View {
        let title = PerformanceWiringText.portTitle(candidate.to, in: graph)
        let reason = PerformanceWiringText.reason(candidate.connection)
        return Button {
            let request = WiringConnectRequest(edge: EdgeID(uuid: UUID()), from: source, to: candidate.to)
            if edit({ try session.connect(request) }) { pendingSource = nil }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(reason).font(.caption)
            }
        }
        .disabled(!PerformanceWiringText.isSelectable(WiringDestinationClass(candidate.connection)))
        .accessibilityLabel("\(title). \(reason)")
    }

    // MARK: Nodes

    @ViewBuilder private var nodes: some View {
        Text(PerformanceWiringText.nodesHeading).font(.headline)
        Menu(PerformanceWiringText.addNode) {
            ForEach(session.project.roles) { role in
                Button(PerformanceWiringText.addNodeItem(role)) {
                    let label = PerformanceWiringText.nextLabel(for: role, in: graph)
                    _ = edit { try session.addRoleNode(role: role.id, id: NodeID(uuid: UUID()), label: label) }
                }
            }
        }
        .fixedSize()
        ForEach(graph.nodes, id: \.id) { node in
            let title = PerformanceWiringText.nodeTitle(node.id, in: graph)
            HStack {
                Text(title).accessibilityLabel(label(.node(node.id), fallback: title))
                Spacer()
                Button("Remove…") { _ = edit { pendingRemoval = try session.nodeRemovalPlan(node.id) } }
                    .accessibilityLabel("Remove \(title) from draft")
            }
        }
    }

    /// The inspector's accessible label (it says "draft, not active"), or `fallback` if it cannot be made.
    private func label(_ subject: WiringInspectorSubject, fallback: String) -> String {
        labels[subject] ?? fallback
    }
}
