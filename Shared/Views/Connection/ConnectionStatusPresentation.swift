//
//  ConnectionStatusPresentation.swift
//  FluxKlang
//

import SwiftUI

extension WingConnectionState {
    var statusTitle: String {
        if case .failed = self {
            return "Connection failed"
        }
        return statusLabel
    }

    func statusTint(isDemo: Bool) -> Color {
        switch self {
        case .connected:
            return isDemo ? .orange : .green
        case .connecting:
            return .blue
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }
}
