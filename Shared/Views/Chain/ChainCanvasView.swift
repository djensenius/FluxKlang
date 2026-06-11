//
//  ChainCanvasView.swift
//  FluxKlang
//
//  The drag-and-drop signal-chain builder. Nodes (user gear + WING endpoints) are
//  placed on a pannable / zoomable canvas and wired output → input. The graph is
//  persisted, and the WING-touching wires can be applied as real routing.
//

import SwiftUI

struct ChainCanvasView: View {
    static let space = "chain"
    private static let contentSize = CGSize(width: 2200, height: 1500)

    @Environment(AppModel.self) private var appModel

    @State private var selection: UUID?
    @State private var wireDrag: WireDrag?
    @State private var showLibrary = false
    @State private var pan: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @GestureState private var livePan: CGSize = .zero
    @GestureState private var liveZoom: CGFloat = 1
    @State private var isApplying = false

    private struct WireDrag {
        var from: ChainPortRef
        var current: CGPoint
    }

    private var graph: ChainGraph { appModel.chain.graph }
    private var equipment: [Equipment] { appModel.equipment.items }

    var body: some View {
        Group {
            if graph.nodes.isEmpty {
                emptyState
            } else {
                canvas
            }
        }
        .navigationTitle("Chain")
        .toolbar { toolbar }
        .sheet(isPresented: $showLibrary) {
            EquipmentLibraryView { kind, title in addNode(kind, title) }
                .environment(appModel)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            Color.gray.opacity(0.06)
                .contentShape(Rectangle())
                .gesture(panGesture.simultaneously(with: zoomGesture))
                .onTapGesture { selection = nil }
            content
                .scaleEffect(zoom * liveZoom)
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

    private var content: some View {
        ZStack(alignment: .topLeading) {
            WireLayer(graph: graph, equipment: equipment, size: Self.contentSize, tempWire: tempWire)
            ForEach(graph.nodes) { node in
                NodeView(
                    node: node,
                    ports: ChainGeometry.ports(for: node, equipment: equipment),
                    isSelected: selection == node.id,
                    onDragEnded: { center in appModel.chain.moveNode(node.id, to: center) },
                    onWireChanged: { ref, point in wireDrag = WireDrag(from: ref, current: point) },
                    onWireEnded: { ref, point in finishWire(ref, point) },
                    onSelect: { selection = node.id },
                    onDelete: { appModel.chain.removeNode(node.id) }
                )
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    private var tempWire: (from: CGPoint, to: CGPoint)? {
        guard let drag = wireDrag, let node = graph.node(drag.from.nodeID) else { return nil }
        let ports = ChainGeometry.ports(for: node, equipment: equipment)
        let from = ChainGeometry.anchor(
            node: node,
            side: .output,
            port: drag.from.port,
            inputs: ports.inputs.count,
            outputs: ports.outputs.count
        )
        return (from, drag.current)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { showLibrary = true } label: {
                Label("Add Node", systemImage: "plus")
            }
            .help("Add gear or a WING endpoint to the canvas")
        }
        ToolbarItem {
            Button(action: applyRouting) {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Apply Routing", systemImage: "bolt.horizontal.circle")
                }
            }
            .disabled(!appModel.isConnected || appModel.chain.wingSettings().isEmpty || isApplying)
            .help("Send the WING-touching connections to the console")
        }
        ToolbarItem {
            Button { resetView() } label: {
                Label("Reset View", systemImage: "arrow.counterclockwise")
            }
            .help("Reset pan and zoom")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Build a Signal Chain", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Add your gear and WING endpoints, then drag from an output to an input to wire them up.")
        } actions: {
            Button { showLibrary = true } label: {
                Label("Add Node", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Chain")
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .updating($livePan) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($liveZoom) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 0.4), 2.5)
            }
    }

    // MARK: - Actions

    private func finishWire(_ ref: ChainPortRef, _ point: CGPoint) {
        defer { wireDrag = nil }
        let anchors = ChainGeometry.inputAnchors(in: graph, equipment: equipment)
        guard let hit = anchors.min(by: { distance($0.point, point) < distance($1.point, point) }),
              distance(hit.point, point) <= ChainGeometry.portHitRadius else { return }
        appModel.chain.connect(from: ref, to: hit.ref)
    }

    private func addNode(_ kind: ChainNodeKind, _ title: String) {
        let count = graph.nodes.count
        let position = CGPoint(
            x: 220 + CGFloat(count % 4) * 220,
            y: 160 + CGFloat(count / 4) * 170
        )
        appModel.chain.addNode(ChainNode(kind: kind, title: title, position: position))
        showLibrary = false
    }

    private func applyRouting() {
        isApplying = true
        Task {
            await appModel.applyChainRouting()
            isApplying = false
        }
    }

    private func resetView() {
        withAnimation {
            pan = .zero
            zoom = 1
        }
    }

    private func deleteSelection() {
        guard let id = selection else { return }
        appModel.chain.removeNode(id)
        selection = nil
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

#Preview {
    NavigationStack { ChainCanvasView() }
        .environment(AppModel.preview())
}
