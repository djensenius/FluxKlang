//
//  StudioCanvasView.swift
//  FluxKlang
//
//  Guided semantic patch canvas: Gear -> Controls.
//

import SwiftUI

struct StudioCanvasView: View {
    let graph: StudioGraph
    let endpoints: [StudioEndpoint]
    let equipment: [Equipment]
    let effects: [Effect]
    let onConnect: (StudioNode.ID, StudioNode.ID) -> Void
    let onRemoveEdge: (StudioEdge.ID) -> Void
    let onRemoveNode: (StudioNode.ID) -> Void
    let onMoveNode: (StudioNode.ID, CGPoint) -> Void
    var viewportHeight: CGFloat = 560

    @State private var routingFrom: StudioNode.ID?
    @State private var retainedBounds: CGRect?
    @GestureState private var nodeMove: NodeMove?
    @GestureState private var routeDrag: RouteDrag?

    private struct NodeMove {
        var nodeID: StudioNode.ID
        var start: CGPoint
        var position: CGPoint
        var geometry: StudioCanvasGeometry
    }

    private struct RouteDrag {
        var from: StudioNode.ID
        var current: CGPoint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            canvas
            routeList
        }
        .onChange(of: geometry.worldBounds, initial: true) { _, bounds in
            // Never shrink a mounted canvas: removing a far node or resetting a
            // gesture must not clamp the scroll offset or shift its world origin.
            retainedBounds = bounds
        }
        .onChange(of: graph.nodes.map(\.id)) { _, nodeIDs in
            if let routingFrom, !nodeIDs.contains(routingFrom) {
                self.routingFrom = nil
            }
        }
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                // A background tap can cancel routing, but never owns a pan.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { routingFrom = nil }
                laneBackgrounds
                    .allowsHitTesting(false)
                wires
                    .allowsHitTesting(false)
                ForEach(graph.nodes) { node in
                    StudioCanvasNodeCard(
                        node: node,
                        title: title(for: node),
                        subtitle: subtitle(for: node),
                        tint: tint(for: node),
                        canStartRoute: canStartRoute(node),
                        isRoutingFrom: routingFrom == node.id || routeDrag?.from == node.id,
                        isRouteTarget: routingFrom != nil && routingFrom != node.id,
                        remove: { remove(node) },
                        route: { routeAction(for: node) },
                        moveGesture: moveGesture(for: node),
                        routeGesture: routeGesture(for: node)
                    )
                    .position(geometry.contentPoint(fromWorld: displayPosition(for: node)))
                }
            }
            .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
            .coordinateSpace(name: "studioCanvas")
        }
        .frame(height: viewportHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("studio.canvas")
    }

    private var geometry: StudioCanvasGeometry {
        StudioCanvasGeometry(positions: graph.nodes.map(displayPosition), retaining: retainedBounds)
    }

    private var laneBackgrounds: some View {
        HStack(spacing: 0) {
            lane(
                "Gear", "Anything that makes sound, takes sound in, or both", .blue,
                width: StudioCanvasGeometry.gearWidth - geometry.worldBounds.minX
            )
            lane(
                "Controls", "Where branches become playable", .purple,
                width: geometry.worldBounds.maxX - StudioCanvasGeometry.gearWidth
            )
        }
    }

    private func lane(_ title: String, _ subtitle: String, _ color: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(width: width, height: geometry.contentSize.height, alignment: .topLeading)
        .background(color.opacity(0.06))
    }

    private var wires: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let start = graph.node(edge.from.nodeID),
                      let end = graph.node(edge.to.nodeID) else { continue }
                drawWire(
                    from: geometry.outputAnchor(center: displayPosition(for: start)),
                    to: geometry.inputAnchor(center: displayPosition(for: end)),
                    color: .accentColor.opacity(0.72),
                    context: context
                )
            }
            if let routeDrag, let start = graph.node(routeDrag.from) {
                drawWire(
                    from: geometry.outputAnchor(center: displayPosition(for: start)),
                    to: routeDrag.current,
                    color: .green.opacity(0.78),
                    context: context
                )
            }
        }
    }

    private func drawWire(from startPoint: CGPoint, to endPoint: CGPoint, color: Color, context: GraphicsContext) {
        var path = Path()
        path.move(to: startPoint)
        let controlOffset = max(abs(endPoint.x - startPoint.x) * 0.45, 70)
        path.addCurve(
            to: endPoint,
            control1: CGPoint(x: startPoint.x + controlOffset, y: startPoint.y),
            control2: CGPoint(x: endPoint.x - controlOffset, y: endPoint.y)
        )
        context.stroke(path, with: .color(color), lineWidth: 3)
    }

    private var routeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connections")
                .font(.headline)
            if graph.edges.isEmpty {
                Text("Drag from a gear card’s output dot to a card, or tap Draw then Here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(graph.edges) { edge in
                    HStack {
                        Text(edgeLabel(edge))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Reroute") {
                            onRemoveEdge(edge.id)
                            routingFrom = edge.from.nodeID
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            onRemoveEdge(edge.id)
                        } label: {
                            Image(systemName: "xmark")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Remove connection \(edgeLabel(edge))")
                        .buttonStyle(.bordered)
                    }
                    .accessibilityIdentifier("studio.edge.\(edge.id)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func storedPosition(for node: StudioNode) -> CGPoint {
        guard node.position == .zero else { return node.position }
        let peers = graph.nodes.filter { isControl($0) == isControl(node) }
        let index = peers.firstIndex { $0.id == node.id } ?? 0
        return isControl(node)
            ? StudioCanvasGeometry.controlPosition(at: index)
            : StudioCanvasGeometry.gearPosition(at: index)
    }

    private func displayPosition(for node: StudioNode) -> CGPoint {
        if let nodeMove, nodeMove.nodeID == node.id { return nodeMove.position }
        return storedPosition(for: node)
    }

    private func moveGesture(for node: StudioNode) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("studioCanvas"))
                .updating($nodeMove) { value, state, _ in
                    let start = state?.start ?? storedPosition(for: node)
                    let startingGeometry = state?.geometry ?? geometry
                    state = NodeMove(
                        nodeID: node.id,
                        start: start,
                        position: startingGeometry.movedPosition(from: start, translation: value.translation),
                        geometry: startingGeometry
                    )
                }
                .onEnded { value in
                    let start = nodeMove?.start ?? storedPosition(for: node)
                    let startingGeometry = nodeMove?.geometry ?? geometry
                    let final = startingGeometry.movedPosition(from: start, translation: value.translation)
                    // The store is updated synchronously before GestureState resets.
                    // Cancellation simply discards the transient position.
                    onMoveNode(node.id, final)
                }
        )
    }

    private func routeGesture(for node: StudioNode) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("studioCanvas"))
                .updating($routeDrag) { value, state, _ in
                    state = RouteDrag(from: node.id, current: value.location)
                }
                .onEnded { value in
                    routingFrom = nil
                    guard let destination = hitNode(at: value.location, excluding: node.id) else { return }
                    onConnect(node.id, destination.id)
                }
        )
    }

    private func routeAction(for node: StudioNode) {
        if routingFrom == node.id {
            routingFrom = nil
        } else if let source = routingFrom {
            onConnect(source, node.id)
            routingFrom = nil
        } else if canStartRoute(node) {
            routingFrom = node.id
        }
    }

    private func remove(_ node: StudioNode) {
        if routingFrom == node.id { routingFrom = nil }
        onRemoveNode(node.id)
    }

    private func hitNode(at point: CGPoint, excluding excluded: StudioNode.ID) -> StudioNode? {
        // Reverse drawing order so the visually topmost overlapping card wins.
        graph.nodes.reversed().first {
            $0.id != excluded && geometry.contentCardRect(center: displayPosition(for: $0)).contains(point)
        }
    }

    private func canStartRoute(_ node: StudioNode) -> Bool {
        !isControl(node)
    }

    private func isControl(_ node: StudioNode) -> Bool {
        if case .endpoint = node.kind { return true }
        return false
    }

    private func title(for node: StudioNode) -> String {
        switch node.kind {
        case .instrument(let id):
            return equipment.first { $0.id == id }?.name ?? node.title
        case .effect(let id):
            return effects.first { $0.id == id }?.name ?? node.title
        case .endpoint(let id):
            return endpoints.first { $0.id == id }?.name ?? node.title
        }
    }

    private func subtitle(for node: StudioNode) -> String {
        switch node.kind {
        case .instrument(let id):
            return equipment.first { $0.id == id }?.inputs.isEmpty == false ? "gear · in/out" : "gear · output"
        case .effect:
            return "gear · in/out"
        case .endpoint(let id):
            return endpoints.first { $0.id == id }?.destination.label ?? "control"
        }
    }

    private func tint(for node: StudioNode) -> Color {
        switch node.kind {
        case .instrument: return .blue
        case .effect: return .teal
        case .endpoint(let id):
            return endpoints.first { $0.id == id }.map { Theme.color(for: $0.destination) } ?? .purple
        }
    }

    private func edgeLabel(_ edge: StudioEdge) -> String {
        let start = graph.node(edge.from.nodeID).map(title) ?? "Missing"
        let end = graph.node(edge.to.nodeID).map(title) ?? "Missing"
        return "\(start) -> \(end)"
    }
}
