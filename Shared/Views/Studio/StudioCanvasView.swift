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

    @ScaledMetric(relativeTo: .subheadline) private var nodeWidth = StudioCanvasGeometry.cardSize.width
    @ScaledMetric(relativeTo: .subheadline) private var nodeHeight = StudioCanvasGeometry.cardSize.height
    @ScaledMetric(relativeTo: .subheadline) private var scaledControlSize = StudioCanvasGeometry.controlSize
    @State private var routingFrom: StudioNode.ID?
    @State private var retainedBounds: CGRect?
    @GestureState private var nodeMove: NodeMove?
    @GestureState private var routeDrag: RouteDrag?

    private struct NodeMove {
        var nodeID: StudioNode.ID
        var position: CGPoint
        var geometry: StudioCanvasGeometry
    }

    private struct RouteDrag {
        var from: StudioNode.ID
        var current: CGPoint
    }

    var body: some View {
        let positions = layoutPositions
        let geometry = StudioCanvasGeometry(
            positions: graph.nodes.map { displayPosition(for: $0, positions: positions) },
            retaining: retainedBounds,
            cardSize: nodeSize, controlSize: controlSize
        )
        VStack(alignment: .leading, spacing: 12) {
            canvas(positions: positions, geometry: geometry)
            if graph.nodes.contains(where: { $0.position != .zero && positions[$0.id] != $0.position }) {
                Text("Overlapping cards are separated for display. Only cards you move are saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func canvas(positions: [StudioNode.ID: CGPoint], geometry: StudioCanvasGeometry) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                // A background tap can cancel routing, but never owns a pan.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { routingFrom = nil }
                laneBackgrounds(geometry: geometry)
                    .allowsHitTesting(false)
                wires(positions: positions, geometry: geometry)
                    .allowsHitTesting(false)
                ForEach(graph.nodes) { node in
                    StudioCanvasNodeCard(
                        node: node,
                        cardSize: nodeSize,
                        controlSize: controlSize,
                        title: title(for: node),
                        subtitle: subtitle(for: node),
                        tint: tint(for: node),
                        canStartRoute: canStartRoute(node),
                        isRoutingFrom: routingFrom == node.id || routeDrag?.from == node.id,
                        isRouteTarget: routingFrom != nil && routingFrom != node.id,
                        remove: { remove(node) },
                        route: { routeAction(for: node) },
                        moveGesture: moveGesture(
                            for: node, start: positions[node.id] ?? node.position, geometry: geometry
                        ),
                        routeGesture: routeGesture(for: node, positions: positions, geometry: geometry)
                    )
                    .position(geometry.contentPoint(fromWorld: displayPosition(for: node, positions: positions)))
                }
            }
            .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
            .coordinateSpace(name: "studioCanvas")
        }
        .defaultScrollAnchor(.topLeading)
        .frame(height: viewportHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("studio.canvas")
    }

    private var nodeSize: CGSize {
        CGSize(
            width: max(nodeWidth, StudioCanvasGeometry.cardSize.width),
            height: max(nodeHeight, StudioCanvasGeometry.cardSize.height)
        )
    }

    private var controlSize: CGFloat { max(scaledControlSize, StudioCanvasGeometry.controlSize) }

    private var layoutPositions: [StudioNode.ID: CGPoint] {
        let placements = graph.nodes.map {
            StudioCanvasGeometry.Placement(position: $0.position, lane: isControl($0) ? .controls : .gear)
        }
        let positions = StudioCanvasGeometry.layoutPositions(for: placements, cardSize: nodeSize)
        return Dictionary(zip(graph.nodes.map(\.id), positions), uniquingKeysWith: { first, _ in first })
    }

    private func laneBackgrounds(geometry: StudioCanvasGeometry) -> some View {
        HStack(spacing: 0) {
            lane(
                "Gear", "Anything that makes sound, takes sound in, or both", .blue,
                width: StudioCanvasGeometry.gearWidth - geometry.worldBounds.minX,
                height: geometry.contentSize.height
            )
            lane(
                "Controls", "Where branches become playable", .purple,
                width: geometry.worldBounds.maxX - StudioCanvasGeometry.gearWidth,
                height: geometry.contentSize.height
            )
        }
    }

    private func lane(
        _ title: String, _ subtitle: String, _ color: Color, width: CGFloat, height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(width: width, height: height, alignment: .topLeading)
        .background(color.opacity(0.06))
    }

    private func wires(positions: [StudioNode.ID: CGPoint], geometry: StudioCanvasGeometry) -> some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let start = graph.node(edge.from.nodeID),
                      let end = graph.node(edge.to.nodeID) else { continue }
                drawWire(
                    from: geometry.outputAnchor(center: displayPosition(for: start, positions: positions)),
                    to: geometry.inputAnchor(center: displayPosition(for: end, positions: positions)),
                    color: .accentColor.opacity(0.72),
                    context: context
                )
            }
            if let routeDrag, let start = graph.node(routeDrag.from) {
                drawWire(
                    from: geometry.outputAnchor(center: displayPosition(for: start, positions: positions)),
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

    private func displayPosition(for node: StudioNode, positions: [StudioNode.ID: CGPoint]) -> CGPoint {
        if let nodeMove, nodeMove.nodeID == node.id { return nodeMove.position }
        return positions[node.id] ?? node.position
    }

    private func moveGesture(
        for node: StudioNode, start: CGPoint, geometry: StudioCanvasGeometry
    ) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("studioCanvas"))
                .updating($nodeMove) { value, state, _ in
                    let startingGeometry = state?.geometry ?? geometry
                    state = NodeMove(
                        nodeID: node.id,
                        position: startingGeometry.movedPosition(from: start, translation: value.translation),
                        geometry: startingGeometry
                    )
                }
                .onEnded { value in
                    let startingGeometry = nodeMove?.geometry ?? geometry
                    let final = startingGeometry.movedPosition(from: start, translation: value.translation)
                    // `start` is the render-layout baseline, not GestureState.
                    // Only an explicit completed move persists this one node.
                    onMoveNode(node.id, final)
                }
        )
    }

    private func routeGesture(
        for node: StudioNode, positions: [StudioNode.ID: CGPoint], geometry: StudioCanvasGeometry
    ) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("studioCanvas"))
                .updating($routeDrag) { value, state, _ in
                    state = RouteDrag(from: node.id, current: value.location)
                }
                .onEnded { value in
                    routingFrom = nil
                    guard let destination = hitNode(
                        at: value.location, excluding: node.id, positions: positions, geometry: geometry
                    ) else { return }
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

    private func hitNode(
        at point: CGPoint, excluding excluded: StudioNode.ID,
        positions: [StudioNode.ID: CGPoint], geometry: StudioCanvasGeometry
    ) -> StudioNode? {
        graph.nodes.reversed().first {
            $0.id != excluded && geometry.contentCardRect(
                center: displayPosition(for: $0, positions: positions)
            ).contains(point)
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
