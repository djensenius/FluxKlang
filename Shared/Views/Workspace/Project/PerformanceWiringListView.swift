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
        switch connectionList() {
        case .success(let list):
            if list.sections.isEmpty { Text(PerformanceWiringText.noConnections) }
            ForEach(list.sections, id: \.node) { section in connectionSection(section) }
        case .failure(let refusal):
            Text(PerformanceWiringText.connectionsUnavailable(refusal))
        }
    }

    private func connectionList() -> Result<WiringConnectionList, WiringConnectionListRefusal> {
        do { return .success(try session.connectionList()) } catch { return .failure(error) }
    }

    /// The model's heading (VoiceOver heading rotor), its "No connections" line when it has no rows, then its rows.
    @ViewBuilder
    private func connectionSection(_ section: WiringConnectionSection) -> some View {
        Text(section.heading)
            .font(.subheadline.bold())
            .accessibilityLabel(section.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
        if let empty = section.emptyText { Text(empty).foregroundStyle(.secondary) }
        ForEach(section.rows, id: \.self) { row in connectionRow(row) }
    }

    private func connectionRow(_ row: WiringConnectionRow) -> some View {
        let remove = { _ = edit { try session.removeConnection(row.edge) } }
        let removable = PerformanceWiringText.isRemovable(row.badge)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.text).strikethrough(row.badge.isStruckThrough)
                    if let badge = row.badge.text { Text(badge).font(.caption).foregroundStyle(.secondary) }
                }
                if let detail = row.detailText { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityActions {
                if removable { Button(PerformanceWiringText.removeFromDraft, action: remove) }
            }
            Spacer()
            if removable {
                Button("Remove", action: remove)
                    .accessibilityLabel(PerformanceWiringText.removeLabel(row))
            }
        }
    }

    // MARK: Add Connection

    @ViewBuilder private var addConnection: some View {
        if let source = session.liveSource(pendingSource) {
            destinationPicker(source)
        } else {
            switch sourceList() {
            case .success(let list):
                Menu(PerformanceWiringText.addConnection) {
                    ForEach(list.sections) { section in sourceSection(section) }
                }
                .disabled(list.rows.isEmpty)
                .fixedSize()
                if let empty = list.emptyText { Text(empty).foregroundStyle(.secondary) }
            case .failure(let refusal):
                Text(PerformanceWiringText.sourcesUnavailable(refusal))
            }
        }
    }

    private func sourceList() -> Result<WiringSourceList, WiringSourceListRefusal> {
        do { return .success(try session.sourceList()) } catch { return .failure(error) }
    }

    /// The model's heading over one button per output; an observed shortcut is one disabled entry.
    @ViewBuilder
    private func sourceSection(_ section: WiringSourceSection) -> some View {
        if section.isEnabled {
            Section(section.heading) {
                ForEach(section.rows) { row in
                    Button(PerformanceWiringText.sourceTitle(row)) { pendingSource = row.address }
                        .accessibilityLabel(row.accessibilityLabel)
                }
            }
        } else {
            Button(section.heading) {}
                .disabled(true)
                .accessibilityLabel(section.accessibilityLabel)
        }
    }

    @ViewBuilder
    private func destinationPicker(_ source: PortAddress) -> some View {
        let from = session.fromText(source) ?? PerformanceWiringText.portTitle(source, in: graph)
        Text(PerformanceWiringText.fromHeader(from)).font(.headline)
        Text(PerformanceWiringText.toHeading).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
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
