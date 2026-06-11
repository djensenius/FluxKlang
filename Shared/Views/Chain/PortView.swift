//
//  PortView.swift
//  FluxKlang
//
//  A single connection point on a node. Output ports start wire drags; input
//  ports are drop targets. The label is drawn by the node alongside the dot.
//

import SwiftUI

struct PortView: View {
    let side: ChainPortSide
    var isActive = false

    var body: some View {
        Circle()
            .fill(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
            .contentShape(Circle().inset(by: -ChainGeometry.portHitRadius / 2))
    }
}

#Preview {
    HStack(spacing: 24) {
        PortView(side: .input)
        PortView(side: .output, isActive: true)
    }
    .padding()
}
