//
//  StudioCanvasView.swift
//  FluxKlang
//
//  Guided semantic patch canvas: Gear -> Controls. Gear can make sound, process
//  sound, or both; Controls are where a branch becomes playable.
//

import SwiftUI

// The canvas centralizes hit-testing so moved cards, hover help and connection
// drops stay in sync. Splitting that state across child views reintroduced stale
// hit areas after layout changes.
// swiftlint:disable:next type_body_length
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
    @State private var routeDrag: RouteDrag?
    @State private var dragOverrides: [StudioNode.ID: CGPoint] = [:]
    @State private var interaction: Interaction?
    @State private var hoverHint: HoverHint?

    private let cardSize = CGSize(width: 190, height: 76)
    private let gearWidth: CGFloat = 560
    private let controlsWidth: CGFloat = 280
    private let fixedCanvasHeight: CGFloat = 900
    private let topPadding: CGFloat = 84
    private let rowHeight: CGFloat = 100

    private struct RouteDrag {
        var from: StudioNode.ID
        var current: CGPoint
    }

    private struct HoverHint {
        var message: String
        var point: CGPoint
    }

    private enum Interaction {
        case moving(node: StudioNode.ID, start: CGPoint)
        case routing(node: StudioNode.ID)
        case tapping(start: CGPoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            canvas
            routeList
        }
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                laneBackgrounds
                wires
                ForEach(graph.nodes) { node in
                    StudioCanvasNodeCard(
                        node: node,
                        title: title(for: node),
                        subtitle: subtitle(for: node),
                        tint: tint(for: node),
                        canStartRoute: canStartRoute(node),
                        canReceiveRoute: canReceiveRoute(node),
                        isRoutingFrom: routingFrom == node.id || routeDrag?.from == node.id,
                        isRouteTarget: routingFrom != nil && routingFrom != node.id && canReceiveRoute(node)
                    )
                    .position(displayPosition(for: node))
                }
                interactionLayer
                hoverTip
            }
            .coordinateSpace(name: "studioCanvas")
            .frame(width: canvasWidth, height: canvasHeight)
        }
        .frame(height: viewportHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary)
        }
    }

    private var laneBackgrounds: some View {
        HStack(spacing: 0) {
            lane("Gear", "Anything that makes sound, takes sound in, or both", .blue, width: gearWidth)
            lane("Controls", "Where branches become playable", .purple, width: controlsWidth)
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
        .frame(width: width, height: canvasHeight, alignment: .topLeading)
        .background(color.opacity(0.06))
    }

    private var wires: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let start = graph.node(edge.from.nodeID),
                      let end = graph.node(edge.to.nodeID) else { continue }
                drawWire(
                    from: outputAnchor(for: start),
                    to: inputAnchor(for: end),
                    color: .accentColor.opacity(0.72),
                    context: context
                )
            }
            if let routeDrag, let start = graph.node(routeDrag.from) {
                drawWire(
                    from: outputAnchor(for: start),
                    to: routeDrag.current,
                    color: .green.opacity(0.78),
                    context: context
                )
            }
        }
    }

    @ViewBuilder
    private var interactionLayer: some View {
        let layer = Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("studioCanvas"))
                    .onChanged(handleInteractionChanged)
                    .onEnded(handleInteractionEnded)
            )
        #if os(macOS)
        layer.onContinuousHover(coordinateSpace: .named("studioCanvas")) { phase in
            switch phase {
            case .active(let point):
                hoverHint = hoverHint(at: point).map { HoverHint(message: $0, point: point) }
            case .ended:
                hoverHint = nil
            }
        }
        #else
        layer
        #endif
    }

    @ViewBuilder
    private var hoverTip: some View {
        if let hoverHint {
            Text(hoverHint.message)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .position(hoverTipPosition(for: hoverHint.point))
                .allowsHitTesting(false)
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
                        Spacer()
                        Button("Reroute") {
                            onRemoveEdge(edge.id)
                            routingFrom = edge.from.nodeID
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            onRemoveEdge(edge.id)
                        } label: {
                            Label("Remove", systemImage: "xmark")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var canvasWidth: CGFloat {
        gearWidth + controlsWidth
    }

    private var canvasHeight: CGFloat {
        fixedCanvasHeight
    }

    private var gearNodes: [StudioNode] {
        graph.nodes.filter { !isControl($0) }
    }

    private var controlNodes: [StudioNode] {
        graph.nodes.filter(isControl)
    }

    private func fallbackPosition(for node: StudioNode) -> CGPoint {
        if isControl(node) {
            let row = controlNodes.firstIndex(where: { $0.id == node.id }) ?? 0
            return CGPoint(x: gearWidth + controlsWidth / 2, y: topPadding + CGFloat(row) * rowHeight)
        }
        let row = gearNodes.firstIndex(where: { $0.id == node.id }) ?? 0
        let column = row % 2
        return CGPoint(
            x: 150 + CGFloat(column) * 230,
            y: topPadding + CGFloat(row / 2) * rowHeight
        )
    }

    private func displayPosition(for node: StudioNode) -> CGPoint {
        dragOverrides[node.id] ?? storedPosition(for: node)
    }

    private func storedPosition(for node: StudioNode) -> CGPoint {
        node.position == .zero ? fallbackPosition(for: node) : node.position
    }

    private func inputAnchor(for node: StudioNode) -> CGPoint {
        let center = displayPosition(for: node)
        return CGPoint(x: center.x - cardSize.width / 2, y: center.y)
    }

    private func outputAnchor(for node: StudioNode) -> CGPoint {
        let center = displayPosition(for: node)
        return CGPoint(x: center.x + cardSize.width / 2, y: center.y)
    }

    private func connect(to destination: StudioNode.ID) {
        guard let source = routingFrom, source != destination else { return }
        onConnect(source, destination)
        routingFrom = nil
    }

    private func finishRouteDrag(from source: StudioNode.ID, at point: CGPoint) {
        defer { routeDrag = nil }
        guard let hit = hitNode(at: point, excluding: source, receivingOnly: true) else { return }
        onConnect(source, hit.id)
    }

    private func move(_ nodeID: StudioNode.ID, from start: CGPoint, by translation: CGSize) {
        dragOverrides[nodeID] = clamp(CGPoint(
            x: start.x + translation.width,
            y: start.y + translation.height
        ))
    }

    private func commitMove(_ nodeID: StudioNode.ID, from start: CGPoint, by translation: CGSize) {
        let final = clamp(CGPoint(
            x: start.x + translation.width,
            y: start.y + translation.height
        ))
        dragOverrides[nodeID] = nil
        onMoveNode(nodeID, final)
    }

    private func handleInteractionChanged(_ value: DragGesture.Value) {
        hoverHint = nil
        if interaction == nil {
            interaction = interactionStarting(at: value.startLocation)
        }
        switch interaction {
        case .moving(let nodeID, let start):
            move(nodeID, from: start, by: value.translation)
        case .routing(let nodeID):
            routeDrag = RouteDrag(from: nodeID, current: value.location)
        case .tapping, .none:
            break
        }
    }

    private func handleInteractionEnded(_ value: DragGesture.Value) {
        defer {
            interaction = nil
            hoverHint = nil
        }
        switch interaction {
        case .moving(let nodeID, let start):
            commitMove(nodeID, from: start, by: value.translation)
        case .routing(let nodeID):
            finishRouteDrag(from: nodeID, at: value.location)
        case .tapping(let start):
            handleTap(start: start, end: value.location)
        case .none:
            break
        }
    }

    private func interactionStarting(at point: CGPoint) -> Interaction {
        if let node = graph.nodes.first(where: { moveHandleRect(for: $0).contains(point) }) {
            return .moving(node: node.id, start: storedPosition(for: node))
        }
        if let node = graph.nodes.first(where: { routeStartRect(for: $0).contains(point) && canStartRoute($0) }) {
            return .routing(node: node.id)
        }
        return .tapping(start: point)
    }

    private func hoverHint(at point: CGPoint) -> String? {
        guard interaction == nil else { return nil }
        if let node = graph.nodes.reversed().first(where: { removeButtonRect(for: $0).contains(point) }) {
            return "Remove \(title(for: node)) from this patch"
        }
        if let node = graph.nodes.reversed().first(where: { moveHandleRect(for: $0).contains(point) }) {
            return "Drag to move \(title(for: node))"
        }
        if let node = graph.nodes.reversed().first(where: {
            routeStartRect(for: $0).contains(point) && canStartRoute($0)
        }) {
            return "Drag from here to connect \(title(for: node))"
        }
        if let source = routingFrom,
           let destination = hitNode(at: point, excluding: source, receivingOnly: true) {
            return "Click to connect to \(title(for: destination))"
        }
        if let node = graph.nodes.reversed().first(where: {
            drawButtonRect(for: $0).contains(point) && canStartRoute($0)
        }) {
            return "Click, then click another card to connect \(title(for: node))"
        }
        if let node = hitNode(at: point, excluding: nil, receivingOnly: false) {
            return isControl(node)
                ? "Controls are where a branch becomes playable"
                : "Gear can make sound, process sound, or both"
        }
        return "Drag a dot to draw a connection"
    }

    private func hoverTipPosition(for point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x + 92, 90), canvasWidth - 110),
            y: min(max(point.y - 26, 24), canvasHeight - 24)
        )
    }

    private func handleTap(start: CGPoint, end: CGPoint) {
        guard distance(start, end) < 8 else { return }
        if let source = routingFrom {
            if let destination = hitNode(at: end, excluding: source, receivingOnly: true) {
                onConnect(source, destination.id)
                routingFrom = nil
            } else {
                routingFrom = nil
            }
            return
        }
        if let node = graph.nodes.first(where: { removeButtonRect(for: $0).contains(end) }) {
            onRemoveNode(node.id)
            return
        }
        if let node = graph.nodes.first(where: { drawButtonRect(for: $0).contains(end) && canStartRoute($0) }) {
            routingFrom = node.id
        }
    }

    private func hitNode(
        at point: CGPoint,
        excluding excluded: StudioNode.ID?,
        receivingOnly: Bool
    ) -> StudioNode? {
        graph.nodes.reversed().first { node in
            node.id != excluded &&
                (!receivingOnly || canReceiveRoute(node)) &&
                cardRect(for: node).insetBy(dx: -10, dy: -10).contains(point)
        }
    }

    private func cardRect(for node: StudioNode) -> CGRect {
        let center = displayPosition(for: node)
        return CGRect(
            x: center.x - cardSize.width / 2,
            y: center.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
    }

    private func moveHandleRect(for node: StudioNode) -> CGRect {
        let rect = cardRect(for: node)
        return CGRect(x: rect.maxX - 58, y: rect.minY + 6, width: 36, height: 36)
    }

    private func removeButtonRect(for node: StudioNode) -> CGRect {
        let rect = cardRect(for: node)
        return CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 34, height: 34)
    }

    private func routeStartRect(for node: StudioNode) -> CGRect {
        let rect = cardRect(for: node)
        return CGRect(x: rect.maxX - 28, y: rect.minY + 8, width: 38, height: 38)
    }

    private func drawButtonRect(for node: StudioNode) -> CGRect {
        let rect = cardRect(for: node)
        return CGRect(x: rect.minX + 8, y: rect.maxY - 30, width: 60, height: 26)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, cardSize.width / 2 + 12), canvasWidth - cardSize.width / 2 - 12),
            y: min(max(point.y, topPadding), canvasHeight - cardSize.height / 2 - 12)
        )
    }

    private func canStartRoute(_ node: StudioNode) -> Bool {
        !isControl(node)
    }

    private func canReceiveRoute(_ node: StudioNode) -> Bool {
        true
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

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
