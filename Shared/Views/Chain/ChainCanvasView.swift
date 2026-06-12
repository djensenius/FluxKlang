//
//  ChainCanvasView.swift
//  FluxKlang
//
//  The drag-and-drop signal-chain builder, and the way you build an environment.
//  The same pannable / zoomable canvas shows two layers: the persisted free-form
//  patchbay (user gear + raw WING endpoints wired output → input) and the
//  environment's effect overlay — instrument sources feeding effect nodes whose
//  returns land on Main. The overlay is derived from the environment's `[Effect]`
//  (see `EnvironmentChainCanvas`), so wiring it here and ticking boxes in the
//  Environments list edit the very same effects. Switching environments swaps the
//  whole canvas; Apply pushes the lot to the console.
//

import SwiftUI

struct ChainCanvasView: View {
    static let space = "chain"
    static let contentSize = CGSize(width: 2200, height: 1500)

    @Environment(AppModel.self) var appModel

    @State var selection: UUID?
    @State var wireDrag: WireDrag?
    @State var showLibrary = false
    @State var editingEffect: Effect?
    @State var pan: CGSize = .zero
    @State var zoom: CGFloat = 1
    @GestureState var livePan: CGSize = .zero
    @GestureState var liveZoom: CGFloat = 1
    @State var isApplying = false

    struct WireDrag {
        var from: ChainPortRef
        var current: CGPoint
    }

    // MARK: - Model

    /// The persisted free-form patchbay graph for the active environment.
    var graph: ChainGraph { appModel.environments.activeGraph }
    var equipment: [Equipment] { appModel.equipment.items }
    var effects: [Effect] { appModel.environments.activeEffects }
    var effectLayout: [String: CGPoint] { appModel.environments.activeEffectLayout }
    var assignments: [Equipment.ChannelAssignment] { Equipment.channelAssignments(from: equipment) }
    var allocations: [Effect.ID: EffectRouting.Allocation] { EffectRouting.allocations(for: effects) }

    /// The effect-overlay nodes derived from the environment's effects.
    var derivedNodes: [ChainNode] {
        EnvironmentChainCanvas.nodes(effects: effects, layout: effectLayout, equipment: equipment)
    }

    /// The effect-overlay wires derived from the environment's effects.
    var derivedEdges: [EnvironmentChainCanvas.DerivedEdge] {
        EnvironmentChainCanvas.edges(effects: effects, layout: effectLayout)
    }

    /// The free-form graph fused with the derived effect overlay, for rendering,
    /// hit-testing, and node lookups. Derived wires are added as plain edges so
    /// the wire layer draws them too; they aren't persisted.
    var combinedGraph: ChainGraph {
        ChainGraph(
            nodes: graph.nodes + derivedNodes,
            edges: graph.edges + derivedEdges.map { ChainEdge(from: $0.from, to: $0.to) }
        )
    }

    var body: some View {
        Group {
            if combinedGraph.nodes.isEmpty {
                emptyState
            } else {
                canvas
            }
        }
        .navigationTitle(title)
        #if os(macOS)
        .navigationSubtitle(subtitle)
        #endif
        .toolbar { toolbar }
        .sheet(isPresented: $showLibrary) {
            EquipmentLibraryView { kind, title in addNode(kind, title) }
                .environment(appModel)
        }
        .sheet(item: $editingEffect) { effect in
            EffectEditor(
                effect: effect,
                isNew: false,
                allEffects: effects,
                onSave: { appModel.environments.update($0) },
                onDelete: {
                    appModel.environments.remove(effect)
                    appModel.environments.removeEffectLayoutEntry(EnvironmentChainCanvas.effectKey(effect.id))
                }
            )
            .environment(appModel)
        }
    }

    /// The screen title — the active environment's name, so it's clear the canvas
    /// belongs to (and switches with) the current environment.
    var title: String {
        appModel.environments.active?.name ?? "Chain"
    }

    var subtitle: String {
        appModel.environments.active == nil ? "" : "Signal chain"
    }
}

// MARK: - Canvas content

