//
//  Theme.swift
//  FluxKlang
//
//  Central colours so strips, routing and chain nodes share one visual language
//  for the different WING node kinds.
//

import SwiftUI

enum Theme {
    /// Accent colour for a WING strip kind.
    static func color(for kind: WingNodeKind) -> Color {
        switch kind {
        case .channel: return .blue
        case .aux: return .teal
        case .bus: return .orange
        case .main: return .red
        case .matrix: return .purple
        case .dca: return .green
        }
    }

    /// Accent colour for a chain node.
    static func color(for kind: ChainNodeKind) -> Color {
        switch kind {
        case .equipment: return .gray
        case .wingInput: return .indigo
        case .wingChannel: return .blue
        case .wingBus: return .orange
        case .wingMain: return .red
        case .wingOutput: return .green
        }
    }
}
