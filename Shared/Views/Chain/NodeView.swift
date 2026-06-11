//
//  NodeView.swift
//  FluxKlang
//
//  A draggable card on the chain canvas. Shows a coloured header and its input
//  ports (left) and output ports (right). Dragging the body moves the node;
//  dragging from an output port starts a wire.
//

import SwiftUI

struct NodeView: View {
    let node: ChainNode
    let ports: ChainPorts
    let isSelected: Bool

    /// Called when the node drag ends (commit the new centre).
    var onDragEnded: (CGPoint) -> Void
    /// Wire drag from an output port, in "chain" coordinates.
    var onWireChanged: (ChainPortRef, CGPoint) -> Void
    var onWireEnded: (ChainPortRef, CGPoint) -> Void
    var onSelect: () -> Void
    var onDelete: () -> Void

    @GestureState private var dragOffset: CGSize = .zero

    private var size: CGSize {
        ChainGeometry.size(inputs: ports.inputs.count, outputs: ports.outputs.count)
    }

    private var tint: Color { Theme.color(for: node.kind) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
            header
            portDots
        }
        .frame(width: size.width, height: size.height)
        .position(currentCenter)
        .gesture(moveGesture)
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Node", systemImage: "trash")
            }
        }
    }

    private var currentCenter: CGPoint {
        CGPoint(x: node.position.x + dragOffset.width, y: node.position.y + dragOffset.height)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.background)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : tint.opacity(0.5), lineWidth: isSelected ? 2.5 : 1.5)
            )
            .shadow(radius: 3, y: 1)
    }

    private var header: some View {
        Text(node.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: size.width, height: ChainGeometry.headerHeight, alignment: .leading)
            .background(tint.opacity(0.85), in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
            .foregroundStyle(.white)
    }

    private var portDots: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ports.inputs.indices, id: \.self) { index in
                portRow(side: .input, index: index, label: ports.inputs[index])
            }
            ForEach(ports.outputs.indices, id: \.self) { index in
                portRow(side: .output, index: index, label: ports.outputs[index])
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func portRow(side: ChainPortSide, index: Int, label: String) -> some View {
        let count = side == .input ? ports.inputs.count : ports.outputs.count
        let usable = size.height - ChainGeometry.headerHeight - ChainGeometry.footerPadding
        let localY = ChainGeometry.headerHeight + usable * (CGFloat(index) + 0.5) / CGFloat(max(count, 1))
        let localX: CGFloat = side == .input ? 0 : size.width

        return ZStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: size.width - 28, alignment: side == .input ? .leading : .trailing)
                .position(x: size.width / 2 + (side == .input ? 6 : -6), y: localY)
            portDot(side: side, index: index)
                .position(x: localX, y: localY)
        }
    }

    @ViewBuilder
    private func portDot(side: ChainPortSide, index: Int) -> some View {
        if side == .output {
            PortView(side: .output)
                .gesture(wireGesture(port: index))
        } else {
            PortView(side: .input)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named(ChainCanvasView.space))
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let center = CGPoint(
                    x: node.position.x + value.translation.width,
                    y: node.position.y + value.translation.height
                )
                onDragEnded(center)
            }
    }

    private func wireGesture(port: Int) -> some Gesture {
        let ref = ChainPortRef(nodeID: node.id, side: .output, port: port)
        return DragGesture(coordinateSpace: .named(ChainCanvasView.space))
            .onChanged { value in onWireChanged(ref, value.location) }
            .onEnded { value in onWireEnded(ref, value.location) }
    }
}
