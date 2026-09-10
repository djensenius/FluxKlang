//
//  StudioView.swift
//  FluxKlang
//
//  The first user-facing slice of the redesigned studio workflow. It exposes the
//  semantic model — gear, custom controls/stems, Space and Final Mix —
//  without asking the user to think in WING buses/channels.
//

import CoreGraphics
import SwiftUI

struct StudioView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isApplying = false

    private var store: EnvironmentStore { appModel.environments }
    private var graph: StudioGraph { store.activeStudioGraph }
    private var endpoints: [StudioEndpoint] { store.activeStudioEndpoints }
    private var effects: [Effect] { store.activeEffects }
    private var compiled: StudioCompiledRouting { appModel.studioCompiledRouting() }
    private var routingPlan: StudioRoutingPlan { compiled.routingPlan }
    private var resourcePlan: StudioResourcePlan { compiled.resourcePlan }
    private var issues: [StudioIssueText] {
        routingPlan.issues.map(StudioIssueText.routing)
            + resourcePlan.issues.map(StudioIssueText.resource)
            + compiled.issues.map(StudioIssueText.compile)
    }

    var body: some View {
        content
            .navigationTitle("Studio")
            .toolbar { toolbar }
            .sheet(isPresented: reviewPresented) {
                if let draft = appModel.assistant.pendingStudioDraft {
                    PendingStudioPatchReviewView(
                        draft: draft,
                        accept: acceptPendingDraft,
                        discard: discardPendingDraft
                    )
                    .task {
                        _ = await appModel.assistant.perform(
                            .validatePendingStudioDraft,
                            context: appModel.assistantToolContext()
                        )
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macStudioLayout
        #else
        compactStudioLayout
        #endif
    }

    private var compactStudioLayout: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                startSection
                pendingDraftSection
                graphSection
                endpointsSection
                warningsSection
                behindTheScenesSection
            }
            .padding()
        }
    }

    #if os(macOS)
    private var macStudioLayout: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if graph.nodes.isEmpty {
                        emptyPatchState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        canvasView(viewportHeight: max(520, geometry.size.height - 40))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        startSection
                        pendingDraftSection
                        endpointsSection
                        warningsSection
                        behindTheScenesSection
                    }
                    .padding()
                }
                .frame(width: 330)
                .background(.regularMaterial)
            }
        }
    }
    #endif

    private var startSection: some View {
        StudioSection("Start") {
            StudioStatusCard(
                title: statusTitle,
                detail: statusDetail,
                systemImage: issues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: issues.isEmpty ? .green : .orange
            )
            .accessibilityIdentifier("studio.status")
        } footer: {
            Text("""
            FluxKlang keeps the mixer details out of the way. You describe the sound path; it handles the mixer.
            """)
        }
    }

    private var graphSection: some View {
        StudioSection("Patch") {
            if graph.nodes.isEmpty {
                emptyPatchState
            } else {
                canvasView()
                canvasActions
            }
        } footer: {
            Text("A patch is simply: gear anywhere on the left, playable controls on the right.")
        }
    }

    private var emptyPatchState: some View {
        ContentUnavailableView {
            Label("Make Your First Patch", systemImage: "wand.and.stars")
        } description: {
            Text("Start with one piece of gear going to a dry control and a space control.")
        } actions: {
            Button { seedStarterSketch() } label: {
                Label(
                    "Start with \(appModel.equipment.items.first?.name ?? "Instrument")",
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.equipment.items.isEmpty)
        }
    }

    private func canvasView(viewportHeight: CGFloat = 560) -> some View {
        StudioCanvasView(
            graph: graph,
            endpoints: endpoints,
            equipment: appModel.equipment.items,
            effects: effects,
            onConnect: connect,
            onRemoveEdge: removeEdge,
            onRemoveNode: removeNode,
            onMoveNode: moveNode,
            viewportHeight: viewportHeight
        )
    }

    private var canvasActions: some View {
        HStack {
            addGearMenu
            newGearButton
            addControlMenu
            StudioConnectNodesMenu(graph: graph, title: nodeTitle, connect: connect)
        }
        .buttonStyle(.bordered)
    }

    private var addGearMenu: some View {
        Menu {
            ForEach(appModel.equipment.items) { item in
                Button(item.name) { addGear(item) }
            }
            if !effects.isEmpty {
                Divider()
                ForEach(effects) { effect in
                    Button(effect.name) { addGear(effect) }
                }
            }
        } label: {
            Label("Add Gear", systemImage: "square.stack.3d.up")
        }
    }

    private var newGearButton: some View {
        Button { addBlankGear() } label: {
            Label("New Gear", systemImage: "plus.square")
        }
    }

    private var addControlMenu: some View {
        Menu {
            Button("Mix Control") { addEndpoint(.finalMix) }
            Button("Space Control") { addEndpoint(.space) }
        } label: {
            Label("Add Control", systemImage: "slider.vertical.3")
        }
    }

    private var endpointsSection: some View {
        StudioSection("Controls") {
            if endpoints.isEmpty {
                Text("Controls are the faders you actually want to touch: dry sound, processed branches, or space.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(endpoints) { endpoint in
                    StudioEndpointCard(
                        endpoint: endpoint,
                        allocation: allocation(for: endpoint),
                        speakers: appModel.spatial.array.speakers,
                        setPlacement: { store.setStudioEndpointPlacement(endpoint.id, to: $0) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !issues.isEmpty {
            StudioSection("Needs Attention") {
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: issue.systemImage)
                        .foregroundStyle(issue.tint)
                }
            } footer: {
                Text("You can leave unfinished ideas on the patch. FluxKlang only applies parts that can make sound.")
            }
        }
    }

    private var behindTheScenesSection: some View {
        StudioSection("Behind the Scenes") {
            DisclosureGroup("What FluxKlang will do to the mixer") {
                if resourcePlan.allocations.isEmpty {
                    Text("Nothing yet. Create a patch first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(resourcePlan.allocations) { allocation in
                        LabeledContent(allocation.endpoint.name) {
                            Text(allocation.controlNode.defaultLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Home connection map") {
                    let effective = appModel.studioConnections.connections.effectiveHome
                    if effective.isEmpty {
                        Text("No Home connections configured in Settings.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(effective.inputs.sorted(using: KeyPathComparator(\.connector))) { connection in
                            Text(effective.inputDisplayName(
                                connection.connector,
                                equipment: appModel.equipment.items,
                                liveScribble: appModel.wing.inputName(connection.connector)
                            ))
                        }
                        ForEach(effective.outputs.sorted(using: KeyPathComparator(\.connector))) { connection in
                            Text(effective.outputDisplayName(
                                connection.connector,
                                equipment: appModel.equipment.items
                            ))
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            addGearMenu
            newGearButton
            addControlMenu
        }
        #endif
        ToolbarItem {
            Button {
                appModel.assistantChat.suggestedPrompt = "Explain this Studio patch and any conflicts."
                appModel.section = .assistant
            } label: {
                Label("Ask about this patch", systemImage: "sparkles")
            }
            .accessibilityIdentifier("assistant.askAboutPatch")
        }
        ToolbarItem {
            Button(action: applyStudioPatch) {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Listen", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(!appModel.isConnected || compiled.settings.isEmpty || compiled.hasErrors || isApplying)
            .accessibilityIdentifier("studio.listen")
        }
    }

    private func allocation(for endpoint: StudioEndpoint) -> StudioEndpointAllocation? {
        resourcePlan.allocations.first { $0.endpoint.id == endpoint.id }
    }

    private func seedStarterSketch() {
        guard let first = appModel.equipment.items.first else { return }
        let instrument = StudioNode(
            kind: .instrument(first.id),
            title: first.name,
            position: CGPoint(x: 150, y: 170)
        )
        let dry = StudioEndpoint(name: "\(first.name) Dry", destination: .finalMix, colorName: "blue")
        let space = StudioEndpoint(
            name: "\(first.name) Space",
            destination: .space,
            colorName: "purple",
            placement: VoicePlacement()
        )
        let dryNode = StudioNode(kind: .endpoint(dry.id), title: dry.name, position: CGPoint(x: 700, y: 130))
        let spaceNode = StudioNode(kind: .endpoint(space.id), title: space.name, position: CGPoint(x: 700, y: 250))
        var sketch = StudioGraph(nodes: [instrument, dryNode, spaceNode])
        sketch.connect(from: output(instrument), to: input(dryNode))
        sketch.connect(from: output(instrument), to: input(spaceNode))
        store.replaceStudio(graph: sketch, endpoints: [dry, space])
    }

    private func addEndpoint(_ destination: StudioEndpointDestination) {
        let number = endpoints.filter { $0.destination == destination }.count + 1
        let name = destination == .space ? "Space Control \(number)" : "Mix Control \(number)"
        let endpoint = StudioEndpoint(
            name: name,
            destination: destination,
            placement: destination == .space ? VoicePlacement() : nil
        )
        store.addStudioEndpointNode(
            endpoint,
            position: CGPoint(x: 700, y: 120 + CGFloat(endpoints.count) * 100)
        )
    }

    private func addGear(_ equipment: Equipment) {
        guard !graph.nodes.contains(where: { $0.kind == .instrument(equipment.id) }) else { return }
        store.addStudioNode(StudioNode(
            kind: .instrument(equipment.id),
            title: equipment.name,
            position: nextGearPosition()
        ))
    }

    private func addGear(_ effect: Effect) {
        guard !graph.nodes.contains(where: { $0.kind == .effect(effect.id) }) else { return }
        store.addStudioNode(StudioNode(
            kind: .effect(effect.id),
            title: effect.name,
            position: nextGearPosition()
        ))
    }

    private func addBlankGear() {
        let effect = Effect(name: "Gear \(effects.count + 1)")
        store.add(effect)
        store.addStudioNode(StudioNode(kind: .effect(effect.id), title: effect.name, position: nextGearPosition()))
    }

    private func connect(from source: StudioNode.ID, to destination: StudioNode.ID) {
        store.connectStudio(
            from: StudioPortRef(nodeID: source, side: .output, port: 0),
            to: StudioPortRef(nodeID: destination, side: .input, port: 0)
        )
    }

    private func removeEdge(_ id: StudioEdge.ID) {
        store.removeStudioEdge(id)
    }

    private func removeNode(_ id: StudioNode.ID) {
        store.removeStudioNode(id)
    }

    private func moveNode(_ id: StudioNode.ID, to position: CGPoint) {
        store.moveStudioNode(id, to: position)
    }

    private func nextGearPosition() -> CGPoint {
        let gearCount = graph.nodes.filter { node in
            if case .endpoint = node.kind { return false }
            return true
        }.count
        return CGPoint(x: 150 + CGFloat(gearCount % 2) * 230, y: 150 + CGFloat(gearCount / 2) * 110)
    }

    private func output(_ node: StudioNode) -> StudioPortRef {
        StudioPortRef(nodeID: node.id, side: .output, port: 0)
    }

    private func input(_ node: StudioNode) -> StudioPortRef {
        StudioPortRef(nodeID: node.id, side: .input, port: 0)
    }

    private func nodeTitle(_ node: StudioNode) -> String {
        switch node.kind {
        case .instrument(let id):
            return appModel.equipment.items.first { $0.id == id }?.name ?? node.title
        case .effect(let id):
            return effects.first { $0.id == id }?.name ?? node.title
        case .endpoint(let id):
            return endpoints.first { $0.id == id }?.name ?? node.title
        }
    }

    private func applyStudioPatch() {
        isApplying = true
        Task {
            await appModel.applyStudio()
            isApplying = false
        }
    }

    private var statusTitle: String {
        if graph.nodes.isEmpty { return "Ready to make a patch" }
        if issues.isEmpty { return "Ready to listen" }
        return "Some parts need attention"
    }

    private var statusDetail: String {
        if graph.nodes.isEmpty {
            return "Pick a sound, give it a dry control, give it a space control, then explore."
        }
        if issues.isEmpty {
            let connections = appModel.studioConnections.connections.effectiveHome
            return "\(endpoints.count) controls · \(connections.inputs.count + connections.outputs.count) connections"
        }
        return "\(issues.count) note\(issues.count == 1 ? "" : "s") before everything can play"
    }
}

private extension StudioView {
    @ViewBuilder
    var pendingDraftSection: some View {
        if let draft = appModel.assistant.pendingStudioDraft {
            StudioSection("Assistant Draft") {
                PendingStudioPatchCard(
                    draft: draft,
                    review: { appModel.assistant.navigationTarget = .reviewPendingDraft },
                    discard: discardPendingDraft
                )
            } footer: {
                Text("Review is local-only. Accept adds semantic routing; Listen remains a separate action.")
            }
        }
    }

    var reviewPresented: Binding<Bool> {
        Binding(
            get: { appModel.assistant.navigationTarget == .reviewPendingDraft },
            set: { isPresented in
                if !isPresented {
                    appModel.assistant.clearNavigation()
                }
            }
        )
    }

    func acceptPendingDraft() {
        Task {
            _ = await appModel.acceptPendingAssistantDraft()
        }
    }

    func discardPendingDraft() {
        Task {
            await appModel.assistant.discardPendingStudioDraft()
        }
    }
}

#Preview {
    NavigationStack { StudioView() }
        .environment(AppModel.preview())
}
