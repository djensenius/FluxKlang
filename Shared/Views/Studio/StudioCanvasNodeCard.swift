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
    let canReceiveRoute: Bool
    let isRoutingFrom: Bool
    let isRouteTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                removeIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                moveHandle
                routeDot
            }
            controls
        }
        .padding(10)
        .frame(width: 190, height: 76, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: isRoutingFrom || isRouteTarget ? 2.5 : 1)
        }
        .shadow(radius: 2, y: 1)
    }

    private var removeIcon: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.trailing, 2)
            .help("Remove from patch")
    }

    private var moveHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .help("Drag to move this card")
    }

    @ViewBuilder
    private var routeDot: some View {
        if canStartRoute {
            Circle()
                .fill(tint)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                .help("Drag to draw a connection")
        } else {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isRoutingFrom {
            Text("tap empty space to cancel")
                .font(.caption2.weight(.semibold))
        } else if isRouteTarget {
            Text("Here")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        } else if canStartRoute {
            Text("Draw")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else if canReceiveRoute {
            Text("control")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var borderColor: Color {
        if isRoutingFrom { return .accentColor }
        if isRouteTarget { return .green }
        return tint.opacity(0.45)
    }
}
