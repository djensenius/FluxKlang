//
//  StudioCanvasNodeCard.swift
//  FluxKlang
//

import SwiftUI

struct StudioCanvasNodeCard: View {
    let node: StudioNode
    let title: String
    let subtitle: String
    let tint: Color
    let canStartRoute: Bool
    let isRoutingFrom: Bool
    let isRouteTarget: Bool
    let remove: () -> Void
    let route: () -> Void
    let moveGesture: AnyGesture<DragGesture.Value>
    let routeGesture: AnyGesture<DragGesture.Value>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture {
                if isRouteTarget { route() }
            }
            HStack(spacing: 0) {
                removeButton
                routeButton
                    .frame(maxWidth: .infinity)
                moveHandle
                routeDot
            }
        }
        .padding(StudioCanvasGeometry.cardPadding)
        .frame(width: StudioCanvasGeometry.cardSize.width, height: StudioCanvasGeometry.cardSize.height)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: isRoutingFrom || isRouteTarget ? 2.5 : 1)
                .allowsHitTesting(false)
        }
        .shadow(radius: 2, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.node.\(node.id)")
    }

    private var removeButton: some View {
        Button(role: .destructive, action: remove) {
            Image(systemName: "xmark.circle.fill")
                .frame(width: StudioCanvasGeometry.controlSize, height: StudioCanvasGeometry.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) from patch")
        .accessibilityIdentifier("studio.node.\(node.id).remove")
        .help("Remove from patch")
    }

    @ViewBuilder
    private var routeButton: some View {
        if isRoutingFrom || isRouteTarget || canStartRoute {
            Button(action: route) {
                Text(isRoutingFrom ? "Cancel" : isRouteTarget ? "Here" : "Draw")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(minWidth: StudioCanvasGeometry.controlSize, minHeight: StudioCanvasGeometry.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isRouteTarget ? Color.green : Color.accentColor)
            .accessibilityLabel(isRoutingFrom ? "Cancel connection" : isRouteTarget
                ? "Connect to \(title)" : "Draw connection from \(title)")
            .accessibilityIdentifier("studio.node.\(node.id).route")
        } else {
            Color.clear
                .frame(width: StudioCanvasGeometry.controlSize, height: StudioCanvasGeometry.controlSize)
                .accessibilityHidden(true)
        }
    }

    private var moveHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .foregroundStyle(.secondary)
            .frame(width: StudioCanvasGeometry.controlSize, height: StudioCanvasGeometry.controlSize)
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .accessibilityLabel("Move \(title)")
            .accessibilityIdentifier("studio.node.\(node.id).move")
            .help("Drag to move this card")
    }

    @ViewBuilder
    private var routeDot: some View {
        if canStartRoute {
            Button(action: route) {
                Circle()
                    .fill(tint)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .frame(width: StudioCanvasGeometry.controlSize, height: StudioCanvasGeometry.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gesture(routeGesture)
            .accessibilityLabel("Output of \(title)")
            .accessibilityHint("Drag to a card, or tap then choose a connection target")
            .accessibilityIdentifier("studio.node.\(node.id).output")
            .help("Drag to draw a connection")
        } else {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(tint)
                .frame(width: StudioCanvasGeometry.controlSize, height: StudioCanvasGeometry.controlSize)
                .accessibilityHidden(true)
        }
    }

    private var borderColor: Color {
        if isRoutingFrom { return .accentColor }
        if isRouteTarget { return .green }
        return tint.opacity(0.45)
    }
}