private extension ChainCanvasView {
    var canvas: some View {
        // The content is a large fixed-size virtual canvas. Render it as a
        // clipped overlay on a flexible base so its size does not propagate to
        // the layout: otherwise, with `.windowResizability(.contentMinSize)`,
        // the Mac window's minimum size grows to the canvas size and balloons
        // past the screen.
        Color.gray.opacity(0.06)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(panGesture.simultaneously(with: zoomGesture))
            .onTapGesture { selection = nil }
            .overlay(alignment: .topLeading) {
                content
                    .scaleEffect(zoom * liveZoom, anchor: .topLeading)
                    .offset(x: pan.width + livePan.width, y: pan.height + livePan.height)
            }
            .clipped()
            .onScrollWheel { info in
                if info.commandKey {
                    zoom = min(max(zoom * (1 - info.deltaY * 0.005), 0.4), 2.5)
                } else {
                    pan.width += info.deltaX
                    pan.height += info.deltaY
                }
            }
            #if os(macOS)
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand(perform: deleteSelection)
            #endif
    }

    var content: some View {
        ZStack(alignment: .topLeading) {
            WireLayer(graph: combinedGraph, equipment: equipment, size: Self.contentSize, tempWire: tempWire)
            ForEach(graph.edges) { edge in
                if let mid = edgeMidpoint(edge.from, edge.to) {
                    WireDeleteButton { appModel.environments.removeChainEdge(edge.id) }
                        .position(mid)
                }
            }
            ForEach(derivedEdges) { edge in
                if edge.isDeletable, let mid = edgeMidpoint(edge.from, edge.to) {
                    WireDeleteButton { disconnect(edge) }
                        .position(mid)
                }
            }
            ForEach(combinedGraph.nodes) { node in
                NodeView(
                    node: node,
                    ports: ports(for: node),
                    isSelected: selection == node.id,
                    onDragEnded: { center in moveNode(node, to: center) },
                    onWireChanged: { ref, point in wireDrag = WireDrag(from: ref, current: point) },
                    onWireEnded: { ref, point in finishWire(ref, point) },
                    onSelect: { selectNode(node) },
                    onDelete: { deleteNode(node) }
                )
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    /// The display ports for a node: allocation-aware labels (bus, return, and
    /// channels) for the effect overlay, library ports for free-form gear.
    func ports(for node: ChainNode) -> ChainPorts {
        guard node.kind.isEffectDomain else {
            return ChainGeometry.ports(for: node, equipment: equipment)
        }
        return EnvironmentChainCanvas.ports(
            for: node.kind, effects: effects, allocations: allocations, assignments: assignments
        )
    }

    var tempWire: (from: CGPoint, to: CGPoint)? {
        guard let drag = wireDrag, let from = anchor(drag.from) else { return nil }
        return (from, drag.current)
    }

    var emptyState: some View {
        ContentUnavailableView {
            Label("Build Your Environment", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("""
            Add effects and the instruments that feed them, then wire instrument → effect → Main. \
            You can also drop raw WING endpoints for hand patching.
            """)
        } actions: {
            Button { showLibrary = true } label: {
                Label("Add Node", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle(title)
    }
}

// MARK: - Toolbar

private extension ChainCanvasView {
    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { showLibrary = true } label: {
                Label("Add Node", systemImage: "plus")
            }
            .help("Add an effect, an instrument, or a raw WING endpoint to the canvas")
        }
        ToolbarItem {
            Button(action: applyRouting) {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Apply Routing", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(!appModel.isConnected || appModel.activeEnvironmentSettings().isEmpty || isApplying)
            .help("Send this environment's effects and WING-touching connections to the console")
        }
        ToolbarItem {
            Button { resetView() } label: {
                Label("Reset View", systemImage: "arrow.counterclockwise")
            }
            .help("Reset pan and zoom")
        }
    }
}

// MARK: - Gestures & actions

private extension ChainCanvasView {
    var panGesture: some Gesture {
        DragGesture()
            .updating($livePan) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($liveZoom) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 0.4), 2.5)
            }
    }

    /// Resolves a dropped wire: an effect-overlay wire edits the effects, a
    /// free-form wire is patched into the graph, and anything else is dropped.
    func finishWire(_ ref: ChainPortRef, _ point: CGPoint) {
        defer { wireDrag = nil }
        let anchors = ChainGeometry.inputAnchors(in: combinedGraph, equipment: equipment)
        guard let hit = anchors.min(by: { distance($0.point, point) < distance($1.point, point) }),
              distance(hit.point, point) <= ChainGeometry.portHitRadius,
              let fromKind = combinedGraph.node(ref.nodeID)?.kind,
              let toKind = combinedGraph.node(hit.ref.nodeID)?.kind else { return }
        switch EnvironmentChainCanvas.connect(from: fromKind, to: toKind, effects: effects) {
        case .effects(let updated):
            appModel.environments.setActiveEffects(updated)
        case .notEffectEdge:
            appModel.environments.connectChain(from: ref, to: hit.ref)
        case .rejected:
            break
        }
    }

    /// Removes a derived overlay wire, mapping it back to an effect edit.
    func disconnect(_ edge: EnvironmentChainCanvas.DerivedEdge) {
        appModel.environments.setActiveEffects(EnvironmentChainCanvas.disconnect(edge.kind, effects: effects))
    }

    /// Moves a node, saving overlay positions to the environment's layout and
    /// free-form nodes to the graph.
    func moveNode(_ node: ChainNode, to center: CGPoint) {
        if let key = EnvironmentChainCanvas.layoutKey(for: node.kind) {
            appModel.environments.setEffectNodePosition(key, to: center)
        } else {
            appModel.environments.moveChainNode(node.id, to: center)
        }
    }

    /// Tapping an effect node opens its editor; other nodes just select.
    func selectNode(_ node: ChainNode) {
        if case .effect(let id) = node.kind, let effect = effects.first(where: { $0.id == id }) {
            editingEffect = effect
        } else {
            selection = node.id
        }
    }

    func addNode(_ kind: ChainNodeKind, _ title: String) {
        showLibrary = false
        switch kind {
        case .effect:
            let effect = Effect(name: title.isEmpty ? "Effect \(effects.count + 1)" : title)
            appModel.environments.add(effect)
            editingEffect = effect
        case .effectSource(let instrument):
            appModel.environments.addEffectSourceNode(instrument)
        case .effectMain:
            appModel.environments.setEffectNodePosition(
                EnvironmentChainCanvas.mainKey, to: EnvironmentChainCanvas.defaultMainPosition
            )
        default:
            let count = graph.nodes.count
            let position = CGPoint(
                x: 220 + CGFloat(count % 4) * 220,
                y: 160 + CGFloat(count / 4) * 170
            )
            appModel.environments.addChainNode(ChainNode(kind: kind, title: title, position: position))
        }
    }

    /// Removes a node: effects and instrument sources fold back into `[Effect]`;
    /// Main can't be removed; free-form nodes drop from the graph.
    func deleteNode(_ node: ChainNode) {
        switch node.kind {
        case .effectMain:
            return
        case .effect, .effectSource:
            appModel.environments.setActiveEffects(EnvironmentChainCanvas.removeNode(node.kind, effects: effects))
            if let key = EnvironmentChainCanvas.layoutKey(for: node.kind) {
                appModel.environments.removeEffectLayoutEntry(key)
            }
        default:
            appModel.environments.removeChainNode(node.id)
        }
        if selection == node.id { selection = nil }
    }

    func applyRouting() {
        isApplying = true
        Task {
            await appModel.applyActiveEnvironment()
            isApplying = false
        }
    }

    func resetView() {
        withAnimation {
            pan = .zero
            zoom = 1
        }
    }

    func deleteSelection() {
        guard let id = selection, let node = combinedGraph.node(id) else { return }
        deleteNode(node)
    }

    func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    /// The canvas-space anchor for a port, resolved against the combined graph.
    func anchor(_ ref: ChainPortRef) -> CGPoint? {
        guard let node = combinedGraph.node(ref.nodeID) else { return nil }
        let ports = ChainGeometry.ports(for: node, equipment: equipment)
        return ChainGeometry.anchor(
            node: node,
            side: ref.side,
            port: ref.port,
            inputs: ports.inputs.count,
            outputs: ports.outputs.count
        )
    }

    /// The midpoint of a wire's bezier between two ports. The curve is symmetric
    /// (its x control offsets cancel), so the t = 0.5 point is exactly the average
    /// of the endpoints — a stable spot for the delete button.
    func edgeMidpoint(_ from: ChainPortRef, _ to: ChainPortRef) -> CGPoint? {
        guard let start = anchor(from), let end = anchor(to) else { return nil }
        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }
}

/// A small button that sits on a wire's midpoint to delete that connection.
private struct WireDeleteButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.red)
                .background(Circle().fill(.white).padding(3))
                .opacity(hovering ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Delete this connection")
        .accessibilityLabel("Delete connection")
        .accessibilityHint("Removes this wire between the two ports")
    }
}

#Preview {
    NavigationStack { ChainCanvasView() }
        .environment(AppModel.preview())
}
